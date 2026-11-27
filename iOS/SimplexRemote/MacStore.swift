import Foundation
import SwiftUI

/// One WebSocket connection to a relay server (shared by all Macs on that server).
final class RelayConnection: NSObject {
    enum State: Equatable { case disconnected, connecting, connected, failed(String) }

    let server: String
    private(set) var password: String
    private(set) var macIDs: Set<String>
    private var keys: [String: RemoteCrypto]
    private var task: URLSessionWebSocketTask?
    private lazy var session = URLSession(configuration: .default)
    private var generation = 0
    private var reconnectWork: DispatchWorkItem?
    private var shouldRun = false
    private let lock = NSLock()
    /// Mac the relay currently routes our commands to.
    private(set) var attachedMac: String?

    // Callbacks (status/control on the main queue, video on the receive queue).
    var onState: ((State) -> Void)?
    var onPresence: ((String, Presence) -> Void)?
    var onStatus: ((String, [String: Any]) -> Void)?
    var onControl: ((String, [String: Any]) -> Void)?
    var onVideo: ((String, Data) -> Void)?

    init(server: String, password: String) {
        self.server = server
        self.password = password
        self.macIDs = []
        self.keys = [:]
    }

    func register(macID: String, key: Data, password: String) {
        lock.lock()
        macIDs.insert(macID)
        keys[macID] = RemoteCrypto(keyData: key)
        self.password = password
        lock.unlock()
        if task != nil { sendJSON(["type": "subscribe", "macs": Array(macIDs)]) }
    }

    func unregister(macID: String) {
        lock.lock()
        macIDs.remove(macID)
        keys[macID] = nil
        lock.unlock()
        if task != nil { sendJSON(["type": "subscribe", "macs": Array(macIDs)]) }
    }

    private func crypto(for macID: String) -> RemoteCrypto? {
        lock.lock(); defer { lock.unlock() }
        return keys[macID]
    }

    var webSocketURL: URL? {
        var raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.contains("://") { raw = "https://" + raw }
        guard var comps = URLComponents(string: raw) else { return nil }
        comps.scheme = (comps.scheme?.lowercased() == "http" || comps.scheme?.lowercased() == "ws") ? "ws" : "wss"
        if comps.path.isEmpty || comps.path == "/" { comps.path = "/ws" }
        return comps.url
    }

    // MARK: Connection

    func start() {
        shouldRun = true
        guard task == nil else { return }
        connect()
    }

    func stop() {
        shouldRun = false
        reconnectWork?.cancel()
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        emit(.disconnected)
    }

    private func connect() {
        guard let url = webSocketURL else { return emit(.failed("Ungültige Server-Adresse")) }
        generation += 1
        let gen = generation
        let task = session.webSocketTask(with: url)
        task.maximumMessageSize = 16 * 1024 * 1024
        self.task = task
        attachedMac = nil
        emit(.connecting)
        task.resume()
        lock.lock()
        let macs = Array(macIDs)
        lock.unlock()
        sendJSON(["type": "hello", "role": "client", "password": password, "macs": macs])
        receive(task, gen)
        schedulePing(gen)
    }

    private func scheduleReconnect() {
        task = nil
        guard shouldRun else { return }
        reconnectWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.shouldRun, self.task == nil else { return }
            self.connect()
        }
        reconnectWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func schedulePing(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, gen == self.generation, let task = self.task else { return }
            task.sendPing { _ in }
            self.schedulePing(gen)
        }
    }

    private func receive(_ task: URLSessionWebSocketTask, _ gen: Int) {
        task.receive { [weak self] result in
            guard let self, gen == self.generation else { return }
            switch result {
            case .failure(let error):
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }
                    self.emit(.failed(error.localizedDescription))
                    self.scheduleReconnect()
                }
            case .success(let message):
                self.handle(message)
                self.receive(task, gen)
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            guard let data = text.data(using: .utf8),
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
            DispatchQueue.main.async { self.handleServer(json) }
        case .data(let data):
            // [kind][len][mac id][sealed]
            guard data.count > 3 else { return }
            let bytes = [UInt8](data.prefix(2))
            let kind = bytes[0], idLength = Int(bytes[1])
            guard data.count > 2 + idLength,
                  let macID = String(data: data.subdata(in: 2..<(2 + idLength)), encoding: .utf8),
                  let crypto = crypto(for: macID),
                  let plain = crypto.open(data.subdata(in: (2 + idLength)..<data.count)) else { return }
            switch RemoteKind(rawValue: kind) {
            case .video:
                onVideo?(macID, plain)
            case .status:
                if let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] {
                    DispatchQueue.main.async { self.onStatus?(macID, json) }
                }
            case .control:
                if let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any] {
                    DispatchQueue.main.async { self.onControl?(macID, json) }
                }
            case .none:
                break
            }
        @unknown default:
            break
        }
    }

    private func handleServer(_ json: [String: Any]) {
        switch json["type"] as? String {
        case "welcome":
            emit(.connected)
            for entry in json["macs"] as? [[String: Any]] ?? [] { handlePresence(entry) }
        case "presence":
            handlePresence(json)
        case "clips":
            NotificationCenter.default.post(name: .simplexClipsChanged, object: nil)
        case "error":
            emit(.failed(json["message"] as? String ?? "Serverfehler"))
            if json["code"] as? String == "auth" { shouldRun = false }
        default:
            break
        }
    }

    private func handlePresence(_ json: [String: Any]) {
        guard let mac = json["mac"] as? String else { return }
        var p = Presence()
        p.online = json["online"] as? Bool ?? false
        if let since = (json["since"] as? NSNumber)?.doubleValue { p.since = Date(timeIntervalSince1970: since) }
        if let seen = (json["lastSeen"] as? NSNumber)?.doubleValue { p.lastSeen = Date(timeIntervalSince1970: seen) }
        onPresence?(mac, p)
    }

    private func emit(_ state: State) {
        if Thread.isMainThread { onState?(state) } else { DispatchQueue.main.async { self.onState?(state) } }
    }

    // MARK: Sending

    func sendJSON(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(text)) { _ in }
    }

    func attach(_ macID: String) {
        attachedMac = macID
        sendJSON(["type": "attach", "mac": macID])
    }

    func detach() {
        attachedMac = nil
        sendJSON(["type": "detach"])
    }

    /// The relay only forwards commands to the attached Mac – attach first if needed.
    /// (Text and binary messages keep their order on the WebSocket.)
    func sendControl(_ object: [String: Any], to macID: String) {
        if attachedMac != macID { attach(macID) }
        guard let crypto = crypto(for: macID),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let sealed = crypto.seal(.control, data) else { return }
        task?.send(.data(sealed)) { _ in }
    }
}

/// All paired Macs and their live data.
@MainActor
final class MacStore: ObservableObject {
    @Published private(set) var macs: [PairedMac] = []
    @Published private(set) var statuses: [String: MacStatus] = [:]
    @Published private(set) var presence: [String: Presence] = [:]
    @Published private(set) var cpuHistory: [String: [Double]] = [:]
    @Published private(set) var serverStates: [String: RelayConnection.State] = [:]
    @Published var toast: String?

    private var connections: [String: RelayConnection] = [:]
    private let storageKey = "pairedMacs"

    /// Control messages for an active remote session.
    var controlHandler: ((String, [String: Any]) -> Void)?
    /// Called when a relay connection is (re)established – the session re-requests its stream.
    var reconnectHandler: ((String) -> Void)?
    /// Video frames (called off the main thread).
    var videoHandler: ((String, Data) -> Void)? {
        didSet { connections.values.forEach { $0.onVideo = videoHandler } }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let list = try? JSONDecoder().decode([PairedMac].self, from: data) {
            macs = list
        }
        for mac in macs { register(mac) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(macs) { UserDefaults.standard.set(data, forKey: storageKey) }
    }

    // MARK: Pairing

    @discardableResult
    func add(_ payload: PairingPayload) -> PairedMac {
        Keychain.set(payload.key, account: "key-\(payload.macID)")
        Keychain.set(Data(payload.password.utf8), account: "server-\(payload.macID)")
        let mac = PairedMac(id: payload.macID, name: payload.name, server: payload.server)
        if let index = macs.firstIndex(where: { $0.id == mac.id }) {
            macs[index] = mac
        } else {
            macs.append(mac)
        }
        save()
        register(mac)
        connection(for: mac)?.start()
        return mac
    }

    func remove(_ mac: PairedMac) {
        connection(for: mac)?.unregister(macID: mac.id)
        Keychain.delete("key-\(mac.id)")
        Keychain.delete("server-\(mac.id)")
        Keychain.deleteUnlockPassword(macID: mac.id)
        macs.removeAll { $0.id == mac.id }
        statuses[mac.id] = nil
        save()
    }

    func rename(_ mac: PairedMac, to name: String) {
        guard let index = macs.firstIndex(where: { $0.id == mac.id }) else { return }
        macs[index].name = name
        save()
    }

    private func register(_ mac: PairedMac) {
        guard let key = Keychain.get("key-\(mac.id)"),
              let pw = Keychain.get("server-\(mac.id)").flatMap({ String(data: $0, encoding: .utf8) }) else { return }
        let conn = connections[mac.serverKey] ?? makeConnection(server: mac.server, password: pw)
        conn.register(macID: mac.id, key: key, password: pw)
    }

    private func makeConnection(server: String, password: String) -> RelayConnection {
        let conn = RelayConnection(server: server, password: password)
        let key = server.lowercased()
        conn.onState = { [weak self] state in
            guard let self else { return }
            let previous = self.serverStates[key]
            self.serverStates[key] = state
            if state == .connected && previous != .connected { self.reconnectHandler?(key) }
        }
        conn.onPresence = { [weak self] mac, p in self?.presence[mac] = p }
        conn.onStatus = { [weak self] mac, json in self?.updateStatus(mac, json) }
        conn.onControl = { [weak self] mac, json in self?.handleControl(mac, json) }
        conn.onVideo = videoHandler
        connections[key] = conn
        return conn
    }

    func connection(for mac: PairedMac) -> RelayConnection? { connections[mac.serverKey] }

    // MARK: Lifecycle

    func connectAll() { connections.values.forEach { $0.start() } }
    func disconnectAll() { connections.values.forEach { $0.stop() } }

    func serverState(for mac: PairedMac) -> RelayConnection.State {
        serverStates[mac.serverKey] ?? .disconnected
    }

    func isOnline(_ mac: PairedMac) -> Bool { presence[mac.id]?.online ?? false }

    // MARK: Incoming

    private func updateStatus(_ mac: String, _ json: [String: Any]) {
        let status = MacStatus(json: json)
        statuses[mac] = status
        var history = cpuHistory[mac] ?? []
        history.append(status.cpu)
        cpuHistory[mac] = Array(history.suffix(60))
        if var p = presence[mac], !p.online {
            p.online = true
            presence[mac] = p
        }
    }

    private func handleControl(_ mac: String, _ json: [String: Any]) {
        if json["t"] as? String == "toast", let text = json["s"] as? String {
            withAnimation(.spring) { toast = text }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.5))
                if self.toast == text { withAnimation { self.toast = nil } }
            }
        }
        controlHandler?(mac, json)
    }

    // MARK: Commands

    func send(_ object: [String: Any], to mac: PairedMac) {
        guard let conn = connection(for: mac) else { return }
        conn.sendControl(object, to: mac.id)
    }

    func detach(_ mac: PairedMac) {
        guard let conn = connection(for: mac), conn.attachedMac == mac.id else { return }
        conn.detach()
    }

    func action(_ action: QuickAction, on mac: PairedMac) {
        send(["t": "action", "a": action.rawValue], to: mac)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    func quitApp(_ app: AppUsage, on mac: PairedMac, force: Bool = false) {
        send(["t": "action", "a": "quitApp", "pid": app.pid, "force": force], to: mac)
    }

    func unlock(_ mac: PairedMac) async -> Bool {
        guard let password = await Keychain.loadUnlockPassword(macID: mac.id) else { return false }
        send(["t": "unlock", "pw": password], to: mac)
        return true
    }
}
