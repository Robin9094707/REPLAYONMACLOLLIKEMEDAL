import SwiftUI
import AppKit
import AVFoundation

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
                Toggle("Mitteilung anzeigen", isOn: $settings.showNotifications)
            }

            Section("Berechtigungen") {
                PermissionRow(title: "Bildschirmaufnahme",
                              detail: "Pflicht – damit Spiele aufgenommen werden können.",
                              granted: screenGranted,
                              actionTitle: "Erlauben …") {
                    if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
                }
                if !screenGranted {
                    HStack {
                        Text("Nach dem Erlauben muss die App einmal neu starten.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("App neu starten") { LaunchAgentManager.relaunch() }
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
        micStatus = Permissions.microphoneStatus
        Permissions.notificationsAuthorized { notificationsGranted = $0 }
    }
}

// MARK: - Aufnahme

struct RecordingSettingsView: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section {
                Picker("Clip-Länge", selection: $settings.replayDuration) {
                    ForEach(AppSettings.durationOptions, id: \.self) { Text(durationLabel($0)).tag($0) }
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
                Picker("Aufnahmebereich", selection: $settings.captureTarget) {
                    ForEach(CaptureTarget.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Mauszeiger aufnehmen", isOn: $settings.showCursor)
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

    var body: some View {
        Form {
            Section {
                if let game = detector.currentGame {
                    Label("Erkannt: \(game.name)", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Gerade läuft kein erkanntes Spiel", systemImage: "moon.zzz")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Automatische Erkennung")
            } footer: {
                Text("Erkannt werden u. a. Minecraft Java Edition (auch über Prism, Lunar, CurseForge …), Steam- und Epic-Spiele, Apps aus der Kategorie „Spiele“ sowie viele bekannte Engines. Fehlt ein Spiel, markiere es unten einfach selbst.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Laufende Programme") {
                if detector.runningApps.isEmpty {
                    Text("Keine Programme gefunden").foregroundStyle(.secondary)
                }
                ForEach(detector.runningApps) { app in
                    HStack(spacing: 10) {
                        if let icon = app.icon {
                            Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                        } else {
                            Image(systemName: "app").frame(width: 22, height: 22)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name)
                            Text(app.detection ?? "Kein Spiel")
                                .font(.caption)
                                .foregroundStyle(app.isGame ? Color.green : Color.secondary)
                        }
                        Spacer()
                        Picker("", selection: Binding(
                            get: { RuleChoice(settings.rule(for: app.ruleKey)) },
                            set: { settings.setRule(for: app.ruleKey, include: $0.value); detector.scan() })) {
                            ForEach(RuleChoice.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 170)
                    }
                }
            }

            if !settings.includedApps.isEmpty || !settings.excludedApps.isEmpty {
                Section("Eigene Regeln") {
                    ForEach(settings.includedApps, id: \.self) { key in
                        ruleRow(key: key, text: "Immer aufnehmen", color: .green)
                    }
                    ForEach(settings.excludedApps, id: \.self) { key in
                        ruleRow(key: key, text: "Nie aufnehmen", color: .red)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { detector.scan() }
    }

    private func ruleRow(key: String, text: String, color: Color) -> some View {
        HStack {
            Text(key).font(.system(.body, design: .monospaced))
            Spacer()
            Text(text).foregroundStyle(color).font(.caption)
            Button {
                settings.setRule(for: key, include: nil)
                detector.scan()
            } label: {
                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
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
