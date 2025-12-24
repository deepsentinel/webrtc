/*
 *  Copyright 2024 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

package org.webrtc;

import android.media.MediaFormat;
import android.util.Base64;
import androidx.annotation.Nullable;
import java.nio.ByteBuffer;
import java.util.Map;

/**
 * H.265/HEVC hardware video decoder for Android.
 * Extracts VPS/SPS/PPS parameter sets from RTP frames (in-band).
 */
class AndroidVideoDecoderH265 extends AndroidVideoDecoder {
  private static final String TAG = "AndroidVideoDecoderH265";

  // H.265 NAL unit types
  private static final int NAL_VPS = 32;
  private static final int NAL_SPS = 33;
  private static final int NAL_PPS = 34;

  // Annex B start code
  private static final byte[] ANNEXB_START_CODE = new byte[] {0x00, 0x00, 0x00, 0x01};

  private byte[] configuredCsd0;

  AndroidVideoDecoderH265(MediaCodecWrapperFactory mediaCodecWrapperFactory, String codecName,
      VideoCodecMimeType codecType, int colorFormat, @Nullable EglBase.Context sharedContext,
      Map<String, String> codecParams) {
    super(mediaCodecWrapperFactory, codecName, codecType, colorFormat, sharedContext);
  }

  /**
   * Extract parameter sets from an Annex B encoded frame.
   * Extracts VPS/SPS/PPS from RTP packets (in-band).
   */
  private byte[] extractParameterSetsFromFrame(ByteBuffer frameBuffer) {
    byte[] frameData = new byte[frameBuffer.remaining()];
    frameBuffer.get(frameData);
    frameBuffer.rewind(); // Reset position for later use

    byte[] vps = null;
    byte[] sps = null;
    byte[] pps = null;

    // Find all NAL units
    int offset = 0;
    while (offset < frameData.length - 4) {
      // Look for start code: 0x00 0x00 0x00 0x01 or 0x00 0x00 0x01
      int startCodeSize = 0;
      if (frameData[offset] == 0x00 && frameData[offset + 1] == 0x00) {
        if (frameData[offset + 2] == 0x00 && frameData[offset + 3] == 0x01) {
          startCodeSize = 4;
        } else if (frameData[offset + 2] == 0x01) {
          startCodeSize = 3;
        }
      }

      if (startCodeSize == 0) {
        offset++;
        continue;
      }

      // Get NAL unit type (bits 1-6 of first byte after start code)
      int nalHeaderOffset = offset + startCodeSize;
      if (nalHeaderOffset >= frameData.length) {
        break;
      }

      int nalType = (frameData[nalHeaderOffset] >> 1) & 0x3F;

      // Find next start code to determine NAL unit size
      int nextStartCode = findNextStartCode(frameData, nalHeaderOffset);
      int nalSize = (nextStartCode > 0 ? nextStartCode : frameData.length) - nalHeaderOffset;

      // Extract parameter sets
      if (nalType == NAL_VPS && vps == null) {
        vps = new byte[nalSize];
        System.arraycopy(frameData, nalHeaderOffset, vps, 0, nalSize);
        Logging.d(TAG, "Extracted VPS from frame: " + nalSize + " bytes");
      } else if (nalType == NAL_SPS && sps == null) {
        sps = new byte[nalSize];
        System.arraycopy(frameData, nalHeaderOffset, sps, 0, nalSize);
        Logging.d(TAG, "Extracted SPS from frame: " + nalSize + " bytes");
      } else if (nalType == NAL_PPS && pps == null) {
        pps = new byte[nalSize];
        System.arraycopy(frameData, nalHeaderOffset, pps, 0, nalSize);
        Logging.d(TAG, "Extracted PPS from frame: " + nalSize + " bytes");
      }

      offset = nalHeaderOffset + 1;
    }

    // Create CSD-0 if we found all parameter sets
    if (vps != null && sps != null && pps != null) {
      // Create CSD-0 buffer in Annex B format: [start_code][VPS][start_code][SPS][start_code][PPS]
      int totalSize = ANNEXB_START_CODE.length * 3 + vps.length + sps.length + pps.length;
      byte[] csd0 = new byte[totalSize];
      int bufferOffset = 0;

      // VPS
      System.arraycopy(ANNEXB_START_CODE, 0, csd0, bufferOffset, ANNEXB_START_CODE.length);
      bufferOffset += ANNEXB_START_CODE.length;
      System.arraycopy(vps, 0, csd0, bufferOffset, vps.length);
      bufferOffset += vps.length;

      // SPS
      System.arraycopy(ANNEXB_START_CODE, 0, csd0, bufferOffset, ANNEXB_START_CODE.length);
      bufferOffset += ANNEXB_START_CODE.length;
      System.arraycopy(sps, 0, csd0, bufferOffset, sps.length);
      bufferOffset += sps.length;

      // PPS
      System.arraycopy(ANNEXB_START_CODE, 0, csd0, bufferOffset, ANNEXB_START_CODE.length);
      bufferOffset += ANNEXB_START_CODE.length;
      System.arraycopy(pps, 0, csd0, bufferOffset, pps.length);

      return csd0;
    }

    return null;
  }

  /**
   * Find the next Annex B start code position.
   */
  private int findNextStartCode(byte[] data, int startOffset) {
    for (int i = startOffset; i < data.length - 3; i++) {
      if (data[i] == 0x00 && data[i + 1] == 0x00) {
        if ((data[i + 2] == 0x00 && data[i + 3] == 0x01) || data[i + 2] == 0x01) {
          return i;
        }
      }
    }
    return -1;
  }

  @Override
  protected MediaFormat createMediaFormat(int width, int height) {
    MediaFormat format = MediaFormat.createVideoFormat(
        VideoCodecMimeType.H265.mimeType(), width, height);

    // Add CSD-0 buffer if available (extracted from keyframe)
    if (configuredCsd0 != null) {
      Logging.d(TAG, "Adding CSD-0 to MediaFormat (" + configuredCsd0.length + " bytes)");
      format.setByteBuffer("csd-0", ByteBuffer.wrap(configuredCsd0));
    } else {
      Logging.d(TAG, "No CSD-0 available - decoder will be initialized on first keyframe");
    }

    return format;
  }

  @Override
  public VideoCodecStatus decode(EncodedImage frame, DecodeInfo info) {
    // If we don't have parameter sets yet and this is a keyframe, try to extract them
    if (configuredCsd0 == null && frame.frameType == EncodedImage.FrameType.VideoFrameKey) {
      Logging.d(TAG, "Attempting to extract parameter sets from keyframe");
      byte[] extractedCsd0 = extractParameterSetsFromFrame(frame.buffer);

      if (extractedCsd0 != null) {
        Logging.d(TAG, "Successfully extracted parameter sets from keyframe, reinitializing decoder");
        configuredCsd0 = extractedCsd0;

        // Reinitialize decoder with new parameter sets
        int width;
        int height;
        if (frame.encodedWidth > 0 && frame.encodedHeight > 0) {
          width = frame.encodedWidth;
          height = frame.encodedHeight;
        } else {
          // Use default dimensions if not specified
          width = 320;
          height = 180;
        }

        VideoCodecStatus status = reinitDecode(width, height);
        if (status != VideoCodecStatus.OK) {
          Logging.e(TAG, "Failed to reinitialize decoder after extracting parameter sets");
          return status;
        }
      } else {
        Logging.w(TAG, "Could not extract parameter sets from keyframe");
      }
    }

    // Call parent decode
    return super.decode(frame, info);
  }
}
