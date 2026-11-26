import Foundation
import AppKit
import Carbon.HIToolbox

// MARK: - Option enums

enum VideoCodecChoice: String, CaseIterable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hevc: return "HEVC (H.265) – kleinere Dateien"
        case .h264: return "H.264 – maximale Kompatibilität"
        }
    }
}

enum ResolutionChoice: String, CaseIterable, Identifiable {
    case native, p2160, p1440, p1080, p720
    var id: String { rawValue }
    var title: String {
        switch self {
        case .native: return "Nativ (Retina)"
        case .p2160: return "Max. 2160p (4K)"
        case .p1440: return "Max. 1440p"
        case .p1080: return "Max. 1080p"
        case .p720: return "Max. 720p"
        }
    }
    var maxHeight: Int? {
        switch self {
        case .native: return nil
        case .p2160: return 2160
        case .p1440: return 1440
        case .p1080: return 1080
        case .p720: return 720
        }
    }
}

enum CaptureTarget: String, CaseIterable, Identifiable {
    case gameWindow, gameDisplay, fullDisplay
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gameWindow: return "Nur das Spielfenster (empfohlen)"
        case .gameDisplay: return "Spiel auf dem ganzen Bildschirm"
        case .fullDisplay: return "Kompletter Bildschirm"
        }
    }
}

enum RecordingMode: String, CaseIterable, Identifiable {
    case gamesOnly, always
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gamesOnly: return "Nur wenn ein Spiel läuft"
        case .always: return "Immer (Bildschirm)"
        }
    }
}

// MARK: - Key combo

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt
    var keyLabel: String

    static let defaultClip = KeyCombo(
        keyCode: UInt32(kVK_ANSI_S),
        modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
        keyLabel: "S")
    static let defaultLongClip = KeyCombo(
        keyCode: UInt32(kVK_ANSI_L),
        modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
        keyLabel: "L")
    static let defaultScreenshot = KeyCombo(
        keyCode: UInt32(kVK_ANSI_X),
        modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
        keyLabel: "X")
    static let defaultRecord = KeyCombo(
        keyCode: UInt32(kVK_ANSI_R),
        modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
        keyLabel: "R")
    static let defaultMaximize = KeyCombo(
        keyCode: UInt32(kVK_ANSI_F),
        modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
        keyLabel: "F")
    static let defaultPause = KeyCombo(
        keyCode: UInt32(kVK_ANSI_P),
        modifiers: NSEvent.ModifierFlags([.option, .shift]).rawValue,
        keyLabel: "P")

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayString: String {
        let f = modifierFlags
        var s = ""
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + keyLabel
    }

    var carbonModifiers: UInt32 {
        let f = modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    static let specialKeyNames: [UInt16: String] = [
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20",
        49: "Leertaste", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 53: "⎋",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
    ]

    static func isFunctionKey(_ keyCode: UInt16) -> Bool {
        guard let name = specialKeyNames[keyCode] else { return false }
        return name.hasPrefix("F")
    }

    static func label(for event: NSEvent) -> String {
        if let name = specialKeyNames[event.keyCode] { return name }
        let chars = event.charactersIgnoringModifiers?.uppercased() ?? "?"
        return chars.isEmpty ? "?" : chars
    }
}

// MARK: - Settings store

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    static var defaultSaveFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies")
        return movies.appendingPathComponent("Simplex Recorder", isDirectory: true)
    }

    static let durationOptions = [10, 15, 20, 30, 45, 60, 90, 120, 180, 300]
    static let longDurationOptions = [60, 90, 120, 180, 300, 600]
    static let clipSounds = ["Glass", "Hero", "Pop", "Tink", "Ping", "Purr", "Submarine", "Funk", "Bottle", "Morse"]

    private let d = UserDefaults.standard

    private enum K {
        static let replayDuration = "replayDuration"
        static let fps = "fps"
        static let resolution = "resolution"
        static let bitrate = "bitrateMbps"
        static let codec = "codec"
        static let systemAudio = "captureSystemAudio"
        static let mic = "captureMicrophone"
        static let cursor = "showCursor"
        static let target = "captureTarget"
        static let mode = "recordingMode"
        static let folder = "saveFolderPath"
        static let organize = "organizeByGame"
        static let maxStorage = "maxClipStorageGB"
        static let clipHotKey = "clipHotKey"
        static let pauseHotKey = "pauseHotKey"
        static let playSound = "playSound"
        static let clipSound = "clipSound"
        static let notifications = "showNotifications"
        static let launchAtLogin = "launchAtLogin"
        static let keepAlive = "keepAlive"
        static let paused = "isPaused"
        static let pausedUntil = "pausedUntil"
        static let included = "includedApps"
        static let excluded = "excludedApps"
        static let onboarding = "hasCompletedOnboarding"
        static let cropTitleBar = "cropTitleBar"
        static let longClipEnabled = "longClipEnabled"
        static let longClipDuration = "longClipDuration"
        static let longClipHotKey = "longClipHotKey"
        static let screenshotHotKey = "screenshotHotKey"
        static let showOverlay = "showOverlay"
        static let copyToClipboard = "copyClipToClipboard"
        static let revealAfterSave = "revealAfterSave"
        static let menuBarTimer = "menuBarShowsTimer"
        static let settingsVersion = "settingsVersion"
        static let snapAssist = "snapAssistEnabled"
        static let autoMaximize = "autoMaximizeGames"
        static let startAnimation = "showStartAnimation"
        static let maximizeHotKey = "maximizeHotKey"
    }

    @Published var replayDuration: Int { didSet { d.set(replayDuration, forKey: K.replayDuration) } }
    @Published var fps: Int { didSet { d.set(fps, forKey: K.fps) } }
    @Published var resolution: ResolutionChoice { didSet { d.set(resolution.rawValue, forKey: K.resolution) } }
    @Published var bitrateMbps: Double { didSet { d.set(bitrateMbps, forKey: K.bitrate) } }
    @Published var codec: VideoCodecChoice { didSet { d.set(codec.rawValue, forKey: K.codec) } }
    @Published var captureSystemAudio: Bool { didSet { d.set(captureSystemAudio, forKey: K.systemAudio) } }
    @Published var captureMicrophone: Bool { didSet { d.set(captureMicrophone, forKey: K.mic) } }
    @Published var showCursor: Bool { didSet { d.set(showCursor, forKey: K.cursor) } }
    @Published var captureTarget: CaptureTarget { didSet { d.set(captureTarget.rawValue, forKey: K.target) } }
    @Published var recordingMode: RecordingMode { didSet { d.set(recordingMode.rawValue, forKey: K.mode) } }
    @Published var saveFolderPath: String { didSet { d.set(saveFolderPath, forKey: K.folder) } }
    @Published var organizeByGame: Bool { didSet { d.set(organizeByGame, forKey: K.organize) } }
    @Published var maxClipStorageGB: Int { didSet { d.set(maxClipStorageGB, forKey: K.maxStorage) } }
    @Published var clipHotKey: KeyCombo { didSet { saveCodable(clipHotKey, K.clipHotKey) } }
    @Published var pauseHotKey: KeyCombo { didSet { saveCodable(pauseHotKey, K.pauseHotKey) } }
    @Published var playSound: Bool { didSet { d.set(playSound, forKey: K.playSound) } }
    @Published var clipSound: String { didSet { d.set(clipSound, forKey: K.clipSound) } }
    @Published var showNotifications: Bool { didSet { d.set(showNotifications, forKey: K.notifications) } }
    @Published var launchAtLogin: Bool { didSet { d.set(launchAtLogin, forKey: K.launchAtLogin) } }
    @Published var keepAlive: Bool { didSet { d.set(keepAlive, forKey: K.keepAlive) } }
    @Published var isPaused: Bool { didSet { d.set(isPaused, forKey: K.paused) } }
    @Published var pausedUntil: Date? {
        didSet {
            if let pausedUntil { d.set(pausedUntil.timeIntervalSince1970, forKey: K.pausedUntil) }
            else { d.removeObject(forKey: K.pausedUntil) }
        }
    }
    @Published var includedApps: [String] { didSet { d.set(includedApps, forKey: K.included) } }
    @Published var excludedApps: [String] { didSet { d.set(excludedApps, forKey: K.excluded) } }
    @Published var hasCompletedOnboarding: Bool { didSet { d.set(hasCompletedOnboarding, forKey: K.onboarding) } }
    @Published var cropTitleBar: Bool { didSet { d.set(cropTitleBar, forKey: K.cropTitleBar) } }
    @Published var longClipEnabled: Bool { didSet { d.set(longClipEnabled, forKey: K.longClipEnabled) } }
    @Published var longClipDuration: Int { didSet { d.set(longClipDuration, forKey: K.longClipDuration) } }
    @Published var longClipHotKey: KeyCombo { didSet { saveCodable(longClipHotKey, K.longClipHotKey) } }
    @Published var screenshotHotKey: KeyCombo { didSet { saveCodable(screenshotHotKey, K.screenshotHotKey) } }
    @Published var showOverlay: Bool { didSet { d.set(showOverlay, forKey: K.showOverlay) } }
    @Published var copyClipToClipboard: Bool { didSet { d.set(copyClipToClipboard, forKey: K.copyToClipboard) } }
    @Published var revealAfterSave: Bool { didSet { d.set(revealAfterSave, forKey: K.revealAfterSave) } }
    @Published var menuBarShowsTimer: Bool { didSet { d.set(menuBarShowsTimer, forKey: K.menuBarTimer) } }
    @Published var snapAssistEnabled: Bool { didSet { d.set(snapAssistEnabled, forKey: K.snapAssist) } }
    @Published var autoMaximizeGames: Bool { didSet { d.set(autoMaximizeGames, forKey: K.autoMaximize) } }
    @Published var showStartAnimation: Bool { didSet { d.set(showStartAnimation, forKey: K.startAnimation) } }
    @Published var maximizeHotKey: KeyCombo { didSet { saveCodable(maximizeHotKey, K.maximizeHotKey) } }
    @Published var recordHotKey: KeyCombo { didSet { saveCodable(recordHotKey, "recordHotKey") } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            K.replayDuration: 30,
            K.fps: 60,
            K.resolution: ResolutionChoice.p1440.rawValue,
            K.bitrate: 25.0,
            K.codec: VideoCodecChoice.hevc.rawValue,
            K.systemAudio: true,
            K.mic: false,
            K.cursor: false,
            K.target: CaptureTarget.gameWindow.rawValue,
            K.mode: RecordingMode.gamesOnly.rawValue,
            K.folder: AppSettings.defaultSaveFolder.path,
            K.organize: true,
            K.maxStorage: 0,
            K.playSound: true,
            K.clipSound: "Glass",
            K.notifications: true,
            K.launchAtLogin: true,
            K.keepAlive: true,
            K.paused: false,
            K.onboarding: false,
            K.cropTitleBar: true,
            K.longClipEnabled: true,
            K.longClipDuration: 120,
            K.showOverlay: true,
            K.copyToClipboard: false,
            K.revealAfterSave: false,
            K.menuBarTimer: false,
            K.snapAssist: true,
            K.autoMaximize: false,
            K.startAnimation: true,
        ])

        replayDuration = d.integer(forKey: K.replayDuration)
        fps = d.integer(forKey: K.fps)
        resolution = ResolutionChoice(rawValue: d.string(forKey: K.resolution) ?? "") ?? .p1440
        bitrateMbps = d.double(forKey: K.bitrate)
        codec = VideoCodecChoice(rawValue: d.string(forKey: K.codec) ?? "") ?? .hevc
        captureSystemAudio = d.bool(forKey: K.systemAudio)
        captureMicrophone = d.bool(forKey: K.mic)
        showCursor = d.bool(forKey: K.cursor)
        captureTarget = CaptureTarget(rawValue: d.string(forKey: K.target) ?? "") ?? .gameWindow
        recordingMode = RecordingMode(rawValue: d.string(forKey: K.mode) ?? "") ?? .gamesOnly
        saveFolderPath = d.string(forKey: K.folder) ?? AppSettings.defaultSaveFolder.path
        organizeByGame = d.bool(forKey: K.organize)
        maxClipStorageGB = d.integer(forKey: K.maxStorage)
        clipHotKey = AppSettings.loadCodable(d, K.clipHotKey) ?? .defaultClip
        pauseHotKey = AppSettings.loadCodable(d, K.pauseHotKey) ?? .defaultPause
        playSound = d.bool(forKey: K.playSound)
        clipSound = d.string(forKey: K.clipSound) ?? "Glass"
        showNotifications = d.bool(forKey: K.notifications)
        launchAtLogin = d.bool(forKey: K.launchAtLogin)
        keepAlive = d.bool(forKey: K.keepAlive)
        isPaused = d.bool(forKey: K.paused)
        let until = d.double(forKey: K.pausedUntil)
        pausedUntil = until > 0 ? Date(timeIntervalSince1970: until) : nil
        includedApps = d.stringArray(forKey: K.included) ?? []
        excludedApps = d.stringArray(forKey: K.excluded) ?? []
        hasCompletedOnboarding = d.bool(forKey: K.onboarding)
        cropTitleBar = d.bool(forKey: K.cropTitleBar)
        longClipEnabled = d.bool(forKey: K.longClipEnabled)
        longClipDuration = d.integer(forKey: K.longClipDuration)
        longClipHotKey = AppSettings.loadCodable(d, K.longClipHotKey) ?? .defaultLongClip
        screenshotHotKey = AppSettings.loadCodable(d, K.screenshotHotKey) ?? .defaultScreenshot
        showOverlay = d.bool(forKey: K.showOverlay)
        copyClipToClipboard = d.bool(forKey: K.copyToClipboard)
        revealAfterSave = d.bool(forKey: K.revealAfterSave)
        menuBarShowsTimer = d.bool(forKey: K.menuBarTimer)
        snapAssistEnabled = d.bool(forKey: K.snapAssist)
        autoMaximizeGames = d.bool(forKey: K.autoMaximize)
        showStartAnimation = d.bool(forKey: K.startAnimation)
        maximizeHotKey = AppSettings.loadCodable(d, K.maximizeHotKey) ?? .defaultMaximize
        recordHotKey = AppSettings.loadCodable(d, "recordHotKey") ?? .defaultRecord

        // Migration: v2 makes "game window only" the default capture mode.
        if d.integer(forKey: K.settingsVersion) < 2 {
            captureTarget = .gameWindow
            d.set(CaptureTarget.gameWindow.rawValue, forKey: K.target)
            d.set(2, forKey: K.settingsVersion)
        }
        if longClipDuration <= 0 { longClipDuration = 120 }

        if fps <= 0 { fps = 60 }
        if replayDuration <= 0 { replayDuration = 30 }
        if bitrateMbps <= 0 { bitrateMbps = 25 }
    }

    // MARK: Derived

    var saveFolderURL: URL { URL(fileURLWithPath: saveFolderPath, isDirectory: true) }

    var wantsLaunchAgent: Bool { launchAtLogin || keepAlive }

    var isPausedNow: Bool {
        guard isPaused else { return false }
        if let pausedUntil { return pausedUntil > Date() }
        return true
    }

    /// Approximate RAM used by the replay buffer in megabytes.
    /// Seconds the replay buffer must hold (covers the long-clip hotkey too).
    var bufferSeconds: Int {
        max(replayDuration, longClipEnabled ? longClipDuration : 0) + 3
    }

    var estimatedBufferMB: Int {
        let seconds = Double(bufferSeconds)
        let video = bitrateMbps * seconds / 8.0
        let audioChannels = (captureSystemAudio ? 2.0 : 0) + (captureMicrophone ? 1.0 : 0)
        let audio = audioChannels * 48_000 * 4 * seconds / 1_000_000
        return Int((video + audio).rounded())
    }

    func setRule(for key: String, include: Bool?) {
        includedApps.removeAll { $0 == key }
        excludedApps.removeAll { $0 == key }
        switch include {
        case .some(true): includedApps.append(key)
        case .some(false): excludedApps.append(key)
        case .none: break
        }
    }

    func rule(for key: String) -> Bool? {
        if includedApps.contains(key) { return true }
        if excludedApps.contains(key) { return false }
        return nil
    }

    // MARK: Codable helpers

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { d.set(data, forKey: key) }
    }

    private static func loadCodable<T: Decodable>(_ d: UserDefaults, _ key: String) -> T? {
        guard let data = d.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}

// MARK: - Quality presets

enum QualityPreset: String, CaseIterable, Identifiable {
    case efficient, balanced, high, smooth
    var id: String { rawValue }

    var title: String {
        switch self {
        case .efficient: return "Sparsam"
        case .balanced: return "Ausgewogen"
        case .high: return "Maximal"
        case .smooth: return "Butterweich"
        }
    }

    var symbol: String {
        switch self {
        case .efficient: return "leaf.fill"
        case .balanced: return "dial.medium.fill"
        case .high: return "sparkles"
        case .smooth: return "hare.fill"
        }
    }

    var detail: String {
        switch self {
        case .efficient: return "30 FPS · 1080p · 12 Mbit/s"
        case .balanced: return "60 FPS · 1440p · 25 Mbit/s"
        case .high: return "60 FPS · Nativ · 50 Mbit/s"
        case .smooth: return "120 FPS · 1080p · 40 Mbit/s"
        }
    }

    private var values: (fps: Int, resolution: ResolutionChoice, bitrate: Double) {
        switch self {
        case .efficient: return (30, .p1080, 12)
        case .balanced: return (60, .p1440, 25)
        case .high: return (60, .native, 50)
        case .smooth: return (120, .p1080, 40)
        }
    }

    @MainActor
    func apply(to settings: AppSettings) {
        let v = values
        settings.fps = v.fps
        settings.resolution = v.resolution
        settings.bitrateMbps = v.bitrate
        settings.codec = .hevc
    }

    @MainActor
    func isActive(in settings: AppSettings) -> Bool {
        let v = values
        return settings.fps == v.fps && settings.resolution == v.resolution && settings.bitrateMbps == v.bitrate
    }
}
