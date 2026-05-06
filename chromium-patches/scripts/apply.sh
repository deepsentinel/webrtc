#!/usr/bin/env bash
#
# Apply all patches needed to enable software HEVC decode in Chromium WebRTC.
#
# Auto-detects the Chromium src/ directory when this script is run from its
# normal location at src/third_party/webrtc/chromium-patches/scripts/. If you
# checked out chromium-patches somewhere else (e.g. for reference), set
# CHROMIUM_SRC explicitly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# When this lives at src/third_party/webrtc/chromium-patches/, the Chromium
# src/ directory is three levels up from REPO_ROOT.
if [[ -z "${CHROMIUM_SRC:-}" ]]; then
  candidate="$(cd "$REPO_ROOT/../../.." && pwd)"
  if [[ -d "$candidate/media" && -d "$candidate/third_party/ffmpeg" ]]; then
    CHROMIUM_SRC="$candidate"
    echo "==> auto-detected CHROMIUM_SRC=$CHROMIUM_SRC"
  fi
fi

if [[ -z "${CHROMIUM_SRC:-}" ]]; then
  echo "ERROR: set CHROMIUM_SRC to your Chromium src/ directory" >&2
  echo "  example: export CHROMIUM_SRC=/c/src/chromium/src" >&2
  exit 1
fi

if [[ ! -d "$CHROMIUM_SRC/media" || ! -d "$CHROMIUM_SRC/third_party/ffmpeg" ]]; then
  echo "ERROR: $CHROMIUM_SRC does not look like a Chromium src/ directory" >&2
  exit 1
fi

# Pre-flight: warn if third_party/webrtc isn't on the expected fork branch.
# Catches the most common misconfiguration: gclient custom_deps not set, so
# webrtc is upstream and the H265DecoderImpl is missing.
EXPECTED_BRANCH="$(awk -F= '/^webrtc-fork-branch=/{print $2}' "$REPO_ROOT/chromium-version.txt")"
ACTUAL_BRANCH="$(cd "$CHROMIUM_SRC/third_party/webrtc" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
if [[ "$ACTUAL_BRANCH" != "$EXPECTED_BRANCH" ]]; then
  echo "WARN: $CHROMIUM_SRC/third_party/webrtc is on '$ACTUAL_BRANCH'" >&2
  echo "      expected '$EXPECTED_BRANCH' per chromium-version.txt" >&2
  echo "      gclient custom_deps may not be configured correctly" >&2
fi

apply_patch() {
  local target_dir="$1"
  local patch_file="$2"
  echo "==> applying $(basename "$patch_file") to $target_dir"
  ( cd "$target_dir" && git apply --check "$patch_file" ) || {
    echo "ERROR: $patch_file does not apply cleanly to $target_dir" >&2
    echo "       Has the upstream commit drifted? See chromium-version.txt for the pinned commits." >&2
    exit 1
  }
  ( cd "$target_dir" && git apply "$patch_file" )
}

echo "=== Chromium-side patches ==="
for p in "$REPO_ROOT/patches/chromium"/*.patch; do
  apply_patch "$CHROMIUM_SRC" "$p"
done

echo "=== FFmpeg-side patches ==="
for p in "$REPO_ROOT/patches/ffmpeg"/*.patch; do
  apply_patch "$CHROMIUM_SRC/third_party/ffmpeg" "$p"
done

echo
echo "All patches applied. Next steps:"
echo "  1. bash $REPO_ROOT/scripts/build.sh"
echo "     (or copy config/args.gn to out/Release and run autoninja yourself)"
