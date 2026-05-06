/*
 *  Copyright (c) 2026 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#ifndef MODULES_VIDEO_CODING_CODECS_H265_H265_COLOR_SPACE_H_
#define MODULES_VIDEO_CODING_CODECS_H265_H265_COLOR_SPACE_H_

// Everything declared in this header is only required when WebRTC is
// built with H.265 software decoding support, please do not move anything
// out of the #ifdef unless needed and tested.
#ifdef RTC_ENABLE_H265

#if defined(WEBRTC_WIN) && !defined(__clang__)
#error "See: bugs.webrtc.org/9213#c13."
#endif

extern "C" {
#include <libavcodec/avcodec.h>
}  // extern "C"

#include "api/video/color_space.h"

namespace webrtc {

// Helper class for extracting color space information from an H.265 stream
// via FFmpeg's AVCodecContext. Logic is codec-agnostic; this is a sibling of
// ExtractH264ColorSpace kept separate to mirror H.264's file layout.
ColorSpace ExtractH265ColorSpace(AVCodecContext* codec);

}  // namespace webrtc

#endif  // RTC_ENABLE_H265

#endif  // MODULES_VIDEO_CODING_CODECS_H265_H265_COLOR_SPACE_H_
