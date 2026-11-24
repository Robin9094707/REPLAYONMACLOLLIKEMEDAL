import SwiftUI
import AppKit

@MainActor
enum SuiteActions {
    static func quit(_ usage: ProcessUsage, force: Bool = false) {
        if usage.isApp, let app = NSRunningApplication(processIdentifier: usage.pid) {
            if ProtectedApps.isProtected(bundleID: app.bundleIdentifier) { return NSSound.beep() }
            _ = force ? app.forceTerminate() : app.terminate()
        } else {
            kill(usage.pid, force ? SIGKILL : SIGTERM)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            SystemMonitor.shared.sample()
        }
    }

    /// Quits every regular app except protected ones, exclusions and the frontmost game.
    static func quitAllApps(confirm: Bool = true) {
        let exclusions = Set(SuiteSettings.shared.quitAllExclusions)
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            app.activationPolicy == .regular && !app.isTerminated
                && !ProtectedApps.isProtected(bundleID: app.bundleIdentifier)
                && !exclusions.contains(app.bundleIdentifier ?? "")
        }
        guard !apps.isEmpty else { return NSSound.beep() }
        if confirm {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "\(apps.count) Apps beenden?"
            alert.informativeText = apps.compactMap(\.localizedName).sorted().joined(separator: ", ")
                + "\n\nApps mit ungesicherten Änderungen fragen vorher nach."
            alert.addButton(withTitle: "Alle beenden")
            alert.addButton(withTitle: "Abbrechen")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        apps.forEach { $0.terminate() }
        OverlayHUD.shared.show(symbol: "xmark.circle.fill", title: "\(apps.count) Apps werden beendet",
                               subtitle: nil, tint: .systemRed)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1))
            SystemMonitor.shared.sample()
        }
    }
}

struct TaskManagerView: View {
    @ObservedObject private var monitor = SystemMonitor.shared
    @ObservedObject private var suite = SuiteSettings.shared
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\ProcessUsage.memory, order: .reverse)]
    @State private var selection: pid_t?

    private var rows: [ProcessUsage] {
        monitor.apps
            .filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
            .sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                StatTile(title: "CPU", value: "\(Int(monitor.snapshot.cpuUsage * 100)) %",
                         fraction: monitor.snapshot.cpuUsage, history: monitor.cpuHistory, color: .blue)
                StatTile(title: "Arbeitsspeicher",
                         value: "\(Int64(monitor.snapshot.memoryUsed).formattedBytes) / \(Int64(monitor.snapshot.memoryTotal).formattedBytes)",
                         fraction: monitor.snapshot.memoryFraction, history: monitor.memoryHistory, color: .purple)
                StatTile(title: "Temperatur", value: monitor.snapshot.cpuTemperature.map { "\(Int($0.rounded())) °C" } ?? monitor.snapshot.thermalText,
                         fraction: min(1, (monitor.snapshot.cpuTemperature ?? 40) / 105), history: nil, color: .orange)
            }
            .padding(14)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Suchen", text: $search).textFieldStyle(.plain)
                Toggle("Hintergrundprozesse", isOn: $suite.taskManagerShowBackground)
                    .onChange(of: suite.taskManagerShowBackground) { _, _ in monitor.sample() }
                Spacer()
                Text("\(monitor.apps.filter(\.isApp).count) Apps").foregroundStyle(.secondary).font(.caption)
                Button(role: .destructive) { SuiteActions.quitAllApps() } label: {
                    Label("Alle Apps beenden", systemImage: "xmark.circle")
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)

            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.name) { usage in
                    HStack(spacing: 8) {
                        if let icon = usage.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        } else {
                            Image(systemName: "gearshape").frame(width: 18, height: 18).foregroundStyle(.secondary)
                        }
                        Text(usage.name).lineLimit(1)
                        if usage.processCount > 1 {
                            Text("\(usage.processCount)").font(.caption2).padding(.horizontal, 5)
                                .background(Capsule().fill(Color.secondary.opacity(0.2)))
                                .help("\(usage.processCount) Prozesse")
                        }
                    }
                }
                TableColumn("CPU", value: \.cpu) { usage in
                    Text(String(format: "%.1f %%", usage.cpu)).monospacedDigit()
                        .foregroundStyle(usage.cpu > 80 ? Color.red : (usage.cpu > 25 ? Color.orange : Color.primary))
                }
                .width(80)
                TableColumn("Speicher", value: \.memory) { usage in
                    Text(Int64(usage.memory).formattedBytes).monospacedDigit()
                }
                .width(100)
                TableColumn("PID", value: \.pid) { usage in
                    Text("\(usage.pid)").monospacedDigit().foregroundStyle(.secondary)
                }
                .width(60)
                TableColumn("") { usage in
                    HStack(spacing: 4) {
                        Button { SuiteActions.quit(usage) } label: { Image(systemName: "xmark.circle") }
                            .help("Beenden")
                        Button { SuiteActions.quit(usage, force: true) } label: { Image(systemName: "bolt.circle") }
                            .help("Sofort beenden")
                    }
                    .buttonStyle(.borderless)
                }
                .width(56)
            }
            .contextMenu(forSelectionType: pid_t.self) { pids in
                if let pid = pids.first, let usage = monitor.apps.first(where: { $0.pid == pid }) {
                    Button("Beenden") { SuiteActions.quit(usage) }
                    Button("Sofort beenden") { SuiteActions.quit(usage, force: true) }
                    if usage.isApp, let url = NSRunningApplication(processIdentifier: pid)?.bundleURL {
                        Divider()
                        Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear { monitor.acquire("taskmanager", perApp: true) }
        .onDisappear { monitor.release("taskmanager") }
    }
}

// MARK: - Stat tile with sparkline

struct StatTile: View {
    let title: String
    let value: String
    let fraction: Double
    let history: [Double]?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded)).monospacedDigit().lineLimit(1)
                .minimumScaleFactor(0.7)
            if let history {
                Sparkline(values: history, color: color).frame(height: 30)
            } else {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.15))
                        Capsule().fill(LinearGradient(colors: [color.opacity(0.7), color], startPoint: .leading, endPoint: .trailing))
                            .frame(width: geo.size.width * max(0.02, min(1, fraction)))
                    }
                }
                .frame(height: 8)
                .padding(.vertical, 11)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.secondary.opacity(0.08)))
    }
}

struct Sparkline: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = values.enumerated().map { index, value in
                CGPoint(x: geo.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                        y: geo.size.height * (1 - CGFloat(min(max(value, 0), 1))))
            }
            ZStack {
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: first.x, y: geo.size.height))
                    points.forEach { path.addLine(to: $0) }
                    path.addLine(to: CGPoint(x: points.last?.x ?? 0, y: geo.size.height))
                    path.closeSubpath()
                }
                .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: first)
                    points.dropFirst().forEach { path.addLine(to: $0) }
                }
                .stroke(color, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
            }
        }
    }
}
