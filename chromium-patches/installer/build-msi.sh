#!/usr/bin/env bash
#
# Build an MSI installer for DeepSentinel Live Viewer from the portable
# zip that scripts/package.sh produces.
#
# Usage:
#   bash installer/build-msi.sh [path-to-portable-zip] [output-dir]
#
# Both arguments are optional; defaults are inferred from
# chromium-version.txt and the standard package.sh output path.
#
# Environment:
#   WIX_BIN     Override path to the WiX v3 bin/ directory (containing
#               heat.exe, candle.exe, light.exe). Auto-probed via PATH
#               and the default Program Files install path.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
CHROME_VER="$(awk -F= '/^chromium=/{print $2}' "$REPO_ROOT/chromium-version.txt")"

# Default zip path matches package.sh's `./dist` (cwd-relative) default,
# so running both scripts from the same cwd Just Works.
ZIP="${1:-./dist/chrome-hevc-portable-${CHROME_VER}.zip}"
OUT_DIR="${2:-$(dirname "$ZIP")}"

if [[ ! -f "$ZIP" ]]; then
  echo "ERROR: portable zip not found at $ZIP" >&2
  echo "  Build one first with: bash scripts/package.sh" >&2
  exit 1
fi

# Probe for WiX v3. Default install path on Win11 64-bit:
#   C:\Program Files (x86)\WiX Toolset v3.14\bin\
if [[ -n "${WIX_BIN:-}" ]]; then
  :
elif command -v candle.exe >/dev/null 2>&1; then
  WIX_BIN="$(dirname "$(command -v candle.exe)")"
elif [[ -d "/c/Program Files (x86)/WiX Toolset v3.14/bin" ]]; then
  WIX_BIN="/c/Program Files (x86)/WiX Toolset v3.14/bin"
elif [[ -d "/c/Program Files/WiX Toolset v3.14/bin" ]]; then
  WIX_BIN="/c/Program Files/WiX Toolset v3.14/bin"
else
  echo "ERROR: WiX Toolset v3 not found." >&2
  echo "  Install via (elevated PowerShell):" >&2
  echo "    winget install --id WiXToolset.WiXToolset --version 3.14.1.8722 \\" >&2
  echo "      --silent --accept-package-agreements --accept-source-agreements" >&2
  echo "  Or set WIX_BIN to the bin/ dir of an existing install." >&2
  exit 1
fi

HEAT="$WIX_BIN/heat.exe"
CANDLE="$WIX_BIN/candle.exe"
LIGHT="$WIX_BIN/light.exe"

echo "==> using WiX: $WIX_BIN"

# Chromium version → MSI ProductVersion. MSI ProductVersion is
# major.minor.build with the per-field limits major < 256, minor < 256,
# build < 65536. Chromium versions are major.minor.build.patch where
# build can be up to ~8000 and patch up to ~300, so neither fits into
# the minor field directly. Match real Google Chrome's MSI: take the
# first three Chromium fields (major.minor.build = e.g. 145.0.7632) and
# drop the patch number from MSI version comparison. AllowSameVersion-
# Upgrades is enabled in the .wxs so a respin of the same Chromium build
# can still upgrade in place. Full version including patch is preserved
# in DISP_VER → ARPDISPLAYVERSION → HKLM\Software\DeepSentinel\Live
# Viewer\Version (which is what SCCM detection rules should match on).
IFS=. read -r CV_MAJOR CV_MINOR CV_BUILD CV_PATCH <<< "$CHROME_VER"
PROD_VER="${CV_MAJOR}.${CV_MINOR}.${CV_BUILD}"
DISP_VER="$CHROME_VER"
echo "==> product version: $PROD_VER (display: $DISP_VER)"

BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

STAGE="$BUILD_DIR/stage"
TMP_EXTRACT="$BUILD_DIR/extract"
mkdir -p "$TMP_EXTRACT"

echo "==> extracting $ZIP"
if command -v unzip >/dev/null 2>&1; then
  # PowerShell's Compress-Archive writes backslash path separators, which
  # makes Info-ZIP's unzip emit a "appears to use backslashes" warning and
  # return exit 1 (warning, not error). Files are still extracted fine; we
  # tolerate exit ≤ 1 so set -e doesn't kill us here.
  unzip -q "$ZIP" -d "$TMP_EXTRACT" || [[ $? -eq 1 ]]
else
  PS_ZIP="$(cygpath -w "$ZIP")"
  PS_EXTRACT="$(cygpath -w "$TMP_EXTRACT")"
  powershell.exe -NoProfile -Command \
    "Expand-Archive -Path '$PS_ZIP' -DestinationPath '$PS_EXTRACT' -Force"
fi
inner="$(find "$TMP_EXTRACT" -mindepth 1 -maxdepth 1 -type d | head -1)"
if [[ -z "$inner" || ! -d "$inner" ]]; then
  echo "ERROR: extraction did not produce a top-level directory under $TMP_EXTRACT" >&2
  exit 1
fi
mv "$inner" "$STAGE"

# Strip portable-zip-specific files: the portable chrome.bat uses a
# profile dir next to the binary (wrong for an MSI-installed Program
# Files location, which is read-only for normal users), and the
# README/NOTICES describe the portable layout. We'll regenerate the
# launcher and rely on installer/README.md for MSI-specific docs.
rm -f "$STAGE/chrome.bat" "$STAGE/README.txt" "$STAGE/NOTICES.txt"

# MSI launcher. Resolves %LOCALAPPDATA% at runtime so each user on a
# per-machine install gets their own profile. --disable-component-update
# kills the only remaining network path that might mutate the install.
cat > "$STAGE/live-viewer.bat" <<'EOF'
@echo off
setlocal
set "USER_DATA=%LOCALAPPDATA%\DeepSentinel\Live Viewer\User Data"
if not exist "%USER_DATA%" mkdir "%USER_DATA%"
start "" "%~dp0chrome.exe" --user-data-dir="%USER_DATA%" --no-default-browser-check --disable-component-update %*
endlocal
EOF

echo "==> harvesting staged tree with heat.exe"
"$HEAT" dir "$(cygpath -w "$STAGE")" \
  -ag -srd -sreg -scom -sfrag \
  -cg HarvestedFiles \
  -dr INSTALLFOLDER \
  -var var.StageDir \
  -out "$(cygpath -w "$BUILD_DIR/Harvested.wxs")"

echo "==> compiling .wxs with candle.exe"
"$CANDLE" -arch x64 -nologo \
  -dStageDir="$(cygpath -w "$STAGE")" \
  -dProductVersion="$PROD_VER" \
  -dDisplayVersion="$DISP_VER" \
  -out "$(cygpath -w "$BUILD_DIR")\\" \
  "$(cygpath -w "$SCRIPT_DIR/DeepSentinelLiveViewer.wxs")" \
  "$(cygpath -w "$BUILD_DIR/Harvested.wxs")"

mkdir -p "$OUT_DIR"
MSI_NAME="DeepSentinel-Live-Viewer-${CHROME_VER}.msi"
MSI_PATH="$OUT_DIR/$MSI_NAME"

echo "==> linking → $MSI_PATH"
# ICE57: per-user/per-machine component mixing — fired by HKCU KeyPath
#        on a perMachine install (standard MSI shortcut idiom, safe to
#        suppress).
# ICE91: warns that shortcuts targeting non-advertised files may not
#        self-heal — fine for our use case (the .bat is small and the
#        chrome.exe behind it is the actual self-healing concern).
# ICE61: warns that MajorUpgrade allows same-version upgrades, which
#        is intentional (AllowSameVersionUpgrades="yes") so respins of
#        the same Chromium build can reinstall cleanly during dev.
"$LIGHT" -nologo -spdb \
  -sice:ICE57 -sice:ICE91 -sice:ICE61 \
  -out "$(cygpath -w "$MSI_PATH")" \
  "$(cygpath -w "$BUILD_DIR/DeepSentinelLiveViewer.wixobj")" \
  "$(cygpath -w "$BUILD_DIR/Harvested.wixobj")"

echo
echo "==> done"
echo "    msi:  $MSI_PATH"
[[ -f "$MSI_PATH" ]] && echo "    size: $(du -h "$MSI_PATH" | cut -f1)"
echo
echo "    Install (interactive basic UI):"
echo "      msiexec /i \"$MSI_NAME\" /qb /l*v install.log"
echo
echo "    Silent install for SCCM/GPO/Intune:"
echo "      msiexec /i \"$MSI_NAME\" /qn /l*v install.log"
echo
echo "    Uninstall:"
echo "      msiexec /x \"$MSI_NAME\" /qn"
