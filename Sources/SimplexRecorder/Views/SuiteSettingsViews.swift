import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Tastatur

struct KeyboardSettingsView: View {
    @ObservedObject private var suite = SuiteSettings.shared
    @State private var trusted = AXIsProcessTrusted()
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                Toggle("Strg wie ⌘ verwenden (Windows-Tastatur)", isOn: $suite.windowsKeyboard)
                if suite.windowsKeyboard {
                    VStack(alignment: .leading, spacing: 6) {
                        shortcutRow("Strg + C / V / X", "Kopieren · Einfügen · Ausschneiden")
                        shortcutRow("Strg + A / Z / Y", "Alles · Rückgängig · Wiederholen")
                        shortcutRow("Strg + S / F / P", "Sichern · Suchen · Drucken")
                        shortcutRow("Strg + T / W / N", "Tab · Tab schließen · Neu")
                    }
                    .padding(.vertical, 4)
                }
                Toggle("Pos1/Ende, Strg+←/→ und Strg+⌫ wie unter Windows", isOn: $suite.windowsNavigationKeys)
                Toggle("In Spielen ausschalten (Strg bleibt Strg, z. B. zum Sprinten)", isOn: $suite.remapDisabledInGames)
            } header: {
                Text("Windows-Tastatur")
            } footer: {
                Text("Terminal-Apps und virtuelle Maschinen sind ausgenommen, dort bleibt Strg+C ein Abbruch. Strg+Q, Strg+H und Strg+M werden bewusst nicht umgelegt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("App-Starter öffnen mit", selection: $suite.launcherTrigger) {
                    ForEach(LauncherTrigger.allCases) { Text($0.title).tag($0) }
                }
                Button("App-Starter jetzt öffnen") { LauncherPanel.shared.show() }
            } header: {
                Text("App-Starter")
            } footer: {
                Text("Wie das Startmenü: Taste kurz antippen (ohne weitere Taste) → alle Apps mit Suche erscheinen. Tippen, Enter, fertig. Im Spiel ist das Antippen deaktiviert.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Ausnahmen") {
                ForEach(suite.remapExclusions, id: \.self) { id in
                    HStack {
                        AppLabel(bundleID: id)
                        Spacer()
                        Button { suite.remapExclusions.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("App hinzufügen …") {
                    if let id = pickAppBundleID(), !suite.remapExclusions.contains(id) { suite.remapExclusions.append(id) }
                }
            }

            Section("Berechtigung") {
                PermissionRow(title: "Bedienungshilfen",
                              detail: "Nötig, damit Tastendrücke umgelegt werden können.",
                              granted: trusted, actionTitle: "Erlauben …") {
                    GameWindowAssistant.requestTrust()
                    GameWindowAssistant.openAccessibilitySettings()
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(refresh) { _ in trusted = AXIsProcessTrusted() }
    }

    private func shortcutRow(_ keys: String, _ meaning: String) -> some View {
        HStack {
            Text(keys).font(.system(.callout, design: .monospaced)).frame(width: 150, alignment: .leading)
            Text("→ \(meaning)").font(.callout).foregroundStyle(.secondary)
        }
    }
}

// MARK: - System

struct SystemSettingsView: View {
    @ObservedObject private var suite = SuiteSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Werte neben dem Menüleisten-Symbol anzeigen", isOn: $suite.statsInMenuBar)
                if suite.statsInMenuBar {
                    Toggle("CPU-Auslastung", isOn: $suite.menuBarShowCPU)
                    Toggle("CPU-Temperatur", isOn: $suite.menuBarShowTemp)
                    Toggle("Arbeitsspeicher", isOn: $suite.menuBarShowRAM)
                }
            } header: {
                Text("Menüleiste")
            } footer: {
                Text("Gemessen wird nur, wenn das Dashboard oder der Taskmanager offen ist, oder alle 4 Sekunden, wenn Werte in der Menüleiste stehen. Die Temperatur gibt es auf Apple-Silicon-Macs, sonst wird der Wärmezustand angezeigt.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Rotes X beendet die App, wenn das letzte Fenster geschlossen wird", isOn: $suite.closeQuitsApps)
                if suite.closeQuitsApps {
                    ForEach(suite.closeExclusions, id: \.self) { id in
                        HStack {
                            AppLabel(bundleID: id)
                            Spacer()
                            Text("läuft weiter").font(.caption).foregroundStyle(.secondary)
                            Button { suite.closeExclusions.removeAll { $0 == id } } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button("Ausnahme hinzufügen …") {
                        if let id = pickAppBundleID(), !suite.closeExclusions.contains(id) { suite.closeExclusions.append(id) }
                    }
                }
            } header: {
                Text("Apps schließen wie unter Windows")
            } footer: {
                Text("Ausnahmen laufen nach dem Schließen weiter, z. B. Musik-Apps.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Toggle("Fenster-Vorschau beim Darüberfahren im Dock", isOn: $suite.dockPreviews)
                Picker("Fenster-Assistent (an den Rand ziehen)", selection: $suite.windowAssistScope) {
                    ForEach(WindowAssistScope.allCases) { Text($0.title).tag($0) }
                }
            } header: {
                Text("Dock & Fenster")
            } footer: {
                Text("Die Dock-Vorschau zeigt Live-Bilder aller Fenster einer App. Klick holt das Fenster nach vorne, das × schließt es.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(suite.quitAllExclusions, id: \.self) { id in
                    HStack {
                        AppLabel(bundleID: id)
                        Spacer()
                        Button { suite.quitAllExclusions.removeAll { $0 == id } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                Button("App hinzufügen …") {
                    if let id = pickAppBundleID(), !suite.quitAllExclusions.contains(id) { suite.quitAllExclusions.append(id) }
                }
            } header: {
                Text("„Alle Apps beenden“ lässt aus")
            }

            Section {
                HStack {
                    Button("Taskmanager öffnen") { WindowManager.shared.showTaskManager() }
                    Button("Aufräumen & Deinstallieren") { WindowManager.shared.showCleaner() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Helpers

struct AppLabel: View {
    let bundleID: String

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 8) {
            if let url {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 20, height: 20)
                Text(FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: ""))
            } else {
                Image(systemName: "app.dashed").frame(width: 20, height: 20).foregroundStyle(.secondary)
                Text(bundleID).font(.system(.body, design: .monospaced))
            }
        }
    }
}

@MainActor
func pickAppBundleID() -> String? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.prompt = "Hinzufügen"
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    return Bundle(url: url)?.bundleIdentifier
}
