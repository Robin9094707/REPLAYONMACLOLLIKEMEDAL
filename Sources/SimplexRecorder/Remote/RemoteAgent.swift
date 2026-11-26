import AppKit
import IOKit.ps
import VirtualDisplayBridge

/// Keeps the Mac permanently reachable through the relay: reconnects automatically,
/// publishes live status, streams the screen on demand and executes remote input/actions.
@MainActor
final class RemoteAgent: ObservableObject {
    static let shared = RemoteAgent()

    enum ConnectionState: Equatable {
        case off, connecting, connected, error(String)

        var title: String {
            switch self {
            case .off: return "Aus"
            case .connecting: return "Verbinde …"
            case .connected: return "Verbunden"
            case .error(let message): return message
            }
        }
    }

    @Published private(set) var state: ConnectionState = .off
    @Published private(set) var attachedClients = 0
    @Published private(set) var watchingClients = 0
    @Published private(set) var streaming = false
    @Published private(set) var streamMode = "mirror"

    private var task: URLSessionWebSocketTask?
    private let session = URLSession(configuration: .default)
    private var reconnectDelay: Double = 2
    private var reconnectTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var clipboardTimer: Timer?
    private var lastClipboardCount = NSPasteboard.general.changeCount
    private var observers: [NSObjectProtocol] = []
    private var cancellables: [Any] = []
    private var generation = 0

    private let injector = InputInjector()
    private let streamer = ScreenStreamer()
    private var virtualDisplay: SXVirtualDisplay?
    private var savedMainOrigin: CGPoint?

    // Video send pacing (accessed from the encoder thread).
    nonisolated(unsafe) private var inflight = 0
    nonisolated(unsafe) private var waitingForKeyframe = false
    nonisolated private let sendLock = NSLock()
    nonisolated(unsafe) private var sendTask: URLSessionWebSocketTask?
    nonisolated(unsafe) private var sendCrypto: RemoteCrypto?

    // Adaptive streaming: the phone acknowledges frames by sequence number. Frames older
    // than the latency budget are skipped and the bitrate follows the connection.
    nonisolated(unsafe) private var frameSeq: UInt64 = 0
    nonisolated(unsafe) private var ackedSeq: UInt64 = 0
    nonisolated(unsafe) private var acksSeen = false
    nonisolated(unsafe) private var sentTimes: [UInt64: TimeInterval] = [:]
    nonisolated(unsafe) private var droppedFrames = 0
    nonisolated(unsafe) private var sentBytes = 0
    private var rttMs: Double = 0
    private var currentKbps = 4500
    private var targetKbps = 4500
    private var streamFPS = 30
    private var stableSeconds = 0
    private var adaptTimer: Timer?
    private static let latencyBudget: TimeInterval = 0.25

    private var config: RemoteConfig { RemoteConfig.shared }

    // MARK: Lifecycle

    func start() {
        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in RemoteAgent.shared.reconnectNow() }
        }
        observers.append(token)
        streamer.onPacket = { [weak self] data, keyframe in
            self?.sendVideo(data, keyframe: keyframe)
        }
        streamer.onStop = { _ in
            Task { @MainActor in RemoteAgent.shared.stopStreaming() }
        }
        applyConfig()
    }

    /// Call after settings changed.
    func applyConfig() {
        disconnect()
        guard config.enabled else {
            state = .off
            return
        }
        guard config.isConfigured, config.webSocketURL != nil else {
            state = .error("Server-Adresse oder Passwort fehlt")
            return
        }
        connect()
    }

    func reconnectNow() {
        guard config.enabled else { return }
        reconnectDelay = 2
        disconnect()
        connect()
    }

    private func connect() {
        guard let url = config.webSocketURL else { return }
        generation += 1
        let gen = generation
        state = .connecting
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        sendLock.lock()
        sendTask = task
        sendCrypto = config.crypto
        sendLock.unlock()
        task.resume()

        let hello: [String: Any] = [
            "type": "hello", "role": "mac", "password": config.serverPassword,
            "mac": config.macID, "name": config.computerName,
        ]
        sendJSON(hello)
        receiveLoop(task, generation: gen)
    }

    private func disconnect() {
        generation += 1
        reconnectTask?.cancel()
        statusTimer?.invalidate()
        statusTimer = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        sendLock.lock()
        sendTask = nil
        sendLock.unlock()
        attachedClients = 0
        watchingClients = 0
        stopStreaming()
        updateClipboardWatch()
    }

    private func scheduleReconnect(reason: String) {
        guard config.enabled else { return }
        state = .error(reason)
        task = nil
        stopStreaming()
        let delay = reconnectDelay
        reconnectDelay = min(reconnectDelay * 2, 30)
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, self.config.enabled else { return }
            self.connect()
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask, generation gen: Int) {
        task.receive { result in
            Task { @MainActor in
                let agent = RemoteAgent.shared
                guard gen == agent.generation else { return }
                switch result {
                case .failure(let error):
                    DiagnosticsLog.write("remote: connection lost: \(error.localizedDescription)")
                    agent.scheduleReconnect(reason: "Getrennt – verbinde neu …")
                case .success(let message):
                    agent.handle(message)
                    agent.receiveLoop(task, generation: gen)
                }
            }
        }
    }

    // MARK: Incoming

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            handleServer(json)
        case .data(let data):
            guard data.count > 1, data[data.startIndex] == RemoteKind.control.rawValue,
                  let plain = config.crypto.open(data.dropFirst()),
                  let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] else { return }
            handleControl(json)
        @unknown default:
            break
        }
    }

    private func handleServer(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "welcome":
            state = .connected
            reconnectDelay = 2
            DiagnosticsLog.write("remote: connected to relay")
            sendStatus()
            rescheduleStatus()
        case "clients":
            let attached = json["attached"] as? Int ?? 0
            let watching = json["watching"] as? Int ?? 0
            let wasWatching = watchingClients + attachedClients > 0
            attachedClients = attached
            watchingClients = watching
            if attached == 0 { stopStreaming() }
            let nowWatching = attached + watching > 0
            if nowWatching != wasWatching {
                if nowWatching {
                    SystemMonitor.shared.acquire("remote", perApp: true)
                } else {
                    SystemMonitor.shared.release("remote")
                }
            }
            rescheduleStatus()
            updateClipboardWatch()
            sendStatus()
        case "error":
            let message = json["message"] as? String ?? "Fehler"
            state = .error(message)
            if json["code"] as? String == "auth" {
                // Wrong password: don't hammer the server.
                reconnectDelay = 30
            }
        default:
            break
        }
    }

    private var lastAccessibilityWarning = Date.distantPast

    /// Synthetic mouse/keyboard events are silently dropped by macOS without Accessibility.
    private func ensureAccessibility() -> Bool {
        if AXIsProcessTrusted() { return true }
        if Date().timeIntervalSince(lastAccessibilityWarning) > 20 {
            lastAccessibilityWarning = Date()
            toast("⚠️ Am Mac fehlt die Berechtigung „Bedienungshilfen“ – bitte erlauben")
            GameWindowAssistant.requestTrust()
            DiagnosticsLog.write("remote: input blocked – Accessibility not granted")
        }
        return false
    }

    private func handleControl(_ msg: [String: Any]) {
        guard let type = msg["t"] as? String else { return }
        let control = config.allowControl
        let inputTypes: Set<String> = ["mouse", "text", "key", "unlock"]
        if inputTypes.contains(type) && control && !ensureAccessibility() { return }
        switch type {
        case "start":
            guard control else { return toast("Fernsteuerung ist am Mac deaktiviert") }
            startStreaming(msg)
        case "stop":
            stopStreaming()
        case "keyframe":
            streamer.requestKeyframe()
        case "ack":
            if let seq = (msg["seq"] as? NSNumber)?.uint64Value { handleAck(seq) }
        case "mouse":
            if control { injector.handleMouse(msg) }
        case "text":
            if control, let s = msg["s"] as? String { injector.typeText(s) }
        case "key":
            if control, let k = msg["k"] as? String { injector.pressKey(k, modifiers: msg["m"] as? [String] ?? []) }
        case "clip":
            if let s = msg["s"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
                lastClipboardCount = NSPasteboard.general.changeCount
            }
        case "action":
            guard control else { return toast("Fernsteuerung ist am Mac deaktiviert") }
            if msg["a"] as? String == "openAccessibility" {
                if AXIsProcessTrusted() { return toast("✓ Bedienungshilfen sind bereits erlaubt") }
                GameWindowAssistant.resetTrust()
                GameWindowAssistant.requestTrust()
                GameWindowAssistant.openAccessibilitySettings()
                return toast("Am Mac: „Simplex Suite“ in Bedienungshilfen einschalten")
            }
            let keyActions: Set<String> = ["lock", "playPause", "next", "previous", "showDesktop", "spotlight",
                                           "appSwitcher", "copy", "paste", "undo", "closeWindow"]
            if keyActions.contains(msg["a"] as? String ?? "") && !ensureAccessibility() { return }
            RemoteActions.perform(msg, injector: injector) { [weak self] text in self?.toast(text) }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.2))
                self.sendStatus()
            }
        case "unlock":
            guard config.allowUnlock, let pw = msg["pw"] as? String, !pw.isEmpty else {
                return toast("Entsperren ist am Mac deaktiviert")
            }
            DiagnosticsLog.write("remote: unlock requested")
            injector.unlock(password: pw)
            toast("Mac wird entsperrt …")
        case "status":
            sendStatus()
        default:
            break
        }
    }

    // MARK: Outgoing

    private func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    private func sendEncrypted(_ kind: RemoteKind, _ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let sealed = config.crypto.seal(kind, data) else { return }
        task?.send(.data(sealed)) { _ in }
    }

    func toast(_ text: String) {
        sendEncrypted(.control, ["t": "toast", "s": text])
    }

    /// Called on the encoder thread. Skips frames when the connection can't keep up, so the
    /// picture on the phone stays live instead of lagging behind.
    nonisolated private func sendVideo(_ packet: Data, keyframe: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        sendLock.lock()
        let task = sendTask, crypto = sendCrypto
        var tooLate = false
        if acksSeen {
            // Oldest frame the phone hasn't confirmed yet.
            if let oldest = sentTimes[ackedSeq + 1], now - oldest > Self.latencyBudget { tooLate = true }
        } else if inflight > 4 {
            tooLate = true
        }
        if !keyframe && (tooLate || waitingForKeyframe) {
            waitingForKeyframe = true
            droppedFrames += 1
            sendLock.unlock()
            return
        }
        if keyframe && tooLate && sentTimes.count > Int(Self.latencyBudget * 120) {
            // Even keyframes wait while the pipe is completely clogged.
            droppedFrames += 1
            sendLock.unlock()
            return
        }
        waitingForKeyframe = false
        frameSeq += 1
        let seq = frameSeq
        sentTimes[seq] = now
        if sentTimes.count > 600 {
            let floor = seq > 300 ? seq - 300 : 0
            sentTimes = sentTimes.filter { $0.key > floor }
        }
        inflight += 1
        sentBytes += packet.count
        sendLock.unlock()

        // Bytes 1…8 carry the frame sequence number (the phone acknowledges it).
        var stamped = packet
        var seqBE = seq.bigEndian
        withUnsafeBytes(of: &seqBE) { stamped.replaceSubrange(1..<9, with: $0) }

        guard let task, let crypto, let sealed = crypto.seal(.video, stamped) else {
            sendLock.lock(); inflight -= 1; sendLock.unlock()
            return
        }
        task.send(.data(sealed)) { [weak self] _ in
            guard let self else { return }
            self.sendLock.lock()
            self.inflight -= 1
            let recovered = !self.acksSeen && self.waitingForKeyframe && self.inflight < 2
            self.sendLock.unlock()
            if recovered {
                Task { @MainActor in RemoteAgent.shared.streamer.requestKeyframe() }
            }
        }
    }

    /// The phone confirmed frames up to `seq`.
    private func handleAck(_ seq: UInt64) {
        let now = ProcessInfo.processInfo.systemUptime
        sendLock.lock()
        acksSeen = true
        var rtt: Double?
        if seq > ackedSeq {
            if let sent = sentTimes[seq] { rtt = (now - sent) * 1000 }
            ackedSeq = seq
            sentTimes = sentTimes.filter { $0.key > seq }
        }
        let caughtUp = waitingForKeyframe && sentTimes.count < 3
        sendLock.unlock()
        if let rtt { rttMs = rttMs == 0 ? rtt : rttMs * 0.8 + rtt * 0.2 }
        if caughtUp { streamer.requestKeyframe() }
    }

    /// Once per second: follow the connection (AIMD – drop fast, climb slowly).
    private func adaptBitrate() {
        sendLock.lock()
        let dropped = droppedFrames
        let bytes = sentBytes
        droppedFrames = 0
        sentBytes = 0
        sendLock.unlock()

        let congested = dropped > 0 || rttMs > 300
        if congested {
            currentKbps = max(600, Int(Double(currentKbps) * 0.7))
            stableSeconds = 0
            streamer.setBitrate(kbps: currentKbps)
        } else {
            stableSeconds += 1
            if stableSeconds >= 3 && rttMs < 180 && currentKbps < targetKbps {
                currentKbps = min(targetKbps, Int(Double(currentKbps) * 1.15) + 100)
                streamer.setBitrate(kbps: currentKbps)
            }
        }
        sendEncrypted(.control, ["t": "net", "kbps": currentKbps, "actualKbps": bytes * 8 / 1000,
                                 "rtt": Int(rttMs), "dropped": dropped, "fps": streamFPS])
    }

    // MARK: Status

    private func rescheduleStatus() {
        statusTimer?.invalidate()
        guard state == .connected else { return }
        let interval: TimeInterval = attachedClients + watchingClients > 0 ? 2 : 30
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in RemoteAgent.shared.sendStatus() }
        }
        timer.tolerance = interval * 0.2
        statusTimer = timer
    }

    func sendStatus() {
        guard state == .connected else { return }
        if attachedClients + watchingClients == 0 { SystemMonitor.shared.sample() }
        let s = SystemMonitor.shared.snapshot
        let app = AppState.shared
        var status: [String: Any] = [
            "name": config.computerName,
            "model": Self.model,
            "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "uptime": Int(ProcessInfo.processInfo.systemUptime),
            "cpu": s.cpuUsage,
            "mem": s.memoryUsed,
            "memTotal": s.memoryTotal,
            "thermal": s.thermalText,
            "diskFree": s.diskFree,
            "diskTotal": s.diskTotal,
            "locked": InputInjector.isScreenLocked,
            "clipping": app.isRecording,
            "clipStatus": app.statusLine,
            "streaming": streaming,
            "mode": streamMode,
            "control": config.allowControl,
            "virtualDisplays": SXVirtualDisplay.isSupported(),
            "trusted": AXIsProcessTrusted(),
            "screen": Permissions.hasScreenRecording,
            "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
            "t": Date().timeIntervalSince1970,
        ]
        if let temp = s.cpuTemperature { status["temp"] = temp }
        if let battery = Self.battery() { status["battery"] = battery.level; status["charging"] = battery.charging }
        if let game = app.detector.currentGame { status["game"] = game.name }
        if attachedClients + watchingClients > 0 {
            status["apps"] = SystemMonitor.shared.apps.filter(\.isApp).prefix(40).map { usage -> [String: Any] in
                ["pid": Int(usage.pid), "name": usage.name, "bundle": usage.bundleID ?? "",
                 "cpu": usage.cpu, "mem": usage.memory,
                 "protected": ProtectedApps.isProtected(bundleID: usage.bundleID)]
            }
        }
        sendEncrypted(.status, status)
    }

    private static let model: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
    }()

    private static func battery() -> (level: Int, charging: Bool)? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in list {
            guard let desc = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  let capacity = desc[kIOPSCurrentCapacityKey] as? Int else { continue }
            let charging = (desc[kIOPSIsChargingKey] as? Bool) ?? false
            return (capacity, charging)
        }
        return nil
    }

    // MARK: Clipboard

    private func updateClipboardWatch() {
        let wanted = attachedClients > 0
        if wanted, clipboardTimer == nil {
            lastClipboardCount = NSPasteboard.general.changeCount
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                Task { @MainActor in RemoteAgent.shared.checkClipboard() }
            }
            timer.tolerance = 0.3
            clipboardTimer = timer
        } else if !wanted {
            clipboardTimer?.invalidate()
            clipboardTimer = nil
        }
    }

    private func checkClipboard() {
        let count = NSPasteboard.general.changeCount
        guard count != lastClipboardCount else { return }
        lastClipboardCount = count
        if let text = NSPasteboard.general.string(forType: .string), text.utf8.count < 512_000 {
            sendEncrypted(.control, ["t": "clip", "s": text])
        }
    }

    // MARK: Streaming

    private func startStreaming(_ msg: [String: Any]) {
        let mode = msg["mode"] as? String ?? "mirror"
        let fps = min(max(msg["fps"] as? Int ?? 30, 10), 60)
        let kbps = min(max(msg["kbps"] as? Int ?? 6000, 500), 40000)
        let maxWidth = min(max(msg["maxWidth"] as? Int ?? 1920, 640), 3840)
        let phoneW = msg["w"] as? Int ?? 852
        let phoneH = msg["h"] as? Int ?? 393

        Task { @MainActor in
            if self.streaming { await self.stopStreamingAsync(keepDisplay: false) }
            var displayID = CGMainDisplayID()
            if mode == "extend" || mode == "main" {
                guard let id = self.createVirtualDisplay(phoneWidth: phoneW, phoneHeight: phoneH, makeMain: mode == "main") else {
                    self.toast("Virtueller Bildschirm wird von diesem macOS nicht unterstützt – spiegele stattdessen")
                    return
                }
                displayID = id
                try? await Task.sleep(for: .milliseconds(900)) // let macOS set the display up
            }
            self.injector.displayID = displayID
            self.resetAdaptiveState(kbps: kbps, fps: fps)
            do {
                try await self.streamer.start(.init(displayID: displayID, maxWidth: maxWidth, fps: fps, kbps: self.currentKbps))
                self.adaptTimer?.invalidate()
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
                    Task { @MainActor in RemoteAgent.shared.adaptBitrate() }
                }
                timer.tolerance = 0.1
                self.adaptTimer = timer
                self.streaming = true
                self.streamMode = mode
                let (w, h) = self.streamer.dimensions
                self.sendEncrypted(.control, ["t": "stream", "w": w, "h": h, "mode": mode])
                self.sendStatus()
            } catch {
                DiagnosticsLog.write("remote: stream start failed: \(error)")
                self.toast("Bildschirm konnte nicht übertragen werden: \(error.localizedDescription)")
                self.destroyVirtualDisplay()
            }
        }
    }

    func stopStreaming() {
        Task { @MainActor in await self.stopStreamingAsync(keepDisplay: false) }
    }

    private func stopStreamingAsync(keepDisplay: Bool) async {
        guard streaming || virtualDisplay != nil else { return }
        adaptTimer?.invalidate()
        adaptTimer = nil
        await streamer.stop()
        streaming = false
        injector.displayID = CGMainDisplayID()
        if !keepDisplay { destroyVirtualDisplay() }
        DiagnosticsLog.write("remote: streaming stopped")
    }

    private func resetAdaptiveState(kbps: Int, fps: Int) {
        sendLock.lock()
        frameSeq = 0
        ackedSeq = 0
        acksSeen = false
        sentTimes = [:]
        droppedFrames = 0
        sentBytes = 0
        waitingForKeyframe = false
        inflight = 0
        sendLock.unlock()
        rttMs = 0
        targetKbps = kbps
        // Start a bit below the target and climb – avoids a burst of lag right at the start.
        currentKbps = max(800, Int(Double(kbps) * 0.6))
        streamFPS = fps
        stableSeconds = 0
    }

    /// Creates a virtual monitor shaped like the phone (scaled up so the desktop is usable).
    private func createVirtualDisplay(phoneWidth: Int, phoneHeight: Int, makeMain: Bool) -> CGDirectDisplayID? {
        destroyVirtualDisplay()
        let factor = 1.6
        let w = UInt32((Double(phoneWidth) * factor).rounded()) & ~1
        let h = UInt32((Double(phoneHeight) * factor).rounded()) & ~1
        guard let display = SXVirtualDisplay(name: "iPhone (Simplex)", width: w, height: h, hiDPI: true) else { return nil }
        virtualDisplay = display
        let id = display.displayID
        DiagnosticsLog.write("remote: virtual display \(id) \(w)x\(h) main=\(makeMain)")

        var configRef: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&configRef) == .success, let configRef else { return id }
        let main = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(main)
        if makeMain {
            // The display at (0,0) is the main display (menu bar + Dock).
            CGConfigureDisplayOrigin(configRef, id, 0, 0)
            CGConfigureDisplayOrigin(configRef, main, -Int32(mainBounds.width), 0)
        } else {
            CGConfigureDisplayOrigin(configRef, id, Int32(mainBounds.maxX), 0)
        }
        CGCompleteDisplayConfiguration(configRef, .forSession)
        return id
    }

    private func destroyVirtualDisplay() {
        guard virtualDisplay != nil else { return }
        virtualDisplay = nil  // releasing the object removes the display
    }
}
