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

    private func handleControl(_ msg: [String: Any]) {
        guard let type = msg["t"] as? String else { return }
        let control = config.allowControl
        switch type {
        case "start":
            guard control else { return toast("Fernsteuerung ist am Mac deaktiviert") }
            startStreaming(msg)
        case "stop":
            stopStreaming()
        case "keyframe":
            streamer.requestKeyframe()
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

    /// Called on the encoder thread. Drops frames when the connection can't keep up.
    nonisolated private func sendVideo(_ packet: Data, keyframe: Bool) {
        sendLock.lock()
        let task = sendTask, crypto = sendCrypto
        if inflight > 8 && !keyframe {
            waitingForKeyframe = true
            sendLock.unlock()
            return
        }
        if waitingForKeyframe && !keyframe {
            sendLock.unlock()
            return
        }
        waitingForKeyframe = false
        inflight += 1
        sendLock.unlock()
        guard let task, let crypto, let sealed = crypto.seal(.video, packet) else {
            sendLock.lock(); inflight -= 1; sendLock.unlock()
            return
        }
        task.send(.data(sealed)) { [weak self] _ in
            guard let self else { return }
            self.sendLock.lock()
            self.inflight -= 1
            let recovered = self.waitingForKeyframe && self.inflight < 3
            self.sendLock.unlock()
            if recovered {
                Task { @MainActor in RemoteAgent.shared.streamer.requestKeyframe() }
            }
        }
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
            do {
                try await self.streamer.start(.init(displayID: displayID, maxWidth: maxWidth, fps: fps, kbps: kbps))
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
        await streamer.stop()
        streaming = false
        injector.displayID = CGMainDisplayID()
        if !keepDisplay { destroyVirtualDisplay() }
        DiagnosticsLog.write("remote: streaming stopped")
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
