# Nit

macOS menu-bar app for Samsung Smart Monitors (M5 / M7 / M8 / M9). Hardware
backlight and volume from the Mac keyboard — not a software overlay.

Samsung Smart Monitors do not speak DDC/CI. Nit uses **IP Control G2**
(`https://<IP>:1516/`) for absolute backlight (0–50) and volume (0–100), and
the Tizen WebSocket remote for keys (mute, power, nav).

```sh
DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh
```

Requires macOS 13+, Accessibility permission, and on the monitor:
**Settings → General → Network → Expert Settings → IP Remote** ON.
For auto-wake, also turn on **Power On with Mobile**.

See `docs/SETUP.md` and `docs/PROTOCOL.md`.
