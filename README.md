# MacTemp

A tiny macOS menu bar app that shows the CPU temperature. One Swift file, no
dependencies, no root.

Click it for a CPU / GPU / SoC breakdown and a °C ⇄ °F toggle.

## Requirements

- An **Apple Silicon** Mac (M1 or later). Intel Macs are not supported — they
  report temperatures through the SMC, which this does not read.
- macOS 12 or later.
- **Full Xcode** installed (from the App Store). The standalone Command Line
  Tools ship an SDK that is too old to build this; `build.sh` picks up Xcode
  automatically if it's in `/Applications`.

## Install and run

```bash
git clone https://github.com/mariolonghi/mactemp.git
```

```bash
cd mactemp && ./build.sh && open MacTemp.app
```

The temperature appears in your menu bar straight away. There is no Dock icon
and no window — click the reading to open the menu, and use **Quit** there to
stop it.

If macOS refuses to open the app, right-click `MacTemp.app` → **Open** once and
confirm. The build is signed ad-hoc (with your own machine's key, not a paid
Developer ID), so Gatekeeper wants a one-time acknowledgement.

### Start it at login

System Settings → General → Login Items → **+** → pick `MacTemp.app`.

Keep the app where it is — the login item points at wherever you built it, so
moving the folder afterwards breaks it.

## How it reads the temperature

Apple Silicon exposes its thermal sensors through the private
`IOHIDEventSystem` API — the same source `powermetrics` uses, but without
needing `sudo`. The symbols aren't in any public header, so `main.swift`
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

## Layout

| File | |
| --- | --- |
| `main.swift` | The entire app — sensor reading and menu bar UI |
| `build.sh` | Compiles and assembles `MacTemp.app` |
| `Info.plist` | `LSUIElement` so there's no Dock icon |

## License

MIT
