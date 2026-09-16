// main.swift — Nit (menu-bar agent)
//
// Forwards the Mac keyboard's volume up / down / mute keys to a Samsung Smart
// Monitor M7 / M70D over its Wi-Fi WebSocket remote. Menu-bar only, no Dock icon.
//
// This build adds:
//   * IP auto-discovery (remembers last IP; sweeps the /24 to find the M9 by model)
//   * Faster reconnect (proactive, with backoff; reconnects on system wake; and
//     re-discovers the IP if it keeps failing — e.g. DHCP gave it a new address)
//   * "Launch at Login" toggle (SMAppService) — works once it's a real .app
//   * Auto-wake the monitor on Mac/displays wake (Wake-on-LAN + guarded KEY_POWER)
//   * Always-on ⌃⌥ nav hotkeys (arrows/OK/Back/Home/Power) and a toggleable Remote Mode
//     where bare arrows/Return/Esc drive the monitor
//   * Absolute backlight 0–50 over Samsung IP Control G2 (`https://IP:1516/`) — not the
//     WebSocket remote. Requires the monitor's IP Remote setting; first use shows Allow.
//
// Build it into a signed /Applications app with the accompanying build.sh.
// Quick compile-check first:  swiftc main.swift -o /tmp/nit -framework Cocoa

import Cocoa
import ServiceManagement

// MARK: - WebSocket remote + discovery ---------------------------------------

final class NitRemote: NSObject, URLSessionWebSocketDelegate {
    static let clientName = "Nit"
    /// Matched against the raw :8001 body. Sales-code modelName (LS32DM702…)
    /// does not contain "M7"; the hit is in device.name / type ("Smart M70D",
    /// "[TV] Samsung M7", "Samsung SmartTV").
    static let modelKeywords = ["M7", "M70", "M8", "M9", "Smart Monitor", "SmartTV"]
    private let ipKey = "nit_last_ip"
    private let wifiMacKey = "nit_wifi_mac"    // persisted for Wake-on-LAN across launches
    private let tokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nit_token")
    private let ipTokenURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".nit_ip_token")
    static let backlightMin = 0
    static let backlightMax = 50
    static let volumeMin = 0
    static let volumeMax = 100

    /// Parsed from the :8001/api/v2/ probe. `wifiMac` feeds Wake-on-LAN; `powerState`
    /// ("on"/"standby") gates the guarded KEY_POWER on the auto-wake path.
    struct DeviceInfo {
        let wifiMac: String?
        let powerState: String?
    }

    private(set) var ip: String?
    private(set) var connected = false
    var onUpdate: (() -> Void)?

    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var connecting = false
    private var reconnectScheduled = false
    private var attempts = 0
    private var pending: [String] = []
    private var sweeping = false
    private var wifiMac: String?
    private var waking = false                 // wake sequence in flight; toggled on main
    private(set) var lastSweepFailed = false   // true after a /24 sweep found nothing
    private(set) var backlight: Int?           // IP Control G2 panel backlight, 0–50
    private(set) var volume: Int?              // IP Control G2 absolute volume, 0–100
    private var ipRPCID = 0
    private var backlightWrite: DispatchWorkItem?
    private var volumeWrite: DispatchWorkItem?

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        wifiMac = UserDefaults.standard.string(forKey: wifiMacKey)
    }

    // Discovery ---------------------------------------------------------------

    func start() {
        if let saved = UserDefaults.standard.string(forKey: ipKey) {
            probe(saved) { [weak self] info in
                guard let self = self else { return }
                if let info = info { self.adopt(saved, info); self.connect() } else { self.sweep() }
            }
        } else {
            sweep()
        }
    }

    private func setIP(_ value: String) {
        let changed = ip != value
        ip = value
        UserDefaults.standard.set(value, forKey: ipKey)
        DispatchQueue.main.async { self.onUpdate?() }
        if changed { refreshLevels() }
    }

    /// Accept a confirmed M9: set the IP and persist its wifiMac for later Wake-on-LAN.
    /// The wake sequence reads `wifiMac` on main, so the write hops there too (adopt is
    /// called from URLSession completion queues).
    private func adopt(_ ip: String, _ info: DeviceInfo) {
        if let mac = info.wifiMac {
            DispatchQueue.main.async {
                self.wifiMac = mac
                UserDefaults.standard.set(mac, forKey: self.wifiMacKey)
            }
        }
        setIP(ip)
    }

    /// GET http://IP:8001/api/v2/ — identity is Samsung Smart Monitor / TV (M7/M70D
    /// included). Also parses wifiMac + PowerState. `nil` = not a target or unreachable.
    /// `requireMatch: false` accepts any :8001 JSON (manual IP).
    private func probe(_ ip: String, timeout: TimeInterval = 2, requireMatch: Bool = true,
                       completion: @escaping (DeviceInfo?) -> Void) {
        guard let url = URL(string: "http://\(ip):8001/api/v2/") else { completion(nil); return }
        var req = URLRequest(url: url); req.timeoutInterval = timeout
        session.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let body = String(data: data, encoding: .utf8) else { completion(nil); return }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if requireMatch && !Self.isTargetMonitor(body, obj: obj) { completion(nil); return }
            let device = obj?["device"] as? [String: Any]
            completion(DeviceInfo(wifiMac: device?["wifiMac"] as? String,
                                  powerState: device?["PowerState"] as? String))
        }.resume()
    }

    static func isTargetMonitor(_ body: String, obj: [String: Any]?) -> Bool {
        let device = obj?["device"] as? [String: Any]
        let type = ((device?["type"] as? String) ?? (obj?["type"] as? String) ?? "")
        if type.range(of: "Samsung", options: .caseInsensitive) != nil { return true }
        return modelKeywords.contains { body.range(of: $0, options: .caseInsensitive) != nil }
    }

    /// Settings "Connect IP": remember the address and try it even if the body
    /// doesn't match the keyword list (covers odd M70D name strings).
    func adoptManualIP(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        connected = false; connecting = false; task = nil; attempts = 0
        lastSweepFailed = false
        probe(trimmed, requireMatch: false) { [weak self] info in
            guard let self = self else { return }
            if let info = info { self.adopt(trimmed, info) } else { self.setIP(trimmed) }
            self.connect()
        }
    }

    func sweep() {
        guard !sweeping, let base = Self.localSubnetBase() else { return }
        sweeping = true
        lastSweepFailed = false
        DispatchQueue.main.async { self.onUpdate?() }      // shows "searching…"
        let group = DispatchGroup()
        let lock = NSLock()
        var found: (ip: String, info: DeviceInfo)?
        for i in 1...254 {
            let candidate = "\(base).\(i)"
            group.enter()
            probe(candidate) { info in
                if let info = info { lock.lock(); if found == nil { found = (candidate, info) }; lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            self.sweeping = false
            if let found = found {
                self.adopt(found.ip, found.info); self.attempts = 0; self.connect()
            } else {
                self.lastSweepFailed = true
                self.onUpdate?()
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                    guard let self, self.ip == nil, !self.sweeping else { return }
                    self.sweep()
                }
            }
        }
    }

    /// First non-loopback IPv4 on en0/en1, reduced to its /24 base (e.g. "192.168.1").
    static func localSubnetBase() -> String? {
        var result: String?
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let start = head else { return nil }
        defer { freeifaddrs(head) }
        var p: UnsafeMutablePointer<ifaddrs>? = start
        while let cur = p {
            let flags = Int32(cur.pointee.ifa_flags)
            if let addr = cur.pointee.ifa_addr,
               addr.pointee.sa_family == UInt8(AF_INET),
               (flags & IFF_UP) == IFF_UP, (flags & IFF_LOOPBACK) == 0 {
                let name = String(cString: cur.pointee.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    if getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                                   &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ipStr = String(cString: host)
                        if let dot = ipStr.range(of: ".", options: .backwards) {
                            result = String(ipStr[..<dot.lowerBound]); break
                        }
                    }
                }
            }
            p = cur.pointee.ifa_next
        }
        return result
    }

    // Connection --------------------------------------------------------------

    func connect() {
        guard !connected, !connecting, let ip = ip else { return }
        connecting = true
        let name64 = Data(Self.clientName.utf8).base64EncodedString()
        var urlStr = "wss://\(ip):8002/api/v2/channels/samsung.remote.control?name=\(name64)"
        if let t = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            urlStr += "&token=\(t)"
        }
        guard let url = URL(string: urlStr) else { connecting = false; return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive()
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure:
                self.markDisconnected()
            case .success(let msg):
                if case .string(let text) = msg { self.handle(text) }
                self.receive()
            }
        }
    }

    private func handle(_ text: String) {
        if text.contains("ms.channel.connect") {
            if let data = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let d = obj["data"] as? [String: Any],
               let token = d["token"] as? String {
                try? token.write(to: tokenURL, atomically: true, encoding: .utf8)
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenURL.path)
            }
            connected = true; connecting = false; attempts = 0
            DispatchQueue.main.async { self.onUpdate?() }
            refreshLevels()
            let queued = pending; pending.removeAll()
            for k in queued { rawSend(k) }
        } else if text.contains("unauthorized") {
            markDisconnected()
        }
    }

    private func markDisconnected() {
        connected = false; connecting = false; task = nil
        DispatchQueue.main.async { self.onUpdate?() }
        scheduleReconnect()
    }

    private func scheduleReconnect() {
        guard !connected, !connecting, !reconnectScheduled, ip != nil else { return }
        reconnectScheduled = true
        let delay = min(pow(2.0, Double(attempts)), 10.0)   // 1,2,4,8,10…
        attempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self = self else { return }
            self.reconnectScheduled = false
            if self.attempts >= 5 { self.attempts = 0; self.sweep() }  // IP may have changed
            else { self.connect() }
        }
    }

    /// Called on system wake — try to get back instantly.
    func reconnectNow() {
        attempts = 0; reconnectScheduled = false
        if !connected { connect() }
    }

    func rescan() {
        UserDefaults.standard.removeObject(forKey: ipKey)
        connected = false; connecting = false; task = nil; attempts = 0
        sweep()
    }

    // Sending -----------------------------------------------------------------

    private func payload(_ key: String) -> String {
        let p: [String: Any] = ["method": "ms.remote.control",
                                "params": ["Cmd": "Click", "DataOfCmd": key,
                                           "Option": "false", "TypeOfRemote": "SendRemoteKey"]]
        let data = (try? JSONSerialization.data(withJSONObject: p)) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func rawSend(_ key: String) {
        guard let task = task else { queue(key); connect(); return }
        task.send(.string(payload(key))) { [weak self] err in
            guard err != nil, let self = self else { return }
            self.queue(key)
            DispatchQueue.main.async { self.markDisconnected() }
        }
    }

    private func queue(_ key: String) {
        if pending.count < 8 { pending.append(key) }
    }

    func send(_ key: String) {
        if connected { rawSend(key) }
        else { queue(key); if ip != nil { connect() } else { start() } }
    }

    func forceUnmute() {
        send("KEY_VOLUP")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.send("KEY_VOLDOWN")
        }
    }

    // IP Control G2 backlight (port 1516) -------------------------------------
    //
    // Separate from the WebSocket remote. HTTPS JSON-RPC at https://IP:1516/ after
    // Settings > General > Network > Expert > IP Remote is ON. First createAccessToken
    // shows Allow; persist ~/.nit_ip_token. backlightControl is the real panel
    // backlight 0–50 — getVideoStates.brightness is black level, not this.

    func nudgeBacklight(_ delta: Int) {
        setBacklight((backlight ?? UserDefaults.standard.integer(forKey: "nit_backlight")) + delta)
    }

    func setBacklight(_ value: Int) {
        scheduleLevel(&backlight, write: &backlightWrite, value: value,
                      min: Self.backlightMin, max: Self.backlightMax, key: "nit_backlight") {
            self.intRPC(method: "backlightControl", field: "backlight", value: $0, key: "nit_backlight") { self.backlight = $0 }
        }
    }

    func nudgeVolume(_ delta: Int) {
        setVolume((volume ?? UserDefaults.standard.integer(forKey: "nit_volume")) + delta)
    }

    func setVolume(_ value: Int) {
        scheduleLevel(&volume, write: &volumeWrite, value: value,
                      min: Self.volumeMin, max: Self.volumeMax, key: "nit_volume") {
            self.intRPC(method: "directVolumeControl", field: "volume", value: $0, key: "nit_volume") { self.volume = $0 }
        }
    }

    func refreshLevels() {
        if backlightWrite == nil {
            intRPC(method: "backlightControl", field: "backlight", value: nil, key: "nit_backlight") { self.backlight = $0 }
        }
        if volumeWrite == nil {
            intRPC(method: "directVolumeControl", field: "volume", value: nil, key: "nit_volume") { self.volume = $0 }
        }
    }

    private func scheduleLevel(_ current: inout Int?, write: inout DispatchWorkItem?,
                               value: Int, min: Int, max: Int, key: String, send: @escaping (Int) -> Void) {
        let clamped = Swift.min(max, Swift.max(min, value))
        current = clamped
        UserDefaults.standard.set(clamped, forKey: key)
        DispatchQueue.main.async { self.onUpdate?() }
        write?.cancel()
        let work = DispatchWorkItem { send(clamped) }
        write = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    private func intRPC(method: String, field: String, value: Int?, key: String,
                        retried: Bool = false, assign: @escaping (Int) -> Void) {
        withIPToken { [weak self] token in
            guard let self, let token else { return }
            var params: [String: Any] = ["AccessToken": token]
            if let value { params[field] = value }
            self.ipRPC(method, params: params) { result, err in
                if err == -32010, !retried {
                    try? FileManager.default.removeItem(at: self.ipTokenURL)
                    self.intRPC(method: method, field: field, value: value, key: key, retried: true, assign: assign)
                    return
                }
                guard let n = Self.jsonInt(result?[field]) else { return }
                // SET responses must not snap the slider back — a hold fires many
                // optimistic steps while older writes are still in flight.
                if value != nil { return }
                DispatchQueue.main.async {
                    assign(n)
                    UserDefaults.standard.set(n, forKey: key)
                    self.onUpdate?()
                }
            }
        }
    }

    private func withIPToken(_ done: @escaping (String?) -> Void) {
        if let t = loadIPToken() { done(t); return }
        ipRPC("createAccessToken", params: nil, timeout: 20) { [weak self] result, _ in
            guard let self else { done(nil); return }
            if let token = result?["AccessToken"] as? String, !token.isEmpty {
                self.saveIPToken(token)
                done(token)
            } else {
                done(nil)
            }
        }
    }

    private func loadIPToken() -> String? {
        guard let t = try? String(contentsOf: ipTokenURL, encoding: .utf8) else { return nil }
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveIPToken(_ token: String) {
        try? token.write(to: ipTokenURL, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: ipTokenURL.path)
    }

    private func ipRPC(_ method: String, params: [String: Any]?, timeout: TimeInterval = 8,
                       completion: @escaping ([String: Any]?, Int?) -> Void) {
        guard let ip, let url = URL(string: "https://\(ip):1516/") else { completion(nil, nil); return }
        ipRPCID += 1
        var body: [String: Any] = ["jsonrpc": "2.0", "method": method, "id": ipRPCID]
        if let params { body["params"] = params }
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        session.dataTask(with: req) { data, _, _ in
            guard let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, nil); return
            }
            if let err = obj["error"] as? [String: Any] {
                completion(nil, Self.jsonInt(err["code"]))
                return
            }
            completion(obj["result"] as? [String: Any], nil)
        }.resume()
    }

    private static func jsonInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let n = value as? NSNumber { return n.intValue }
        return nil
    }

    // Wake --------------------------------------------------------------------

    /// KEY_POWER is a toggle and must NEVER be queued — a queued power key would flush on
    /// the next connect and turn the just-woken monitor back OFF. Send only over a live
    /// socket; on failure drop it (mark disconnected) rather than enqueue.
    func sendPowerIfConnected() {
        guard connected, let task = task else { return }
        task.send(.string(payload("KEY_POWER"))) { [weak self] err in
            guard err != nil, let self = self else { return }
            DispatchQueue.main.async { self.markDisconnected() }
        }
    }

    /// Wake-on-LAN magic packet (6×0xFF + 16×MAC) to UDP :9. In deep standby the NIC is
    /// off (HTTP/WS both unreachable), so WoL is the only wake lever; requires the monitor
    /// setting "Power On with Mobile". Sent to the global and subnet-directed broadcasts
    /// (some APs drop the global one). Harmless if the monitor is already on.
    private func sendWakeOnLAN() {
        guard let mac = wifiMac else { return }
        let macBytes = mac.split(separator: ":").compactMap { UInt8($0, radix: 16) }
        guard macBytes.count == 6 else { return }
        var packet = [UInt8](repeating: 0xFF, count: 6)
        for _ in 0..<16 { packet.append(contentsOf: macBytes) }   // 6 + 16×6 = 102
        var targets = ["255.255.255.255"]
        if let base = Self.localSubnetBase() { targets.append("\(base).255") }
        DispatchQueue.global().async {
            let fd = socket(AF_INET, SOCK_DGRAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &on, socklen_t(MemoryLayout<Int32>.size))
            for target in targets {
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = in_port_t(9).bigEndian
                addr.sin_addr.s_addr = inet_addr(target)
                _ = packet.withUnsafeBytes { buf in
                    withUnsafePointer(to: &addr) { aptr in
                        aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                            sendto(fd, buf.baseAddress, buf.count, 0, sa,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
        }
    }

    /// Auto-wake: WoL (always, harmless if on) → probe. Only PowerState=="standby" from a
    /// reachable probe sends the guarded KEY_POWER, and only once the WS is connected —
    /// standby-without-socket retries (the millisecond HTTP probe wins the race against
    /// the TLS+upgrade WS handshake, so waiting is the common case, not the exception).
    /// "on"/missing → done (never blind-toggle); unreachable → retry. Retries every 2 s
    /// until a ~20 s deadline, re-sending WoL each round. `waking` guards re-entry.
    func wakeMonitor() {
        DispatchQueue.main.async {
            guard !self.waking else { return }
            self.waking = true
            self.attemptWake(ip: self.ip, deadline: Date().addingTimeInterval(20))
        }
    }

    private func attemptWake(ip: String?, deadline: Date) {
        sendWakeOnLAN()
        // Discovery may land mid-sequence: retries pass nil so this coalescing re-reads
        // self.ip every round.
        guard let ip = ip ?? self.ip else {
            // No IP yet (monitor was dark at launch, sweep found nothing) — restart
            // discovery (the sweeping guard prevents storms) and retry once WoL has had
            // a chance to raise the NIC.
            start()
            if Date() < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.attemptWake(ip: nil, deadline: deadline)
                }
            } else {
                DispatchQueue.main.async { self.waking = false }
            }
            return
        }
        probe(ip, timeout: 2) { [weak self] info in
            guard let self = self else { return }
            if let info = info, info.powerState != "standby" {
                // "on" or PowerState missing — never blind-toggle.
                DispatchQueue.main.async { self.waking = false }
            } else if info != nil, self.connected {
                // standby + live socket → the guarded power press can actually land.
                self.sendPowerIfConnected()
                DispatchQueue.main.async { self.waking = false }
            } else if Date() < deadline {
                // standby without a socket — hasten the WS handshake (connect() dedupes
                // via its connecting/connected guards) so the power key can be delivered
                // next round; or unreachable. Either way retry after 2 s.
                if info != nil { self.connect() }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.attemptWake(ip: nil, deadline: deadline)
                }
            } else {
                DispatchQueue.main.async { self.waking = false }
            }
        }
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

// MARK: - Media-key event tap (C callback) -----------------------------------

private func mediaKeyCallback(proxy: CGEventTapProxy, type: CGEventType,
                              event: CGEvent, refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
    let app = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()

    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        app.reenableTap()
        return Unmanaged.passUnretained(event)
    }

    if type.rawValue == 14, app.forwardingEnabled, app.hasExternalDisplay,  // 14 == NSSystemDefined
       let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
        let data1 = ns.data1
        let keyCode = (data1 & 0xFFFF0000) >> 16
        let keyState = (data1 & 0x0000FF00) >> 8                // 0x0A down
        let isRepeat = (data1 & 0x1) != 0
        if keyCode == 0 || keyCode == 1 || keyCode == 7 {       // up / down / mute
            if keyCode == 7 {
                if keyState == 0x0A, !isRepeat { app.remote.send("KEY_MUTE") }
            } else if keyState == 0x0A, !isRepeat {
                app.beginLevelHold(.volume, delta: keyCode == 0 ? 1 : -1)
            } else if keyState == 0x0B {
                app.endLevelHold(.volume)
            }
            return nil
        }
        if keyCode == 2 || keyCode == 3 || keyCode == 21 || keyCode == 22 {
            let delta = (keyCode == 2 || keyCode == 21) ? 1 : -1
            if keyState == 0x0A, !isRepeat { app.beginLevelHold(.backlight, delta: delta) }
            else if keyState == 0x0B { app.endLevelHold(.backlight) }
            return nil
        }
    }

    // ⌃⌥ hotkeys are always live and Remote Mode maps bare keys — both independent of
    // forwardingEnabled so nav works with volume forwarding off. ⌃⌥ is checked first so
    // ⌃⌥R always exits Remote Mode. Both branches intersect only the four "real" modifier
    // masks (arrows carry NumericPad/Fn flags that must not disqualify a match): hotkeys
    // require exactly ⌃⌥ — ⌃⌥⇧/⌃⌥⌘ combos pass through to apps, not get swallowed.
    if type == .keyDown || type == .keyUp {
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let flags = event.flags
        let noRealMods = flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]).isEmpty
        if flags.intersection([.maskControl, .maskAlternate, .maskCommand, .maskShift]) == [.maskControl, .maskAlternate] {
            if type == .keyUp, (keyCode == 33 || keyCode == 30) {
                app.endLevelHold(.backlight); return nil
            }
            if type == .keyDown, app.handleHotkey(keyCode: keyCode, autorepeat: autorepeat) { return nil }
        } else if app.remoteModeActive, noRealMods {
            if type == .keyDown, app.handleRemoteKey(keyCode: keyCode, autorepeat: autorepeat) { return nil }
        } else if app.forwardingEnabled, app.hasExternalDisplay, noRealMods,
                  let delta = brightnessKeyDelta(keyCode) {
            if type == .keyDown, !autorepeat { app.beginLevelHold(.backlight, delta: delta) }
            else if type == .keyUp { app.endLevelHold(.backlight) }
            return nil
        }
    }
    return Unmanaged.passUnretained(event)
}

/// Brightness down/up across keyboard families:
/// 145/144 = macOS media brightness; 122/120 = F1/F2 (MacBook);
/// 107/113 = F14/F15 (Logitech / Apple external — these otherwise dim the Air).
private func brightnessKeyDelta(_ keyCode: Int) -> Int? {
    switch keyCode {
    case 145, 122, 107: return -1
    case 144, 120, 113: return 1
    default: return nil
    }
}

// MARK: - App delegate / menu bar --------------------------------------------

enum LevelKind { case volume, backlight }

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let remote = NitRemote()
    var forwardingEnabled = true
    private(set) var hasExternalDisplay = false  // laptop-only → let keys reach the Air
    var remoteModeActive = false               // not persisted; starts off each launch
    private var holdKind: LevelKind?
    private var holdDelta = 0
    private var holdDelayTimer: Timer?
    private var holdRepeatTimer: Timer?

    private let autoWakeKey = "nit_autowake"
    private let forwardKeysKey = "nit_forward_keys"    // persists forwardingEnabled across launches
    private let launchAtLoginKey = "nit_launch_at_login"
    private var autoWakeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: autoWakeKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoWakeKey) }
    }

    private var statusItem: NSStatusItem!
    private var eventTaps: [CFMachPort] = []
    private var runLoopSources: [CFRunLoopSource] = []
    private var permTimer: Timer?

    // Settings window + its controls, built lazily on first open. Strong refs are required:
    // the window is isReleasedWhenClosed = false and refreshSettingsUI reads/writes the
    // controls to keep them in sync with the menu.
    private var settingsWindow: NSWindow?
    private var settingsStatusLabel: NSTextField?
    private var settingsMacLabel: NSTextField?
    private var settingsIPField: NSTextField?
    private var forwardCheckbox: NSButton?
    private var autoWakeCheckbox: NSButton?
    private var loginCheckbox: NSButton?
    private var brightnessSlider: NSSlider?
    private var brightnessValueLabel: NSTextField?
    private var volumeSlider: NSSlider?
    private var volumeValueLabel: NSTextField?
    private var menuVolumeSlider: NSSlider?
    private var menuVolumeLabel: NSTextField?
    private var menuBrightnessSlider: NSSlider?
    private var menuBrightnessLabel: NSTextField?
    private var hudVolumeSlider: NSSlider?
    private var hudVolumeLabel: NSTextField?
    private var hudBrightnessSlider: NSSlider?
    private var hudBrightnessLabel: NSTextField?
    private var levelHUD: NSPanel?
    private var hudHideTimer: Timer?
    private var hudKind: LevelKind?
    private var hudVolumeRow: NSView?
    private var hudBrightnessRow: NSView?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: [
            autoWakeKey: true, forwardKeysKey: true, launchAtLoginKey: true,
            "nit_backlight": 11, "nit_volume": 10,
        ])
        forwardingEnabled = UserDefaults.standard.bool(forKey: forwardKeysKey)  // before createTap()
        if UserDefaults.standard.bool(forKey: launchAtLoginKey) {
            try? SMAppService.mainApp.register()
        }
        setupMenu()
        NSApp.applicationIconImage = Self.appIconImage()
        remote.onUpdate = { [weak self] in self?.refreshMenu() }
        remote.start()

        promptAccessibilityIfNeeded()
        createTap()
        if eventTaps.isEmpty {
            permTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                guard AXIsProcessTrusted() else { return }
                t.invalidate()
                // TCC only applies a freshly-granted Accessibility permission to a
                // newly-launched process; CGEvent.tapCreate will silently fail in
                // this one even though AXIsProcessTrusted now returns true.
                self.relaunchSelf()
            }
        }

        // Reconnect promptly on Mac wake and on displays-wake-after-idle; also auto-wake
        // the monitor (WoL + guarded power) when enabled. No power assertions anywhere —
        // the monitor must still sleep normally.
        let onWake: (Notification) -> Void = { [weak self] _ in
            guard let self = self else { return }
            self.remote.reconnectNow()
            if self.autoWakeEnabled { self.remote.wakeMonitor() }
        }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: onWake)
        nc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main, using: onWake)
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshExternalDisplay() }
        refreshExternalDisplay()

        refreshMenu()
    }

    /// Swallow volume/brightness only while a non-built-in screen is attached.
    /// Clamshell + monitor still forwards; unplugged laptop uses the Air.
    private func refreshExternalDisplay() {
        let attached = NSScreen.screens.contains { screen in
            guard let num = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }
            return CGDisplayIsBuiltin(num.uint32Value) == 0
        }
        if hasExternalDisplay && !attached { endAllLevelHolds() }
        hasExternalDisplay = attached
    }

    // Menu --------------------------------------------------------------------

    private func setupMenu() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        if let button = statusItem.button {
            button.addTrackingArea(NSTrackingArea(
                rect: button.bounds,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        }
    }

    /// Normal state: a display+speaker glyph. Remote Mode: an A/V remote glyph. Each has an
    /// SF Symbol fallback chain (glyphs vary by release), and Remote Mode falls back to the
    /// accent-tinted normal icon. Images stay template so the menu bar tints them per appearance.
    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        if remoteModeActive,
           let img = symbol("av.remote.fill", "dpad", accessibility: "Nit Remote Mode") {
            button.image = img
            button.contentTintColor = nil
        } else if let img = symbol("tv.and.hifispeaker.fill", "display", "speaker.wave.2.fill",
                                   accessibility: remoteModeActive ? "Nit Remote Mode" : "Nit") {
            button.image = img
            button.contentTintColor = remoteModeActive ? .controlAccentColor : nil
        } else {
            button.title = "Nit"
        }
    }

    /// First available SF Symbol in `names` as a template image, or nil if none exist.
    private func symbol(_ names: String..., accessibility: String) -> NSImage? {
        for name in names {
            if let img = NSImage(systemSymbolName: name, accessibilityDescription: accessibility) {
                img.isTemplate = true
                return img
            }
        }
        return nil
    }

    /// Menu-header / Settings status string. Shared so both surfaces read identically.
    private func statusString() -> String {
        if let ip = remote.ip { return remote.connected ? "Monitor — connected (\(ip))" : "Monitor — \(ip) (offline)" }
        if remote.lastSweepFailed { return "Monitor — not found on this Wi‑Fi" }
        return "Monitor — searching…"
    }

    private func isTrackingSliders() -> Bool {
        let sliders = [volumeSlider, brightnessSlider, menuVolumeSlider, menuBrightnessSlider,
                       hudVolumeSlider, hudBrightnessSlider]
        return sliders.contains { sl in
            // A slider in a closed menu or hidden window keeps its last highlighted state, so
            // without the visibility check a stale cell would defer the HUD hide forever.
            guard let sl, let win = sl.window, win.isVisible else { return false }
            return win.currentEvent?.type == .leftMouseDragged || (sl.cell?.isHighlighted ?? false)
        }
    }

    private func refreshMenu() {
        guard let menu = statusItem.menu else { return }
        if isTrackingSliders() || levelHUD?.isVisible == true {
            applyLevelViews()
            if settingsWindow?.isVisible == true { refreshSettingsUI() }
            return
        }
        menu.removeAllItems()

        let vol = remote.volume ?? UserDefaults.standard.integer(forKey: "nit_volume")
        let br = remote.backlight ?? UserDefaults.standard.integer(forKey: "nit_backlight")
        let (volRow, volSl, volLab) = menuSliderRow(
            icon: "speaker.wave.2.fill", min: NitRemote.volumeMin, max: NitRemote.volumeMax,
            value: vol, action: #selector(volumeSliderChanged(_:)))
        menuVolumeSlider = volSl
        menuVolumeLabel = volLab
        let volItem = NSMenuItem()
        volItem.view = volRow
        menu.addItem(volItem)

        let (briRow, briSl, briLab) = menuSliderRow(
            icon: "sun.max.fill", min: NitRemote.backlightMin, max: NitRemote.backlightMax,
            value: br, action: #selector(brightnessSliderChanged(_:)))
        menuBrightnessSlider = briSl
        menuBrightnessLabel = briLab
        let briItem = NSMenuItem()
        briItem.view = briRow
        menu.addItem(briItem)

        menu.addItem(.separator())

        // Untrusted is an actionable error state, so it stays at the top level where the
        // submenu can't hide it.
        let trusted = AXIsProcessTrusted()
        if !trusted {
            let warn = NSMenuItem(title: "Grant Accessibility to capture keys…", action: #selector(openAccessibility), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        let details = NSMenu()
        let detailsItem = NSMenuItem(title: "Details", action: nil, keyEquivalent: "")
        detailsItem.submenu = details
        menu.addItem(detailsItem)

        let header = NSMenuItem(title: statusString(), action: nil, keyEquivalent: "")
        header.isEnabled = false
        details.addItem(header)

        let fwd = NSMenuItem(title: "Forward volume & brightness keys to the monitor", action: #selector(toggleForwarding), keyEquivalent: "")
        fwd.state = (forwardingEnabled && trusted) ? .on : .off
        fwd.target = self
        details.addItem(fwd)

        details.addItem(.separator())
        let actions: [(String, Selector)] = [
            ("Mute (toggle)", #selector(mute)), ("Unmute", #selector(unmute)),
        ]
        for (t, sel) in actions {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: ""); it.target = self
            details.addItem(it)
        }

        // Nav / Remote Mode. Key equivalents are display-only: an LSUIElement app has no
        // main menu so they never fire on their own, and the tap swallows the combos first.
        details.addItem(.separator())
        let rm = NSMenuItem(title: "Remote Mode", action: #selector(toggleRemoteModeMenu), keyEquivalent: "r")
        rm.keyEquivalentModifierMask = [.control, .option]
        rm.state = remoteModeActive ? .on : .off
        rm.target = self
        details.addItem(rm)
        let nav: [(String, String, Selector)] = [
            ("OK", "\r", #selector(okPress)), ("Back", "\u{8}", #selector(backPress)),
            ("Home", "h", #selector(homePress)), ("Monitor Power", "p", #selector(powerToggle)),
        ]
        for (t, ke, sel) in nav {
            let it = NSMenuItem(title: t, action: sel, keyEquivalent: ke)
            it.keyEquivalentModifierMask = [.control, .option]
            it.target = self
            details.addItem(it)
        }

        // Launch-at-Login and Auto-wake now live only in Settings.
        details.addItem(.separator())
        let rescan = NSMenuItem(title: "Rescan for monitor", action: #selector(rescan), keyEquivalent: "")
        rescan.target = self
        details.addItem(rescan)
        let about = NSMenuItem(title: "About Nit", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        details.addItem(about)

        let settings = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.keyEquivalentModifierMask = [.command]     // display-only, like the nav items
        settings.target = self
        menu.addItem(settings)
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)

        applyLevelViews()
        if settingsWindow?.isVisible == true { refreshSettingsUI() }
    }

    /// Slider row used as an `NSMenuItem.view`. The menu lays these out from the view's
    /// frame rather than constraints, so the row carries an explicit size.
    private func menuSliderRow(icon: String, min lo: Int, max hi: Int, value: Int,
                               action: Selector) -> (NSView, NSSlider, NSTextField) {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
        image.image?.isTemplate = true
        image.contentTintColor = .secondaryLabelColor
        image.translatesAutoresizingMaskIntoConstraints = false
        image.widthAnchor.constraint(equalToConstant: 16).isActive = true
        image.heightAnchor.constraint(equalToConstant: 16).isActive = true

        let sl = NSSlider(value: Double(value), minValue: Double(lo), maxValue: Double(hi),
                          target: self, action: action)
        sl.isContinuous = true
        sl.translatesAutoresizingMaskIntoConstraints = false
        sl.widthAnchor.constraint(equalToConstant: 150).isActive = true

        let lab = NSTextField(labelWithString: "")
        lab.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        lab.textColor = .secondaryLabelColor
        lab.translatesAutoresizingMaskIntoConstraints = false
        lab.widthAnchor.constraint(equalToConstant: 44).isActive = true

        let stack = NSStackView(views: [image, sl, lab])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = true
        stack.frame = NSRect(x: 0, y: 0, width: 252, height: 28)
        return (stack, sl, lab)
    }

    private func applyLevelViews() {
        let vol = remote.volume ?? UserDefaults.standard.integer(forKey: "nit_volume")
        let br = remote.backlight ?? UserDefaults.standard.integer(forKey: "nit_backlight")
        if menuVolumeSlider?.window?.currentEvent?.type != .leftMouseDragged {
            menuVolumeSlider?.integerValue = vol
        }
        if menuBrightnessSlider?.window?.currentEvent?.type != .leftMouseDragged {
            menuBrightnessSlider?.integerValue = br
        }
        menuVolumeLabel?.stringValue = "Vol \(vol)"
        menuBrightnessLabel?.stringValue = "Bri \(br)"
        if volumeSlider?.window?.currentEvent?.type != .leftMouseDragged {
            volumeSlider?.integerValue = vol
        }
        if brightnessSlider?.window?.currentEvent?.type != .leftMouseDragged {
            brightnessSlider?.integerValue = br
        }
        volumeValueLabel?.stringValue = "Volume \(vol)/\(NitRemote.volumeMax)"
        brightnessValueLabel?.stringValue = "Backlight \(br)/\(NitRemote.backlightMax)"
        if hudVolumeSlider?.window?.currentEvent?.type != .leftMouseDragged {
            hudVolumeSlider?.integerValue = vol
        }
        if hudBrightnessSlider?.window?.currentEvent?.type != .leftMouseDragged {
            hudBrightnessSlider?.integerValue = br
        }
        hudVolumeLabel?.stringValue = "\(vol)"
        hudBrightnessLabel?.stringValue = "\(br)"
    }

    @objc func mouseEntered(with event: NSEvent) {
        showLevelHUD(hudKind, linger: true)
    }

    @objc func mouseExited(with event: NSEvent) {
        scheduleHUDHide(after: 0.35)
    }

    func showLevelHUD(_ kind: LevelKind? = nil, linger: Bool = false) {
        if statusItem.button?.isHighlighted == true { return }   // full menu is open
        guard let shown = kind ?? holdKind ?? hudKind else { return }
        hudKind = shown
        if levelHUD == nil { levelHUD = buildLevelHUD() }
        hudVolumeRow?.isHidden = shown != .volume
        hudBrightnessRow?.isHidden = shown != .backlight
        if let hud = levelHUD {
            var frame = hud.frame
            frame.size = NSSize(width: 268, height: 48)
            hud.setFrame(frame, display: true)
        }
        applyLevelViews()
        positionLevelHUD()
        levelHUD?.orderFrontRegardless()
        if linger { hudHideTimer?.invalidate(); hudHideTimer = nil }
        else { scheduleHUDHide(after: 1.4) }
    }

    private func scheduleHUDHide(after delay: TimeInterval) {
        hudHideTimer?.invalidate()
        hudHideTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self else { return }
            if self.isTrackingSliders() || self.holdKind != nil { self.scheduleHUDHide(after: 0.6); return }
            if self.levelHUD?.isVisible == true, let hud = self.levelHUD,
               hud.frame.contains(NSEvent.mouseLocation) { return }
            self.levelHUD?.orderOut(nil)
        }
    }

    private func positionLevelHUD() {
        guard let hud = levelHUD, let button = statusItem.button, let win = button.window else { return }
        let buttonScreen = win.convertToScreen(button.convert(button.bounds, to: nil))
        var x = buttonScreen.midX - hud.frame.width / 2
        let y = buttonScreen.minY - hud.frame.height - 6
        if let screen = win.screen?.visibleFrame ?? NSScreen.main?.visibleFrame {
            x = min(max(x, screen.minX + 8), screen.maxX - hud.frame.width - 8)
        }
        hud.setFrameOrigin(NSPoint(x: x, y: y))
    }

    private func buildLevelHUD() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 268, height: 48),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false

        let fx = NSVisualEffectView(frame: panel.contentView!.bounds)
        fx.autoresizingMask = [.width, .height]
        fx.material = .hudWindow
        fx.blendingMode = .behindWindow
        fx.state = .active
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 10
        panel.contentView = fx

        func row(icon: String, min: Int, max: Int, value: Int, action: Selector) -> (NSView, NSSlider, NSTextField) {
            let image = NSImageView()
            image.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            image.image?.isTemplate = true
            image.contentTintColor = .secondaryLabelColor
            image.translatesAutoresizingMaskIntoConstraints = false
            image.widthAnchor.constraint(equalToConstant: 18).isActive = true
            image.heightAnchor.constraint(equalToConstant: 18).isActive = true
            let sl = NSSlider(value: Double(value), minValue: Double(min), maxValue: Double(max),
                              target: self, action: action)
            sl.isContinuous = true
            sl.widthAnchor.constraint(equalToConstant: 168).isActive = true
            let lab = NSTextField(labelWithString: "")
            lab.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
            lab.textColor = .secondaryLabelColor
            lab.alignment = .right
            lab.widthAnchor.constraint(equalToConstant: 28).isActive = true
            let stack = NSStackView(views: [image, sl, lab])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.spacing = 8
            return (stack, sl, lab)
        }

        let vol = remote.volume ?? UserDefaults.standard.integer(forKey: "nit_volume")
        let br = remote.backlight ?? UserDefaults.standard.integer(forKey: "nit_backlight")
        let (volRow, volSl, volLab) = row(icon: "speaker.wave.2.fill",
                                          min: NitRemote.volumeMin, max: NitRemote.volumeMax,
                                          value: vol, action: #selector(volumeSliderChanged(_:)))
        let (brRow, brSl, brLab) = row(icon: "sun.max.fill",
                                       min: NitRemote.backlightMin, max: NitRemote.backlightMax,
                                       value: br, action: #selector(brightnessSliderChanged(_:)))
        hudVolumeSlider = volSl; hudVolumeLabel = volLab
        hudBrightnessSlider = brSl; hudBrightnessLabel = brLab
        hudVolumeRow = volRow; hudBrightnessRow = brRow
        volRow.isHidden = true
        brRow.isHidden = true

        let col = NSStackView(views: [volRow, brRow])
        col.orientation = .vertical
        col.alignment = .leading
        col.spacing = 8
        col.edgeInsets = NSEdgeInsets(top: 12, left: 14, bottom: 12, right: 14)
        col.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(col)
        NSLayoutConstraint.activate([
            col.leadingAnchor.constraint(equalTo: fx.leadingAnchor),
            col.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            col.topAnchor.constraint(equalTo: fx.topAnchor),
            col.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        fx.addTrackingArea(NSTrackingArea(rect: .zero,
                                          options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                          owner: self, userInfo: nil))
        return panel
    }

    @objc private func toggleForwarding() { setForwarding(!forwardingEnabled) }
    /// Flip only the flag (persisted) — the tap stays enabled so the always-on hotkeys keep
    /// working. `forwardingEnabled` gates only the media-key branch inside the callback.
    private func setForwarding(_ on: Bool) {
        forwardingEnabled = on
        UserDefaults.standard.set(on, forKey: forwardKeysKey)
        if eventTaps.isEmpty { createTap() }
        refreshMenu()
    }
    /// Register/unregister the login item; the failure alert explains the /Applications
    /// requirement. Shared by the Settings checkbox. Callers refresh their own UI.
    private func setLaunchAtLogin(_ enable: Bool) {
        UserDefaults.standard.set(enable, forKey: launchAtLoginKey)
        do {
            if enable { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            let a = NSAlert(); a.messageText = "Launch at Login failed"
            a.informativeText = "\(error.localizedDescription)\n\nThis works when run as Nit.app in /Applications."
            a.runModal()
        }
    }
    @objc private func volUp()   { remote.nudgeVolume(1) }
    @objc private func volDown() { remote.nudgeVolume(-1) }
    @objc private func mute()    { remote.send("KEY_MUTE") }
    @objc private func unmute()  { remote.forceUnmute() }
    @objc private func brightUp()   { remote.nudgeBacklight(1) }
    @objc private func brightDown() { remote.nudgeBacklight(-1) }
    @objc private func volumeSliderChanged(_ sender: NSSlider) {
        remote.setVolume(sender.integerValue)
        if sender === hudVolumeSlider { showLevelHUD(.volume, linger: true) }
    }
    @objc private func brightnessSliderChanged(_ sender: NSSlider) {
        remote.setBacklight(sender.integerValue)
        if sender === hudBrightnessSlider { showLevelHUD(.backlight, linger: true) }
    }
    @objc private func okPress()   { remote.send("KEY_ENTER") }
    @objc private func backPress() { remote.send("KEY_RETURN") }
    @objc private func homePress() { remote.send("KEY_HOME") }
    @objc private func toggleRemoteModeMenu() { toggleRemoteMode() }

    // Settings checkboxes apply immediately (no Save button).
    @objc private func forwardCheckboxChanged(_ sender: NSButton) { setForwarding(sender.state == .on) }
    @objc private func autoWakeCheckboxChanged(_ sender: NSButton) {
        autoWakeEnabled = (sender.state == .on); refreshMenu()
    }
    @objc private func loginCheckboxChanged(_ sender: NSButton) {
        setLaunchAtLogin(sender.state == .on)
        refreshSettingsUI()   // reflect the real status (register/unregister may have failed)
    }

    // Settings window ---------------------------------------------------------

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = buildSettingsWindow() }
        refreshSettingsUI()
        NSApp.activate(ignoringOtherApps: true)     // .accessory app must activate to show a window
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    /// Programmatic AppKit (no SwiftUI/xib). isReleasedWhenClosed = false or closing the
    /// window double-releases it. Height derives from the stack; width fixed so labels wrap.
    private func buildSettingsWindow() -> NSWindow {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let statusLabel = NSTextField(labelWithString: "")
        let macLabel = NSTextField(labelWithString: "—")
        macLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        macLabel.textColor = .secondaryLabelColor
        let rescanBtn = NSButton(title: "Rescan", target: self, action: #selector(rescan))
        rescanBtn.bezelStyle = .rounded
        settingsStatusLabel = statusLabel
        settingsMacLabel = macLabel

        let ipRow = NSStackView()
        ipRow.orientation = .horizontal
        ipRow.spacing = 8
        let ipField = NSTextField(string: remote.ip ?? "")
        ipField.placeholderString = "192.168.x.x"
        ipField.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let applyIP = NSButton(title: "Connect IP", target: self, action: #selector(applyManualIP))
        applyIP.bezelStyle = .rounded
        settingsIPField = ipField
        ipRow.addArrangedSubview(ipField)
        ipRow.addArrangedSubview(applyIP)

        let hint = NSTextField(wrappingLabelWithString:
            "The monitor must join the same Wi‑Fi as this Mac. USB‑C video alone is not enough.")
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 320

        let volSl = NSSlider(value: Double(remote.volume ?? UserDefaults.standard.integer(forKey: "nit_volume")),
                             minValue: Double(NitRemote.volumeMin),
                             maxValue: Double(NitRemote.volumeMax),
                             target: self, action: #selector(volumeSliderChanged(_:)))
        volSl.isContinuous = true
        volSl.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let volLabel = NSTextField(labelWithString: "")
        volLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        volLabel.textColor = .secondaryLabelColor
        volumeSlider = volSl
        volumeValueLabel = volLabel

        let sl = NSSlider(value: Double(remote.backlight ?? UserDefaults.standard.integer(forKey: "nit_backlight")),
                          minValue: Double(NitRemote.backlightMin),
                          maxValue: Double(NitRemote.backlightMax),
                          target: self, action: #selector(brightnessSliderChanged(_:)))
        sl.isContinuous = true
        sl.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let slLabel = NSTextField(labelWithString: "")
        slLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        slLabel.textColor = .secondaryLabelColor
        brightnessSlider = sl
        brightnessValueLabel = slLabel
        let slHint = NSTextField(wrappingLabelWithString:
            "Absolute levels over IP Remote (volume 0–100, backlight 0–50). First use may show Allow.")
        slHint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        slHint.textColor = .secondaryLabelColor
        slHint.preferredMaxLayoutWidth = 320

        let fwd = NSButton(checkboxWithTitle: "Forward volume & brightness keys to the monitor",
                           target: self, action: #selector(forwardCheckboxChanged(_:)))
        let aw = NSButton(checkboxWithTitle: "Auto-wake monitor when the Mac wakes",
                          target: self, action: #selector(autoWakeCheckboxChanged(_:)))
        let login = NSButton(checkboxWithTitle: "Launch at Login",
                             target: self, action: #selector(loginCheckboxChanged(_:)))
        forwardCheckbox = fwd; autoWakeCheckbox = aw; loginCheckbox = login

        let shortcuts = NSTextField(wrappingLabelWithString:
            "⌃⌥←↑↓→ navigate · ⌃⌥↩ OK · ⌃⌥⌫ Back · ⌃⌥H Home · ⌃⌥P Power\n" +
            "⌃⌥[ ] brightness · ⌃⌥R Remote Mode (bare arrows / Return / Esc).")
        shortcuts.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        shortcuts.textColor = .secondaryLabelColor
        shortcuts.isSelectable = false
        shortcuts.widthAnchor.constraint(equalToConstant: 320).isActive = true   // 360 − insets → wraps

        for v in [settingsHeading("Monitor"), statusLabel, macLabel, ipRow, hint, rescanBtn,
                  settingsHeading("Volume"), volSl, volLabel,
                  settingsHeading("Backlight"), sl, slLabel, slHint,
                  settingsHeading("Options"), fwd, aw, login,
                  settingsHeading("Shortcuts"), shortcuts] {
            stack.addArrangedSubview(v)
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 360),
        ])
        container.layoutSubtreeIfNeeded()

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: container.fittingSize),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Nit Settings"
        window.isReleasedWhenClosed = false
        window.contentView = container
        window.center()
        return window
    }

    private func settingsHeading(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)
        return l
    }

    /// Two-way sync: re-read every state into the Settings controls. Called on open, from
    /// refreshMenu when the window is visible (which the remote.onUpdate path drives).
    private func refreshSettingsUI() {
        guard settingsWindow != nil else { return }
        settingsStatusLabel?.stringValue = statusString()
        settingsMacLabel?.stringValue = UserDefaults.standard.string(forKey: "nit_wifi_mac") ?? "—"
        if settingsIPField?.currentEditor() == nil {
            settingsIPField?.stringValue = remote.ip ?? settingsIPField?.stringValue ?? ""
        }
        forwardCheckbox?.state = (forwardingEnabled && AXIsProcessTrusted()) ? .on : .off  // same gate as the menu
        autoWakeCheckbox?.state = autoWakeEnabled ? .on : .off
        loginCheckbox?.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        applyLevelViews()
    }

    // About panel -------------------------------------------------------------

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)     // .accessory app must activate to show the panel
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]
        let credits = NSAttributedString(string:
            "Forwards the Mac keyboard's volume/mute and brightness keys, plus remote " +
            "navigation, to a Samsung Smart Monitor over Wi-Fi. Backlight uses " +
            "IP Control (IP Remote must be on).\n\n" +
            "⌃⌥←↑↓→ navigate · ⌃⌥↩ OK · ⌃⌥⌫ Back · ⌃⌥H Home · ⌃⌥P Power · ⌃⌥[ ] brightness · ⌃⌥R Remote Mode",
            attributes: attrs)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            .applicationName: "Nit",
            .applicationIcon: Self.appIconImage(),
        ])
    }

    /// LSUIElement apps have no Dock icon, so the stock About panel would otherwise
    /// show a generic placeholder. Load the bundled icns (asset-catalog AppIcon is
    /// not always reachable via NSImage(named:)).
    private static func appIconImage() -> NSImage {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let img = NSImage(contentsOf: url) {
            return img
        }
        let img = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        img.size = NSSize(width: 256, height: 256)
        return img
    }
    /// Smart power: toggle over the live socket, else run the wake sequence (WoL + guarded
    /// power). Never queues KEY_POWER — see NitRemote.sendPowerIfConnected.
    @objc private func powerToggle() {
        if remote.connected { remote.sendPowerIfConnected() }
        else { remote.wakeMonitor() }
    }
    @objc private func rescan()  { remote.rescan() }
    @objc private func applyManualIP() {
        remote.adoptManualIP(settingsIPField?.stringValue ?? "")
    }

    func menuWillOpen(_ menu: NSMenu) {
        remote.refreshLevels()
    }

    private func toggleRemoteMode() {
        remoteModeActive.toggle()
        updateStatusIcon()
        refreshMenu()
    }

    /// ⌃⌥ hotkeys → M9 nav. Arrows pass autorepeat (held navigation); every other handled
    /// key fires once but its autorepeats are still swallowed. Returns true when handled.
    func handleHotkey(keyCode: Int, autorepeat: Bool) -> Bool {
        switch keyCode {
        case 123: remote.send("KEY_LEFT");  return true
        case 124: remote.send("KEY_RIGHT"); return true
        case 125: remote.send("KEY_DOWN");  return true
        case 126: remote.send("KEY_UP");    return true
        case 36:  if !autorepeat { remote.send("KEY_ENTER") };  return true   // Return → OK
        case 51:  if !autorepeat { remote.send("KEY_RETURN") }; return true   // ⌫ → Back
        case 4:   if !autorepeat { remote.send("KEY_HOME") };   return true   // H → Home
        case 35:  if !autorepeat { powerToggle() };             return true   // P → power
        case 15:  if !autorepeat { toggleRemoteMode() };        return true   // R → Remote Mode
        case 33:  if !autorepeat { beginLevelHold(.backlight, delta: -1) }; return true
        case 30:  if !autorepeat { beginLevelHold(.backlight, delta: 1) };  return true
        default:  return false
        }
    }

    /// First event wins (HID + session, or F1 + NX_SYSDEFINED, must not double-step).
    /// OS key-repeat is ignored; a delay then a steady timer does the hold.
    func beginLevelHold(_ kind: LevelKind, delta: Int) {
        if holdKind == kind { return }
        endAllLevelHolds()
        holdKind = kind
        holdDelta = delta
        applyHoldStep()
        showLevelHUD(kind)
        holdDelayTimer = Timer.scheduledTimer(withTimeInterval: 0.22, repeats: false) { [weak self] _ in
            guard let self, self.holdKind == kind else { return }
            self.applyHoldStep()
            self.holdRepeatTimer = Timer.scheduledTimer(withTimeInterval: 0.07, repeats: true) { [weak self] _ in
                self?.applyHoldStep()
            }
        }
    }

    func endLevelHold(_ kind: LevelKind) {
        guard holdKind == kind else { return }
        endAllLevelHolds()
    }

    private func endAllLevelHolds() {
        holdDelayTimer?.invalidate(); holdDelayTimer = nil
        holdRepeatTimer?.invalidate(); holdRepeatTimer = nil
        holdKind = nil
    }

    private func applyHoldStep() {
        switch holdKind {
        case .volume: remote.nudgeVolume(holdDelta)
        case .backlight: remote.nudgeBacklight(holdDelta)
        case nil: break
        }
        if let holdKind { showLevelHUD(holdKind) }
    }

    /// Remote Mode bare keys → M9 nav. Same autorepeat policy as the ⌃⌥ hotkeys.
    func handleRemoteKey(keyCode: Int, autorepeat: Bool) -> Bool {
        switch keyCode {
        case 123: remote.send("KEY_LEFT");  return true
        case 124: remote.send("KEY_RIGHT"); return true
        case 125: remote.send("KEY_DOWN");  return true
        case 126: remote.send("KEY_UP");    return true
        case 36:  if !autorepeat { remote.send("KEY_ENTER") };  return true   // Return → OK
        case 53:  if !autorepeat { remote.send("KEY_RETURN") }; return true   // Esc → Back
        default:  return false
        }
    }
    @objc private func openAccessibility() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // Event tap ---------------------------------------------------------------

    private func promptAccessibilityIfNeeded() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    private func createTap() {
        guard eventTaps.isEmpty, AXIsProcessTrusted() else { return }
        let mask = CGEventMask((1 << 14) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue))
        // HID first: Logitech brightness is often F14/F15 or a consumer HID event that
        // WindowServer applies to the Air before a session tap sees it. Swallowing here
        // keeps both keyboards on the monitor. Session tap is the fallback for media keys.
        for location: CGEventTapLocation in [.cghidEventTap, .cgSessionEventTap] {
            guard let tap = CGEvent.tapCreate(
                tap: location, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask,
                callback: mediaKeyCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ) else { continue }
            eventTaps.append(tap)
            if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
                CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
                runLoopSources.append(src)
            }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    func reenableTap() {
        for tap in eventTaps { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func relaunchSelf() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-n", Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }
}

// MARK: - Entry point ---------------------------------------------------------

let delegate = AppDelegate()
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
