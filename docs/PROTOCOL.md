# Observed HEAVN One BLE protocol

Verified on one HEAVN One Series II, firmware `4.5.2`, on 20 November 2026. These are observations from that device, not a complete or guaranteed vendor API. No HEAVN Wi-Fi endpoint was identified during discovery; successful control used Bluetooth Low Energy.

## Transport

The lamp advertises a Nordic UART service. The clients discover by service UUID and exact advertised name, subscribe to notifications, and send UTF-8/ASCII commands.

| Role | UUID |
| --- | --- |
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| Write | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |
| Notify | `6E400003-B5A3-F393-E0A9-E50E24DCCA9E` |

The tested write characteristic supports both writes with response and writes without response. Queries and presence settings use writes with response; simulated button events use writes without response. Close the HEAVN app so it releases its connection before connecting another controller.

## Queries

| Command | Observed response | Meaning |
| --- | --- | --- |
| `@s` | `$s1111` / `$s0000` | Power; final digit represents overall on/off |
| `@e` | `$e0` / `$e1` | Automatic / manual lighting |
| `@V` | `$V4.5.2` | Firmware |
| `@Q` | `$I085.030.085` | Brightness values; writes untested |
| `@o` | `$O1:00600` | Presence shutoff enabled, timeout 600 seconds |

The presence query is lowercase `o`; its response prefix is uppercase `O`.

## Preserve automatic lighting while pausing motion shutoff

Read and save the entire original presence value before changing it. Given the observed original `$O1:00600`:

```text
@O0:00600    pause motion shutoff, preserving the timeout duration
@o          verify response $O0:00600
@e          verify response $e0 (automatic lighting)
```

Restore with `@O1:00600` and verify using `@o`. Do not assume 600 seconds for another lamp: preserve the actual original flag and five-digit duration. The app refuses to enable the override unless automatic lighting is already active. It turns power on if necessary and verifies both power and mode afterward.

The lamp retains this setting independently of the Mac. The app saves the original value before writing so it can restore after a failed operation or restart. Normal toggle-off and Quit restore it; force-quitting or losing connectivity can leave restoration pending.

## Power button simulation

A toggle requires both press and release:

```text
@KXXXXXD    press
            wait 250 milliseconds
@KXXXXXU    release
            wait 500 milliseconds
@s          verify power
```

A press without release produced no visible change. Full pairs produced `$s1111 → $s0000 → $s1111`, also confirmed visually. Automatic mode remained active after the power tests. The clients read current state before implementing explicit on/off actions.

Brightness and colour-temperature writes are not implemented or verified. Device firmware updates and other models may behave differently.

## References

- [HEAVN support](https://heavn-lights.com/en/pages/support): Bluetooth app connection.
- [HEAVN One Desk manual](https://cdn.shopify.com/s/files/1/0508/0186/8972/files/Manual_Bedienungsanleitung_HEAVN_One_Desk_v1.7.pdf?v=1699916421): Bluetooth instructions.
- [Public reverse-engineering discussion](https://www.reddit.com/r/ReverseEngineering/comments/1g43d8j/reverseengineering_ble_commands_for_lamp/): partial command examples.
- [Experimental community Home Assistant project](https://github.com/monofox/ha-heavn-one): reference only; not a dependency of this code.
