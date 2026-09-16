# Nit

macOS menu-bar app that drives a **Samsung Smart Monitor** from the Mac keyboard:
hardware volume, backlight, mute, power, and on-screen navigation — not a software overlay.

Samsung Smart Monitors (M5 / M7 / M8 / M9) run Tizen and do **not** speak DDC/CI, so
MonitorControl / BetterDisplay cannot see them. Nit uses **IP Control G2**
(`https://<IP>:1516/`) for absolute backlight (0–50) and volume (0–100), and the Tizen
WebSocket remote for keys (mute, power, nav).

Menu-bar only (no Dock icon). Launch at Login is on by default.

## Features

- Keyboard **volume / mute / brightness** keys go to the monitor
- With **no external display**, those keys stay with macOS (MacBook volume and screen)
- **Remote Mode** (⌃⌥R): bare arrows / Return / Esc drive the monitor
- **Auto-wake** via Wake-on-LAN when the Mac wakes
- Auto-discovery on the local /24; IP and Wi-Fi MAC are remembered

## Requirements

- macOS 13+
- Monitor on the same Wi-Fi subnet as the Mac
- On the monitor, **Settings → General → Network → Expert Settings**:
  - **IP Remote** ON (backlight and absolute volume)
  - **Power On with Mobile** ON (auto-wake)

## Install

```sh
./build.sh
```

Builds a signed `Nit.app` into `/Applications` and launches it. Grant **Accessibility**
when prompted. The first connection shows **Allow** on the monitor; after that, the token
is reused (`~/.nit_token`).

If signing picks the wrong team:

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh
```

## Shortcuts

Always-live (independent of the Forward-keys toggle):

| Shortcut | Action |
|---|---|
| ⌃⌥ ← ↑ ↓ → | Navigate |
| ⌃⌥ ↩ | OK |
| ⌃⌥ ⌫ | Back |
| ⌃⌥ H | Home |
| ⌃⌥ P | Monitor power |
| ⌃⌥ [ / ] | Backlight down / up |
| ⌃⌥ R | Remote Mode |

## Docs

- Setup and troubleshooting: [`docs/SETUP.md`](docs/SETUP.md)
- Protocol notes: [`docs/PROTOCOL.md`](docs/PROTOCOL.md)

## License

Proprietary. See [`LICENSE`](LICENSE).
