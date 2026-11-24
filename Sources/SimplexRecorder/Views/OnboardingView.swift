import SwiftUI
import AppKit

struct OnboardingView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var step = 0
    @State private var screenGranted = Permissions.hasScreenRecording
    @State private var notificationsGranted = false
    @State private var externalVolumes: [URL] = []

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let stepCount = 4

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0: welcome
                case 1: permission
                case 2: storage
                default: background
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 40)
            .padding(.top, 36)

            Divider()
            HStack {
                HStack(spacing: 6) {
                    ForEach(0..<stepCount, id: \.self) { i in
                        Circle().fill(i == step ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 7, height: 7)
                    }
                }
                Spacer()
                if step > 0 {
                    Button("Zurück") { withAnimation { step -= 1 } }
                }
                Button(step == stepCount - 1 ? "Fertig" : "Weiter") {
                    if step == stepCount - 1 { finish() } else { withAnimation { step += 1 } }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 620, height: 560)
        .onReceive(timer) { _ in
            screenGranted = Permissions.hasScreenRecording
            if !screenGranted, step == 1 {
                Task { if await Permissions.probeScreenRecording() { screenGranted = true } }
            }
        }
        .onAppear {
            externalVolumes = StorageMonitor.externalVolumes()
            Permissions.notificationsAuthorized { notificationsGranted = $0 }
        }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 18) {
            AppBadge(size: 96)
            Text("Willkommen bei Simplex Recorder").font(.largeTitle.weight(.bold))
            Text("Dein Replay-Recorder für den Mac – wie Medal, nur nativ.")
                .font(.title3).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 12) {
                feature("gamecontroller.fill", "Startet automatisch, sobald ein Spiel läuft – z. B. Minecraft Java Edition.")
                feature("keyboard", "Ein Tastendruck (\(settings.clipHotKey.displayString)) speichert die letzten \(settings.replayDuration) Sekunden.")
                feature("bolt.fill", "Hardware-Encoder & Puffer im RAM – kaum spürbar, schont die SSD.")
                feature("externaldrive.fill", "Clips direkt auf deine externe Festplatte – mit Speicheranzeige.")
            }
            .padding(.top, 8)
            Spacer()
        }
    }

    private var permission: some View {
        VStack(spacing: 18) {
            Image(systemName: screenGranted ? "checkmark.shield.fill" : "rectangle.dashed.badge.record")
                .font(.system(size: 60))
                .foregroundStyle(screenGranted ? Color.green : Color.accentColor)
            Text("Bildschirmaufnahme erlauben").font(.title.weight(.bold))
            Text("macOS fragt einmal nach deiner Erlaubnis. Aktiviere „Simplex Recorder“ unter Systemeinstellungen › Datenschutz & Sicherheit › Bildschirm- & Systemaudioaufnahme.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if screenGranted {
                Label("Erlaubt – alles bereit!", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.headline)
            } else {
                HStack {
                    Button("Erlauben …") {
                        if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Button("Systemeinstellungen öffnen") { Permissions.openScreenRecordingSettings() }
                        .controlSize(.large)
                    Button("Zurücksetzen") { Permissions.repairScreenRecording() }
                        .controlSize(.large)
                        .help("Löscht einen alten Eintrag einer früheren Version und fragt neu")
                }
                Text("Wenn du den Schalter aktiviert hast, aber hier noch nichts passiert: macOS verlangt einen Neustart der App. Klicke dann einfach auf „Fertig“ am Ende – die App startet dabei ohnehin neu.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }

            Divider().padding(.vertical, 6)

            HStack {
                Image(systemName: "bell.badge.fill").foregroundStyle(.red)
                Text("Mitteilungen, wenn ein Clip gespeichert wurde")
                Spacer()
                if notificationsGranted {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                } else {
                    Button("Erlauben") {
                        NotificationManager.shared.requestAuthorization { notificationsGranted = $0 }
                    }
                }
            }
            Spacer()
        }
    }

    private var storage: some View {
        VStack(spacing: 16) {
            Image(systemName: "externaldrive.fill").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Wo sollen Clips gespeichert werden?").font(.title.weight(.bold))
            Text(settings.saveFolderPath)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))

            if !externalVolumes.isEmpty {
                Text("Externe Festplatten").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
                ForEach(externalVolumes, id: \.self) { volume in
                    Button {
                        settings.saveFolderPath = volume.appendingPathComponent("Simplex Recorder").path
                    } label: {
                        HStack {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: volume.path))
                                .resizable().frame(width: 28, height: 28)
                            Text(volume.lastPathComponent)
                            Spacer()
                            if settings.saveFolderPath.hasPrefix(volume.path) {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            }
                        }
                        .padding(8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
                }
            } else {
                Text("Keine externe Festplatte gefunden – schließe sie an oder wähle einen beliebigen Ordner.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack {
                Button("Anderen Ordner wählen …", action: chooseFolder)
                Button("Liste aktualisieren") { externalVolumes = StorageMonitor.externalVolumes() }
            }
            Spacer()
        }
    }

    private var background: some View {
        VStack(spacing: 18) {
            Image(systemName: "infinity.circle.fill").font(.system(size: 56)).foregroundStyle(Color.accentColor)
            Text("Immer bereit im Hintergrund").font(.title.weight(.bold))
            Text("Simplex Recorder sitzt in der Menüleiste und wird erst aktiv, wenn ein Spiel läuft.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Beim Anmelden automatisch starten", isOn: $settings.launchAtLogin)
                Toggle("Automatisch neu starten, wenn die App beendet wird oder abstürzt", isOn: $settings.keepAlive)
            }
            .toggleStyle(.switch)
            .padding()
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))

            HStack {
                Text("Clip speichern")
                Spacer()
                HotKeyRecorder(combo: $settings.clipHotKey)
            }
            .padding(.horizontal)

            if !LaunchAgentManager.isInstalledLocationValid {
                Label("Tipp: Verschiebe die App zuerst in den Ordner „Programme“ und öffne sie von dort – sonst kann macOS den Autostart nicht einrichten.",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
            }
            Spacer()
        }
    }

    private func feature(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: 24)
            Text(text)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Auswählen"
        if panel.runModal() == .OK, let url = panel.url {
            settings.saveFolderPath = url.path
        }
    }

    private func finish() {
        settings.hasCompletedOnboarding = true
        try? FileManager.default.createDirectory(at: settings.saveFolderURL, withIntermediateDirectories: true)
        WindowManager.shared.closeOnboarding()
        // Restart under launchd (autostart / keep-alive) – also picks up a freshly granted permission.
        if (settings.wantsLaunchAgent && LaunchAgentManager.isInstalledLocationValid) || !Permissions.hasScreenRecording {
            LaunchAgentManager.applyAndRelaunch(runAtLoad: settings.launchAtLogin, keepAlive: settings.keepAlive)
        }
        AppState.shared.refreshLibrary()
    }
}
