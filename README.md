# HEAVN One for Mac

A small macOS menu bar app that keeps a HEAVN One lamp on while you sit still, preserving its automatic brightness and colour schedule.

**Keep Lamp On** pauses the lamp's native motion timeout and turns the lamp on if needed. Turning the toggle off, or quitting normally, restores the previous motion setting. It uses Bluetooth Low Energy directly; the HEAVN app and a Wi-Fi API are not required.

Tested with a HEAVN One Series II advertising as `HEAVN_One2 67a9`, firmware `4.5.2`. Other models and firmware have not been verified. This is an unofficial project, unaffiliated with HEAVN.

## Build and run

Requirements:

- macOS 13 or later with Bluetooth Low Energy.
- Xcode command-line tools (`xcode-select --install` if they are missing).
- No third-party Swift packages or Python packages are needed.

```sh
git clone https://github.com/JH1ller/HEAVN-One-Mac.git
cd HEAVN-One-Mac
./scripts/build.sh
open "build/HEAVN Keep Awake.app"
```

The script creates the complete `.app` bundle, compiles for the Mac's current architecture, and ad-hoc signs and verifies it. The app is not notarized for distribution. Build from source locally; an Apple Developer account is not needed for this build.

The current source targets the exact Bluetooth name `HEAVN_One2 67a9`. For another lamp, change `LampConnection.name` near the top of [Sources/HEAVNMenu.swift](Sources/HEAVNMenu.swift) before building. Exact matching avoids changing a nearby lamp accidentally.

Close any previous instance before launching a newly built copy. You can copy the generated app to Applications and run it there. It has no Dock icon and does not configure automatic launch at login.

## Use the menu bar toggle

1. Power the lamp, enable Bluetooth on the Mac, and stay within range.
2. Select automatic lighting in the HEAVN app, then close the HEAVN app to release its Bluetooth connection.
3. Open the Mac app and allow its Bluetooth permission when prompted.
4. Click the lightbulb and **HEAVN** in the menu bar, then select **Keep Lamp On**.

The status should show **Auto lighting · Motion timeout paused**. Automatic lighting remains active; the app does not write brightness, colour temperature, scene, clock or location settings.

Once the override is applied, the Mac can sleep: the setting lives on the lamp. The app connects briefly for changes and status reads, then disconnects. It refreshes status every minute while the Mac is awake and after wake. It does not continuously reapply an override changed by another controller.

Uncheck **Keep Lamp On** to restore the original presence setting without turning the lamp off. **Quit** also attempts to restore before exiting. The original value is saved in macOS preferences before the first write and retained until restoration is verified.

If the app is force-quit, or cannot reach the lamp during restoration, the override may remain. Reopen the same app within lamp range and turn the toggle off to restore it. If an operation fails, a checkmark can mean restoration is still pending; read the status and use **Refresh Lamp Status** before retrying. Do not delete the app's preferences while restoration is pending.

To launch a closed app and immediately enable the override:

```sh
open "build/HEAVN Keep Awake.app" --args --enable
```

## Command-line control

[tools/heavn.swift](tools/heavn.swift) provides JSON output for power and status:

```sh
swift tools/heavn.swift status
swift tools/heavn.swift on
swift tools/heavn.swift off
swift tools/heavn.swift toggle
```

The optional final argument selects an exact Bluetooth name:

```sh
swift tools/heavn.swift status "HEAVN_One2 1234"
```

`on` and `off` read power first, change it only when needed, and verify the result. `test` changes power for two seconds and attempts to restore the initial state. Errors exit nonzero. A timeout can happen after a command reaches the lamp; query status before retrying a toggle.

The CLI does not expose the motion override; use the menu bar app for that. It reads brightness but does not implement brightness or colour-temperature writes. Avoid overlapping the menu app's Bluetooth operations with CLI or bridge requests.

## Home Assistant

An optional authenticated HTTP bridge lets Home Assistant call power actions through the Mac:

**Home Assistant → LAN HTTP → Mac → Bluetooth → HEAVN**

See [Home Assistant setup](docs/HOME_ASSISTANT.md) and the [example configuration](docs/home-assistant.yaml). The bridge needs an awake Mac in Bluetooth range; the menu app's native motion override does not. Home Assistant Green needs no additional radio when using this HTTP bridge.

## Files and verification

| Path | Purpose |
| --- | --- |
| `Sources/HEAVNMenu.swift` | AppKit menu bar app and Bluetooth motion override |
| `Resources/Info.plist` | Bundle identity, menu bar mode and Bluetooth permission text |
| `scripts/build.sh` | Build, bundle and ad-hoc signing |
| `tools/heavn.swift` | Standalone Bluetooth power/status controller |
| `tools/heavn_bridge.py` | Optional Python standard-library HTTP bridge |
| `docs/PROTOCOL.md` | Commands, timing, observed responses and references |

Hardware verification on 20 November 2026 confirmed power **on → off → on**, automatic mode retained, presence timeout disabled and restored, and authenticated bridge status/off/on through loopback. Home Assistant installation and access from a second LAN host were not tested. The build script has also been checked from a fresh source checkout. No lamp interaction is needed to build the app.

For protocol details and compatibility limits, see [docs/PROTOCOL.md](docs/PROTOCOL.md).
