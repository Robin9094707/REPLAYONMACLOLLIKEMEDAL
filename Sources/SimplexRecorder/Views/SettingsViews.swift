import SwiftUI
import AppKit
import AVFoundation
import UniformTypeIdentifiers

// MARK: - Allgemein

struct GeneralSettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings

    @State private var screenGranted = Permissions.hasScreenRecording
    @State private var micStatus = Permissions.microphoneStatus
    @State private var notificationsGranted = true
    @State private var pendingAgentChange = false

    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section { StatusHeader() }

            Section("Aufnahme") {
                Toggle("Aufnahme pausieren (ruhen lassen)", isOn: Binding(
                    get: { settings.isPausedNow },
                    set: { $0 ? state.pause(minutes: nil) : state.resume() }))
                Picker("Aufnehmen", selection: $settings.recordingMode) {
                    ForEach(RecordingMode.allCases) { Text($0.title).tag($0) }
                }
            }

            Section {
                Toggle("Beim Anmelden automatisch starten", isOn: Binding(
                    get: { settings.launchAtLogin },
                    set: { settings.launchAtLogin = $0; pendingAgentChange = true }))
                Toggle("Automatisch neu starten, wenn die App beendet wird oder abstürzt", isOn: Binding(
                    get: { settings.keepAlive },
                    set: { settings.keepAlive = $0; pendingAgentChange = true }))
                if pendingAgentChange {
                    HStack {
                        Text("Wird nach einem kurzen Neustart der App übernommen.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Jetzt übernehmen") { state.applyBackgroundSettings() }
                            .buttonStyle(.borderedProminent)
                    }
                }
                BackgroundServiceRow()
            } header: {
                Text("Start & Hintergrund")
            } footer: {
                Text("Die App läuft unauffällig in der Menüleiste und nimmt nur auf, solange ein Spiel läuft. Egal ob ⌘Q, „Sofort beenden“ oder Absturz – sie kommt nach wenigen Sekunden zurück. Nur „Simplex Recorder beenden“ im eigenen Menü stoppt sie bis zur nächsten Anmeldung.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Rückmeldung") {
                Toggle("Ton abspielen, wenn ein Clip gespeichert wurde", isOn: $settings.playSound)
                if settings.playSound {
                    Picker("Ton", selection: $settings.clipSound) {
                        ForEach(AppSettings.clipSounds, id: \.self) { Text($0).tag($0) }
                    }
                    .onChange(of: settings.clipSound) { _, newValue in
                        NSSound(named: NSSound.Name(newValue))?.play()
                    }
                }
                Toggle("Einblendung im Spiel („Clip gespeichert“)", isOn: $settings.showOverlay)
                Toggle("Mitteilung in der Mitteilungszentrale", isOn: $settings.showNotifications)
                Toggle("Clip automatisch in die Zwischenablage kopieren (zum Einfügen in Discord)", isOn: $settings.copyClipToClipboard)
                Toggle("Clip nach dem Speichern im Finder zeigen", isOn: $settings.revealAfterSave)
                Toggle("Puffer-Sekunden neben dem Menüleisten-Symbol anzeigen", isOn: $settings.menuBarShowsTimer)
            }

            Section {
                HStack {
                    Button("Protokoll öffnen") {
                        if !FileManager.default.fileExists(atPath: DiagnosticsLog.url.path) {
                            DiagnosticsLog.write("log created")
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NSWorkspace.shared.open(DiagnosticsLog.url)
                        }
                    }
                    Button("Im Finder zeigen") {
                        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticsLog.url])
                    }
                }
            } header: {
                Text("Diagnose")
            } footer: {
                Text("Falls etwas nicht klappt (z. B. kein Ton): Protokoll öffnen und den Inhalt schicken.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Berechtigungen") {
                PermissionRow(title: "Bildschirmaufnahme",
                              detail: "Pflicht – damit Spiele aufgenommen werden können.",
                              granted: screenGranted,
                              actionTitle: "Erlauben …") {
                    if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
                }
                if !screenGranted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Schalter ist an, aber die App sagt trotzdem „fehlt“? Dann gehört der Eintrag noch zu einer älteren Version. „Zurücksetzen“ löscht ihn – danach einfach erneut erlauben.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Berechtigung zurücksetzen & neu erlauben") { Permissions.repairScreenRecording() }
                                .buttonStyle(.borderedProminent)
                            Spacer()
                            Button("App neu starten") { LaunchAgentManager.relaunch() }
                        }
                    }
                }
                PermissionRow(title: "Mitteilungen",
                              detail: "Zeigt an, wenn ein Clip gespeichert wurde.",
                              granted: notificationsGranted,
                              actionTitle: "Erlauben …") {
                    NotificationManager.shared.requestAuthorization { granted in
                        notificationsGranted = granted
                        if !granted { Permissions.openNotificationSettings() }
                    }
                }
                PermissionRow(title: "Mikrofon (optional)",
                              detail: "Nur nötig, wenn deine Stimme mit aufgenommen werden soll.",
                              granted: micStatus == .authorized,
                              actionTitle: "Erlauben …") {
                    if micStatus == .notDetermined {
                        Permissions.requestMicrophone { _ in micStatus = Permissions.microphoneStatus }
                    } else {
                        Permissions.openMicrophoneSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshPermissions)
        .onReceive(refresh) { _ in refreshPermissions() }
    }

    private func refreshPermissions() {
        screenGranted = Permissions.hasScreenRecording
        if !screenGranted {
            Task { if await Permissions.probeScreenRecording() { screenGranted = true } }
        }
        micStatus = Permissions.microphoneStatus
        Permissions.notificationsAuthorized { notificationsGranted = $0 }
    }
}

// MARK: - Aufnahme

struct RecordingSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("Schnellauswahl") {
                HStack(spacing: 10) {
                    ForEach(QualityPreset.allCases) { preset in
                        PresetCard(preset: preset, active: preset.isActive(in: settings)) {
                            withAnimation { preset.apply(to: settings) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section {
                Picker("Aufnahmebereich", selection: $settings.captureTarget) {
                    ForEach(CaptureTarget.allCases) { Text($0.title).tag($0) }
                }
                if settings.captureTarget == .gameWindow {
                    Toggle("Fenster-Titelleiste wegschneiden", isOn: $settings.cropTitleBar)
                }
                Toggle("Mauszeiger aufnehmen", isOn: $settings.showCursor)
            } header: {
                Text("Was wird aufgenommen?")
            } footer: {
                Text(settings.captureTarget == .gameWindow
                     ? "Nur das Spielfenster – egal wo es liegt oder ob andere Fenster darüber sind. Das Video hat immer das Format deines Bildschirms: Im Vollbild passt es exakt, kleinere Fenster werden hochskaliert. Fenstergröße ändern oder Vollbild umschalten unterbricht die Aufnahme nicht."
                     : "Es wird der Bildschirm aufgenommen, auf dem das Spiel läuft.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Clip-Länge", selection: $settings.replayDuration) {
                    ForEach(AppSettings.durationOptions, id: \.self) { Text(durationLabel($0)).tag($0) }
                }
                Toggle("Langer Clip per eigenem Tastenkürzel (\(settings.longClipHotKey.displayString))", isOn: $settings.longClipEnabled)
                if settings.longClipEnabled {
                    Picker("Länge des langen Clips", selection: $settings.longClipDuration) {
                        ForEach(AppSettings.longDurationOptions, id: \.self) { Text(durationLabel($0)).tag($0) }
                    }
                }
                LabeledContent("Benötigter Arbeitsspeicher", value: "ca. \(settings.estimatedBufferMB) MB")
            } header: {
                Text("Replay-Puffer")
            } footer: {
                Text("Der Puffer liegt komplett im Arbeitsspeicher – deine SSD wird nicht dauerhaft beschrieben. Erst beim Speichern eines Clips wird eine Datei erzeugt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Video") {
                Picker("Bildrate", selection: $settings.fps) {
                    Text("30 FPS").tag(30)
                    Text("60 FPS").tag(60)
                    Text("120 FPS (ProMotion)").tag(120)
                }
                Picker("Auflösung", selection: $settings.resolution) {
                    ForEach(ResolutionChoice.allCases) { Text($0.title).tag($0) }
                }
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodecChoice.allCases) { Text($0.title).tag($0) }
                }
                LabeledContent("Qualität") {
                    HStack {
                        Slider(value: $settings.bitrateMbps, in: 5...100, step: 5)
                            .frame(width: 220)
                        Text("\(Int(settings.bitrateMbps)) Mbit/s")
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }

            Section {
                Toggle("Spiel- & Systemton aufnehmen", isOn: $settings.captureSystemAudio)
                Toggle("Mikrofon aufnehmen", isOn: Binding(
                    get: { settings.captureMicrophone },
                    set: { newValue in
                        settings.captureMicrophone = newValue
                        if newValue, Permissions.microphoneStatus == .notDetermined {
                            Permissions.requestMicrophone { _ in }
                        }
                    }))
                    .disabled(!Self.supportsMicrophone)
            } header: {
                Text("Audio")
            } footer: {
                if !Self.supportsMicrophone {
                    Text("Mikrofonaufnahme benötigt macOS 15 oder neuer.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                Text("Empfehlung für Minecraft: 60 FPS, max. 1440p, HEVC, 25–40 Mbit/s. Auf Apple-Silicon-Macs übernimmt der Media-Encoder die Arbeit – die Spiel-Performance bleibt praktisch unberührt.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static var supportsMicrophone: Bool {
        if #available(macOS 15.0, *) { return true }
        return false
    }
}

// MARK: - Tastenkürzel

struct HotKeySettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                LabeledContent("Clip speichern") { HotKeyRecorder(combo: $settings.clipHotKey) }
                LabeledContent("Langen Clip speichern (\(durationLabel(settings.longClipDuration)))") {
                    HotKeyRecorder(combo: $settings.longClipHotKey)
                }
                .disabled(!settings.longClipEnabled)
                LabeledContent("Screenshot") { HotKeyRecorder(combo: $settings.screenshotHotKey) }
                LabeledContent("Spielfenster einpassen / wiederherstellen") { HotKeyRecorder(combo: $settings.maximizeHotKey) }
                LabeledContent("Aufnahme pausieren / fortsetzen") { HotKeyRecorder(combo: $settings.pauseHotKey) }
            } header: {
                Text("Globale Tastenkürzel")
            } footer: {
                Text("Die Kürzel funktionieren überall – auch im Vollbild-Spiel. Klicke auf ein Kürzel und drücke die neue Tastenkombination. Normale Tasten brauchen mindestens eine Sondertaste (⌘ ⌥ ⌃ ⇧), F-Tasten gehen auch allein.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Auf Standard zurücksetzen") {
                    settings.clipHotKey = .defaultClip
                    settings.pauseHotKey = .defaultPause
                    settings.longClipHotKey = .defaultLongClip
                    settings.screenshotHotKey = .defaultScreenshot
                    settings.maximizeHotKey = .defaultMaximize
                    AppState.shared.registerHotKeys()
                }
            } footer: {
                Text("Tipp: F-Tasten wie F8 musst du auf Mac-Tastaturen ggf. mit fn drücken – oder in den Systemeinstellungen › Tastatur „F1, F2 usw. als Standard-Funktionstasten verwenden“ aktivieren.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Spiele

struct GamesSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var detector: GameDetector
    @State private var search = ""

    private var filteredApps: [RunningAppInfo] {
        detector.runningApps.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: detector.currentGame == nil ? "moon.zzz.fill" : "gamecontroller.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(detector.currentGame == nil ? Color.secondary : Color.green)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detector.currentGame.map { "\($0.name) wird aufgenommen" } ?? "Gerade läuft kein Spiel")
                            .font(.headline)
                        Text("Automatisch erkannt: Minecraft Java, Steam-, Epic- und App-Store-Spiele u. v. m.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Programm suchen", text: $search).textFieldStyle(.plain)
                }
                if filteredApps.isEmpty {
                    Text("Keine Programme gefunden").foregroundStyle(.secondary)
                }
                ForEach(filteredApps) { app in
                    AppRuleRow(name: app.name, icon: app.icon, ruleKey: app.ruleKey,
                               status: app.detection ?? "Wird nicht aufgenommen", isGame: app.isGame)
                }
            } header: {
                Text("Laufende Programme")
            } footer: {
                Text("Auto = Simplex Recorder entscheidet selbst · Aufnehmen = immer als Spiel behandeln · Nie = niemals aufnehmen. Geht auch direkt über das Menüleisten-Symbol.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(settings.includedApps, id: \.self) { key in
                    SavedRuleRow(key: key, include: true)
                }
                ForEach(settings.excludedApps, id: \.self) { key in
                    SavedRuleRow(key: key, include: false)
                }
                if settings.includedApps.isEmpty && settings.excludedApps.isEmpty {
                    Text("Noch keine eigenen Regeln").foregroundStyle(.secondary)
                }
                HStack {
                    Button {
                        addApp(include: true)
                    } label: {
                        Label("Spiel hinzufügen …", systemImage: "plus.circle.fill")
                    }
                    Button {
                        addApp(include: false)
                    } label: {
                        Label("Programm ausschließen …", systemImage: "nosign")
                    }
                }
            } header: {
                Text("Eigene Regeln")
            } footer: {
                Text("Regeln gelten auch für Programme, die gerade nicht laufen.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { detector.scan() }
    }

    private func addApp(include: Bool) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = include ? "Als Spiel aufnehmen" : "Ausschließen"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            let bundle = Bundle(url: url)
            let key = bundle?.bundleIdentifier ?? url.deletingPathExtension().lastPathComponent
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            AppState.shared.setRule(key: key, name: name, include: include)
        }
    }
}

/// One row with icon, status and a segmented Auto / Aufnehmen / Nie control.
struct AppRuleRow: View {
    @EnvironmentObject private var settings: AppSettings
    let name: String
    let icon: NSImage?
    let ruleKey: String
    let status: String
    let isGame: Bool

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(name).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(isGame ? Color.green : Color.secondary.opacity(0.5)).frame(width: 6, height: 6)
                    Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Picker("", selection: Binding(
                get: { RuleChoice(settings.rule(for: ruleKey)) },
                set: { AppState.shared.setRule(key: ruleKey, name: name, include: $0.value) })) {
                ForEach(RuleChoice.allCases) { Text($0.shortTitle).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)
        }
    }
}

/// A saved rule, resolved to the app's real name and icon where possible.
struct SavedRuleRow: View {
    let key: String
    let include: Bool

    private var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: key) }

    var body: some View {
        HStack(spacing: 10) {
            if let url = appURL {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 22, height: 22)
            } else {
                Image(systemName: "app.dashed").frame(width: 22, height: 22).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName)
                Text(key).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Label(include ? "Immer aufnehmen" : "Nie aufnehmen",
                  systemImage: include ? "checkmark.circle.fill" : "nosign")
                .font(.caption)
                .foregroundStyle(include ? Color.green : Color.red)
            Button {
                AppState.shared.setRule(key: key, name: displayName, include: nil)
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Regel entfernen")
        }
    }

    private var displayName: String {
        guard let url = appURL else { return key }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

// MARK: - Fenster

struct WindowSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var detector: GameDetector
    @State private var trusted = GameWindowAssistant.isTrusted
    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                SnapIllustration()
                    .frame(height: 150)
                    .frame(maxWidth: .infinity)
            }

            Section {
                Toggle("Fenster-Assistent für Spiele", isOn: $settings.snapAssistEnabled)
                Toggle("Spielfenster beim Start automatisch einpassen", isOn: $settings.autoMaximizeGames)
                Toggle("Start-Animation „Clipping aktiv“", isOn: $settings.showStartAnimation)
                LabeledContent("Einpassen / Wiederherstellen") { HotKeyRecorder(combo: $settings.maximizeHotKey) }
            } header: {
                Text("Fenstermanagement")
            } footer: {
                Text("Zieh das Spielfenster an den oberen Bildschirmrand: Eine Vorschau zeigt, wo es landet. Loslassen → es füllt den Bildschirm, Menüleiste und Dock bleiben sichtbar. Linker/rechter Rand → halber Bildschirm.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Sofort anordnen") {
                HStack {
                    Button("Bildschirm füllen") { GameWindowAssistant.shared.perform(.maximize) }
                    Button("Links") { GameWindowAssistant.shared.perform(.leftHalf) }
                    Button("Rechts") { GameWindowAssistant.shared.perform(.rightHalf) }
                    Button("Zentriert") { GameWindowAssistant.shared.perform(.center) }
                    Spacer()
                    Button("Zurücksetzen") { GameWindowAssistant.shared.restore() }
                }
                .disabled(detector.currentGame == nil)
                if detector.currentGame == nil {
                    Text("Starte ein Spiel, um sein Fenster anzuordnen.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Berechtigung") {
                PermissionRow(title: "Bedienungshilfen",
                              detail: "Nötig, damit Simplex Recorder Spielfenster verschieben und vergrößern darf.",
                              granted: trusted,
                              actionTitle: "Erlauben …") {
                    GameWindowAssistant.requestTrust()
                    GameWindowAssistant.openAccessibilitySettings()
                }
                if !trusted {
                    HStack {
                        Text("Schalter ist an, aber hier steht trotzdem „fehlt“? Eintrag einer älteren Version – zurücksetzen und neu erlauben.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Zurücksetzen") {
                            GameWindowAssistant.resetTrust()
                            GameWindowAssistant.requestTrust()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in trusted = GameWindowAssistant.isTrusted }
    }
}

/// Small animated sketch of the snap gesture.
struct SnapIllustration: View {
    var body: some View {
        GeometryReader { geo in
            let w = min(geo.size.width, 300.0)
            let h = geo.size.height
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.12))
                // Menu bar
                Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 8)
                // Dock
                VStack {
                    Spacer()
                    Capsule().fill(Color.secondary.opacity(0.3)).frame(width: w * 0.5, height: 10).padding(.bottom, 4)
                }
                // Animated window
                RoundedRectangle(cornerRadius: 6)
                    .fill(LinearGradient(colors: [Color(red: 0.3, green: 0.6, blue: 0.3), Color(red: 0.25, green: 0.45, blue: 0.2)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(alignment: .top) {
                        Rectangle().fill(Color.black.opacity(0.35)).frame(height: 6)
                    }
                    .phaseAnimator([0, 1, 2]) { view, phase in
                        view
                            .frame(width: phase == 2 ? w - 12 : w * 0.45, height: phase == 2 ? h - 30 : h * 0.4)
                            .offset(x: phase == 0 ? w * 0.12 : 0, y: phase == 0 ? h * 0.42 : (phase == 1 ? 10 : 12))
                    } animation: { phase in
                        phase == 0 ? .easeInOut(duration: 0.8).delay(0.8) : .spring(response: 0.6, dampingFraction: 0.75).delay(0.4)
                    }
                Image(systemName: "cursorarrow")
                    .font(.system(size: 16))
                    .phaseAnimator([0, 1, 2]) { view, phase in
                        view.offset(x: phase == 0 ? w * 0.12 : 0, y: phase == 0 ? h * 0.42 : 10)
                            .opacity(phase == 2 ? 0 : 1)
                    } animation: { phase in
                        phase == 0 ? .easeInOut(duration: 0.8).delay(0.8) : .spring(response: 0.6, dampingFraction: 0.75).delay(0.4)
                    }
            }
            .frame(width: w, height: h)
            .frame(maxWidth: .infinity)
        }
    }
}

enum RuleChoice: String, CaseIterable, Identifiable {
    case automatic, always, never
    var id: String { rawValue }

    init(_ value: Bool?) {
        switch value {
        case .some(true): self = .always
        case .some(false): self = .never
        case .none: self = .automatic
        }
    }

    var value: Bool? {
        switch self {
        case .automatic: return nil
        case .always: return true
        case .never: return false
        }
    }

    var title: String {
        switch self {
        case .automatic: return "Automatisch"
        case .always: return "Immer aufnehmen"
        case .never: return "Nie aufnehmen"
        }
    }

    var shortTitle: String {
        switch self {
        case .automatic: return "Auto"
        case .always: return "Aufnehmen"
        case .never: return "Nie"
        }
    }
}

// MARK: - Speicher

struct StorageSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var storage: StorageMonitor
    @State private var externalVolumes: [URL] = []

    private let refresh = Timer.publish(every: 10, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent("Ordner") {
                    Text(settings.saveFolderPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Ordner wählen …", action: chooseFolder)
                    if !externalVolumes.isEmpty {
                        Menu("Externe Festplatte") {
                            ForEach(externalVolumes, id: \.self) { volume in
                                Button(volume.lastPathComponent) {
                                    settings.saveFolderPath = volume.appendingPathComponent("Simplex Recorder").path
                                }
                            }
                        }
                        .fixedSize()
                    }
                    Button("Im Finder zeigen") { AppState.shared.openClipFolder() }
                    Spacer()
                    Button("Standard") { settings.saveFolderPath = AppSettings.defaultSaveFolder.path }
                }
                Toggle("Clips pro Spiel in Unterordnern ablegen", isOn: $settings.organizeByGame)
            } header: {
                Text("Speicherort")
            }

            Section("Festplatte") {
                if let info = storage.info {
                    if info.isMounted {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: info.volumePath))
                                .resizable().frame(width: 40, height: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(info.volumeName).font(.headline)
                                Text("\(info.available.formattedBytes) von \(info.total.formattedBytes) frei · \(info.clipCount) Clips")
                                    .font(.subheadline).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(info.isInternal ? "Intern" : "Extern")
                                .font(.caption.weight(.semibold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        }
                        StorageBar(info: info)
                        if info.total > 0, Double(info.available) / Double(info.total) < 0.05 {
                            Label("Fast voll! Lösche alte Clips oder aktiviere die automatische Aufräumfunktion.",
                                  systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange).font(.caption)
                        }
                    } else {
                        Label("„\(info.volumeName)“ ist nicht verbunden. Clips werden solange in „Filme/Simplex Recorder“ gespeichert.",
                              systemImage: "externaldrive.badge.xmark")
                            .foregroundStyle(.orange)
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }

            Section {
                Picker("Maximaler Platz für Clips", selection: $settings.maxClipStorageGB) {
                    Text("Unbegrenzt").tag(0)
                    ForEach([10, 25, 50, 100, 250, 500, 1000], id: \.self) { gb in
                        Text(gb >= 1000 ? "\(gb / 1000) TB" : "\(gb) GB").tag(gb)
                    }
                }
            } header: {
                Text("Automatisch aufräumen")
            } footer: {
                Text("Wird die Grenze überschritten, löscht Simplex Recorder die ältesten Clips endgültig.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
        .onReceive(refresh) { _ in reload() }
        .onChange(of: settings.saveFolderPath) { _, _ in reload() }
    }

    private func reload() {
        storage.refresh(folder: settings.saveFolderURL)
        externalVolumes = StorageMonitor.externalVolumes()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Auswählen"
        panel.message = "Wähle, wo deine Clips gespeichert werden sollen (z. B. deine externe Festplatte)."
        panel.directoryURL = settings.saveFolderURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }
}

// MARK: - Background service status

struct BackgroundServiceRow: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(color).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if needsRepair {
                Button("Reparieren") { AppState.shared.applyBackgroundSettings() }
            }
        }
    }

    private var active: Bool { LaunchAgentManager.isLaunchedByAgent }
    private var locationOK: Bool { LaunchAgentManager.isInstalledLocationValid }
    private var needsRepair: Bool { settings.wantsLaunchAgent && locationOK && !active }

    private var icon: String {
        if active { return "checkmark.shield.fill" }
        return settings.wantsLaunchAgent ? "exclamationmark.triangle.fill" : "minus.circle"
    }

    private var color: Color {
        if active { return .green }
        return settings.wantsLaunchAgent ? .orange : .secondary
    }

    private var title: String {
        if active { return "Hintergrunddienst aktiv" }
        return settings.wantsLaunchAgent ? "Hintergrunddienst nicht aktiv" : "Hintergrunddienst aus"
    }

    private var detail: String {
        if !locationOK {
            return "Verschiebe die App in den Ordner „Programme“ und öffne sie von dort – aus dem DMG oder Downloads kann macOS sie nicht automatisch starten."
        }
        if active { return "Wird von macOS überwacht und automatisch neu gestartet." }
        if settings.wantsLaunchAgent { return "Klicke auf „Reparieren“ – die App startet kurz neu. Protokoll: ~/Library/Logs/SimplexRecorder/agent.log" }
        return "Autostart und Neustart sind ausgeschaltet."
    }
}

// MARK: - Preset card

struct PresetCard: View {
    let preset: QualityPreset
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: preset.symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.accentColor)
                Text(preset.title).font(.system(size: 12, weight: .semibold))
                Text(preset.detail)
                    .font(.system(size: 9))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(active ? Color.white.opacity(0.85) : Color.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 82)
            .padding(.horizontal, 4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(active ? Color.accentColor : Color.secondary.opacity(hovering ? 0.16 : 0.08))
            )
            .foregroundStyle(active ? Color.white : Color.primary)
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
