import SwiftUI
import AppKit

/// The native menu-bar menu.
struct MenuContentView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var storage: StorageMonitor
    @EnvironmentObject private var detector: GameDetector

    var body: some View {
        Text(state.statusLine)
        if state.isRecording {
            Text("Puffer: \(Int(state.bufferedSeconds)) von \(settings.replayDuration) s · \(state.bufferMB) MB RAM")
            if settings.captureSystemAudio {
                Text(state.audioBufferedSeconds > 0
                     ? "Ton: \(Int(state.audioBufferedSeconds)) s im Puffer"
                     : "Ton: noch kein Systemton empfangen")
            }
        }

        Divider()

        Button("Clip speichern (letzte \(settings.replayDuration) s)   \(settings.clipHotKey.displayString)") {
            state.saveClip()
        }
        .disabled(!state.canSaveClip)
        if settings.longClipEnabled {
            Button("Langen Clip speichern (\(durationLabel(settings.longClipDuration)))   \(settings.longClipHotKey.displayString)") {
                state.saveLongClip()
            }
            .disabled(!state.canSaveClip)
        }
        Button("Screenshot   \(settings.screenshotHotKey.displayString)") { state.takeScreenshot() }
            .disabled(!state.isRecording)

        Picker("Clip-Länge", selection: $settings.replayDuration) {
            ForEach(AppSettings.durationOptions, id: \.self) { seconds in
                Text(durationLabel(seconds)).tag(seconds)
            }
        }

        if let game = detector.currentGame {
            Menu("Spielfenster – \(game.name)") {
                Button("Bildschirm füllen (Menüleiste & Dock bleiben)   \(settings.maximizeHotKey.displayString)") {
                    GameWindowAssistant.shared.perform(.maximize)
                }
                Button("Linke Hälfte") { GameWindowAssistant.shared.perform(.leftHalf) }
                Button("Rechte Hälfte") { GameWindowAssistant.shared.perform(.rightHalf) }
                Button("Zentriert (80 %)") { GameWindowAssistant.shared.perform(.center) }
                Divider()
                Button("Ursprüngliche Größe") { GameWindowAssistant.shared.restore() }
                if !GameWindowAssistant.isTrusted {
                    Divider()
                    Button("Bedienungshilfen erlauben …") { GameWindowAssistant.requestTrust() }
                }
            }
        }

        if let app = detector.frontmostApp {
            Divider()
            if app.isGame {
                Button("„\(app.name)“ nicht mehr aufnehmen") {
                    state.setRule(key: app.ruleKey, name: app.name, include: false)
                }
            } else {
                Button("„\(app.name)“ als Spiel aufnehmen") {
                    state.setRule(key: app.ruleKey, name: app.name, include: true)
                }
            }
            if settings.rule(for: app.ruleKey) != nil {
                Button("Regel für „\(app.name)“ zurücksetzen") {
                    state.setRule(key: app.ruleKey, name: app.name, include: nil)
                }
            }
        }

        Divider()

        if settings.isPausedNow {
            Button("Aufnahme fortsetzen   \(settings.pauseHotKey.displayString)") { state.resume() }
        } else {
            Menu("Aufnahme pausieren") {
                Button("15 Minuten") { state.pause(minutes: 15) }
                Button("1 Stunde") { state.pause(minutes: 60) }
                Button("3 Stunden") { state.pause(minutes: 180) }
                Divider()
                Button("Bis ich fortsetze   \(settings.pauseHotKey.displayString)") { state.pause(minutes: nil) }
            }
        }

        Divider()

        Menu("Letzte Clips") {
            if library.clips.isEmpty {
                Text("Noch keine Clips")
            } else {
                ForEach(library.clips.prefix(8)) { clip in
                    Button(clip.name) { NSWorkspace.shared.open(clip.url) }
                }
            }
            Divider()
            Button("Alle Clips anzeigen …") { WindowManager.shared.showSettings(tab: .clips) }
        }
        if let last = state.lastSavedClip {
            Button("Letzten Clip im Finder zeigen") {
                NSWorkspace.shared.activateFileViewerSelecting([last])
            }
        }
        Button("Clip-Ordner öffnen") { state.openClipFolder() }

        if let info = storage.info {
            if info.isMounted {
                Text("\(info.volumeName): \(info.available.formattedBytes) frei · Clips \(info.clipsBytes.formattedBytes)")
            } else {
                Text("⚠︎ \(info.volumeName) ist nicht verbunden")
            }
        }

        Divider()

        Button("Einstellungen …") { WindowManager.shared.showSettings() }
            .keyboardShortcut(",")
        Button("Simplex Recorder beenden") { state.confirmQuit() }
            .keyboardShortcut("q")
    }
}

func durationLabel(_ seconds: Int) -> String {
    if seconds < 60 { return "\(seconds) Sekunden" }
    if seconds % 60 == 0 { return seconds == 60 ? "1 Minute" : "\(seconds / 60) Minuten" }
    return "\(seconds / 60):\(String(format: "%02d", seconds % 60)) Minuten"
}
