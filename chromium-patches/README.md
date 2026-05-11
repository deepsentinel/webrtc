# chromium-patches

Chromium-side prerequisites and build tooling for the software HEVC decoder
that lives on this branch (`deepsentinel/m145-sw-hevc-decoder`).

The WebRTC code changes (the `H265DecoderImpl` and the `InternalDecoderFactory`
wiring) are at the root of this repo, in their normal WebRTC paths. The files
in this `chromium-patches/` directory are everything *outside* WebRTC that you
also need to build and run a Chromium with software HEVC WebRTC decode.

End-to-end verified on Chrome M149 against a production sender (720x576,
25fps, ~500 kbps): `decoderImplementation: "FFmpeg"`,
`powerEfficientDecoder: false`, zero ongoing frame drops. Subsequently
rolled back to **M145** to dodge an upstream Blink regression that hides
`<video controls>` UI on `srcObject = MediaStream` after playback starts;
see "M145 rollback notes" below.

## Why decoder-only

x265 is GPL and HEVC encode is patent-encumbered. We never need to encode in
this use case (the receiver is the only side we control), so the fork adds no
encoder. The decoder side is FFmpeg, which Chromium already builds and which
is licensed compatibly when paired with `ffmpeg_branding = "Chrome"`.

## Layout

```
chromium-patches/
  README.md                 (you are here)
  chromium-version.txt      exact commit pins
  patches/
    chromium/               patches against chromium/src
      0001-stazhu-enable-hevc-in-ffmpeg-pipeline.patch
      0002-rtc-video-decoder-adapter-allow-hevc-software-fallback.patch
      0003-disable-strict-ffmpeg-codecs-default.patch
      0004-list-marker-clang-O3-workaround.patch
    ffmpeg/                 patches against third_party/ffmpeg
      0001-stazhu-add-hevc-decoder-and-parser.patch
  config/
    args.gn                 GN args used to build
  scripts/
    apply.sh                apply all patches in order
    build.sh                gn gen + autoninja chrome
    package.sh              build a portable redistributable zip
  installer/                MSI installer (WiX v3) for SCCM/Intune/GPO
    DeepSentinelLiveViewer.wxs
    build-msi.sh            consumes the portable zip → MSI
    README.md               installer build + deployment notes
  docs/
    design.md               architecture and rationale
```

## Attribution

The `stazhu-` patches are derived from
[StaZhu/enable-chromium-hevc-hardware-decoding](https://github.com/StaZhu/enable-chromium-hevc-hardware-decoding)
which enables HEVC in Chromium's `<video>`/MSE FFmpeg path. They are a
prerequisite — without them, the FFmpeg HEVC decoder symbols aren't compiled
in. Re-snapshotted here against Chromium M145.

The `rtc-video-decoder-adapter-allow-hevc-software-fallback` patch and all
WebRTC-side changes (the H.265 decoder code at the repo root) are local work.

## Prerequisites

- Chromium source synced to the commit in `chromium-version.txt`
- `depot_tools` in PATH
- Windows: VS Build Tools 2022 (17.14+), Windows SDK 26100, Debugging Tools
  for Windows
- ~30 GB free on the build drive (slim dev config, no LTO, no symbols)

## Quick start

The intended workflow uses gclient `custom_deps` so that this branch lands at
`src/third_party/webrtc/` automatically when you sync Chromium. Then the
scripts at `chromium-patches/scripts/` just work — no env vars needed.

In your `.gclient` file (at the parent of `src/`):

```python
solutions = [
  {
    "name": "src",
    "url": "https://chromium.googlesource.com/chromium/src.git",
    "managed": False,
    "custom_deps": {
      "src/third_party/webrtc":
        "https://github.com/deepsentinel/webrtc.git@deepsentinel/m145-sw-hevc-decoder",
    },
    "custom_vars": {},
  },
]
```

Then:

```bash
# 1. Sync Chromium to the pinned commit
cd /path/to/chromium/src
git fetch && git checkout $(awk -F= '/^chromium-commit/{print $2}' \
  third_party/webrtc/chromium-patches/chromium-version.txt)
gclient sync -D

# 2. Apply patches (auto-detects CHROMIUM_SRC from the script's location)
bash third_party/webrtc/chromium-patches/scripts/apply.sh

# 3. Build
bash third_party/webrtc/chromium-patches/scripts/build.sh
```

If you cloned the webrtc fork separately (e.g. just to read the patches),
set `CHROMIUM_SRC` explicitly:

```bash
export CHROMIUM_SRC=/path/to/chromium/src
bash chromium-patches/scripts/apply.sh
```

## Verifying the build

After `chrome.exe` builds, launch it with a fresh profile:

```powershell
chrome.exe --user-data-dir=C:\temp\hevc-test-profile
```

In DevTools console on `about:blank`:

```js
const recv = RTCRtpReceiver.getCapabilities('video').codecs;
console.log('H265 entries:', recv.filter(c => c.mimeType === 'video/H265'));
```

Expect 2 entries (Main + Main10 at Level 3.1). If empty, the WebRTC fork
isn't wired in correctly — `apply.sh` will warn at the top if
`third_party/webrtc` is on the wrong branch.

End-to-end verification needs an actual H.265 RTP sender. Confirmed working
against a production peer; in `chrome://webrtc-internals` look for:

- `inbound-rtp.codec` = `H265 (...)`
- `inbound-rtp.decoderImplementation` = `"FFmpeg"`
- `inbound-rtp.powerEfficientDecoder` = `false`
- `inbound-rtp.framesDecoded` increasing

## Distribution to other workstations

For internal deployment to GPU-less Windows targets, run `package.sh`
after a successful build to produce a portable, runtime-only zip:

```bash
bash third_party/webrtc/chromium-patches/scripts/package.sh
# output: ./dist/chrome-hevc-portable-149.0.7826.0.zip   (~400 MB)
```

The recipient unzips the archive and double-clicks `chrome.exe` — no
installer, no registry, no admin rights. SmartScreen will warn on first
run because the binary is unsigned (click "More info → Run anyway").

To bundle Visual C++ runtime DLLs into the zip so recipients don't need
to install the redistributable separately, set `VC_REDIST_DIR` first:

```bash
VC_REDIST_DIR="C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Redist\\MSVC\\14.36.32532\\x64\\Microsoft.VC143.CRT" \
  bash third_party/webrtc/chromium-patches/scripts/package.sh
```

(Adjust the version number under `MSVC\` to whatever's installed on the
build machine.) `LOCALE=all` ships every locale; default is `en-US` only,
which saves ~120 MB.

The script generates a `README.txt` and `NOTICES.txt` inside the zip
covering launch instructions, the SmartScreen warning, and licensing /
HEVC patent attribution. **For internal use only — do not redistribute
outside the company without legal review of HEVC patent obligations.**

### MSI installer (SCCM / Intune / GPO)

For managed deployment, `installer/build-msi.sh` rewraps the portable
zip as an MSI named `DeepSentinel Live Viewer`. It installs per-machine
to `C:\Program Files\DeepSentinel\Live Viewer\`, adds a Start Menu
shortcut that pins `--user-data-dir` to a per-user
`%LOCALAPPDATA%\DeepSentinel\Live Viewer\User Data` location, blocks
Omaha-based updates via Google Update policy keys, and writes an
`HKLM\SOFTWARE\DeepSentinel\Live Viewer\Version` registry value for use
as an SCCM detection rule.

```bash
# One-time on the build host: install WiX (elevated PowerShell)
winget install --id WiXToolset.WiXToolset --version 3.14.1.8722

# Build MSI from the most recent portable zip
bash third_party/webrtc/chromium-patches/installer/build-msi.sh
# output: ./dist/DeepSentinel-Live-Viewer-145.0.7632.218.msi  (~140 MB)
```

See `installer/README.md` for SCCM / Intune / GPO deployment details,
detection rule recommendations, upgrade behavior, and the caveat about
the system-wide Google Update policy keys (they will also block real
Google Chrome from updating on the same workstation).

## M145 rollback notes

Versions M146..M149 of Blink ship a regression that auto-removes the
default `<video controls>` UI for MediaStream-backed elements once
playback starts (cannot be brought back via hover or CSS
`opacity: 1 !important`). Our front-end product (LSC) relies on those
default controls for per-stream mute/unmute by guards; losing them
causes audio mixing complaints. Until the front-end ships its own
control overlay, we pin to M145 (last known good).

Three M145-specific build adjustments are baked into the ffmpeg patch
(no manual steps needed when applying):

1. **Autorename shims for HEVC source.** M149's bundled FFmpeg includes
   `libavcodec/hevc/autorename_libavcodec_hevc_{parse,parser,cabac}.c`
   pre-generated by an upstream roll script. M145's older FFmpeg snapshot
   doesn't have them, so the patch creates them as one-line `#include`
   shims pointing at the real source files.
2. **`libavcodec/x86/hevc/dequant.asm` removed from `ffmpeg_generated.gni`.**
   That SIMD asm file doesn't exist in M145's FFmpeg snapshot and no C
   code references its symbols on M145 — it was only a no-op reference
   that the M149 patch added speculatively.
3. **Per-platform `config.h` hunk #1** (the long `FFMPEG_CONFIGURATION`
   comment string in the file header) is dropped — the comment differs
   per FFmpeg snapshot and has no functional effect; the meaningful
   `CONFIG_HEVC_DECODER 1` etc. defines are in hunks #2-#4 and apply
   cleanly.
4. **Clang frontend `-O3` segfault workaround** (patch `0004`) wraps
   `list_marker.cc` and `unpositioned_list_marker.cc` in
   `#pragma clang optimize off` plus a `-Wignored-attributes` diag
   suppress (so `[[clang::always_inline]]` from the WTF strings include
   chain doesn't fail `-Werror`). Two TUs only — the rest of Blink
   compiles fine. Without this, the build deterministically crashes the
   clang frontend on those two files.

## Strict FFmpeg codecs (4K HEVC fix)

`media/ffmpeg/ffmpeg_common.cc` defines a runtime feature
`kStrictFFmpegCodecs` that, when enabled, sets `AV_EF_EXPLODE` on every
FFmpeg codec context. That promotes any FFmpeg-internal warning (including
recoverable RPS reconstruction hiccups that some 4K HEVC encoders emit) to
a fatal `AVERROR_INVALIDDATA`, killing the pipeline mid-stream. HW decode
sidesteps this entirely because it goes through D3D11VideoDecoder, not
FFmpeg.

Upstream defaults this feature **on** (security hardening for untrusted
inputs — see crbug.com/379418979). Patch `0003` flips the default to
**off** for our fork because our inputs are trusted internal sources and
hard pipeline failure on a recoverable warning is worse than the security
tradeoff. Re-enable per-launch with `--enable-features=StrictFFmpegCodecs`
if needed.

Symptom this fixes: 4K HEVC `<video>`/MSE playback aborts ~1.5 seconds in
with `PIPELINE_ERROR_DECODE`, while HW decode of the same file works.

## Maintenance / rebasing on a new Chromium milestone

The drift hot-spots, ordered by frequency of change:

1. **`media/base/supported_types.cc`** — function names around HEVC profile
   support get refactored every few milestones. Last drift:
   `IsDecoderColorSpaceSupported` → `IsColorSpaceSupported` (M147 era).
2. **`third_party/ffmpeg` config files** — must be regenerated on every
   FFmpeg roll. StaZhu maintains updated patches in his repo; cross-check
   there first.
3. **`third_party/webrtc/media/engine/internal_decoder_factory.cc`** —
   touched on every codec addition. Watch for refactor to a registry pattern
   (would simplify our integration).
4. **`HasSoftwareFallback()` in `rtc_video_decoder_adapter.cc`** — already
   on `crbug.com/355256378`; upstream may reorganize.

Recommended canary in the WebRTC code:
`static_assert(BUILDFLAG(RTC_USE_H265))` at the top of `h265_decoder_impl.cc`.

## When to cut a new milestone

When a new Chromium milestone (M150, M151, ...) becomes interesting:

1. Branch `M{X}-upstream` off the current upstream WebRTC at the commit
   Chromium pins for that milestone (look in Chromium's `DEPS`).
2. Cherry-pick the two H.265 commits onto a new
   `deepsentinel/m{X}-sw-hevc-decoder` branch off `M{X}-upstream`.
3. Re-export the chromium-side patches against the new milestone:
   ```bash
   git -C $CHROMIUM_SRC diff HEAD -- media/ \
     > chromium-patches/patches/chromium/0001-...patch
   git -C $CHROMIUM_SRC diff HEAD -- third_party/blink/ \
     > chromium-patches/patches/chromium/0002-...patch
   git -C $CHROMIUM_SRC/third_party/ffmpeg diff HEAD \
     > chromium-patches/patches/ffmpeg/0001-...patch
   ```
4. Update `chromium-version.txt` with the new pins.
5. Add the rebased patches as a third commit on the new milestone branch
   (matching this branch's pattern).
