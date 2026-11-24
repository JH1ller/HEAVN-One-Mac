# Home Assistant HTTP bridge

The bridge provides power control through an awake Mac within Bluetooth range of the lamp. It uses Python 3's standard library and invokes the colocated Swift controller for each request. Keep `tools/heavn_bridge.py` and `tools/heavn.swift` together, install the macOS Swift command-line tools, and close the HEAVN phone app while controlling the lamp.

## Start the bridge

Generate a token once and save it securely:

```sh
python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
```

From the repository root, start the bridge with that token and your Mac's actual LAN address:

```sh
HEAVN_BRIDGE_HOST='YOUR_MAC_LAN_IP' \
HEAVN_BRIDGE_TOKEN='YOUR_SAVED_TOKEN' \
python3 tools/heavn_bridge.py
```

Reserve the Mac's address in your router so Home Assistant can keep reaching it. Leave the process running; Ctrl-C stops it. No background service is installed. If macOS asks, allow local incoming connections.

The server defaults to `127.0.0.1:8765`, which is accessible only from the Mac. `HEAVN_BRIDGE_HOST` changes the listening address; `HEAVN_BRIDGE_PORT` changes the port. `HEAVN_DEVICE_NAME` selects an exact Bluetooth name and defaults to `HEAVN_One2 67a9`.

The bridge uses plain HTTP with a Bearer token of at least 24 characters. Use it on a trusted LAN and do not expose its port to the internet. No token is stored in this repository.

## Home Assistant configuration

Add the same saved token to Home Assistant's `secrets.yaml`:

```yaml
heavn_bridge_authorization: "Bearer YOUR_SAVED_TOKEN"
```

Merge [home-assistant.yaml](home-assistant.yaml) into `configuration.yaml`, replacing every `MAC_LAN_IP` placeholder. If you already have a `rest_command:` section, merge the three entries into that section. Check the configuration, then reload RESTful Commands or restart Home Assistant as appropriate for your version.

From Developer Tools → Actions, run `rest_command.heavn_on` or `rest_command.heavn_off`. Use the same actions in automations:

```yaml
actions:
  - action: rest_command.heavn_on
```

## HTTP API

Every endpoint requires `Authorization: Bearer YOUR_SAVED_TOKEN`.

| Method | Path | Action |
| --- | --- | --- |
| GET | `/status` | Read power, automatic mode, firmware and brightness response |
| POST | `/on` | Ensure power is on and verify |
| POST | `/off` | Ensure power is off and verify |
| POST | `/toggle` | Invert power and verify |

Prefer `/on` and `/off` for automations. The server serializes its own requests, but cannot coordinate with another app connecting over Bluetooth. Avoid overlapping menu app and bridge operations. A request may time out after reaching the lamp; query `/status` before retrying `/toggle`.

Authenticated status, off and on requests were verified on loopback with the real lamp, along with rejection of missing authentication and the wrong HTTP method. Access from Home Assistant or a second LAN host has not been verified. This bridge controls power, not the motion-timeout override.

Reference: [Home Assistant RESTful Command integration](https://www.home-assistant.io/integrations/rest_command/).
