/*
 *  Copyright (c) 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#import "RTCVideoDecoderH265.h"

#import <VideoToolbox/VideoToolbox.h>

#import "base/RTCVideoFrame.h"
#import "base/RTCVideoFrameBuffer.h"
#import "components/video_frame_buffer/RTCCVPixelBuffer.h"
#import "helpers.h"
#import "helpers/scoped_cftyperef.h"

#if defined(WEBRTC_IOS)
#import "helpers/UIDevice+RTCDevice.h"
#endif

#include "common_video/h265/h265_common.h"
#include "modules/video_coding/include/video_error_codes.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "rtc_base/time_utils.h"

// Struct that we pass to the decoder per frame to decode.
struct RTCFrameDecodeParams {
  RTCFrameDecodeParams(RTCVideoDecoderCallback cb, int64_t ts) : callback(cb), timestamp(ts) {}
  RTCVideoDecoderCallback callback;
  int64_t timestamp;
};

@interface RTC_OBJC_TYPE (RTCVideoDecoderH265)
() - (void)setError : (OSStatus)error;
@end

namespace {

// Converts H.265 Annex B buffer to CMSampleBuffer format
bool H265AnnexBBufferToCMSampleBuffer(const uint8_t* annexb_buffer,
                                      size_t annexb_buffer_size,
                                      CMVideoFormatDescriptionRef video_format,
                                      CMSampleBufferRef* out_sample_buffer,
                                      CMMemoryPoolRef memory_pool) {
  RTC_DCHECK(annexb_buffer);
  RTC_DCHECK(out_sample_buffer);
  RTC_DCHECK(video_format);
  *out_sample_buffer = nullptr;

  // Get NAL unit indices
  std::vector<webrtc::H265::NaluIndex> indices =
      webrtc::H265::FindNaluIndices(annexb_buffer, annexb_buffer_size);

  if (indices.empty()) {
    RTC_LOG(LS_ERROR) << "No H.265 NAL units found.";
    return false;
  }

  // Calculate total size needed for AVCC format (excluding VPS/SPS/PPS)
  size_t avcc_size = 0;
  for (const auto& index : indices) {
    uint8_t nalu_type = webrtc::H265::ParseNaluType(annexb_buffer[index.payload_start_offset]);
    // Skip VPS/SPS/PPS when calculating size
    if (nalu_type == webrtc::H265::kVps ||
        nalu_type == webrtc::H265::kSps ||
        nalu_type == webrtc::H265::kPps) {
      continue;
    }
    avcc_size += 4 + index.payload_size;  // 4 bytes for length prefix
  }

  if (avcc_size == 0) {
    RTC_LOG(LS_WARNING) << "No video NAL units found (only parameter sets).";
    return false;
  }

  // Allocate block buffer using memory pool allocator (like H.264)
  CMBlockBufferRef block_buffer = nullptr;
  CFAllocatorRef block_allocator = CMMemoryPoolGetAllocator(memory_pool);
  OSStatus status = CMBlockBufferCreateWithMemoryBlock(
      kCFAllocatorDefault,
      nullptr,
      avcc_size,
      block_allocator,
      nullptr,
      0,
      avcc_size,
      kCMBlockBufferAssureMemoryNowFlag,
      &block_buffer);

  if (status != kCMBlockBufferNoErr) {
    RTC_LOG(LS_ERROR) << "Failed to create block buffer: " << status;
    return false;
  }

  // Get writable data pointer
  uint8_t* dst_data = nullptr;
  status = CMBlockBufferGetDataPointer(block_buffer, 0, nullptr, nullptr, (char**)&dst_data);
  if (status != kCMBlockBufferNoErr) {
    RTC_LOG(LS_ERROR) << "Failed to get block buffer data pointer: " << status;
    CFRelease(block_buffer);
    return false;
  }

  // Convert from Annex B to AVCC format
  size_t offset = 0;
  for (const auto& index : indices) {
    // Skip VPS/SPS/PPS NAL units as they are in the format description
    uint8_t nalu_type = webrtc::H265::ParseNaluType(annexb_buffer[index.payload_start_offset]);
    if (nalu_type == webrtc::H265::kVps ||
        nalu_type == webrtc::H265::kSps ||
        nalu_type == webrtc::H265::kPps) {
      continue;
    }

    // Write 4-byte length
    uint32_t nalu_length = static_cast<uint32_t>(index.payload_size);
    dst_data[offset++] = (nalu_length >> 24) & 0xFF;
    dst_data[offset++] = (nalu_length >> 16) & 0xFF;
    dst_data[offset++] = (nalu_length >> 8) & 0xFF;
    dst_data[offset++] = nalu_length & 0xFF;

    // Write NALU data
    memcpy(dst_data + offset,
           annexb_buffer + index.payload_start_offset,
           index.payload_size);
    offset += index.payload_size;
  }

  // Create sample buffer
  status = CMSampleBufferCreate(kCFAllocatorDefault,
                               block_buffer,
                               true,
                               nullptr,
                               nullptr,
                               video_format,
                               1,
                               0,
                               nullptr,
                               0,
                               nullptr,
                               out_sample_buffer);

  CFRelease(block_buffer);

  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create sample buffer: " << status;
    return false;
  }

  return true;
}

// Creates video format description from Annex B buffer containing VPS/SPS/PPS
CMVideoFormatDescriptionRef CreateH265VideoFormatDescription(const uint8_t* annexb_buffer,
                                                             size_t annexb_buffer_size) {
  // Find all NAL units
  std::vector<webrtc::H265::NaluIndex> indices =
      webrtc::H265::FindNaluIndices(annexb_buffer, annexb_buffer_size);

  std::vector<const uint8_t*> param_sets;
  std::vector<size_t> param_set_sizes;

  // Extract VPS, SPS, and PPS
  for (const auto& index : indices) {
    uint8_t nalu_type = webrtc::H265::ParseNaluType(annexb_buffer[index.payload_start_offset]);
    if (nalu_type == webrtc::H265::kVps ||
        nalu_type == webrtc::H265::kSps ||
        nalu_type == webrtc::H265::kPps) {
      param_sets.push_back(annexb_buffer + index.payload_start_offset);
      param_set_sizes.push_back(index.payload_size);
    }
  }

  if (param_sets.empty()) {
    RTC_LOG(LS_WARNING) << "No VPS/SPS/PPS found in buffer.";
    return nullptr;
  }

  // Create format description with parameter sets
  CMVideoFormatDescriptionRef format_desc = nullptr;
  OSStatus status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
      kCFAllocatorDefault,
      param_sets.size(),
      param_sets.data(),
      param_set_sizes.data(),
      4,  // NAL unit header length
      nullptr,
      &format_desc);

  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create HEVC format description: " << status;
    return nullptr;
  }

  return format_desc;
}

}  // namespace

// This is the callback function that VideoToolbox calls when decode is complete.
void decompressionOutputCallbackH265(void *decoderRef,
                                 void *params,
                                 OSStatus status,
                                 VTDecodeInfoFlags infoFlags,
                                 CVImageBufferRef imageBuffer,
                                 CMTime timestamp,
                                 CMTime duration) {
  std::unique_ptr<RTCFrameDecodeParams> decodeParams(
      reinterpret_cast<RTCFrameDecodeParams *>(params));
  if (status != noErr) {
    RTC_OBJC_TYPE(RTCVideoDecoderH265) *decoder =
        (__bridge RTC_OBJC_TYPE(RTCVideoDecoderH265) *)decoderRef;
    [decoder setError:status];
    return;
  }

  if (!imageBuffer) {
    return;
  }

  RTC_OBJC_TYPE(RTCCVPixelBuffer) *frameBuffer =
      [[RTC_OBJC_TYPE(RTCCVPixelBuffer) alloc] initWithPixelBuffer:imageBuffer];
  RTC_OBJC_TYPE(RTCVideoFrame) *decodedFrame = [[RTC_OBJC_TYPE(RTCVideoFrame) alloc]
      initWithBuffer:frameBuffer
            rotation:RTCVideoRotation_0
         timeStampNs:CMTimeGetSeconds(timestamp) * rtc::kNumNanosecsPerSec];
  decodedFrame.timeStamp = decodeParams->timestamp;

  decodeParams->callback(decodedFrame);
}

// Decoder implementation
@implementation RTC_OBJC_TYPE (RTCVideoDecoderH265) {
  CMVideoFormatDescriptionRef _videoFormat;
  CMMemoryPoolRef _memoryPool;
  VTDecompressionSessionRef _decompressionSession;
  RTCVideoDecoderCallback _callback;
  OSStatus _error;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _memoryPool = CMMemoryPoolCreate(nil);
  }
  return self;
}

- (instancetype)initWithCodecInfo:(RTC_OBJC_TYPE(RTCVideoCodecInfo) *)codecInfo {
  self = [super init];
  if (self) {
    _memoryPool = CMMemoryPoolCreate(nil);
  }
  return self;
}

- (void)dealloc {
  CMMemoryPoolInvalidate(_memoryPool);
  CFRelease(_memoryPool);
  [self destroyDecompressionSession];
  [self setVideoFormat:nullptr];
}

- (NSInteger)startDecodeWithNumberOfCores:(int)numberOfCores {
  return WEBRTC_VIDEO_CODEC_OK;
}

- (NSInteger)decode:(RTC_OBJC_TYPE(RTCEncodedImage) *)inputImage
        missingFrames:(BOOL)missingFrames
    codecSpecificInfo:(nullable id<RTC_OBJC_TYPE(RTCCodecSpecificInfo)>)info
         renderTimeMs:(int64_t)renderTimeMs {
  RTC_DCHECK(inputImage.buffer);

  if (_error != noErr) {
    _error = noErr;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }

  // Try to create format description from input (may contain VPS/SPS/PPS in keyframes)
  rtc::ScopedCFTypeRef<CMVideoFormatDescriptionRef> inputFormat =
      rtc::ScopedCF(CreateH265VideoFormatDescription((uint8_t *)inputImage.buffer.bytes,
                                                      inputImage.buffer.length));
  if (inputFormat) {
    // Check if the video format has changed, and reinitialize decoder if needed.
    if (!CMFormatDescriptionEqual(inputFormat.get(), _videoFormat)) {
      [self setVideoFormat:inputFormat.get()];
      int resetDecompressionSessionError = [self resetDecompressionSession];
      if (resetDecompressionSessionError != WEBRTC_VIDEO_CODEC_OK) {
        return resetDecompressionSessionError;
      }
    }
  }
  if (!_videoFormat) {
    // We received a frame but we don't have format information so we can't decode it.
    // This can happen after backgrounding. We need to wait for the next vps/sps/pps
    // before we can resume so we request a keyframe by returning an error.
    RTC_LOG(LS_WARNING) << "Missing H.265 video format. Frame with vps/sps/pps required.";
    return WEBRTC_VIDEO_CODEC_ERROR;
  }

  CMSampleBufferRef sampleBuffer = nullptr;
  if (!H265AnnexBBufferToCMSampleBuffer((uint8_t *)inputImage.buffer.bytes,
                                        inputImage.buffer.length,
                                        _videoFormat,
                                        &sampleBuffer,
                                        _memoryPool)) {
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  RTC_DCHECK(sampleBuffer);

  VTDecodeFrameFlags decodeFlags = kVTDecodeFrame_EnableAsynchronousDecompression;
  std::unique_ptr<RTCFrameDecodeParams> frameDecodeParams;
  frameDecodeParams.reset(new RTCFrameDecodeParams(_callback, inputImage.timeStamp));
  OSStatus status = VTDecompressionSessionDecodeFrame(
      _decompressionSession, sampleBuffer, decodeFlags, frameDecodeParams.release(), nullptr);

#if defined(WEBRTC_IOS)
  // Re-initialize the decoder if we have an invalid session while the app is
  // active or decoder malfunctions and retry the decode request.
  if ((status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr) &&
      [self resetDecompressionSession] == WEBRTC_VIDEO_CODEC_OK) {
    RTC_LOG(LS_INFO) << "Failed to decode H.265 frame with code: " << status
                     << " retrying decode after decompression session reset";
    frameDecodeParams.reset(new RTCFrameDecodeParams(_callback, inputImage.timeStamp));
    status = VTDecompressionSessionDecodeFrame(
        _decompressionSession, sampleBuffer, decodeFlags, frameDecodeParams.release(), nullptr);
  }
#endif

  CFRelease(sampleBuffer);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to decode H.265 frame with code: " << status;
    return WEBRTC_VIDEO_CODEC_ERROR;
  }

  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)setCallback:(RTCVideoDecoderCallback)callback {
  _callback = callback;
}

- (void)setError:(OSStatus)error {
  _error = error;
}

- (NSInteger)releaseDecoder {
  [self destroyDecompressionSession];
  [self setVideoFormat:nullptr];
  _callback = nullptr;
  return WEBRTC_VIDEO_CODEC_OK;
}

#pragma mark - Private

- (int)resetDecompressionSession {
  [self destroyDecompressionSession];

  if (!_videoFormat) {
    return WEBRTC_VIDEO_CODEC_OK;
  }

  NSDictionary *attributes = @{
#if defined(WEBRTC_IOS) && (TARGET_OS_MACCATALYST || TARGET_OS_SIMULATOR)
    (NSString *)kCVPixelBufferMetalCompatibilityKey : @(YES),
#elif defined(WEBRTC_IOS)
    (NSString *)kCVPixelBufferOpenGLESCompatibilityKey : @(YES),
#elif defined(WEBRTC_MAC) && !defined(WEBRTC_ARCH_ARM64)
    (NSString *)kCVPixelBufferOpenGLCompatibilityKey : @(YES),
#endif
#if !(TARGET_OS_SIMULATOR)
    (NSString *)kCVPixelBufferIOSurfacePropertiesKey : @{},
#endif
    (NSString *)
    kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange),
  };

  VTDecompressionOutputCallbackRecord record = {
      decompressionOutputCallbackH265, (__bridge void *)self,
  };
  OSStatus status = VTDecompressionSessionCreate(nullptr,
                                                 _videoFormat,
                                                 nullptr,
                                                 (__bridge CFDictionaryRef)attributes,
                                                 &record,
                                                 &_decompressionSession);
  if (status != noErr) {
    RTC_LOG(LS_ERROR) << "Failed to create H.265 decompression session: " << status;
    [self destroyDecompressionSession];
    return WEBRTC_VIDEO_CODEC_ERROR;
  }
  [self configureDecompressionSession];

  return WEBRTC_VIDEO_CODEC_OK;
}

- (void)configureDecompressionSession {
  RTC_DCHECK(_decompressionSession);
#if defined(WEBRTC_IOS)
  VTSessionSetProperty(_decompressionSession, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
#endif
}

- (void)destroyDecompressionSession {
  if (_decompressionSession) {
#if defined(WEBRTC_IOS)
    VTDecompressionSessionWaitForAsynchronousFrames(_decompressionSession);
#endif
    VTDecompressionSessionInvalidate(_decompressionSession);
    CFRelease(_decompressionSession);
    _decompressionSession = nullptr;
  }
}

- (void)setVideoFormat:(CMVideoFormatDescriptionRef)videoFormat {
  if (_videoFormat == videoFormat) {
    return;
  }
  if (_videoFormat) {
    CFRelease(_videoFormat);
  }
  _videoFormat = videoFormat;
  if (_videoFormat) {
    CFRetain(_videoFormat);
  }
}

- (NSString *)implementationName {
  return @"VideoToolbox";
}

@end
