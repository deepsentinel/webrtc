#!/usr/bin/env bash
#
# Build the patched Chromium with HEVC WebRTC SW decode.
# Assumes scripts/apply.sh has already run successfully.
#
# Auto-detects CHROMIUM_SRC the same way apply.sh does.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

if [[ -z "${CHROMIUM_SRC:-}" ]]; then
  candidate="$(cd "$REPO_ROOT/../../.." && pwd)"
  if [[ -d "$candidate/media" && -d "$candidate/third_party/ffmpeg" ]]; then
    CHROMIUM_SRC="$candidate"
  fi
fi

if [[ -z "${CHROMIUM_SRC:-}" ]]; then
  echo "ERROR: set CHROMIUM_SRC to your Chromium src/ directory" >&2
  exit 1
fi

mkdir -p "$CHROMIUM_SRC/out/Release"
cp "$REPO_ROOT/config/args.gn" "$CHROMIUM_SRC/out/Release/args.gn"
echo "==> wrote $CHROMIUM_SRC/out/Release/args.gn"

# Windows builds require these env vars; harmless on other OSes.
export PYTHONUTF8=1
if [[ -z "${vs2022_install:-}" && "$OSTYPE" == "msys" ]]; then
  export vs2022_install="C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools"
  echo "==> defaulted vs2022_install (override the env var to use a different VS install)"
fi

cd "$CHROMIUM_SRC"
echo "==> running gn gen out/Release"
gn gen out/Release

# M145's bundled siso predates the -heartbeat_period flag that current
# depot_tools' autoninja passes, so autoninja crashes immediately. We
# bypass autoninja+siso and call the bundled ninja.exe directly. This
# disables remote-execution (siso's main feature) but for an internal
# fork on a single workstation that's a non-issue.
NINJA="$CHROMIUM_SRC/third_party/ninja/ninja.exe"
if [[ ! -x "$NINJA" ]]; then
  NINJA=ninja
fi

echo "==> running $NINJA -C out/Release chrome"
echo "    (this can take 4-6 hours on a 4-core laptop for a clean build,"
echo "     ~30-60 minutes for a delta build after small patches)"
"$NINJA" -C out/Release chrome
