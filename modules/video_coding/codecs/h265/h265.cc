/*
 *  Copyright (c) 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "modules/video_coding/codecs/h265/include/h265.h"

#include <memory>
#include <string>
#include <vector>

#include "api/video_codecs/h265_profile_tier_level.h"
#include "api/video_codecs/sdp_video_format.h"
#include "media/base/media_constants.h"
#include "rtc_base/checks.h"
#include "rtc_base/logging.h"
#include "rtc_base/trace_event.h"

#ifdef RTC_ENABLE_H265
#include "modules/video_coding/codecs/h265/h265_decoder_impl.h"
#endif

namespace webrtc {

namespace {

bool IsH265CodecSupported() {
#ifdef RTC_ENABLE_H265
  return true;
#else
  return false;
#endif
}

}  // namespace

SdpVideoFormat CreateH265Format(H265Profile profile,
                                H265Tier tier,
                                H265Level level,
                                const std::string& tx_mode) {
  return SdpVideoFormat(
      kH265CodecName,
      {{kH265FmtpProfileId, H265ProfileToString(profile)},
       {kH265FmtpTierFlag, H265TierToString(tier)},
       {kH265FmtpLevelId, H265LevelToString(level)},
       {kH265FmtpTxMode, tx_mode}});
}

std::vector<SdpVideoFormat> SupportedH265DecoderCodecs() {
  TRACE_EVENT0("webrtc", __func__);
  if (!IsH265CodecSupported()) {
    return {};
  }
  // Advertise Main and Main10 at Level 3.1, Tier 0. The remote peer's
  // profile/tier/level negotiation will narrow this further; FFmpeg will
  // accept any HEVC bitstream within these gates.
  return {
      CreateH265Format(H265Profile::kProfileMain, H265Tier::kTier0,
                       H265Level::kLevel3_1),
      CreateH265Format(H265Profile::kProfileMain10, H265Tier::kTier0,
                       H265Level::kLevel3_1),
  };
}

std::unique_ptr<H265Decoder> H265Decoder::Create() {
  RTC_DCHECK(H265Decoder::IsSupported());
#ifdef RTC_ENABLE_H265
  RTC_LOG(LS_INFO) << "Creating H265DecoderImpl.";
  return std::make_unique<H265DecoderImpl>();
#else
  RTC_DCHECK_NOTREACHED();
  return nullptr;
#endif
}

bool H265Decoder::IsSupported() {
  return IsH265CodecSupported();
}

}  // namespace webrtc
