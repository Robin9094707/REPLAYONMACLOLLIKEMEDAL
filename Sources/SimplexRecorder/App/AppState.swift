import AppKit
import Combine
import SwiftUI

/// Central coordinator: decides when to capture, saves clips, wires hotkeys.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    enum Status: Equatable {
        case idle
        case waitingForGame
        case recording(String)
        case paused
        case needsPermission
        case error(String)
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isSaving = false
    @Published private(set) var bufferedSeconds: Double = 0
    @Published private(set) var bufferMB: Int = 0
    @Published private(set) var audioBufferedSeconds: Double = 0
    @Published private(set) var lastSavedClip: URL?
    @Published private(set) var clipsThisSession = 0

    let settings: AppSettings
    let detector: GameDetector
    let storage: StorageMonitor
    let library: ClipLibrary
    private let engine = ReplayEngine()

    private var activeSignature: String?
    private var activeGameName: String?
    private var transition: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var statsTimer: Timer?
    private var launched = false
    private var registeredClipKey: KeyCombo?
    private var registeredPauseKey: KeyCombo?
    private var registeredLongKey: KeyCombo?
    private var registeredScreenshotKey: KeyCombo?
    private var longKeyActive = false
    private var registeredMaximizeKey: KeyCombo?
    private var registeredRecordKey: KeyCombo?
    private var lastAnnouncedPID: pid_t = 0
    /// Process whose footage is currently in the replay buffer (-1 = whole screen).
    private var bufferOwnerPID: pid_t = -2

    private func discardBuffer(reason: String) {
        guard engine.buffer.bufferedSeconds > 0 || bufferOwnerPID != -2 else { return }
        engine.buffer.clear()
        bufferedSeconds = 0
        bufferOwnerPID = -2
        activeGameName = nil
        lastAnnouncedPID = 0
        DiagnosticsLog.write("replay buffer discarded (\(reason))")
    }
    private var lastFolderPath = ""
    private var tickCount = 0

    private init() {
        settings = AppSettings.shared
        detector = GameDetector(settings: AppSettings.shared)
        storage = StorageMonitor()
        library = ClipLibrary()
    }

    // MARK: Lifecycle

    func launch() {
        guard !launched else { return }
        launched = true

        NotificationManager.shared.setup()
        handleUpdatedBuild()
        engine.buffer.maxSeconds = Double(settings.bufferSeconds)
        engine.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in self?.handleUnexpectedStop(error) }
        }

        detector.start()
        registerHotKeys()

        detector.$currentGame
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.scheduleReevaluate()
                Task { @MainActor in GameWindowAssistant.shared.update() }
            }
            .store(in: &cancellables)

        settings.objectWillChange
            .debounce(for: .milliseconds(350), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.settingsChanged() }
            .store(in: &cancellables)

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        timer.tolerance = 0.3
        statsTimer = timer

        lastFolderPath = settings.saveFolderPath
        refreshLibrary()
        scheduleReevaluate()
        SuiteCoordinator.shared.start()
        RemoteAgent.shared.start()
    }

    /// After an update the old privacy entry belongs to the previous (differently signed)
    /// build. Clear it once so macOS asks again for this build.
    private func handleUpdatedBuild() {
        let defaults = UserDefaults.standard
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let previous = defaults.string(forKey: "lastLaunchedBuild")
        defaults.set(build, forKey: "lastLaunchedBuild")
        guard let previous, previous != build, settings.hasCompletedOnboarding else { return }
        // Same story for Accessibility (window assistant), if it was granted before.
        if defaults.bool(forKey: "accessibilityGrantedBefore"), !GameWindowAssistant.isTrusted {
            GameWindowAssistant.resetTrust()
            GameWindowAssistant.requestTrust()
        }
        Task { @MainActor in
            if await Permissions.probeScreenRecording() { return }
            Permissions.resetScreenRecordingPermission()
            Permissions.requestScreenRecording()
            if settings.showNotifications {
                NotificationManager.shared.notify(
                    title: "Bitte Bildschirmaufnahme erneut erlauben",
                    body: "Nach einem Update fragt macOS einmal neu. Simplex Suite startet die Aufnahme automatisch, sobald du zustimmst.")
            }
        }
    }

    func refreshLibrary() {
        library.reload(folder: settings.saveFolderURL)
        storage.refresh(folder: settings.saveFolderURL)
    }

    private func settingsChanged() {
        engine.buffer.maxSeconds = Double(settings.bufferSeconds)
        registerHotKeys()
        GameWindowAssistant.shared.update()
        if settings.saveFolderPath != lastFolderPath {
            lastFolderPath = settings.saveFolderPath
            refreshLibrary()
        }
        scheduleReevaluate()
    }

    private func tick() {
        tickCount &+= 1
        if tickCount % 5 == 0 {
            GameWindowAssistant.shared.update()
            if GameWindowAssistant.isTrusted {
                UserDefaults.standard.set(true, forKey: "accessibilityGrantedBefore")
            }
        }
        if tickCount % 60 == 0 { storage.refresh(folder: settings.saveFolderURL) }
        if settings.isPaused, let until = settings.pausedUntil, until <= Date() {
            settings.isPaused = false
            settings.pausedUntil = nil
        }
        let seconds = engine.isRunning ? engine.buffer.bufferedSeconds : 0
        let rounded = min(seconds, Double(settings.bufferSeconds - 3)).rounded()
        if rounded != bufferedSeconds { bufferedSeconds = rounded }
        engine.checkAudioHealth()
        let audio = engine.isRunning ? min(engine.buffer.audioSeconds, Double(settings.replayDuration)).rounded() : 0
        if audio != audioBufferedSeconds { audioBufferedSeconds = audio }
        let mb = engine.buffer.approximateBytes / 1_000_000
        if mb != bufferMB { bufferMB = mb }
        // Re-check permission state cheaply while waiting for it.
        if status == .needsPermission, tickCount % 3 == 0 { scheduleReevaluate() }
    }

    // MARK: Capture state machine

    func scheduleReevaluate() {
        let previous = transition
        transition = Task { [weak self] in
            await previous?.value
            await self?.applyDesiredState()
        }
    }

    private func applyDesiredState() async {
        var permitted = Permissions.hasScreenRecording
        if !permitted { permitted = await Permissions.probeScreenRecording() }
        guard permitted else {
            await stopEngine()
            status = .needsPermission
            return
        }
        if settings.isPausedNow {
            await stopEngine()
            status = .paused
            return
        }
        let game = detector.currentGame
        if settings.recordingMode == .gamesOnly && game == nil {
            await stopEngine()
            // Game closed → its replay is gone. A clip can never contain the previous game.
            discardBuffer(reason: "Spiel beendet")
            status = .waitingForGame
            return
        }

        // Different game (or game ↔ screen) than the buffered footage → start fresh.
        let owner = game?.pid ?? -1
        if owner != bufferOwnerPID {
            discardBuffer(reason: "neues Spiel")
            bufferOwnerPID = owner
        }

        let config = makeConfig()
        let signature = makeSignature(game: game, config: config)
        if engine.isRunning && signature == activeSignature {
            if let size = game?.windowSize, size.width > 0 {
                await engine.updateWindowGeometry(size: size)
            }
            return
        }

        await stopEngine()
        do {
            try await engine.start(game: game, config: config)
            activeSignature = signature
            activeGameName = game?.name ?? "Bildschirm"
            status = .recording(activeGameName ?? "Bildschirm")
            if let game, game.pid != lastAnnouncedPID {
                lastAnnouncedPID = game.pid
                announceStart(game)
            }
            retryTask?.cancel()
        } catch {
            status = .error(error.localizedDescription)
            scheduleRetry(after: 8)
        }
    }

    private func stopEngine() async {
        if engine.isRunning { await engine.stop() }
        activeSignature = nil
    }

    private func makeConfig() -> CaptureConfig {
        CaptureConfig(fps: settings.fps,
                      bitrateMbps: settings.bitrateMbps,
                      codec: settings.codec,
                      maxHeight: settings.resolution.maxHeight,
                      captureSystemAudio: settings.captureSystemAudio,
                      captureMicrophone: settings.captureMicrophone,
                      showCursor: settings.showCursor,
                      target: settings.captureTarget,
                      cropTitleBar: settings.cropTitleBar)
    }

    private func makeSignature(game: DetectedGame?, config: CaptureConfig) -> String {
        // Window captures follow resizes live, so only a *different* window restarts them.
        var sig = "\(game?.pid ?? -1)|\(config)"
        if config.target == .gameWindow { sig += "|w\(game?.windowID ?? 0)" }
        return sig
    }

    private func handleUnexpectedStop(_ error: Error) {
        activeSignature = nil
        if case .recording = status { status = .error("Aufnahme unterbrochen – starte neu …") }
        scheduleRetry(after: 3)
    }

    private func scheduleRetry(after seconds: Double) {
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.scheduleReevaluate()
        }
    }

    // MARK: Hotkeys

    func registerHotKeys() {
        if registeredClipKey != settings.clipHotKey {
            registeredClipKey = settings.clipHotKey
            HotKeyCenter.shared.register(id: 1, combo: settings.clipHotKey) {
                Task { @MainActor in AppState.shared.saveClip() }
            }
        }
        if registeredPauseKey != settings.pauseHotKey {
            registeredPauseKey = settings.pauseHotKey
            HotKeyCenter.shared.register(id: 2, combo: settings.pauseHotKey) {
                Task { @MainActor in AppState.shared.togglePause() }
            }
        }
        let wantedLong: KeyCombo? = settings.longClipEnabled ? settings.longClipHotKey : nil
        if registeredLongKey != wantedLong || (wantedLong == nil && longKeyActive) {
            registeredLongKey = wantedLong
            if let wantedLong {
                HotKeyCenter.shared.register(id: 3, combo: wantedLong) {
                    Task { @MainActor in AppState.shared.saveLongClip() }
                }
                longKeyActive = true
            } else {
                HotKeyCenter.shared.unregister(id: 3)
                longKeyActive = false
            }
        }
        if registeredRecordKey != settings.recordHotKey {
            registeredRecordKey = settings.recordHotKey
            HotKeyCenter.shared.register(id: 6, combo: settings.recordHotKey) {
                Task { @MainActor in ScreenRecorder.shared.toggle() }
            }
        }
        if registeredMaximizeKey != settings.maximizeHotKey {
            registeredMaximizeKey = settings.maximizeHotKey
            HotKeyCenter.shared.register(id: 5, combo: settings.maximizeHotKey) {
                Task { @MainActor in GameWindowAssistant.shared.toggleMaximize() }
            }
        }
        if registeredScreenshotKey != settings.screenshotHotKey {
            registeredScreenshotKey = settings.screenshotHotKey
            HotKeyCenter.shared.register(id: 4, combo: settings.screenshotHotKey) {
                Task { @MainActor in AppState.shared.takeScreenshot() }
            }
        }
    }

    /// Used by the shortcut recorder so the old combo doesn't fire while typing a new one.
    func suspendHotKeys() {
        HotKeyCenter.shared.unregisterAll()
        registeredClipKey = nil
        registeredPauseKey = nil
        registeredLongKey = nil
        registeredScreenshotKey = nil
        registeredMaximizeKey = nil
        registeredRecordKey = nil
        longKeyActive = false
    }

    // MARK: Clips

    var canSaveClip: Bool {
        if case .recording = status { return !isSaving }
        return !isSaving && bufferedSeconds > 0
    }

    func saveLongClip() {
        saveClip(seconds: settings.longClipDuration)
    }

    func saveClip(seconds requested: Int? = nil) {
        guard !isSaving else { return }
        let snapshot = engine.buffer.snapshot()
        guard !snapshot.isEmpty else {
            NSSound.beep()
            if settings.showOverlay { OverlayHUD.shared.show(symbol: "xmark.circle.fill", title: "Kein Clip möglich", subtitle: "Gerade läuft keine Aufnahme", tint: .systemRed) }
            if settings.showNotifications {
                NotificationManager.shared.notify(title: "Kein Clip möglich",
                                                  body: "Gerade läuft keine Aufnahme – starte ein Spiel.")
            }
            return
        }

        let expectedAudio = settings.captureSystemAudio
        let hasAudio = !snapshot.audio.isEmpty
        let gameName = activeGameName ?? "Clip"
        let destination: URL
        do {
            destination = try makeClipURL(gameName: gameName)
        } catch {
            NSSound.beep()
            NotificationManager.shared.notify(title: "Speichern fehlgeschlagen", body: error.localizedDescription)
            return
        }

        isSaving = true
        let duration = Double(requested ?? settings.replayDuration)
        if settings.showOverlay {
            OverlayHUD.shared.show(symbol: "record.circle", title: "Speichere Clip …",
                                   subtitle: "Letzte \(durationLabel(Int(duration)))", tint: .systemRed, sticky: true)
        }
        let maxBytes = Int64(settings.maxClipStorageGB) * 1_000_000_000
        let folder = settings.saveFolderURL
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try ClipExporter.writeClip(snapshot: snapshot, duration: duration, to: destination) }
            if case .success = result, maxBytes > 0 {
                ClipLibrary.enforceLimit(folder: folder, maxBytes: maxBytes)
            }
            Task { @MainActor in
                AppState.shared.finishSaving(result: result, url: destination, gameName: gameName,
                                             missingAudio: expectedAudio && !hasAudio)
            }
        }
    }

    private func finishSaving(result: Result<Double, Error>, url: URL, gameName: String, missingAudio: Bool) {
        isSaving = false
        switch result {
        case .success(let seconds):
            lastSavedClip = url
            clipsThisSession += 1
            if settings.playSound { NSSound(named: NSSound.Name(settings.clipSound))?.play() }
            if settings.showOverlay {
                OverlayHUD.shared.show(symbol: "checkmark.circle.fill", title: "Clip gespeichert",
                                       subtitle: "\(gameName) · \(Int(seconds.rounded())) s\(missingAudio ? " · ohne Ton" : "")",
                                       tint: .systemGreen)
            }
            if settings.copyClipToClipboard {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([url as NSURL])
            }
            if settings.revealAfterSave {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
            if RemoteConfig.shared.autoUpload && ClipUploader.shared.isAvailable {
                ClipUploader.shared.upload(url, game: gameName)
            }
            if settings.showNotifications {
                NotificationManager.shared.notify(title: "Clip gespeichert 🎬",
                                                  body: "\(gameName) · \(Int(seconds.rounded())) Sekunden\(missingAudio ? " · ohne Ton (kein Systemton empfangen)" : "") – klicken zum Anzeigen",
                                                  fileURL: url)
            }
        case .failure(let error):
            try? FileManager.default.removeItem(at: url)
            NSSound.beep()
            if settings.showOverlay {
                OverlayHUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Speichern fehlgeschlagen",
                                       subtitle: error.localizedDescription, tint: .systemOrange)
            }
            NotificationManager.shared.notify(title: "Clip konnte nicht gespeichert werden",
                                              body: error.localizedDescription)
        }
        refreshLibrary()
    }

    private func makeClipURL(gameName: String, prefix: String = "", ext: String = "mp4") throws -> URL {
        let fm = FileManager.default
        var base = settings.saveFolderURL
        let components = base.standardizedFileURL.pathComponents
        if components.count >= 3, components[1] == "Volumes", !fm.fileExists(atPath: "/Volumes/\(components[2])") {
            base = AppSettings.defaultSaveFolder
            if settings.showNotifications {
                NotificationManager.shared.notify(
                    title: "Festplatte „\(components[2])“ nicht verbunden",
                    body: "Der Clip wird stattdessen in „Filme/Simplex Recorder“ gespeichert.")
            }
        }
        let safeName = Self.sanitize(gameName)
        if settings.organizeByGame { base.appendPathComponent(safeName, isDirectory: true) }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        formatter.dateFormat = "yyyy-MM-dd 'um' HH.mm.ss"
        return base.appendingPathComponent("\(prefix)\(safeName) \(formatter.string(from: Date())).\(ext)")
    }

    private static func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = name.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Clip" : cleaned
    }

    func openClipFolder() {
        let folder = settings.saveFolderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    // MARK: Game start

    private func announceStart(_ game: DetectedGame) {
        DiagnosticsLog.write("game started: \(game.name) (pid \(game.pid))")
        if settings.showStartAnimation && settings.showOverlay {
            OverlayHUD.shared.showHero(
                title: "Clipping aktiv",
                subtitle: "\(game.name) erkannt – die Aufnahme läuft",
                detail: "\(settings.clipHotKey.displayString) speichert die letzten \(settings.replayDuration) s · \(settings.maximizeHotKey.displayString) passt das Fenster ein")
            NSSound(named: NSSound.Name("Purr"))?.play()
        }
        GameWindowAssistant.shared.autoMaximizeIfWanted(for: game)
    }

    // MARK: Include / exclude

    /// include: true = always record, false = never record, nil = automatic.
    func setRule(key: String, name: String, include: Bool?) {
        settings.setRule(for: key, include: include)
        detector.scan()
        scheduleReevaluate()
        guard settings.showOverlay else { return }
        switch include {
        case .some(true):
            OverlayHUD.shared.show(symbol: "plus.circle.fill", title: "„\(name)“ wird aufgenommen",
                                   subtitle: "Als Spiel markiert", tint: .systemGreen)
        case .some(false):
            OverlayHUD.shared.show(symbol: "nosign", title: "„\(name)“ ausgeschlossen",
                                   subtitle: "Wird nie mehr aufgenommen", tint: .systemRed)
        case .none:
            OverlayHUD.shared.show(symbol: "arrow.uturn.backward.circle.fill", title: "Regel entfernt",
                                   subtitle: "„\(name)“ wird wieder automatisch erkannt", tint: .systemGray)
        }
    }

    // MARK: Screenshots

    func takeScreenshot() {
        guard engine.isRunning else {
            NSSound.beep()
            if settings.showOverlay {
                OverlayHUD.shared.show(symbol: "xmark.circle.fill", title: "Kein Screenshot möglich",
                                       subtitle: "Gerade läuft keine Aufnahme", tint: .systemRed)
            }
            return
        }
        let gameName = activeGameName ?? "Screenshot"
        Task { @MainActor in
            do {
                let image = try await engine.screenshot()
                let url = try makeClipURL(gameName: gameName, prefix: "Screenshot ", ext: "png")
                let rep = NSBitmapImageRep(cgImage: image)
                guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
                try data.write(to: url)
                NSSound(named: NSSound.Name("Tink"))?.play()
                if settings.showOverlay {
                    OverlayHUD.shared.show(symbol: "camera.fill", title: "Screenshot gespeichert",
                                           subtitle: "\(image.width)×\(image.height)", tint: .systemBlue)
                }
                if settings.copyClipToClipboard {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([NSImage(cgImage: image, size: .zero)])
                }
                DiagnosticsLog.write("screenshot saved \(url.lastPathComponent)")
            } catch {
                NSSound.beep()
                DiagnosticsLog.write("screenshot failed: \(error)")
                if settings.showOverlay {
                    OverlayHUD.shared.show(symbol: "exclamationmark.triangle.fill", title: "Screenshot fehlgeschlagen",
                                           subtitle: error.localizedDescription, tint: .systemOrange)
                }
            }
        }
    }

    // MARK: Pause

    func pause(minutes: Int?) {
        settings.pausedUntil = minutes.map { Date().addingTimeInterval(Double($0) * 60) }
        settings.isPaused = true
    }

    func resume() {
        settings.isPaused = false
        settings.pausedUntil = nil
    }

    func togglePause() {
        if settings.isPausedNow {
            resume()
            NSSound(named: NSSound.Name("Tink"))?.play()
            if settings.showOverlay {
                OverlayHUD.shared.show(symbol: "play.circle.fill", title: "Aufnahme läuft wieder", subtitle: nil, tint: .systemGreen)
            }
        } else {
            pause(minutes: nil)
            NSSound(named: NSSound.Name("Pop"))?.play()
            if settings.showOverlay {
                OverlayHUD.shared.show(symbol: "pause.circle.fill", title: "Aufnahme pausiert",
                                       subtitle: "Fortsetzen mit \(settings.pauseHotKey.displayString)", tint: .systemOrange)
            }
        }
    }

    // MARK: Background / autostart

    /// Rewrites the LaunchAgent and restarts the app under it.
    func applyBackgroundSettings() {
        LaunchAgentManager.applyAndRelaunch(runAtLoad: settings.launchAtLogin, keepAlive: settings.keepAlive)
    }

    func confirmQuit() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Simplex Suite beenden?"
        alert.informativeText = "Die App bleibt bis zur nächsten Anmeldung aus und nimmt solange keine Clips auf. Du kannst die Aufnahme stattdessen auch nur pausieren."
        alert.addButton(withTitle: "Beenden")
        alert.addButton(withTitle: "Nur pausieren")
        alert.addButton(withTitle: "Abbrechen")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            LaunchAgentManager.quitForReal()
        case .alertSecondButtonReturn:
            pause(minutes: nil)
        default:
            break
        }
    }

    // MARK: Presentation

    var statusLine: String {
        switch status {
        case .idle: return "Startet …"
        case .waitingForGame: return "Wartet auf ein Spiel"
        case .recording(let name): return isSaving ? "Speichert Clip …" : "Replay aktiv – \(name)"
        case .paused:
            if let until = settings.pausedUntil {
                return "Pausiert bis \(until.formatted(date: .omitted, time: .shortened))"
            }
            return "Pausiert"
        case .needsPermission: return "Bildschirmaufnahme-Erlaubnis fehlt"
        case .error(let message): return message
        }
    }

    var menuBarSymbol: String {
        switch status {
        case .recording: return isSaving ? "arrow.down.circle.fill" : "record.circle.fill"
        case .paused: return "pause.circle"
        case .needsPermission, .error: return "exclamationmark.circle"
        case .idle, .waitingForGame: return "gamecontroller"
        }
    }

    var isRecording: Bool {
        if case .recording = status { return true }
        return false
    }
}
