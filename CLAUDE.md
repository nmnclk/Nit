# CLAUDE.md — Nit

A macOS menu-bar agent that controls a **Samsung Smart Monitor M9** volume from the
Mac by forwarding the keyboard's volume/mute keys over the monitor's Wi-Fi remote.

## Why this exists (don't re-derive these — they were proven empirically)

- Samsung Smart Monitors run **Tizen** and do **not** support DDC/CI, so MonitorControl /
  BetterDisplay-style brightness/volume protocols can't see them. Control happens over
  the **Samsung WebSocket remote** (same API as Samsung TVs), exactly like DisplayBuddy.
- **WebSocket remote** (this is what we use):
  - `wss://<IP>:8002/api/v2/channels/samsung.remote.control?name=<base64-name>&token=<token>`
  - The monitor presents a **self-signed TLS cert** — trust it in the URLSession auth
    challenge (`URLCredential(trust:)`). Do not try to validate it.
  - First connect with no token → monitor shows an **Allow** dialog → the granted token
    arrives in an `ms.channel.connect` event → persist it to `~/.nit_token` and reuse.
  - Keys are **relative only**: `KEY_VOLUP`, `KEY_VOLDOWN`, `KEY_MUTE` (mute is a toggle);
    nav uses `KEY_LEFT/RIGHT/UP/DOWN`, `KEY_ENTER` (OK), `KEY_RETURN` (Back), `KEY_HOME`,
    and `KEY_POWER`. Send via JSON: `{"method":"ms.remote.control","params":{"Cmd":"Click",
    "DataOfCmd":"KEY_VOLUP","Option":"false","TypeOfRemote":"SendRemoteKey"}}`
  - "Force unmute" = `KEY_VOLUP` then `KEY_VOLDOWN` (net-zero), because mute is only a toggle
    and the mute state can't be read locally.
- **Waking from standby.** In **network standby** the NIC stays up and
  `http://<IP>:8001/api/v2/` answers with `device.PowerState` (`"on"|"standby"`) and
  `device.wifiMac`; in **deep standby** the NIC is off (HTTP + WS both dead), so a
  **Wake-on-LAN** magic packet (6×0xFF + 16×MAC, UDP :9, sent to `255.255.255.255` **and** the
  subnet-directed `<base>.255`) is the only wake lever. WoL requires the monitor setting
  **Settings > General > Network > Expert Settings > "Power On with Mobile"** (WoWLAN) = ON —
  without it, software wake from deep standby is impossible.
  - `KEY_POWER` is a **toggle** (sent while on → turns it off) and its state can't be read
    back, so it is **never blind-sent and never queued**. The auto-wake path sends WoL, probes
    `PowerState`, and sends `KEY_POWER` **only when the probe returns `"standby"` and the WS is
    currently connected**; `"on"`/missing/unreachable never toggle. A queued KEY_POWER would
    flush on the next connect and switch the just-woken monitor back off — hence it bypasses
    the pending queue entirely (`sendPowerIfConnected`, direct send, dropped on failure).
    Accepted limitation: powering the monitor **off** requires a live WebSocket — during a
    transient disconnect while the monitor is on, ⌃⌥P/Monitor Power will probe, see `"on"`,
    and deliberately do nothing rather than risk a stale toggle.
- **UPnP RenderingControl is a dead end.** The M9 advertises a MediaRenderer at
  `http://<IP>:9197/dmr` with a standard-looking RenderingControl SCPD (GetVolume/SetVolume,
  Channel=Master, Volume 0–100), but every call returns **HTTP 400 / UPnPError 402 "Invalid
  Args"** even with the documented arguments. It's a non-functional stub. Do NOT use UPnP for
  volume. (This is why there's no absolute 0–100 slider.)
- **SmartThings** would give absolute volume (`audioVolume` capability) but Personal Access
  Tokens now expire in ~24h → would require full OAuth. Not used.
- **Backlight is IP Control G2, not the WebSocket remote.** After
  **Settings > General > Network > Expert Settings > IP Remote** is ON, `https://<IP>:1516/`
  speaks JSON-RPC (`createAccessToken` with **no** `params` key → Allow dialog → persist
  `~/.nit_ip_token`; then `backlightControl` read/write, 0–50).
  `getVideoStates.brightness` is black level — do not use it. MDC `:1515` (`MDCSTART<<TLS>>`)
  is open on the M70D but PIN auth never answers; DDC/CI still fails.

## Device specifics

- Model: Samsung Smart Monitor M9 (32", Tizen). Replace `<MODEL_ID>` / `<INTERNAL_ID>`
  with your unit's values if you need them recorded.
- IP: assigned by DHCP — the app auto-discovers, don't hardcode.
- wifiMac: auto-captured from the `:8001/api/v2/` probe and persisted (`m9_wifi_mac`) for
  Wake-on-LAN; you only need to copy it manually for a DHCP reservation or router WoL entry.
- **Required setting for auto-wake:** turn ON **Settings > General > Network > Expert
  Settings > "Power On with Mobile"** — this keeps the NIC alive in standby so WoL and the
  `:8001` probe work. With it off, the monitor drops to deep standby and can't be woken by
  software.

## Architecture (`Sources/main.swift`, single file)

- `NitRemote` — WebSocket client + discovery + reconnect + key sending + wake.
  - Discovery (`probe`): try the saved IP (`UserDefaults` `m9_last_ip`); else sweep the local
    /24 (subnet from `getifaddrs` on en0/en1) hitting `:8001/api/v2/` and matching the raw body
    against "M9" (the hit is in `device.name`, not the sales-code modelName). The probe also
    parses `wifiMac` + `PowerState` into `DeviceInfo`; `adopt` persists the MAC. Re-sweeps
    automatically if reconnects keep failing (IP changed).
  - Reconnect: proactive with exponential backoff (1→10s), reconnect on system/screens wake,
    re-discover after repeated failures.
  - Wake (`wakeMonitor`/`attemptWake`, guarded by a `waking` flag toggled on the main queue):
    WoL → probe → `KEY_POWER` only when connected + `PowerState=="standby"` (see the
    KEY_POWER-never-queued rule above); unreachable retries every 2 s up to ~20 s. No power
    assertions — the monitor still sleeps normally.
- `NitRemote` also talks IP Control G2 on `:1516` for absolute backlight (`backlightControl`,
  0–50) and volume (`directVolumeControl`, 0–100). Token `~/.nit_ip_token`. Debounces
  writes ~120 ms. Menu and Settings both have sliders.
- `mediaKeyCallback` — a `@convention(c)` CGEventTap callback. Mask = `NSSystemDefined`
  (type 14) **and** `keyDown`. Type 14 / subtype 8: keyCodes 0/1/7 = volume up/down/mute
  and 2/3 = brightness up/down (gated by `forwardingEnabled`). `keyDown` also maps
  F1/F2, 145/144, and Logitech/external F14/F15 (107/113) to backlight. A HID tap
  plus the session tap swallows those before WindowServer dims the Air.
  `keyDown`: **⌃⌥ hotkeys** (always live) and, when Remote
  Mode is on, **bare keys** drive the monitor. Remote Mode matches only when flags ∩
  {control, option, command, shift} is empty (arrows carry NumericPad/Fn flags that must not
  disqualify them); ⌃⌥ is checked first so ⌃⌥R always exits. Arrows pass autorepeat; other
  handled keys fire once but their repeats are still swallowed. Handled events return nil.
- `AppDelegate` — `NSStatusItem` menu (status+IP; Forward-keys toggle; accessibility warning
  when untrusted; Vol/Mute/Unmute; Brightness Up/Down + current backlight; Remote Mode ⌃⌥R + OK/Back/Home/Monitor-Power; Rescan;
  Settings…; About Nit; Quit), creates the tap (always enabled once created —
  `forwardingEnabled` gates only the media-key branch, so hotkeys survive unticking
  Forward-keys), prompts for Accessibility. Menu-bar icon: `tv.and.hifispeaker.fill` normally
  (fallback `display` → `speaker.wave.2.fill` → "M9" title), `av.remote.fill` in Remote Mode
  (fallback `dpad` → accent-tinted normal icon); template images so the bar tints them.
  Hotkeys: ⌃⌥ arrows/↩(OK)/⌫(Back)/H(Home)/P(smart power)/[/](brightness)/R(Remote Mode); menu key equivalents
  are display-only (an LSUIElement app has no main menu, and the tap swallows the combo first).
  - Settings window (lazy, programmatic AppKit, `isReleasedWhenClosed = false`): monitor
    status + persisted wifiMac + Rescan; 0–50 backlight slider; checkboxes for Forward-keys /
    Auto-wake / Launch-at-Login that apply immediately; a static ⌃⌥ shortcuts reference. `refreshSettingsUI` two-way-syncs
    the controls (on open and from `refreshMenu` while visible). Launch-at-Login and Auto-wake
    live *only* here, not in the menu. `.accessory` app → always `NSApp.activate` before showing.
  - About panel: `orderFrontStandardAboutPanel` with a `.credits` NSAttributedString listing
    what the app does and the ⌃⌥ shortcuts; no custom window.
- `UserDefaults` keys: `nit_last_ip` (discovery), `nit_wifi_mac` (WoL target),
  `nit_autowake` (auto-wake toggle, default ON), `nit_forward_keys` (Forward-keys toggle,
  default ON, loaded into `forwardingEnabled` before `createTap`), `nit_launch_at_login`
  (default ON; registers `SMAppService` on launch), `nit_backlight` (last 0–50 value).
  Tokens: `~/.nit_token` (WebSocket), `~/.nit_ip_token` (IP Control).

## Build constraints (critical — easy to break)

- **App Sandbox must be OFF** — a sandboxed app cannot create a global event tap.
  (project.yml declares no entitlements file → sandbox off. Don't add the capability.)
- **LSUIElement = YES** — menu-bar agent, no Dock icon / window. (Set in project.yml; the
  code also calls `setActivationPolicy(.accessory)`.)
- **ATS `NSAllowsArbitraryLoads`** — needed once bundled, for the plain-http discovery and the
  self-signed wss. (In project.yml.)
- **Accessibility permission** — required at runtime for key capture (`AXIsProcessTrusted`).
  The app prompts and auto-activates the tap within ~2s of being granted.
- **ServiceManagement** (`SMAppService.mainApp`) for Launch-at-Login — only works when running
  as a real `.app` bundle (ideally from `/Applications`, not the DerivedData build).
- Deployment target **macOS 13+** (SMAppService).

## Build / run

```
brew install xcodegen          # one time
xcodegen generate              # makes Nit.xcodeproj from project.yml
open Nit.xcodeproj        # then set Signing > Team, and Cmd+R
```
Or skip Xcode and produce a signed app in /Applications with `./build.sh` (auto-detects
the signing team from the keychain; override with `DEVELOPMENT_TEAM=XXXXXXXXXX ./build.sh`).

`Nit.xcodeproj` is **generated and gitignored** — never commit it; after cloning,
run `xcodegen generate` first. End-user setup/troubleshooting lives in `docs/SETUP.md`;
the protocol reference in `docs/PROTOCOL.md` (keep both in sync with this file).

For Launch-at-Login to be stable, run the app from `/Applications` (Cmd+R runs it from
DerivedData, which is fine for development but a transient path for the login item).

## Conventions

- Surgical changes; minimum code; no speculative features or abstractions.
- State assumptions and tradeoffs; if a simpler approach exists, say so.
- Verify by compiling (`xcodebuild -scheme Nit build` or `swiftc Sources/main.swift
  -o /tmp/nit -framework Cocoa`) before declaring something done — this is the one thing the
  chat assistant could not do, so prefer to actually build here.
- Success criteria: keyboard volume keys change the M9's volume; menu Unmute works; the app
  reconnects after the monitor sleeps/wakes; Launch-at-Login keeps it running.
```
