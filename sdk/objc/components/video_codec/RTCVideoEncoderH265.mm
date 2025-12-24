/*
 *  Copyright (c) 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCVideoEncoderH265.h"

#import <VideoToolbox/VideoToolbox.h>
#include <vector>

#if defined(WEBRTC_IOS)
#import "helpers/UIDevice+RTCDevice.h"
#endif
#import "base/RTCCodecSpecificInfo.h"
#import "base/RTCI420Buffer.h"
#import "base/RTCVideoEncoder.h"
#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"
#import "helpers.h"

#include "common_video/h265/h265_bitstream_parser.h"
#include "common_video/include/bitrate_adjuster.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/buffer.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"
#include "sdk/objc/components/video_codec/nalu_rewriter.h"
#include "third_party/libyuv/include/libyuv/convert_from.h"

@interface RTC_OBJC_TYPE (RTCVideoEncoderH265)
()

    - (void)frameWasEncoded : (OSStatus)status flags : (VTEncodeInfoFlags)infoFlags sampleBuffer
    : (CMSampleBufferRef)sampleBuffer codecSpecificInfo
    : (id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo width : (int32_t)width height
    : (int32_t)height renderTimeMs : (int64_t)renderTimeMs timestamp : (uint32_t)timestamp rotation
    : (RTCVideoRotation)rotation;

@end

namespace {  // anonymous namespace

// The ratio between kVTCompressionPropertyKey_DataRateLimits and
// kVTCompressionPropertyKey_AverageBitRate. The data rate limit is set higher
// than the average bit rate to avoid undershooting the target.
const float kLimitToAverageBitRateFactor = 1.5f;
// These thresholds deviate from the default h265 QP thresholds, as they
// have been found to work better on devices that support VideoToolbox
const int kLowH265QpThreshold = 28;
const int kHighH265QpThreshold = 39;

const OSType kNV12PixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;

// Struct that we pass to the encoder per frame to encode. We receive it again
// in the encoder callback.
struct RTCFrameEncodeParams {
  RTCFrameEncodeParams(RTC_OBJC_TYPE(RTCVideoEncoderH265) * e,
                       id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)> csi,
                       int32_t w,
                       int32_t h,
                       int64_t rtms,
                       uint32_t ts,
                       RTCVideoRotation r)
      : encoder(e), width(w), height(h), render_time_ms(rtms), timestamp(ts), rotation(r) {
    codecSpecificInfo = csi;
  }

  RTC_OBJC_TYPE(RTCVideoEncoderH265) * encoder;
  id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)> codecSpecificInfo;
  int32_t width;
  int32_t height;
  int64_t render_time_ms;
  uint32_t timestamp;
  RTCVideoRotation rotation;
};

// We receive I420Frames as input, but we need to feed CVPixelBuffers into the
// encoder. This performs the copy and format conversion.
bool CopyVideoFrameToNV12PixelBuffer(id<RTC_OBJC_TYPE(RTCI420Buffer)> frameBuffer,
                                     CVPixelBufferRef pixelBuffer) {
  RTC_DCHECK(pixelBuffer);
  RTC_DCHECK_EQ(CVPixelBufferGetPixelFormatType(pixelBuffer), kNV12PixelFormat);
  RTC_DCHECK_EQ(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), frameBuffer.height);
  RTC_DCHECK_EQ(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0), frameBuffer.width);

  CVReturn cvRet = CVPixelBufferLockBaseAddress(pixelBuffer, 0);
  if (cvRet != kCVReturnSuccess) {
    RTC_LOG(LS_ERROR) << "Failed to lock base address: " << cvRet;
    return false;
  }
  uint8_t *dstY = reinterpret_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0));
  int dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0);
  uint8_t *dstUV = reinterpret_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1));
  int dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1);
  // Convert I420 to NV12.
  int ret = libyuv::I420ToNV12(frameBuffer.dataY,
                               frameBuffer.strideY,
                               frameBuffer.dataU,
                               frameBuffer.strideU,
                               frameBuffer.dataV,
                               frameBuffer.strideV,
                               dstY,
                               dstStrideY,
                               dstUV,
                               dstStrideUV,
                               frameBuffer.width,
                               frameBuffer.height);
  CVPixelBufferUnlockBaseAddress(pixelBuffer, 0);
  if (ret) {
    RTC_LOG(LS_ERROR) << "Error converting I420 VideoFrame to NV12 :" << ret;
    return false;
  }
  return true;
}

CVPixelBufferRef CreatePixelBuffer(VTCompressionSessionRef compression_session) {
  if (!compression_session) {
    RTC_LOG(LS_ERROR) << "Failed to get compression session.";
    return nullptr;
  }
  CVPixelBufferPoolRef pixel_buffer_pool =
      VTCompressionSessionGetPixelBufferPool(compression_session);

  if (!pixel_buffer_pool) {
    RTC_LOG(LS_ERROR) << "Failed to get pixel buffer pool.";
    return nullptr;
  }
  CVPixelBufferRef pixel_buffer;
  CVReturn ret = CVPixelBufferPoolCreatePixelBuffer(nullptr, pixel_buffer_pool, &pixel_buffer);
  if (ret != kCVReturnSuccess) {
    RTC_LOG(LS_ERROR) << "Failed to create pixel buffer: " << ret;
    return nullptr;
  }
  return pixel_buffer;
}

// This is the callback function that VideoToolbox calls when encode is
// complete. From inspection this happens on its own queue.
void compressionOutputCallback(void *encoder,
                               void *params,
                               OSStatus status,
                               VTEncodeInfoFlags infoFlags,
                               CMSampleBufferRef sampleBuffer) {
  if (!params) {
    // If there are pending callbacks when the encoder is destroyed, this can happen.
    return;
  }
  std::unique_ptr<RTCFrameEncodeParams> encodeParams(
      reinterpret_cast<RTCFrameEncodeParams *>(params));
  [encodeParams->encoder frameWasEncoded:status
                                   flags:infoFlags
                            sampleBuffer:sampleBuffer
                       codecSpecificInfo:encodeParams->codecSpecificInfo
                                   width:encodeParams->width
                                  height:encodeParams->height
                            renderTimeMs:encodeParams->render_time_ms
                               timestamp:encodeParams->timestamp
                                rotation:encodeParams->rotation];
}

// Extract VideoToolbox profile out of the codec info.
// For H.265/HEVC, we use Main profile with AutoLevel.
CFStringRef ExtractProfile() {
  return kVTProfileLevel_HEVC_Main_AutoLevel;
}

// Converts H.265 sample buffer from AVCC format to Annex B format.
// Similar to H.264 conversion but for HEVC NAL units.
bool H265CMSampleBufferToAnnexBBuffer(CMSampleBufferRef avcc_sample_buffer,
                                      bool is_keyframe,
                                      rtc::Buffer* annexb_buffer) {
  RTC_DCHECK(avcc_sample_buffer);

  // Get the data buffer reference from the sample buffer.
  CMBlockBufferRef block_buffer = CMSampleBufferGetDataBuffer(avcc_sample_buffer);
  if (!block_buffer) {
    RTC_LOG(LS_ERROR) << "Failed to get block buffer from sample buffer.";
    return false;
  }

  // Get a contiguous data pointer.
  size_t block_buffer_size = CMBlockBufferGetDataLength(block_buffer);
  if (block_buffer_size == 0) {
    RTC_LOG(LS_ERROR) << "Block buffer size is 0.";
    return false;
  }

  uint8_t* block_buffer_data = nullptr;
  OSStatus status = CMBlockBufferGetDataPointer(block_buffer,
                                                0,
                                                nullptr,
                                                nullptr,
                                                (char**)&block_buffer_data);
  if (status != kCMBlockBufferNoErr) {
    RTC_LOG(LS_ERROR) << "Failed to get data pointer from block buffer: " << status;
    return false;
  }

  // If this is a keyframe, we also need to extract VPS/SPS/PPS from the format description.
  if (is_keyframe) {
    CMFormatDescriptionRef format = CMSampleBufferGetFormatDescription(avcc_sample_buffer);
    if (!format) {
      RTC_LOG(LS_ERROR) << "Failed to get format description from sample buffer.";
      return false;
    }

    // Get parameter sets from format description
    // For HEVC, we need VPS, SPS, and PPS
    size_t param_set_count = 0;
    status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,
                                                                 0,
                                                                 nullptr,
                                                                 nullptr,
                                                                 &param_set_count,
                                                                 nullptr);

    // Write parameter sets (VPS/SPS/PPS) first for keyframes
    for (size_t i = 0; i < param_set_count; i++) {
      const uint8_t* param_set = nullptr;
      size_t param_set_size = 0;
      status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format,
                                                                   i,
                                                                   &param_set,
                                                                   &param_set_size,
                                                                   nullptr,
                                                                   nullptr);
      if (status == noErr && param_set && param_set_size > 0) {
        // Write start code
        static const uint8_t kAnnexBHeaderBytes[4] = {0, 0, 0, 1};
        annexb_buffer->AppendData(kAnnexBHeaderBytes, sizeof(kAnnexBHeaderBytes));
        // Write parameter set
        annexb_buffer->AppendData(param_set, param_set_size);
      }
    }
  }

  // Convert AVCC format to Annex B format
  // AVCC: [length(4 bytes)][NALU data]...
  // Annex B: [0 0 0 1][NALU data]...
  size_t offset = 0;
  static const uint8_t kAnnexBHeaderBytes[4] = {0, 0, 0, 1};

  while (offset < block_buffer_size) {
    // Read NALU length (4 bytes in network byte order)
    if (offset + 4 > block_buffer_size) {
      RTC_LOG(LS_ERROR) << "Insufficient data for NALU length.";
      return false;
    }

    uint32_t nalu_length = (block_buffer_data[offset] << 24) |
                          (block_buffer_data[offset + 1] << 16) |
                          (block_buffer_data[offset + 2] << 8) |
                          block_buffer_data[offset + 3];
    offset += 4;

    if (offset + nalu_length > block_buffer_size) {
      RTC_LOG(LS_ERROR) << "NALU length exceeds buffer size.";
      return false;
    }

    // Write Annex B start code
    annexb_buffer->AppendData(kAnnexBHeaderBytes, sizeof(kAnnexBHeaderBytes));
    // Write NALU data
    annexb_buffer->AppendData(block_buffer_data + offset, nalu_length);

    offset += nalu_length;
  }

  return true;
}

}  // namespace

@implementation RTC_OBJC_TYPE (RTCVideoEncoderH265) {
  RTC_OBJC_TYPE(RTCVideoCodecInfo) * _codecInfo;
  std::unique_ptr<webrtc::BitrateAdjuster> _bitrateAdjuster;
  uint32_t _targetBitrateBps;
  uint32_t _encoderBitrateBps;
  uint32_t _encoderFrameRate;
  RTCVideoEncoderCallback _callback;
  int32_t _width;
  int32_t _height;
  VTCompressionSessionRef _compressionSession;
  RTCVideoCodecMode _mode;

  webrtc::H265BitstreamParser _h265BitstreamParser;
  std::vector<uint8_t> _frameScaleBuffer;
}

- (instancetype)initWithCodecInfo:(RTC_OBJC_TYPE(RTCVideoCodecInfo) *)codecInfo {
  if (self = [super init]) {
    _codecInfo = codecInfo;
    _bitrateAdjuster.reset(new webrtc::BitrateAdjuster(.5, .95));
    RTC_LOG(LS_INFO) << "Using H.265/HEVC encoder with VideoToolbox";
  }
  return self;
}

- (void)dealloc {
  [self destroyCompressionSession];
}

- (NSInteger)startEncodeWithSettings:(RTC_OBJC_TYPE(RTCVideoEncoderSettings) *)settings
                       numberOfCores:(int)numberOfCores {
  RTC_DCHECK(settings);

  _width = settings.width;
  _height = settings.height;
  _mode = settings.mode;

  // We can only set average bitrate on the HW encoder.
  _targetBitrateBps = settings.startBitrate * 1000;  // startBitrate is in kbps.
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  _encoderFrameRate = settings.maxFramerate;

  return [self resetCompressionSessionWithPixelFormat:kNV12PixelFormat];
}

- (NSInteger)encode:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame
    codecSpecificInfo:(nullable id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo
           frameTypes:(NSArray<NSNumber *> *)frameTypes {
  if (!_callback || !_compressionSession) {
    return WEBRTC_VIDEO_CODEC_UNINITIALIZED;
  }
  BOOL isKeyframeRequired = NO;

  // Get a pixel buffer from the pool and copy frame data over.
  if ([self resetCompressionSessionIfNeededWithFrame:frame]) {
    isKeyframeRequired = YES;
  }

  CVPixelBufferRef pixelBuffer = nullptr;
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    // Native frame buffer
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *rtcPixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    if (![rtcPixelBuffer requiresCropping]) {
      pixelBuffer = rtcPixelBuffer.pixelBuffer;
      CVBufferRetain(pixelBuffer);
    } else {
      // Cropping required
      pixelBuffer = CreatePixelBuffer(_compressionSession);
      if (!pixelBuffer) {
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
      int dstWidth = CVPixelBufferGetWidth(pixelBuffer);
      int dstHeight = CVPixelBufferGetHeight(pixelBuffer);
      if ([rtcPixelBuffer requiresScalingToWidth:dstWidth height:dstHeight]) {
        int size =
            [rtcPixelBuffer bufferSizeForCroppingAndScalingToWidth:dstWidth height:dstHeight];
        _frameScaleBuffer.resize(size);
      } else {
        _frameScaleBuffer.clear();
      }
      _frameScaleBuffer.shrink_to_fit();
      if (![rtcPixelBuffer cropAndScaleTo:pixelBuffer withTempBuffer:_frameScaleBuffer.data()]) {
        CVBufferRelease(pixelBuffer);
        return WEBRTC_VIDEO_CODEC_ERROR;
      }
    }
  }

  if (!pixelBuffer) {
    // We did not have a native frame buffer
    RTC_DCHECK_EQ(frame.width, _width);
    RTC_DCHECK_EQ(frame.height, _height);

    pixelBuffer = CreatePixelBuffer(_compressionSession);
    if (!pixelBuffer) {
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
    RTC_DCHECK(pixelBuffer);
    if (!CopyVideoFrameToNV12PixelBuffer([frame.buffer toI420], pixelBuffer)) {
      RTC_LOG(LS_ERROR) << "Failed to copy frame data.";
      CVBufferRelease(pixelBuffer);
      return WEBRTC_VIDEO_CODEC_ERROR;
    }
  }

  // Check if we need a keyframe.
  if (!isKeyframeRequired && frameTypes) {
    for (NSNumber *frameType in frameTypes) {
      if ((RTCFrameType)frameType.intValue == RTCFrameTypeVideoFrameKey) {
        isKeyframeRequired = YES;
        break;
      }
    }
  }

  CMTime presentationTimeStamp = CMTimeMake(frame.timeStampNs / rtc::kNumNanosecsPerMillisec, 1000);
  CFDictionaryRef frameProperties = nullptr;
  if (isKeyframeRequired) {
    CFTypeRef keys[] = {kVTEncodeFrameOptionKey_ForceKeyFrame};
    CFTypeRef values[] = {kCFBooleanTrue};
    frameProperties = CreateCFTypeDictionary(keys, values, 1);
  }

  std::unique_ptr<RTCFrameEncodeParams> encodeParams;
  encodeParams.reset(new RTCFrameEncodeParams(self,
                                              codecSpecificInfo,
                                              _width,
                                              _height,
                                              frame.timeStampNs / rtc::kNumNanosecsPerMillisec,
                                              frame.timeStamp,
                                              frame.rotation));

  // Update the bitrate if needed.
  [self setBitrateBps:_bitrateAdjuster->GetAdjustedBitrateBps() frameRate:_encoderFrameRate];

  OSStatus status = VTCompressionSessionEncodeFrame(_compressionSession,
                                                    pixelBuffer,
                                                    presentationTimeStamp,
                                                    kCMTimeInvalid,
                                                    frameProperties,
                                                    encodeParams.release(),
                                                    nullptr);
  if (frameProperties) {
    CFRelease(frameProperties);
  }
  if (pixelBuffer) {
    CVBufferRelease(pixelBuffer);
  }

  if (status == kVTInvalidSessionErr) {
    RTC_LOG(LS_ERROR) << "Invalid compression session, resetting.";
    [self resetCompressionSessionWithPixelFormat:[self pixelFormatOfFrame:frame]];
    return WEBRTC_VIDEO_CODEC_NO_OUTPUT;
  } else if (status == kVTVideoEncoderMalfunctionErr) {
    RTC_LOG(LS_ERROR) << "Encountered video encoder malfunction error. Resetting compression session.";
    [self resetCompressionSessionWithPixelFormat:[self pixelFormatOfFrame:frame]];
    return WEBRTC_VIDEO_CODEC_NO_OUTPUT;
  } else if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to encode frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoEncoderCallback)callback {
  _callback = callback;
}

- (int)setBitrate:(uint32_t)bitrateKbit framerate:(uint32_t)framerate {
  _targetBitrateBps = 1000 * bitrateKbit;
  _bitrateAdjuster->SetTargetBitrateBps(_targetBitrateBps);
  [self setBitrateBps:_bitrateAdjuster->GetAdjustedBitrateBps() frameRate:framerate];
  return WEBRTC_VIDEO_CODEC_OK;
}

- (NSInteger)resolutionAlignment {
  return 1;
}

- (BOOL)applyAlignmentToAllSimulcastLayers {
  return NO;
}

- (BOOL)supportsNativeHandle {
  return YES;
}

#pragma mark - Private

- (NSInteger)releaseEncoder {
  [self destroyCompressionSession];
  _callback = nullptr;
  return WEBRTC_VIDEO_CODEC_OK;
}

- (OSType)pixelFormatOfFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  if ([frame.buffer isKindOfClass:[RTC_OBJC_TYPE(RTCCVPixelBuffer) class]]) {
    RTC_OBJC_TYPE(RTCCVPixelBuffer) *rtcPixelBuffer =
        (RTC_OBJC_TYPE(RTCCVPixelBuffer) *)frame.buffer;
    return CVPixelBufferGetPixelFormatType(rtcPixelBuffer.pixelBuffer);
  }
  return kNV12PixelFormat;
}

- (BOOL)resetCompressionSessionIfNeededWithFrame:(RTC_OBJC_TYPE(RTCVideoFrame) *)frame {
  BOOL resetCompressionSession = NO;

  OSType framePixelFormat = [self pixelFormatOfFrame:frame];

  if (_compressionSession) {
    CVPixelBufferPoolRef pixelBufferPool =
        VTCompressionSessionGetPixelBufferPool(_compressionSession);
    if (!pixelBufferPool) {
      return NO;
    }

    NSDictionary *poolAttributes =
        (__bridge NSDictionary *)CVPixelBufferPoolGetPixelBufferAttributes(pixelBufferPool);
    id pixelFormats =
        [poolAttributes objectForKey:(__bridge NSString *)kCVPixelBufferPixelFormatTypeKey];
    NSArray<NSNumber *> *compressionSessionPixelFormats = nil;
    if ([pixelFormats isKindOfClass:[NSArray class]]) {
      compressionSessionPixelFormats = (NSArray *)pixelFormats;
    } else if ([pixelFormats isKindOfClass:[NSNumber class]]) {
      compressionSessionPixelFormats = @[ (NSNumber *)pixelFormats ];
    }

    if (![compressionSessionPixelFormats
            containsObject:[NSNumber numberWithLong:framePixelFormat]]) {
      resetCompressionSession = YES;
      RTC_LOG(LS_INFO) << "Resetting compression session due to non-matching pixel format.";
    }
  } else {
    resetCompressionSession = YES;
  }

  if (resetCompressionSession) {
    [self resetCompressionSessionWithPixelFormat:framePixelFormat];
  }
  return resetCompressionSession;
}

- (int)resetCompressionSessionWithPixelFormat:(OSType)framePixelFormat {
  [self destroyCompressionSession];

  NSDictionary *sourceAttributes = @{
#if defined(WEBRTC_IOS) && (TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR)
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @(YES),
#elif defined(WEBRTC_IOS)
    (NSString *)kCVPixelBufferOpenGLESCompatibilityKey : @(YES),
#elif defined(WEBRTC_MAC) && !defined(WEBRTC_ARCH_ARM64)
    (NSString *)kCVPixelBufferOpenGLCompatibilityKey : @(YES),
#endif
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (NSString *)kCVPixelBufferPixelFormatTypeKey : @(framePixelFormat),
  };

  NSDictionary *encoder_specs;
#if defined(WEBRTC_MAC) && !defined(WEBRTC_IOS)
  encoder_specs = @{
    (NSString *)kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder : @(YES),
  };
#endif

  OSStatus status = VTCompressionSessionCreate(
      nullptr,
      _width,
      _height,
      kCMVideoCodecType_HEVC,  // Use HEVC codec
      (__bridge CFDictionaryRef)encoder_specs,
      (__bridge CFDictionaryRef)sourceAttributes,
      nullptr,
      compressionOutputCallback,
      nullptr,
      &_compressionSession);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create compression session: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }

#if defined(WEBRTC_MAC) && !defined(WEBRTC_IOS)
  CFBooleanRef hwaccl_enabled = nullptr;
  status = VTSessionCopyProperty(_compressionSession,
                                 kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 nullptr,
                                 &hwaccl_enabled);
  if (status == noErr && (CFBooleanGetValue(hwaccl_enabled))) {
    RTC_LOG(LS_INFO) << "H.265 compression session created with hw accl enabled";
  } else {
    RTC_LOG(LS_INFO) << "H.265 compression session created with hw accl disabled";
  }
#endif

  [self configureCompressionSession];

  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)configureCompressionSession {
  RTC_DCHECK(_compressionSession);
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_RealTime, true);
  SetVTSessionProperty(_compressionSession,
                       kVTCompressionPropertyKey_ProfileLevel,
                       ExtractProfile());
  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_AllowFrameReordering, false);
  [self setEncoderBitrateBps:_targetBitrateBps frameRate:_encoderFrameRate];

  SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_MaxKeyFrameInterval, 7200);
  SetVTSessionProperty(
      _compressionSession, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 240);
}

- (void)destroyCompressionSession {
  if (_compressionSession) {
    VTCompressionSessionInvalidate(_compressionSession);
    CFRelease(_compressionSession);
    _compressionSession = nullptr;
  }
}

- (NSString *)implementationName {
  return @"VideoToolbox";
}

- (void)setBitrateBps:(uint32_t)bitrateBps frameRate:(uint32_t)frameRate {
  if (_encoderBitrateBps != bitrateBps || _encoderFrameRate != frameRate) {
    [self setEncoderBitrateBps:bitrateBps frameRate:frameRate];
  }
}

- (void)setEncoderBitrateBps:(uint32_t)bitrateBps frameRate:(uint32_t)frameRate {
  if (_compressionSession) {
    SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_AverageBitRate, bitrateBps);
    SetVTSessionProperty(_compressionSession, kVTCompressionPropertyKey_ExpectedFrameRate, frameRate);

    int64_t dataLimitBytesPerSecondValue =
        static_cast<int64_t>(bitrateBps * kLimitToAverageBitRateFactor / 8);
    CFNumberRef bytesPerSecond =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &dataLimitBytesPerSecondValue);
    int64_t oneSecondValue = 1;
    CFNumberRef oneSecond =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt64Type, &oneSecondValue);
    const void *nums[2] = {bytesPerSecond, oneSecond};
    CFArrayRef dataRateLimits = CFArrayCreate(nullptr, nums, 2, &kCFTypeArrayCallBacks);
    OSStatus status = VTSessionSetProperty(
        _compressionSession, kVTCompressionPropertyKey_DataRateLimits, dataRateLimits);
    if (bytesPerSecond) {
      CFRelease(bytesPerSecond);
    }
    if (oneSecond) {
      CFRelease(oneSecond);
    }
    if (dataRateLimits) {
      CFRelease(dataRateLimits);
    }
    if (status != noErr) {
      RTC_LOG(LS_ERROR) << "Failed to set data rate limit with code: " << status;
    }

    _encoderBitrateBps = bitrateBps;
    _encoderFrameRate = frameRate;
  }
}

- (void)frameWasEncoded:(OSStatus)status
                  flags:(VTEncodeInfoFlags)infoFlags
           sampleBuffer:(CMSampleBufferRef)sampleBuffer
      codecSpecificInfo:(id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)codecSpecificInfo
                  width:(int32_t)width
                 height:(int32_t)height
           renderTimeMs:(int64_t)renderTimeMs
              timestamp:(uint32_t)timestamp
               rotation:(RTCVideoRotation)rotation {
  RTCVideoEncoderCallback callback = _callback;
  if (!callback) {
    return;
  }
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "H.265 encode failed with code: " << status;
    return;
  }
  if (infoFlags & kVTEncodeInfo_FrameDropped) {
    RTC_LOG(LS_INFO) << "H.265 encode dropped frame.";
    return;
  }

  BOOL isKeyframe = NO;
  CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, 0);
  if (attachments != nullptr && CFArrayGetCount(attachments)) {
    CFDictionaryRef attachment =
        static_cast<CFDictionaryRef>(CFArrayGetValueAtIndex(attachments, 0));
    isKeyframe = !CFDictionaryContainsKey(attachment, kCMSampleAttachmentKey_NotSync);
  }

  if (isKeyframe) {
    RTC_LOG(LS_INFO) << "Generated H.265 keyframe";
  }

  __block std::unique_ptr<rtc::Buffer> buffer = std::make_unique<rtc::Buffer>();
  if (!H265CMSampleBufferToAnnexBBuffer(sampleBuffer, isKeyframe, buffer.get())) {
    return;
  }

  RTC_OBJC_TYPE(RTCEncodedImage) *frame = [[RTC_OBJC_TYPE(RTCEncodedImage) alloc] init];
  frame.buffer = [[NSData alloc] initWithBytesNoCopy:buffer->data()
                                              length:buffer->size()
                                         deallocator:^(void *bytes, NSUInteger size) {
                                           buffer.reset();
                                         }];
  frame.encodedWidth = width;
  frame.encodedHeight = height;
  frame.frameType = isKeyframe ? RTCFrameTypeVideoFrameKey : RTCFrameTypeVideoFrameDelta;
  frame.captureTimeMs = renderTimeMs;
  frame.timeStamp = timestamp;
  frame.rotation = rotation;
  frame.contentType = (_mode == RTCVideoCodecModeScreensharing) ? RTCVideoContentTypeScreenshare :
                                                                  RTCVideoContentTypeUnspecified;
  frame.flags = webrtc::VideoSendTiming::kInvalid;

  _h265BitstreamParser.ParseBitstream(rtc::MakeArrayView(buffer->data(), buffer->size()));
  frame.qp = @(_h265BitstreamParser.GetLastSliceQp().value_or(-1));

  BOOL res = callback(frame, codecSpecificInfo);
  if (!res) {
    RTC_LOG(LS_ERROR) << "Encode callback failed";
    return;
  }
  _bitrateAdjuster->Update(frame.buffer.length);
}

- (nullable RTC_OBJC_TYPE(RTCVideoEncoderQpThresholds) *)scalingSettings {
  return [[RTC_OBJC_TYPE(RTCVideoEncoderQpThresholds) alloc]
      initWithThresholdsLow:kLowH265QpThreshold
                       high:kHighH265QpThreshold];
}

@end
