#!/usr/bin/env bash
#
# Build a portable Chromium HEVC distribution for internal deployment.
#
# Usage:
#   bash package.sh [destination-dir]
#
# Environment variables:
#   CHROMIUM_SRC      Chromium src/ dir (auto-detected if running from
#                     src/third_party/webrtc/chromium-patches/scripts/).
#   OUT_DIR           Build output dir (default: $CHROMIUM_SRC/out/Release).
#   LOCALE            Locale to ship: an exact name like "en-US", "zh-TW",
#                     or "all" for every locale (default: en-US).
#   VC_REDIST_DIR     Optional path to a directory holding VC++ runtime
#                     DLLs (vcruntime140.dll, msvcp140.dll, ...). When
#                     set, those DLLs are bundled alongside chrome.exe so
#                     recipients don't need to install the redistributable
#                     separately. Typical value:
#                       "C:\Program Files (x86)\Microsoft Visual Studio\
#                       2022\BuildTools\VC\Redist\MSVC\<ver>\x64\
#                       Microsoft.VC143.CRT"

set -euo pipefail

DEST="${1:-./dist}"
LOCALE="${LOCALE:-en-US}"
VC_REDIST_DIR="${VC_REDIST_DIR:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Auto-detect CHROMIUM_SRC the same way apply.sh / build.sh do.
if [[ -z "${CHROMIUM_SRC:-}" ]]; then
  candidate="$(cd "$REPO_ROOT/../../.." && pwd)"
  if [[ -d "$candidate/media" && -d "$candidate/third_party/ffmpeg" ]]; then
    CHROMIUM_SRC="$candidate"
  fi
fi
if [[ -z "${CHROMIUM_SRC:-}" ]]; then
  echo "ERROR: CHROMIUM_SRC not set and could not be auto-detected" >&2
  exit 1
fi

OUT_DIR="${OUT_DIR:-$CHROMIUM_SRC/out/Release}"
if [[ ! -f "$OUT_DIR/chrome.exe" ]]; then
  echo "ERROR: $OUT_DIR/chrome.exe not found. Build first with scripts/build.sh." >&2
  exit 1
fi

CHROME_VER="$(awk -F= '/^chromium=/{print $2}' "$REPO_ROOT/chromium-version.txt")"
PACKAGE_NAME="chrome-hevc-portable-${CHROME_VER}"
STAGE="$DEST/$PACKAGE_NAME"

echo "==> staging $STAGE"
rm -rf "$STAGE"
mkdir -p "$STAGE"

# Whitelisted runtime executables. Build-time tools (mksnapshot, protoc,
# torque, llvm-tblgen, flatc, *_generator.exe, root_store_tool, ...) are
# deliberately excluded -- they're 400+ MB combined and never run on the
# target machine.
echo "==> copying executables"
# chrome_proxy.exe is the launcher Chrome registers as the user-facing entry
# point; chrome_pwa_launcher.exe is invoked when launching installed PWAs;
# notification_helper.exe handles toast notifications. All three are
# referenced by chrome.exe at runtime, so omit them at your peril.
for exe in chrome.exe chrome_proxy.exe chrome_pwa_launcher.exe \
           elevation_service.exe elevated_tracing_service.exe \
           notification_helper.exe; do
  if [[ -f "$OUT_DIR/$exe" ]]; then
    cp "$OUT_DIR/$exe" "$STAGE/"
  fi
done
# Include the .exe.manifest files (none are emitted on most builds because
# manifests are linked-in, but copy any that exist) AND the version-named
# Side-by-Side assembly manifest (e.g. 149.0.7826.0.manifest) which chrome.exe
# resolves at startup. Without it Windows refuses to launch with
# "side-by-side configuration is incorrect".
cp "$OUT_DIR"/*.exe.manifest "$STAGE/" 2>/dev/null || true
cp "$OUT_DIR"/*.manifest "$STAGE/" 2>/dev/null || true

echo "==> copying runtime DLLs (skipping debug/validation layers)"
for dll in "$OUT_DIR"/*.dll; do
  base="$(basename "$dll")"
  case "$base" in
    # Skip the Vulkan validation layer -- 19 MB, debug-only.
    VkLayer_*) continue ;;
  esac
  cp "$dll" "$STAGE/"
done

echo "==> copying resources (paks, snapshots, ICU)"
cp "$OUT_DIR"/*.pak "$STAGE/" 2>/dev/null || true
cp "$OUT_DIR"/*.bin "$STAGE/" 2>/dev/null || true
cp "$OUT_DIR"/icudtl.dat "$STAGE/"

if [[ -d "$OUT_DIR/swiftshader" ]]; then
  echo "==> copying swiftshader (SW GPU fallback for GPU-less hosts)"
  cp -r "$OUT_DIR/swiftshader" "$STAGE/"
fi

# Runtime data subdirectories. Chrome looks up these paths relative to its
# executable for various features. Missing them doesn't crash the browser
# but causes degraded behaviour (no media-engagement preload, no privacy
# sandbox attestations, no ANGLE shader cache, etc.). Build-internal
# directories (gen/, obj/, jsproto/, pyproto/, initialexe/, the toolchain
# trees) are deliberately excluded.
echo "==> copying runtime data subdirectories"
for d in MEIPreload PrivacySandboxAttestationsPreloaded angledata \
         hyphen-data resources IwaKeyDistribution; do
  if [[ -d "$OUT_DIR/$d" ]]; then
    cp -r "$OUT_DIR/$d" "$STAGE/" && echo "  + $d/"
  fi
done

echo "==> copying locales (LOCALE=$LOCALE)"
mkdir -p "$STAGE/locales"
if [[ "$LOCALE" == "all" ]]; then
  cp "$OUT_DIR/locales/"*.pak "$STAGE/locales/"
else
  if [[ -f "$OUT_DIR/locales/$LOCALE.pak" ]]; then
    cp "$OUT_DIR/locales/$LOCALE.pak" "$STAGE/locales/"
  else
    echo "WARN: $LOCALE.pak not found; falling back to en-US.pak" >&2
    cp "$OUT_DIR/locales/en-US.pak" "$STAGE/locales/"
  fi
fi

if [[ -n "$VC_REDIST_DIR" && -d "$VC_REDIST_DIR" ]]; then
  echo "==> bundling VC++ runtime DLLs from $VC_REDIST_DIR"
  for dll in vcruntime140.dll vcruntime140_1.dll msvcp140.dll msvcp140_1.dll msvcp140_2.dll concrt140.dll; do
    if [[ -f "$VC_REDIST_DIR/$dll" ]]; then
      cp "$VC_REDIST_DIR/$dll" "$STAGE/"
    fi
  done
fi

echo "==> generating README.txt"
cat > "$STAGE/README.txt" <<EOF
Chromium HEVC build (M${CHROME_VER})
====================================

Internal build of Chromium with software HEVC (H.265) decode enabled in
the WebRTC code path. For internal use only -- do not redistribute.

How to run
----------
Double-click chrome.exe.

For a clean test profile that won't touch your real Chrome data, run
from PowerShell or cmd:
  chrome.exe --user-data-dir=C:\\temp\\chromium-hevc

If Windows SmartScreen warns "Windows protected your PC":
  click "More info" -> "Run anyway".
This binary is not code-signed; the warning is expected and one-time
per machine. Defender or other AV may also quarantine the binary;
whitelist the install directory in your AV settings if so.

Prerequisites
-------------
- Windows 10 or later, 64-bit.
- Visual C++ Redistributable 2015-2022 (x64). Skip if a vcruntime140.dll
  is present alongside chrome.exe in this folder; it's bundled for you.
  Otherwise install from:
  https://aka.ms/vs/17/release/vc_redist.x64.exe

Verifying HEVC WebRTC works
---------------------------
Open chrome://webrtc-internals during an HEVC RTP call. Look for the
inbound-rtp video stream. You should see:
  codec                  = H265 (...)
  decoderImplementation  = "FFmpeg"
  powerEfficientDecoder  = false
  framesDecoded          = increasing

Notices
-------
See NOTICES.txt for licensing and patent attribution.
EOF

echo "==> generating NOTICES.txt"
WEBRTC_FORK="$(awk -F= '/^webrtc-fork=/{print $2}' "$REPO_ROOT/chromium-version.txt")"
WEBRTC_BRANCH="$(awk -F= '/^webrtc-fork-branch=/{print $2}' "$REPO_ROOT/chromium-version.txt")"
CHROMIUM_COMMIT="$(awk -F= '/^chromium-commit=/{print $2}' "$REPO_ROOT/chromium-version.txt")"
FFMPEG_COMMIT="$(awk -F= '/^ffmpeg-commit=/{print $2}' "$REPO_ROOT/chromium-version.txt")"
cat > "$STAGE/NOTICES.txt" <<EOF
Third-party notices and attribution for this build.
====================================================

Chromium
  Source: https://www.chromium.org/Home
  Pinned commit: $CHROMIUM_COMMIT
  License: BSD-3-Clause and others; see Chromium tree LICENSE files.

WebRTC (modified to add software HEVC decode)
  Source: $WEBRTC_FORK
  Branch: $WEBRTC_BRANCH
  License: BSD-3-Clause.

FFmpeg (configured with HEVC parser and decoder)
  Source: https://www.ffmpeg.org/
  Pinned commit: $FFMPEG_COMMIT
  Patches: $WEBRTC_FORK
          (path: chromium-patches/patches/ffmpeg/)
  License: LGPL-2.1+ under this build's configuration.

HEVC patent notice
  This software contains an HEVC (H.265) decoder. HEVC is covered by
  patents administered by MPEG-LA, Access Advance, and Velos Media.
  Internal organisational use does not automatically waive license
  obligations. Contact your legal department if uncertain.

Source code availability (LGPL compliance)
  The modified FFmpeg source is available at the WebRTC fork URL above,
  under chromium-patches/patches/ffmpeg/. Contact the build owner for
  a tarball if external network access is restricted.
EOF

echo "==> staging size: $(du -sh "$STAGE" | cut -f1)"

ZIP_PATH="$DEST/$PACKAGE_NAME.zip"
echo "==> zipping to $ZIP_PATH"
rm -f "$ZIP_PATH"
if command -v 7z >/dev/null 2>&1; then
  ( cd "$DEST" && 7z a -tzip -mx=9 "$PACKAGE_NAME.zip" "$PACKAGE_NAME" >/dev/null )
elif command -v zip >/dev/null 2>&1; then
  ( cd "$DEST" && zip -qr9 "$PACKAGE_NAME.zip" "$PACKAGE_NAME" )
else
  # Native Windows fallback. Slower than 7z but ships with Win10+.
  PS_DEST="$(cygpath -w "$DEST" 2>/dev/null || echo "$DEST")"
  powershell.exe -NoProfile -Command \
    "Compress-Archive -Path '$PS_DEST\\$PACKAGE_NAME' -DestinationPath '$PS_DEST\\$PACKAGE_NAME.zip' -CompressionLevel Optimal -Force"
fi

echo "==> done"
echo "    package: $ZIP_PATH"
[[ -f "$ZIP_PATH" ]] && echo "    size:    $(du -h "$ZIP_PATH" | cut -f1)"
echo
echo "    Recipient steps:"
echo "      1. Unzip $PACKAGE_NAME.zip"
echo "      2. Double-click $PACKAGE_NAME\\chrome.exe"
echo "      3. (First run) click 'More info' -> 'Run anyway' on the SmartScreen prompt"
