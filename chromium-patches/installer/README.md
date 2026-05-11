# DeepSentinel Live Viewer MSI installer

WiX-based MSI installer that wraps the portable Chromium HEVC build for
SCCM / Intune / GPO deployment to internal Windows workstations.

The MSI consumes the zip produced by `scripts/package.sh` — there is no
separate Chromium build step here. Build the portable zip first; this
installer just rewraps it.

## What the MSI does

- Installs to `C:\Program Files\DeepSentinel\Live Viewer\`
- Adds a Start Menu shortcut at `DeepSentinel\DeepSentinel Live Viewer`
  that launches `live-viewer.bat`, which:
  - Resolves `--user-data-dir` to
    `%LOCALAPPDATA%\DeepSentinel\Live Viewer\User Data` (per-user profile
    on a per-machine install — different `%LOCALAPPDATA%` per user)
  - Passes `--no-default-browser-check` and `--disable-component-update`
  - Forwards any extra args (`%*`) so debug flags can be appended via
    a copy-edited shortcut
- Adds an Add/Remove Programs entry with the full Chromium version
  string (e.g. `145.0.7632.218`)
- Writes Google Update policy keys to block any Omaha-based update
  attempt should it ever be sideloaded:
  - `HKLM\SOFTWARE\Policies\Google\Update\UpdateDefault = 0`
  - `HKLM\SOFTWARE\Policies\Google\Update\InstallDefault = 0`
  - `HKLM\SOFTWARE\Policies\Google\Update\AutoUpdateCheckPeriodMinutes = 0`
- Writes product identification (useful as an SCCM detection rule):
  - `HKLM\SOFTWARE\DeepSentinel\Live Viewer\Version`
  - `HKLM\SOFTWARE\DeepSentinel\Live Viewer\InstallPath`

## What the MSI does NOT do

- No file associations — not the default browser, doesn't register one
- No native messaging hosts
- No services or scheduled tasks
- No firewall rule changes
- No code signing — the binary is unsigned, SmartScreen will warn on
  first run until an EV cert is procured. For SCCM-pushed installs in a
  trusted enterprise environment that is typically a tolerated state.

## Caveat: Google Update policy keys are system-wide

`HKLM\SOFTWARE\Policies\Google\Update\UpdateDefault = 0` is read by
**any** Google application on the machine. If the same workstation also
runs real Google Chrome and needs that Chrome to auto-update, this
policy will block it. Drop `UpdatePoliciesComponent` from the `Feature`
in `DeepSentinelLiveViewer.wxs` if that applies to your fleet.

## Prerequisites

- A successful build (`scripts/build.sh`) and a portable zip
  (`scripts/package.sh`). The MSI builder reads the zip from `dist/`.
- WiX Toolset v3.14 on the build host. The build script auto-probes
  `PATH` and the default Program Files install path.

Install WiX once (elevated PowerShell — installer enables .NET 3.5):

```powershell
winget install --id WiXToolset.WiXToolset --version 3.14.1.8722 `
  --silent --accept-package-agreements --accept-source-agreements
```

## Build

From `chromium-patches/` (or anywhere — the script auto-locates):

```bash
bash installer/build-msi.sh
# output: ./dist/DeepSentinel-Live-Viewer-145.0.7632.218.msi  (~140 MB)
```

Optional explicit args:

```bash
bash installer/build-msi.sh /path/to/some-portable.zip /path/to/output/
```

## Smoke test on a dev machine

```powershell
# Install (elevated)
msiexec /i "DeepSentinel-Live-Viewer-145.0.7632.218.msi" /qb /l*v install.log

# Verify files + ARP + policies
Test-Path "C:\Program Files\DeepSentinel\Live Viewer\chrome.exe"
Get-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\* `
  | Where-Object DisplayName -eq "DeepSentinel Live Viewer"
Get-ItemProperty HKLM:\SOFTWARE\Policies\Google\Update
Get-ItemProperty "HKLM:\SOFTWARE\DeepSentinel\Live Viewer"

# Launch
& "C:\Program Files\DeepSentinel\Live Viewer\live-viewer.bat"

# Uninstall
msiexec /x "DeepSentinel-Live-Viewer-145.0.7632.218.msi" /qn /l*v uninstall.log
```

## Deployment to managed workstations

### SCCM / Configuration Manager

Create an Application with the MSI as the deployment type. SCCM picks
up the ProductCode automatically. Recommended detection rule (more
stable than the auto-derived one because ProductCode changes per build
but our `Version` registry value is canonical):

- Type: Registry
- Hive: `HKLM`
- Key: `SOFTWARE\DeepSentinel\Live Viewer`
- Value: `Version`
- Match: equals `145.0.7632.218` (or whatever you're deploying)

Install: `msiexec /i "DeepSentinel-Live-Viewer-145.0.7632.218.msi" /qn`
Uninstall: `msiexec /x {ProductCode} /qn` — derive `{ProductCode}` from
the MSI metadata (`Get-ItemProperty` on the Uninstall registry key).

### Intune

Upload as a Win32 app. Wrap with `IntuneWinAppUtil.exe` for predictable
detection / behavior, but raw MSI works too.

Detection rule: same registry-based one as SCCM.

### Group Policy Software Installation

Place the MSI on a UNC share readable by Domain Computers, assign via
Computer Configuration > Software Settings > Software Installation.
GPSI re-runs on next boot if the install is missing.

## Upgrade behavior

- Stable `UpgradeCode`: `8A1F9E2D-5C4B-4A3F-9E7D-6B8C0A1F2E3D`
- New `ProductCode` per MSI build (the `Id="*"` in the `.wxs`)
- `MajorUpgrade` removes the prior install before laying down the new
  one (no separate uninstall step needed)
- Downgrade is blocked with a clear error dialog
- Same-version reinstall is allowed (handy during dev)

Bumping versions: rebuild the portable zip with a newer Chromium →
`build-msi.sh` reads `chromium-version.txt` and stamps the new
`ProductVersion` automatically. Existing installs upgrade in place.

## Coexistence with real Google Chrome

The MSI's install path, Start Menu folder, registry keys, and
user-data-dir are all under `DeepSentinel\` — nothing overlaps with a
real Google Chrome install. Both browsers can run side-by-side on the
same workstation; their profiles cannot accidentally cross-pollinate.

The one caveat is the Google Update policy keys — see "Caveat" section
above.

## Limitations / TODOs

- **Unsigned.** EV code-signing cert needed before this can be
  deployed outside the company or to less-managed environments. The
  build script will accept a `signtool.exe` post-step if a cert lands
  later — see `light.exe` `-spdb` flag area.
- **No custom branding icon** — ARP entry pulls chrome.exe's embedded
  icon. Drop a `.ico` in `installer/` and reference it in the
  `<Icon>` element to override.
- **ARP DisplayVersion shows only 3 fields** (e.g. `145.0.7632`) rather
  than the full Chromium 4-field version (`145.0.7632.218`). This is a
  Windows Installer quirk: MSI's ProductVersion is capped at
  `major.minor.build` and ARP's DisplayVersion column mirrors it. We
  tried `<Property Id="ARPDISPLAYVERSION">` (static) and `<SetProperty
  Id="ARPDISPLAYVERSION">` (runtime) — neither overrides the registry
  write reliably on this MSI 5.0 host. The full version *is* preserved
  in `HKLM\SOFTWARE\DeepSentinel\Live Viewer\Version`, which is the
  recommended SCCM detection target anyway. A bullet-proof fix would
  write the `DisplayVersion` registry value directly via a
  `<RegistryValue>` component; deferred until somebody actually needs
  the 4-field display.
- **WiX v3 specifically.** Porting to WiX v6 (the dotnet-tool CLI) is
  ~30 min of mechanical schema edits and a one-line build invocation
  change. Punted until WiX v3 is end-of-life.
