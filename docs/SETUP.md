# Nit — Setup Guide

End-user setup for Nit, the macOS menu-bar app that drives a Samsung Smart Monitor
from the Mac keyboard. See [../README.md](../README.md) for the feature overview.

---

## 1. Prerequisites

- **macOS 13 (Ventura) or later** — Launch at Login uses `SMAppService`, which is 13+ only.
- **The monitor on the same /24 subnet as the Mac.** The app finds it by sweeping the
  local subnet; a different VLAN or a "guest" Wi-Fi that isolates clients will hide it.
- **Build tools**, one of:
  - Xcode (full IDE), or
  - Xcode **Command Line Tools** (`xcode-select --install`) plus `xcodegen`.
- **Homebrew** to install `xcodegen`:
  ```sh
  brew install xcodegen
  ```

---

## 2. Required monitor setting (do this first)

On the monitor, turn **ON**:

```
Settings > General > Network > Expert Settings > "Power On with Mobile"
```

**Why it matters.** The monitor has two sleep depths:

- **Network standby** — the network chip stays powered. `http://<ip>:8001/api/v2/` still
  answers (so the app can read power state and MAC) and Wake-on-LAN works.
- **Deep standby** — the network chip is off. HTTP and the WebSocket are both dead, and a
  Wake-on-LAN magic packet is the *only* thing that can wake it.

"Power On with Mobile" (WoWLAN) keeps the NIC alive in standby so software wake works. With
it **off**, the monitor drops to deep standby and nothing on the Mac can wake it — you'll
need the physical remote. Auto-wake depends on this setting.

---

## 3. Build and install

### Option A — `./build.sh` (recommended)

From the repo root:

```sh
./build.sh
```

This builds a **signed** `Nit.app` into **/Applications**. Running from
`/Applications` (a stable path) is what makes Launch at Login reliable — see the note below.

### Option B — manual (xcodegen + Xcode)

```sh
brew install xcodegen        # one time
xcodegen generate            # creates Nit.xcodeproj from project.yml
open Nit.xcodeproj       # then set Signing > Team and build (Cmd+R)
```

In Xcode, set **Signing & Capabilities > Team** to a real Development Team before building.

> **Why a stable signing Team matters.** Two macOS permissions attach to the app's *signing
> identity*, not just its path:
> - **Accessibility** permission (granted once, in System Settings) is remembered per
>   identity — change the Team and macOS treats it as a new app and re-prompts.
> - **Launch at Login** (`SMAppService`) registers the login item against that identity.
>
> A Cmd+R build runs the app from **DerivedData**, a transient path. That's fine for
> development, but for Launch at Login to stick, run the copy in **/Applications**.

App Sandbox is intentionally **off** (a sandboxed app cannot create the global event tap the
volume keys need). Don't add the App Sandbox capability.

---

## 4. First launch

Two one-time prompts appear:

1. **Accessibility permission (macOS).** The app installs a global CGEventTap to capture the
   keyboard's volume keys and the ⌃⌥ hotkeys — this needs Accessibility. The app prompts on
   first launch; grant it in **System Settings > Privacy & Security > Accessibility**.

   > macOS only applies a freshly granted Accessibility permission to a *newly launched*
   > process, so the app **relaunches itself** automatically within ~1–2 s of the grant. If
   > it doesn't, quit and reopen it once.

2. **The monitor's "Allow" dialog (Tizen).** The first time the app connects, the M9 shows an
   **Allow / Deny** pairing prompt on screen. Choose **Allow**. The granted token is written
   to:

   ```
   ~/.nit_token
   ```

   and reused on every later connection, so you're only asked once.

---

## 5. Verify it works

- The menu-bar icon appears (a TV-and-speaker glyph). Click it — the header should read
  **"Monitor — connected (192.168.x.y)"** once discovery and pairing finish.
- Press the keyboard's **volume up / down** and **mute** keys — the monitor's volume changes,
  and the Mac's own volume HUD does **not** appear (the event is swallowed).
  Unplug the monitor (laptop display only) and the same keys drive the MacBook instead.
- Menu > **Unmute** should reliably un-mute (it sends volume-up then volume-down; see the
  protocol notes — mute is toggle-only and its state can't be read back).

---

## 6. Settings and shortcuts

### Settings window (menu > **Settings…**)

- **Monitor** — connection status, the persisted Wi-Fi MAC (used for Wake-on-LAN), and a
  **Rescan** button.
- **Volume / Backlight sliders** — absolute volume 0–100 and panel backlight 0–50 (IP
  Control). Also in the menu-bar menu. Requires **IP Remote** on the monitor; first use
  may show **Allow**.
- **Forward volume & brightness keys to the monitor** — turn key forwarding on/off. (Off still
  leaves the ⌃⌥ hotkeys and Remote Mode working — only the media-key branch is gated.
  Forwarding also pauses automatically when no external display is attached, so the
  keys control the MacBook.)
- **Auto-wake monitor when the Mac wakes** — default **on**. Wakes the monitor at Mac-wake and
  display-wake transitions only; the monitor still sleeps normally otherwise.
- **Launch at Login** — default **on**. Registers the app as a login item on launch
  (needs the /Applications copy). Uncheck to stop.

### Keyboard shortcuts

Always-live global hotkeys (work regardless of the Forward-keys toggle):

| Shortcut | Action |
|---|---|
| ⌃⌥ ← ↑ ↓ → | Navigate |
| ⌃⌥ ↩ | OK / Select |
| ⌃⌥ ⌫ | Back |
| ⌃⌥ H | Home |
| ⌃⌥ P | Monitor power (smart toggle) |
| ⌃⌥ [ / ] | Brightness down / up |
| ⌃⌥ R | Toggle Remote Mode |

**Remote Mode** (⌃⌥R): the menu-bar icon becomes a remote glyph and **bare** arrows /
Return / Esc drive the monitor directly (Esc = Back). Everything else types normally. Press
⌃⌥R again to exit. Remote Mode is not persisted — it starts **off** each launch.

---

## 7. Troubleshooting (deep)

### Mute icon reappears every few seconds

The monitor can redisplay its mute indicator while sound is muted, even after
Nit has quit. This does not mean Nit is sending repeated mute commands. To
distinguish the two, quit Nit while the icon is recurring and check whether it
continues. Menu > **Unmute**, followed by setting the volume slider to **0**, is
an alternative way to silence the monitor without leaving its mute toggle on.

For command diagnostics, quit Nit and launch it with:

```sh
open -n --env NIT_DEBUG=1 --stderr /tmp/nit-mute-debug.log /Applications/Nit.app
```

The log records media-key down/up events, outgoing WebSocket keys, connection
changes, and IP Control level requests/results. It does not record access tokens.
Quit and reopen Nit normally to disable diagnostic logging.

### Discovery: "Monitor — searching…" never resolves

- The app first tries the **saved IP** (`nit_last_ip`), then sweeps the whole local **/24**
  (addresses `.1`–`.254`), hitting `http://<candidate>:8001/api/v2/` and matching the raw
  response body for Samsung Smart Monitor / TV. Confirm the Mac and monitor are on the **same subnet** — a sweep of
  `192.168.1.x` will never reach a monitor on `192.168.0.x` or on an isolating guest network.
- The subnet is derived from the Mac's **en0/en1** IPv4 address. On an unusual interface
  (USB Ethernet dongle, etc.) discovery may not run — connect the Mac via Wi-Fi/en0.
- **DHCP gave the monitor a new IP.** Reconnect failures auto-trigger a re-sweep after a few
  attempts, but you can force it: menu > **Rescan for monitor** (clears the saved IP and
  sweeps fresh). Consider a DHCP reservation for the monitor's MAC to avoid churn.

### Auto-wake does nothing

- **"Power On with Mobile" is off** — the most common cause. In deep standby the NIC is dead,
  so neither Wake-on-LAN nor the `:8001` probe reach the monitor. Turn the setting on
  (Section 2).
- **No MAC captured yet.** Wake-on-LAN needs the monitor's Wi-Fi MAC, which is learned from a
  successful `:8001` probe and persisted as `nit_wifi_mac`. If the app has never reached the
  monitor while it was awake, it has no MAC to target — connect once while the monitor is on,
  then MAC-based wake works thereafter.
- **Wake-on-LAN blocked by the network.** The app sends the magic packet to both the global
  broadcast `255.255.255.255` and the subnet-directed `<base>.255`; some access points drop
  one or the other. If both are filtered (common on isolating APs), software wake can't work.
- **Powering the monitor *off* while disconnected does nothing — by design.** `KEY_POWER` is
  a toggle whose state can't be read back, and it's never blind-sent or queued (a stale queued
  toggle would switch a just-woken monitor back off). ⌃⌥P / Monitor Power over a *live*
  connection toggles; while disconnected it runs the wake sequence instead of guessing.

### Volume keys / hotkeys don't respond

- Grant **Accessibility** (System Settings > Privacy & Security > Accessibility). If you
  granted it but nothing happens, quit and relaunch once (the auto-relaunch may have been
  missed).
- Hotkeys are inert inside **secure-input** fields (password prompts) — that's macOS by
  design, not a bug.

### Pairing / token reset

If the monitor stops accepting the connection (you revoked the device on the TV, replaced the
monitor, or see repeated "unauthorized"), delete the token and re-pair:

```sh
rm ~/.nit_token
```

Next connection triggers the monitor's **Allow** dialog again; accept it and a fresh token is
written.

### Inspecting persisted state

The app stores its keys in `UserDefaults` under `com.numan.nit`:

```sh
defaults read com.numan.nit
```

| Key | Meaning |
|---|---|
| `nit_last_ip` | Last known monitor IP (discovery shortcut). |
| `nit_wifi_mac` | Monitor Wi-Fi MAC, target for Wake-on-LAN. |
| `nit_autowake` | Auto-wake toggle (default on). |
| `nit_forward_keys` | Forward-volume-keys toggle (default on). |
| `nit_launch_at_login` | Launch at Login (default on). |

Read a single key, e.g.:

```sh
defaults read com.numan.nit nit_last_ip
```

To force a clean rediscovery you can clear the saved IP (or just use **Rescan**):

```sh
defaults delete com.numan.nit nit_last_ip
```

The pairing token is **not** in UserDefaults — it lives in `~/.nit_token`.
