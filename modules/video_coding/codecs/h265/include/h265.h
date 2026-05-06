/*
 *  Copyright (c) 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_VIDEO_CODING_CODECS_H265_INCLUDE_H265_H_
#define MODULES_VIDEO_CODING_CODECS_H265_INCLUDE_H265_H_

#include <memory>
#include <string>
#include <vector>

#include "api/video_codecs/h265_profile_tier_level.h"
#include "api/video_codecs/sdp_video_format.h"
#include "api/video_codecs/video_decoder.h"
#include "rtc_base/system/rtc_export.h"

namespace webrtc {

// Creates an H.265 SdpVideoFormat entry with the given profile/tier/level and
// transmission mode (default "SRST", single RTP stream / single transmission).
RTC_EXPORT SdpVideoFormat CreateH265Format(H265Profile profile,
                                           H265Tier tier,
                                           H265Level level,
                                           const std::string& tx_mode = "SRST");

// Returns the H.265 decoder profiles this build supports for SDP advertisement.
// Returns an empty vector when RTC_ENABLE_H265 is not defined.
std::vector<SdpVideoFormat> SupportedH265DecoderCodecs();

class RTC_EXPORT H265Decoder : public VideoDecoder {
 public:
  static std::unique_ptr<H265Decoder> Create();
  static bool IsSupported();

  ~H265Decoder() override = default;
};

}  // namespace webrtc

#endif  // MODULES_VIDEO_CODING_CODECS_H265_INCLUDE_H265_H_
