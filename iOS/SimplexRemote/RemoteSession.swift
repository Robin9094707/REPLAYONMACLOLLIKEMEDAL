import SwiftUI
import UIKit

enum DisplayMode: String, CaseIterable, Identifiable {
    case mirror, extend, main
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mirror: return "Mac spiegeln"
        case .extend: return "Zweiter Bildschirm"
        case .main: return "Hauptbildschirm"
        }
    }
    var detail: String {
        switch self {
        case .mirror: return "Zeigt den Mac-Bildschirm und steuert ihn per Touch."
        case .extend: return "Dein iPhone wird ein zusätzlicher Monitor (experimentell)."
        case .main: return "Das iPhone wird zum Hauptbildschirm mit Menüleiste und Dock (experimentell)."
        }
    }
    var symbol: String {
        switch self {
        case .mirror: return "rectangle.on.rectangle"
        case .extend: return "rectangle.split.2x1"
        case .main: return "iphone.gen3"
        }
    }
}

enum StreamQuality: String, CaseIterable, Identifiable {
    case saver, balanced, sharp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .saver: return "Datensparend"
        case .balanced: return "Flüssig"
        case .sharp: return "Gestochen scharf"
        }
    }
    /// Upper limit – the Mac adapts the real bitrate to the connection automatically.
    var kbps: Int { [.saver: 2500, .balanced: 9000, .sharp: 18000][self] ?? 9000 }
    var fps: Int { self == .saver ? 30 : 60 }
    var maxWidth: Int { [.saver: 1280, .balanced: 1920, .sharp: 2560][self] ?? 1920 }
}

/// A live remote-control session with one Mac.
@MainActor
final class RemoteSession: ObservableObject {
    let mac: PairedMac
    let store: MacStore
    let surface = RemoteSurfaceView()

    @Published var mode: DisplayMode
    @Published var quality: StreamQuality
    @Published var inputMode: InputMode = .touch { didSet { surface.mode = inputMode } }
    @Published var streaming = false
    @Published var connecting = true
    @Published var remoteSize: CGSize = .zero
    @Published var keyboardVisible = false
    @Published var activeModifiers: Set<String> = []
    @Published var autoClipboard = true
    @Published var net = NetStats()
    private var lastAckTime: CFTimeInterval = 0
    private var frameTimes: [CFTimeInterval] = []

    init(mac: PairedMac, store: MacStore, mode: DisplayMode, quality: StreamQuality) {
        self.mac = mac
        self.store = store
        self.mode = mode
        self.quality = quality
        surface.send = { [weak self] msg in self?.send(msg) }
        surface.decoder.needsKeyframe = { [weak self] in self?.send(["t": "keyframe"]) }
        surface.decoder.onFrame = { [weak self] seq, keyframe in self?.frameShown(seq, keyframe: keyframe) }
        surface.keyInput.onText = { [weak self] text in self?.typeText(text) }
        surface.keyInput.onKey = { [weak self] key, mods in self?.press(key, modifiers: mods) }
    }

    func start() {
        let id = mac.id
        let decoder = surface.decoder
        store.videoHandler = { macID, data in
            guard macID == id else { return }
            decoder.decode(data)
        }
        store.controlHandler = { [weak self] macID, json in
            guard macID == id else { return }
            self?.handleControl(json)
        }
        let serverKey = mac.serverKey
        store.reconnectHandler = { [weak self] key in
            guard key == serverKey, let self, self.streaming || self.connecting else { return }
            self.requestStream()
        }
        requestStream()   // attaches automatically
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func stop() {
        send(["t": "stop"])
        store.videoHandler = nil
        store.controlHandler = nil
        store.reconnectHandler = nil
        streaming = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    func requestStream() {
        connecting = true
        surface.decoder.reset()
        // Size of the phone (points) in the orientation we're in – used for the virtual display.
        let bounds = UIScreen.main.bounds
        send(["t": "start", "mode": mode.rawValue, "w": Int(bounds.width), "h": Int(bounds.height),
              "fps": quality.fps, "kbps": quality.kbps, "maxWidth": quality.maxWidth])
    }

    /// Acknowledge frames so the Mac can keep latency low and adapt the bitrate.
    private func frameShown(_ seq: UInt64, keyframe: Bool) {
        let now = CACurrentMediaTime()
        frameTimes.append(now)
        frameTimes.removeAll { now - $0 > 1 }
        if keyframe || now - lastAckTime > 0.05 {
            lastAckTime = now
            send(["t": "ack", "seq": seq])
        }
        if connecting { connecting = false }
    }

    private func handleControl(_ json: [String: Any]) {
        switch json["t"] as? String {
        case "net":
            net = NetStats(kbps: (json["actualKbps"] as? NSNumber)?.intValue ?? 0,
                           targetKbps: (json["kbps"] as? NSNumber)?.intValue ?? 0,
                           rtt: (json["rtt"] as? NSNumber)?.intValue ?? 0,
                           dropped: (json["dropped"] as? NSNumber)?.intValue ?? 0,
                           fps: frameTimes.count)
        case "stream":
            streaming = true
            connecting = false
            remoteSize = CGSize(width: (json["w"] as? NSNumber)?.doubleValue ?? 0,
                                height: (json["h"] as? NSNumber)?.doubleValue ?? 0)
        case "clip":
            if autoClipboard, let text = json["s"] as? String {
                UIPasteboard.general.string = text
                store.toast = "📋 Zwischenablage vom Mac übernommen"
            }
        default:
            break
        }
    }

    func send(_ msg: [String: Any]) {
        store.send(msg, to: mac)
    }

    // MARK: Keyboard

    func typeText(_ text: String) {
        if activeModifiers.isEmpty || activeModifiers == ["shift"] {
            send(["t": "text", "s": text])
        } else {
            for ch in text.lowercased() { press(String(ch), modifiers: Array(activeModifiers)) }
            activeModifiers.removeAll()
        }
    }

    func press(_ key: String, modifiers: [String] = []) {
        let mods = Array(Set(modifiers).union(activeModifiers))
        send(["t": "key", "k": key, "m": mods])
        if !activeModifiers.isEmpty { activeModifiers.removeAll() }
    }

    func toggleModifier(_ m: String) {
        if activeModifiers.contains(m) { activeModifiers.remove(m) } else { activeModifiers.insert(m) }
        UISelectionFeedbackGenerator().selectionChanged()
    }

    func toggleKeyboard() {
        keyboardVisible.toggle()
        if keyboardVisible { surface.keyInput.becomeFirstResponder() } else { surface.keyInput.resignFirstResponder() }
    }

    // MARK: Clipboard

    func sendClipboard() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else {
            store.toast = "Zwischenablage ist leer"
            return
        }
        send(["t": "clip", "s": text])
        store.toast = "📋 Zwischenablage an den Mac gesendet"
    }
}

struct NetStats: Equatable {
    var kbps = 0
    var targetKbps = 0
    var rtt = 0
    var dropped = 0
    var fps = 0

    /// 0…3 bars.
    var quality: Int {
        if kbps == 0 && rtt == 0 { return 0 }
        if rtt < 80 && dropped == 0 { return 3 }
        if rtt < 200 { return 2 }
        return 1
    }

    var text: String {
        let mbit = Double(kbps) / 1000
        return String(format: "%.1f Mbit/s · %d ms · %d fps", mbit, rtt, fps)
    }
}
