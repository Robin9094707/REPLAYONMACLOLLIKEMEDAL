import SwiftUI
import AppKit

/// The menu bar panel of Simplex Suite.
struct DashboardView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var library: ClipLibrary
    @EnvironmentObject private var detector: GameDetector
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var suite = SuiteSettings.shared
    @State private var showAllApps = false

    var body: some View {
        VStack(spacing: 12) {
            header
            statsGrid
            clipCard
            toolsRow
            appsSection
            footer
        }
        .padding(14)
        .frame(width: 380)
        .onAppear { monitor.acquire("dashboard", perApp: true) }
        .onDisappear { monitor.release("dashboard") }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            AppBadge(size: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text("Simplex Suite").font(.system(size: 15, weight: .bold, design: .rounded))
                Text(state.statusLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button { open { WindowManager.shared.showSettings() } } label: {
                Image(systemName: "gearshape.fill").font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help("Einstellungen")
        }
    }

    // MARK: Stats

    private var statsGrid: some View {
        let s = monitor.snapshot
        return HStack(spacing: 8) {
            MiniGauge(symbol: "cpu", title: "CPU", value: "\(Int(s.cpuUsage * 100))%", fraction: s.cpuUsage, color: .blue)
            MiniGauge(symbol: "thermometer.medium", title: s.cpuTemperature == nil ? "Wärme" : "Temp.",
                      value: s.temperatureText,
                      fraction: s.cpuTemperature.map { min(1, $0 / 105) } ?? Double(s.thermalState.rawValue + 1) / 4,
                      color: .orange)
            MiniGauge(symbol: "memorychip", title: "RAM", value: Int64(s.memoryUsed).compactBytes,
                      fraction: s.memoryFraction, color: .purple)
            MiniGauge(symbol: "internaldrive", title: "Frei", value: s.diskFree.compactBytes,
                      fraction: s.diskTotal > 0 ? 1 - Double(s.diskFree) / Double(s.diskTotal) : 0, color: .green)
        }
    }

    // MARK: Clips

    private var clipCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle()
                    .fill(state.isRecording ? Color.red : (settings.isPausedNow ? Color.orange : Color.secondary))
                    .frame(width: 9, height: 9)
                    .shadow(color: state.isRecording ? .red : .clear, radius: 4)
                Text(state.isRecording ? "Clipping aktiv" : (settings.isPausedNow ? "Clipping pausiert" : "Clipping bereit"))
                    .font(.system(size: 13, weight: .semibold))
                if state.isRecording {
                    Text("· \(Int(state.bufferedSeconds)) s Puffer").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                Toggle("", isOn: Binding(get: { !settings.isPausedNow },
                                         set: { $0 ? state.resume() : state.pause(minutes: nil) }))
                    .toggleStyle(.switch).controlSize(.mini).labelsHidden()
                    .help("Clipping an/aus")
            }
            HStack(spacing: 6) {
                DashButton(symbol: "scissors", title: "\(settings.replayDuration) s", tint: .red) { state.saveClip() }
                    .disabled(!state.canSaveClip)
                if settings.longClipEnabled {
                    DashButton(symbol: "film", title: durationShort(settings.longClipDuration), tint: .pink) { state.saveLongClip() }
                        .disabled(!state.canSaveClip)
                }
                DashButton(symbol: "camera", title: "Foto", tint: .blue) { state.takeScreenshot() }
                    .disabled(!state.isRecording)
                DashButton(symbol: "film.stack", title: "Clips", tint: .indigo) {
                    open { WindowManager.shared.showSettings(tab: .clips) }
                }
            }
            RecordRow { action in open(action) }
            if let app = detector.frontmostApp {
                Divider().opacity(0.5)
                HStack(spacing: 8) {
                    if let icon = app.icon { Image(nsImage: icon).resizable().frame(width: 16, height: 16) }
                    Text(app.name).font(.caption).lineLimit(1)
                    Text(app.isGame ? "· wird aufgenommen" : "· nicht aufgenommen")
                        .font(.caption).foregroundStyle(app.isGame ? Color.green : Color.secondary)
                    Spacer()
                    Menu {
                        Button("Als Spiel aufnehmen") { state.setRule(key: app.ruleKey, name: app.name, include: true) }
                        Button("Nie aufnehmen") { state.setRule(key: app.ruleKey, name: app.name, include: false) }
                        if settings.rule(for: app.ruleKey) != nil {
                            Button("Automatisch erkennen") { state.setRule(key: app.ruleKey, name: app.name, include: nil) }
                        }
                        if detector.currentGame != nil {
                            Divider()
                            Button("Spielfenster: Bildschirm füllen") { GameWindowAssistant.shared.perform(.maximize) }
                            Button("Spielfenster: Linke Hälfte") { GameWindowAssistant.shared.perform(.leftHalf) }
                            Button("Spielfenster: Rechte Hälfte") { GameWindowAssistant.shared.perform(.rightHalf) }
                            Button("Spielfenster: Ursprüngliche Größe") { GameWindowAssistant.shared.restore() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }

    // MARK: Tools

    private var toolsRow: some View {
        HStack(spacing: 6) {
            ToolButton(symbol: "square.grid.3x3.fill", title: "Apps", color: .blue) { open { LauncherPanel.shared.show() } }
            ToolButton(symbol: "chart.bar.xaxis", title: "Taskmanager", color: .green) { open { WindowManager.shared.showTaskManager() } }
            ToolButton(symbol: "trash.square.fill", title: "Aufräumen", color: .pink) { open { WindowManager.shared.showCleaner() } }
            ToolButton(symbol: "macwindow.on.rectangle", title: "Fenster", color: .orange) { open { WindowManager.shared.showSettings(tab: .windows) } }
        }
    }

    // MARK: Apps

    private var appsSection: some View {
        let apps = monitor.apps.filter(\.isApp)
        let visible = showAllApps ? apps : Array(apps.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Aktive Apps").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                Text("\(apps.count)").font(.caption2.weight(.bold)).padding(.horizontal, 5)
                    .background(Capsule().fill(Color.secondary.opacity(0.2)))
                Spacer()
                Button {
                    SuiteActions.quitAllApps()
                } label: {
                    Label("Alle beenden", systemImage: "xmark.circle.fill").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.red)
            }
            VStack(spacing: 2) {
                ForEach(visible) { usage in
                    AppUsageRow(usage: usage)
                }
            }
            if apps.count > 6 {
                Button(showAllApps ? "Weniger anzeigen" : "Alle \(apps.count) anzeigen") {
                    withAnimation(.easeInOut(duration: 0.2)) { showAllApps.toggle() }
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            RemoteBadge { open { WindowManager.shared.showSettings(tab: .remote) } }
            Button("Clip-Ordner") { open { state.openClipFolder() } }
            Spacer()
            if let last = state.lastSavedClip {
                Button("Letzter Clip") { open { ClipEditor.shared.open(last, game: "") } }
                Spacer()
            }
            Button("Beenden") { state.confirmQuit() }
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    // MARK: Helpers

    /// Close the menu bar panel, then run the action.
    private func open(_ action: @escaping @MainActor () -> Void) {
        for window in NSApp.windows where window.className.contains("MenuBarExtra") {
            window.close()
        }
        Task { @MainActor in action() }
    }

    private func durationShort(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) min" : "\(seconds) s"
    }
}

// MARK: - Components

struct MiniGauge: View {
    let symbol: String
    let title: String
    let value: String
    let fraction: Double
    let color: Color

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().stroke(color.opacity(0.18), lineWidth: 5)
                Circle()
                    .trim(from: 0, to: max(0.02, min(1, fraction)))
                    .stroke(AngularGradient(colors: [color.opacity(0.6), color], center: .center),
                            style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: fraction)
                Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(color)
            }
            .frame(width: 42, height: 42)
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
}

struct DashButton: View {
    let symbol: String
    let title: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tint.opacity(0.14)))
        }
        .buttonStyle(.plain)
    }
}

struct ToolButton: View {
    let symbol: String
    let title: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [color.opacity(0.85), color], startPoint: .top, endPoint: .bottom)))
                    .scaleEffect(hovering ? 1.07 : 1)
                Text(title).font(.system(size: 10)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}

struct AppUsageRow: View {
    let usage: ProcessUsage
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            if let icon = usage.icon {
                Image(nsImage: icon).resizable().frame(width: 18, height: 18)
            }
            Text(usage.name).font(.system(size: 12)).lineLimit(1)
            Spacer()
            Text(String(format: "%.0f%%", usage.cpu)).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(usage.cpu > 50 ? Color.orange : Color.secondary)
                .frame(width: 38, alignment: .trailing)
            Text(Int64(usage.memory).compactBytes).font(.system(size: 11)).monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .trailing)
            Button {
                SuiteActions.quit(usage)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(hovering ? Color.red : Color.secondary.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("\(usage.name) beenden")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? Color.secondary.opacity(0.1) : .clear))
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Beenden") { SuiteActions.quit(usage) }
            Button("Sofort beenden") { SuiteActions.quit(usage, force: true) }
            if let id = usage.bundleID {
                Divider()
                Button("„\(usage.name)“ als Spiel aufnehmen") { AppState.shared.setRule(key: id, name: usage.name, include: true) }
                Button("„\(usage.name)“ nie aufnehmen") { AppState.shared.setRule(key: id, name: usage.name, include: false) }
            }
        }
    }
}

extension Int64 {
    /// "12,3 GB" without the space-hungry details.
    var compactBytes: String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .memory
        formatter.allowedUnits = [.useMB, .useGB, .useTB]
        formatter.zeroPadsFractionDigits = false
        return formatter.string(fromByteCount: self)
    }
}

struct RemoteBadge: View {
    @ObservedObject private var agent = RemoteAgent.shared
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "iphone.radiowaves.left.and.right")
                Circle().fill(color).frame(width: 6, height: 6)
            }
        }
        .help("Remote: \(agent.state.title)")
    }

    private var color: Color {
        switch agent.state {
        case .connected: return agent.attachedClients > 0 ? .blue : .green
        case .connecting: return .orange
        case .error: return .red
        case .off: return .secondary
        }
    }
}

/// Start/stop the classic screen recording from the dashboard.
struct RecordRow: View {
    @ObservedObject private var recorder = ScreenRecorder.shared
    @EnvironmentObject private var settings: AppSettings
    let open: (@escaping @MainActor () -> Void) -> Void

    var body: some View {
        HStack(spacing: 6) {
            if recorder.isRecording {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Button {
                        Task { await recorder.stop() }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "stop.circle.fill")
                            Text("Aufnahme stoppen · \(recorder.elapsedText)").monospacedDigit()
                        }
                        .font(.system(size: 12, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .foregroundStyle(.white)
                        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.red))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                DashButton(symbol: "record.circle", title: "Bildschirm aufnehmen", tint: .red) {
                    open { ScreenRecorder.shared.startFullScreen() }
                }
                DashButton(symbol: "rectangle.dashed", title: "Bereich aufnehmen", tint: .orange) {
                    open { ScreenRecorder.shared.startRegion() }
                }
            }
        }
        .help("Bildschirmaufnahme starten/stoppen: \(settings.recordHotKey.displayString)")
    }
}
