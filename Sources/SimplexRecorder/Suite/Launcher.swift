import AppKit
import SwiftUI

// MARK: - App catalog (shared by launcher and uninstaller)

struct AppEntry: Identifiable, Hashable {
    let url: URL
    let name: String
    let bundleID: String?
    var id: URL { url }
    var isSystem: Bool { ProtectedApps.isSystemApp(bundleID: bundleID, path: url.path) }
}

/// All installed apps, scanned in the background and cached.
final class AppCatalog: @unchecked Sendable {
    static let shared = AppCatalog()
    private let lock = NSLock()
    private var cached: [AppEntry] = []
    private var lastScan = Date.distantPast

    static let searchRoots: [URL] = {
        var roots = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        ]
        roots.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        return roots
    }()

    func apps(maxAge: TimeInterval = 60) -> [AppEntry] {
        lock.lock()
        let fresh = Date().timeIntervalSince(lastScan) < maxAge && !cached.isEmpty
        let current = cached
        lock.unlock()
        if fresh { return current }
        let scanned = Self.scan()
        lock.lock()
        cached = scanned
        lastScan = Date()
        lock.unlock()
        return scanned
    }

    private static func scan() -> [AppEntry] {
        let fm = FileManager.default
        var seen = Set<String>()
        var result: [AppEntry] = []
        func add(_ url: URL) {
            let path = url.resolvingSymlinksInPath().path
            guard !seen.contains(path) else { return }
            seen.insert(path)
            let bundle = Bundle(url: url)
            let name = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? fm.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            result.append(AppEntry(url: url, name: name, bundleID: bundle?.bundleIdentifier))
        }
        for root in searchRoots {
            guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                          options: [.skipsHiddenFiles]) else { continue }
            for item in items {
                if item.pathExtension == "app" {
                    add(item)
                } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                          root.path == "/Applications" || root.lastPathComponent == "Applications" {
                    // One level of sub folders (e.g. "/Applications/Adobe Photoshop 2025/…").
                    let inner = (try? fm.contentsOfDirectory(at: item, includingPropertiesForKeys: nil,
                                                             options: [.skipsHiddenFiles])) ?? []
                    inner.filter { $0.pathExtension == "app" }.forEach(add)
                }
            }
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Launcher panel

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Start-menu-like launcher: search field, open apps first, all apps as a grid.
/// Opened by tapping the Windows key (left ⌘) or from the dashboard.
@MainActor
final class LauncherPanel: NSObject, NSWindowDelegate {
    static let shared = LauncherPanel()

    private var panel: KeyablePanel?
    private let model = LauncherModel()

    func toggle() {
        if let panel, panel.isVisible { hide() } else { show() }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.reload()
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        if let frame = screen?.visibleFrame {
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2 + 60))
        }
        panel.alphaValue = 0
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.16
            panel.animator().alphaValue = 1
        }
        model.focusToken += 1
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in panel.orderOut(nil) }
        })
    }

    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func makePanel() -> KeyablePanel {
        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .modalPanel
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = true
        panel.isMovableByWindowBackground = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        let view = LauncherView(model: model) { [weak self] in self?.hide() }
        panel.contentView = NSHostingView(rootView: view)
        return panel
    }
}

@MainActor
final class LauncherModel: ObservableObject {
    @Published var query = ""
    @Published var apps: [AppEntry] = []
    @Published var running: [NSRunningApplication] = []
    @Published var selection = 0
    @Published var focusToken = 0

    func reload() {
        query = ""
        selection = 0
        running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AppCatalog.shared.apps()
            Task { @MainActor in self.apps = apps }
        }
    }

    var results: [AppEntry] {
        guard !query.isEmpty else { return apps }
        let q = query.lowercased()
        return apps
            .filter { $0.name.lowercased().contains(q) || ($0.bundleID?.lowercased().contains(q) ?? false) }
            .sorted { a, b in
                let ap = a.name.lowercased().hasPrefix(q), bp = b.name.lowercased().hasPrefix(q)
                if ap != bp { return ap }
                return a.name.count < b.name.count
            }
    }

    func isRunning(_ entry: AppEntry) -> Bool {
        running.contains { $0.bundleURL?.standardizedFileURL == entry.url.standardizedFileURL }
    }

    func open(_ entry: AppEntry) {
        NSWorkspace.shared.openApplication(at: entry.url, configuration: NSWorkspace.OpenConfiguration())
    }
}

struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    let close: () -> Void
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.adaptive(minimum: 96, maximum: 110), spacing: 8)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 18, weight: .medium)).foregroundStyle(.secondary)
                TextField("Apps suchen …", text: $model.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20))
                    .focused($searchFocused)
                    .onSubmit(openSelection)
                if !model.query.isEmpty {
                    Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if model.query.isEmpty && !model.running.isEmpty {
                        Text("Geöffnet").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: 8) {
                            ForEach(model.running, id: \.processIdentifier) { app in
                                LauncherTile(icon: app.icon, name: app.localizedName ?? "App", running: true,
                                             selected: false) {
                                    app.activate()
                                    close()
                                }
                                .contextMenu {
                                    Button("Beenden") { app.terminate() }
                                    Button("Sofort beenden") { app.forceTerminate() }
                                }
                            }
                        }
                        Text("Alle Apps").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    let results = model.results
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(Array(results.enumerated()), id: \.element.id) { index, entry in
                            LauncherTile(icon: NSWorkspace.shared.icon(forFile: entry.url.path), name: entry.name,
                                         running: model.isRunning(entry), selected: index == model.selection && !model.query.isEmpty) {
                                model.open(entry)
                                close()
                            }
                            .contextMenu {
                                Button("Im Finder zeigen") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                            }
                        }
                    }
                    if results.isEmpty {
                        Text("Keine App gefunden").foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 720, height: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(.white.opacity(0.12)))
        .onChange(of: model.query) { _, _ in model.selection = 0 }
        .onChange(of: model.focusToken) { _, _ in searchFocused = true }
        .onAppear { searchFocused = true }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.downArrow) { move(4); return .handled }
        .onKeyPress(.upArrow) { move(-4); return .handled }
        .onKeyPress(.rightArrow) { move(1); return .handled }
        .onKeyPress(.leftArrow) { move(-1); return .handled }
    }

    private func move(_ delta: Int) {
        let count = model.results.count
        guard count > 0 else { return }
        model.selection = min(max(0, model.selection + delta), count - 1)
    }

    private func openSelection() {
        let results = model.results
        guard !results.isEmpty else { return }
        model.open(results[min(model.selection, results.count - 1)])
        close()
    }
}

struct LauncherTile: View {
    let icon: NSImage?
    let name: String
    let running: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Group {
                    if let icon { Image(nsImage: icon).resizable() } else { Image(systemName: "app").resizable() }
                }
                .frame(width: 52, height: 52)
                .scaleEffect(hovering ? 1.08 : 1)
                Text(name).font(.system(size: 11)).lineLimit(2).multilineTextAlignment(.center)
                Circle().fill(running ? Color.accentColor : Color.clear).frame(width: 4, height: 4)
            }
            .frame(maxWidth: .infinity, minHeight: 100)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.3) : (hovering ? Color.primary.opacity(0.08) : .clear))
            )
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
    }
}
