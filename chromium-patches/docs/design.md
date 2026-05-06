# Patch Architecture: Software HEVC Decode for Chromium WebRTC (Receive-Only)

**Target:** Chromium `main` (Chrome 147 era) + StaZhu's HEVC `<video>`/MSE patch set
**Goal:** GPU-less Windows PCs decode incoming WebRTC HEVC streams in software via FFmpeg.
**Approach:** Approach A — add HEVC to `webrtc::InternalDecoderFactory`, parallel to OpenH264 path.

Grounded in source verified at chromium.googlesource.com `main` on 2026-04-30.

---

## Constraints

- Decode-only (no encoder work, no x265 GPL clash).
- Receiver runs on GPU-less Windows PCs.
- Remote peer emits fixed HEVC; no codec renegotiation possible.
- StaZhu's MSE patches are a hard prerequisite (they enable HEVC inside the bundled FFmpeg).

---

## 1. `args.gn` Configuration

```gn
# Branding / proprietary codecs
is_chrome_branded   = false
proprietary_codecs  = true
ffmpeg_branding     = "Chrome"

# StaZhu's territory: enable HEVC compile path through FFmpeg
enable_hevc_parser_and_hw_decoder = true
enable_platform_hevc              = true
media_use_ffmpeg                  = true

# WebRTC H265 build flag (cascades from enable_hevc_parser_and_hw_decoder)
rtc_use_h265 = true

# Build mode (release, non-component)
is_debug                 = false
is_component_build       = false
is_official_build        = true
target_os                = "win"
target_cpu               = "x64"
symbol_level             = 1
blink_symbol_level       = 0
v8_symbol_level          = 0
```

`rtc_use_h265` is forced to mirror `enable_hevc_parser_and_hw_decoder` in `third_party/webrtc/webrtc.gni:177` when `build_with_chromium`. Setting it explicitly is documentation.

---

## 2. Per-File Change Plan

### 2a. `third_party/webrtc/media/engine/internal_decoder_factory.cc` (~122 lines, primary target)

| Change | Lines | What | Why |
|---|---|---|---|
| Add include | top, ~line 28 | `#include "modules/video_coding/codecs/h265/h265_decoder.h"` under `#if defined(RTC_USE_H265)` | Pull in new adapter |
| `GetSupportedFormats()` | 47–61 | After H264 loop, push H265 Main + Main10 SDP entries under `#if defined(RTC_USE_H265)` | Advertise codecs |
| `Create()` | 95–119 | Add HEVC branch returning `CreateH265Decoder(env)` | Hand back the SW decoder |
| `BUILD.gn` (sibling) | engine target | Add `h265:h265_decoder` dep gated by `rtc_use_h265` | Link the new code |

`QueryCodecSupport()` needs no edits — it routes through `format.IsCodecInList(supported_formats)` which picks up the new entries automatically.

### 2b. `third_party/blink/renderer/platform/peerconnection/rtc_video_decoder_adapter.cc` (~949 lines)

`HasSoftwareFallback()` (lines 95–105):

```cpp
// Before:
if (video_codec == media::VideoCodec::kHEVC) {
  return false;
}

// After:
if (video_codec == media::VideoCodec::kHEVC) {
#if BUILDFLAG(RTC_USE_H265) && BUILDFLAG(ENABLE_FFMPEG_VIDEO_DECODERS)
  return true;
#else
  return false;
#endif
}
```

### 2c. Files that need NO edits

- `third_party/blink/renderer/platform/peerconnection/video_codec_factory.cc` — `DecoderAdapter` always holds a SW factory by value, `MergeFormats()` is purely additive.
- `third_party/blink/renderer/platform/peerconnection/rtc_video_decoder_factory.cc` — never instantiated when `use_hw_decoding == false`.

### 2d. New files

- `third_party/webrtc/modules/video_coding/codecs/h265/h265_decoder.h`
- `third_party/webrtc/modules/video_coding/codecs/h265/h265_decoder.cc`
- `third_party/webrtc/modules/video_coding/codecs/h265/BUILD.gn`

---

## 3. New C++ Class: `webrtc::H265DecoderImpl`

**Strategy:** Mirror `third_party/webrtc/modules/video_coding/codecs/h264/h264_decoder_impl.{h,cc}` exactly. Call libavcodec directly. **Do not** wrap `media::FFmpegVideoDecoder` — that's async/callback-based, runs on a separate `SequencedTaskRunner`, and would require a condition variable + frame-format glue. Direct libavcodec on the WebRTC decoder thread is what H264DecoderImpl already does.

### 3a. Header sketch

```cpp
#ifndef MODULES_VIDEO_CODING_CODECS_H265_H265_DECODER_H_
#define MODULES_VIDEO_CODING_CODECS_H265_H265_DECODER_H_

#ifdef RTC_USE_H265

extern "C" {
#include <libavcodec/avcodec.h>
}

#include "api/environment/environment.h"
#include "api/video/encoded_image.h"
#include "api/video_codecs/video_decoder.h"
#include "common_video/include/video_frame_buffer_pool.h"

namespace webrtc {

struct AVCodecContextDeleter { void operator()(AVCodecContext*) const; };
struct AVFrameDeleter        { void operator()(AVFrame*) const; };

class H265DecoderImpl : public VideoDecoder {
 public:
  H265DecoderImpl();
  ~H265DecoderImpl() override;

  bool Configure(const Settings& settings) override;
  int32_t Release() override;
  int32_t RegisterDecodeCompleteCallback(DecodedImageCallback*) override;
  int32_t Decode(const EncodedImage&, bool, int64_t = -1) override;
  DecoderInfo GetDecoderInfo() const override;
  const char* ImplementationName() const override;

 private:
  static int  AVGetBuffer2(AVCodecContext*, AVFrame*, int);
  static void AVFreeBuffer2(void*, uint8_t*);

  VideoFrameBufferPool ffmpeg_buffer_pool_;
  std::unique_ptr<AVCodecContext, AVCodecContextDeleter> av_context_;
  std::unique_ptr<AVFrame, AVFrameDeleter> av_frame_;
  DecodedImageCallback* decoded_image_callback_ = nullptr;
};

std::unique_ptr<VideoDecoder> CreateH265Decoder(const Environment& env);

}  // namespace webrtc
#endif
#endif
```

### 3b. Implementation notes

- `Configure()`: `avcodec_find_decoder(AV_CODEC_ID_HEVC)`, `thread_count = 1`, install `AVGetBuffer2` to use `VideoFrameBufferPool`, `avcodec_open2`.
- `Decode()`: wrap `EncodedImage` in `AVPacket`, `avcodec_send_packet` / `avcodec_receive_frame` loop, build `webrtc::VideoFrame` from buffer (no copy — already in pool), invoke `decoded_image_callback_->Decoded(frame)`.
- Pixel format: `AV_PIX_FMT_YUV420P` → `I420Buffer`, `AV_PIX_FMT_YUV420P10LE` → `I010Buffer`. Anything else → drop frame.
- Threading: all methods run on the WebRTC decoder thread (`Chrome_libJingle_DecodingThread`). Same contract as H264DecoderImpl. Bypasses Chromium media thread, no Mojo, no GPU process.
- `ImplementationName() = "FFmpeg"`.

### 3c. BUILD.gn

```gn
if (rtc_use_h265) {
  rtc_library("h265_decoder") {
    sources = [ "h265_decoder.cc", "h265_decoder.h" ]
    deps = [
      "//third_party/ffmpeg",
      "../..:video_codec_interface",
      "../../../../api/environment",
      "../../../../api/video:encoded_image",
      "../../../../api/video_codecs:video_codecs_api",
      "../../../../common_video",
      "../../../../media:rtc_media_base",
      "../../../../rtc_base:logging",
    ]
  }
}
```

---

## 4. SDP Advertise — Verified

Chain: `RTCRtpReceiver::getCapabilities()` → `PeerConnectionDependencyFactory::GetReceiverCapabilities` → `webrtc::PeerConnectionFactory::GetRtpReceiverCapabilities` → `DecoderAdapter::GetSupportedFormats()` → `MergeFormats(software_formats, hardware_formats)` (additive). **No separate SDP-layer HEVC strip.** Fixing `InternalDecoderFactory` propagates to SDP automatically.

`kWebRtcAllowH265Receive` is `FEATURE_ENABLED_BY_DEFAULT` since ~Chrome 136. Not the gate.

---

## 5. Test Surface

### Unit tests
- Run: `webrtc_unittests --gtest_filter=*InternalDecoderFactory*` after factory edit.
- Author: `H265DecoderImplTest` mirroring `h264_decoder_impl_unittest.cc`. Decode 5-frame static HEVC bitstream, assert PSNR vs. reference YUV.

### Blink tests
- `blink_unittests --gtest_filter=*RTCVideoDecoder*` — update any test asserting "HEVC has no fallback".

### End-to-end
- Sender on a HW-HEVC-capable machine (the user's i7-1165G7 works) emits HEVC over `RTCPeerConnection`.
- Receiver: patched build. Verify in `chrome://webrtc-internals`:
  - `decoderImplementation == "FFmpeg"`
  - `framesDecoded` ticks up
  - `inbound-rtp video.codec` shows `H265` with profile/tier/level

### Diagnostic logs
Run with `--enable-logging=stderr --vmodule="*webrtc*=2"`. Look for `H265DecoderImpl::Configure: pixel format YUV420P`. Negative signal: `Could not find decoder for codec H265`.

---

## 6. Build Sequencing

### Apply order
1. `git fetch && git checkout <Chrome 147 tag>`
2. `gclient sync`
3. Apply StaZhu patches:
   - `third_party/ffmpeg`: `add-hevc-ffmpeg-decoder-parser.patch`, `change-libavcodec-header.patch`
   - `src/`: `enable-hevc-ffmpeg-decoding.patch`
4. Apply our patches:
   - `0001-add-h265-decoder-impl.patch`
   - `0002-internal-decoder-factory-hevc.patch`
   - `0003-relax-has-software-fallback.patch`

### Incremental targets (fast iteration)
```bash
autoninja -C out/Release third_party/webrtc/modules/video_coding/codecs/h265:h265_decoder
autoninja -C out/Release third_party/webrtc/media/engine:internal_decoder_factory
autoninja -C out/Release webrtc_unittests
out/Release/webrtc_unittests --gtest_filter="*H265*"
autoninja -C out/Release blink_platform_unittests
```

Full `chrome` only after components build clean — ~2 hours on 16-core, ~4–6 hours on the i7-1165G7.

---

## 7. Risks

- **Frame-format conversion overhead:** Mitigated — direct-FFmpeg path. 1080p30 should work on Skylake+ 4-core. 4K30 SW HEVC is a stretch even with `thread_count > 1`.
- **Threading mismatches:** Eliminated by direct-FFmpeg approach.
- **Patent/license:** Same posture as StaZhu's existing redistribution. For a personal/internal build this is the same risk profile. For redistribution, consult counsel.
- **Mojo IPC:** Not affected — direct libavcodec in renderer process bypasses Mojo entirely.
- **Drift signals:**
  - `internal_decoder_factory.cc` — touched on every codec addition. Watch for refactor to a registry pattern.
  - `HasSoftwareFallback()` — `crbug.com/355256378` already on TODO list.
  - `third_party/ffmpeg` BUILD config — StaZhu's patches need rebasing on every FFmpeg roll.
  - Recommended canary: `static_assert` on `BUILDFLAG(RTC_USE_H265)`.
- **RTP depacketizer:** `third_party/webrtc/modules/rtp_rtcp/source/rtp_format_h265.cc` exists and is unconditional; smoke-test it for SPS/PPS-out-of-band streams.
- **I010 path:** Verify `VideoFrameBufferPool` is constructed with `support_i010=true` to match the H264 pool ctor.

---

## 8. Effort Estimate

| Phase | Sub-tasks | Estimate |
|---|---|---|
| 0. Environment | depot_tools, fetch + sync, apply StaZhu patches, baseline build that plays HEVC `<video>` | 2–3 days |
| 1. H265DecoderImpl | Clone H264DecoderImpl, swap codec ID, get unit test green | 3–4 days |
| 2. Factory wiring | Edit `internal_decoder_factory.cc` + BUILD.gn, green factory test | 1 day |
| 3. Adapter fallback | `HasSoftwareFallback` + blink unit test fixups | 0.5 day |
| 4. End-to-end | Sender setup, signaling, RTP depacketization edge cases | **4–6 days** |
| 5. Quality / perf | 1080p30 latency, jitter, multithreaded decode tuning | 2–4 days |
| 6. Hardening | ASan pass, fuzz targets, redistributable packaging | 2–3 days |

**Total: 14–22 working days = 3–4.5 calendar weeks.**

---

## 9. Critical files (absolute paths in current Chromium main)

```
third_party/webrtc/media/engine/internal_decoder_factory.cc        (main target)
third_party/webrtc/modules/video_coding/codecs/h265/h265_decoder.{h,cc}  (new)
third_party/webrtc/modules/video_coding/codecs/h264/h264_decoder_impl.cc (reference template)
third_party/blink/renderer/platform/peerconnection/rtc_video_decoder_adapter.cc
third_party/blink/renderer/platform/peerconnection/video_codec_factory.cc  (verify-only, no edits)
media/filters/ffmpeg_video_decoder.cc                              (StaZhu's territory)
media/base/supported_types.cc
media/media_options.gni
third_party/webrtc/webrtc.gni
```
