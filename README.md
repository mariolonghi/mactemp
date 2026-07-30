# MacTemp

A tiny macOS menu bar app that shows the CPU temperature. A handful of Swift
files, no dependencies, no root.

Click the reading for a CPU / GPU / SoC breakdown, a °C ⇄ °F toggle, and a
Launch-at-Login toggle (on by default). Updates are one click: the app checks
GitHub Releases, and installing an update downloads, verifies, swaps and
relaunches automatically.

## Requirements

An **Apple Silicon** Mac (M1 or later) on macOS 12+. Intel Macs are not
supported — they report temperatures through the SMC, which this does not read.

## Install (recommended)

Download the latest `MacTemp-x.y.z.dmg` from
[Releases](https://github.com/mariolonghi/mactemp/releases/latest), open it,
and drag **MacTemp** to **Applications**. The DMG and the app are signed and
notarized, so macOS opens them without warnings.

The temperature appears in your menu bar straight away. There is no Dock icon
and no window — click the reading to open the menu, and use **Quit** there to
stop it. It registers itself to start at login; turn that off from the menu if
you prefer.

## Build from source

Requires **full Xcode** (from the App Store). The standalone Command Line
Tools ship an SDK that is too old to build this; the build script picks up
Xcode automatically if it's in `/Applications`.

```bash
git clone https://github.com/mariolonghi/mactemp.git
```

```bash
cd mactemp && ./packaging/build_dmg.sh && open dist/MacTemp.app
```

Without a Developer ID certificate the build is signed ad-hoc — if macOS
refuses to open it, right-click `MacTemp.app` → **Open** once and confirm.

## How it reads the temperature

Apple Silicon exposes its thermal sensors through the private
`IOHIDEventSystem` API — the same source `powermetrics` uses, but without
needing `sudo`. The symbols aren't in any public header, so `Sensors.swift`
resolves them with `dlsym` and matches on the Apple vendor temperature-sensor
HID usage page.

Readings are averaged per cluster:

| Row | Sensors |
| --- | --- |
| CPU | `pACC MTR Temp Sensor*` + `eACC MTR Temp Sensor*` (performance + efficiency cores) |
| GPU | `GPU MTR Temp Sensor*` |
| SoC | `SOC MTR Temp Sensor*` + `PMGR SOC Die Temp Sensor*` |

Sensors reporting off-scale values (idle sensors park at things like -21 °C) are
discarded. It polls every 2 seconds.

## How self-update stays safe

Before an update is installed, the downloaded app must pass three independent
checks — a tampered or fake "update" cannot get through:

1. `codesign --verify --deep --strict` — the signature is intact
2. `spctl -a -t exec` — Gatekeeper accepts it (Developer ID + notarized)
3. `TeamIdentifier` equals the pinned Team ID — signed by *this* developer,
   not just any notarized one

The old bundle is moved aside and restored if the swap fails, so an
interrupted update never leaves you without an app.

## Layout

| Path | |
| --- | --- |
| `src/main.swift` | Menu bar UI, About panel, update flow |
| `src/Sensors.swift` | IOHID thermal sensor reading |
| `src/Updates.swift` | Version check + verified one-click self-update |
| `src/LoginItem.swift` | Launch-at-login LaunchAgent |
| `src/AppInfo.swift` | Shared metadata + version compare |
| `packaging/build_dmg.sh` | Build → sign → notarize → staple → DMG pipeline |
| `.github/workflows/release.yml` | Tag push → notarized DMG on the Release |

## Releasing

Bump `CFBundleShortVersionString` in `packaging/Info.plist`, then either run
`./packaging/build_dmg.sh` locally (set `NOTARY_PROFILE=<name>` for a
notarized build) or push a `vX.Y.Z` tag and let CI build, notarize and attach
the DMG to the GitHub Release.

## License

MIT
