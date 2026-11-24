import SwiftUI
import AppKit

enum CleanerSection: String, CaseIterable, Identifiable {
    case uninstall, largeFiles, junk
    var id: String { rawValue }
    var title: String {
        switch self {
        case .uninstall: return "Programme entfernen"
        case .largeFiles: return "Große Dateien"
        case .junk: return "Aufräumen"
        }
    }
    var symbol: String {
        switch self {
        case .uninstall: return "trash.square"
        case .largeFiles: return "doc.viewfinder"
        case .junk: return "sparkles"
        }
    }
}

struct CleanerView: View {
    @State private var section: CleanerSection = .uninstall

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $section) {
                    ForEach(CleanerSection.allCases) { s in
                        Label(s.title, systemImage: s.symbol).tag(s)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 520)
            }
            .padding(12)
            Divider()
            switch section {
            case .uninstall: UninstallerView()
            case .largeFiles: LargeFilesView()
            case .junk: JunkView()
            }
        }
        .frame(minWidth: 820, minHeight: 580)
    }
}

// MARK: - Uninstaller

@MainActor
final class UninstallerModel: ObservableObject {
    @Published var apps: [AppEntry] = []
    @Published var sizes: [URL: Int64] = [:]
    @Published var lastUsed: [URL: Date] = [:]
    @Published var selected: AppEntry?
    @Published var leftovers: [FileItem] = []
    @Published var checked: Set<URL> = []
    @Published var scanningLeftovers = false
    @Published var working = false
    @Published var message: String?
    @Published var search = ""
    @Published var showSystem = false

    var visibleApps: [AppEntry] {
        apps.filter { (showSystem || !$0.isSystem) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)) }
    }

    func load() {
        DispatchQueue.global(qos: .userInitiated).async {
            let apps = AppCatalog.shared.apps(maxAge: 0)
            Task { @MainActor in
                self.apps = apps
                self.computeSizes()
            }
        }
    }

    private func computeSizes() {
        let targets = apps.filter { !$0.isSystem && sizes[$0.url] == nil }
        DispatchQueue.global(qos: .utility).async {
            for app in targets {
                let size = Cleaner.size(of: app.url)
                let used = Cleaner.lastUsed(app.url)
                Task { @MainActor in
                    self.sizes[app.url] = size
                    if let used { self.lastUsed[app.url] = used }
                }
            }
        }
    }

    func select(_ app: AppEntry) {
        selected = app
        leftovers = []
        checked = []
        message = nil
        guard !app.isSystem else { return }
        scanningLeftovers = true
        DispatchQueue.global(qos: .userInitiated).async {
            let items = Cleaner.leftovers(for: app)
            Task { @MainActor in
                guard self.selected == app else { return }
                self.leftovers = items
                self.checked = Set(items.map(\.url))
                self.scanningLeftovers = false
            }
        }
    }

    var totalSelected: Int64 {
        (selected.map { sizes[$0.url] ?? 0 } ?? 0) + leftovers.filter { checked.contains($0.url) }.reduce(0) { $0 + $1.size }
    }

    func uninstall(permanently: Bool) {
        guard let app = selected, !app.isSystem else { return }
        let alert = NSAlert()
        alert.messageText = "„\(app.name)“ restlos entfernen?"
        alert.informativeText = "Die App und \(checked.count) zugehörige Dateien/Ordner (\(totalSelected.formattedBytes)) werden \(permanently ? "endgültig gelöscht" : "in den Papierkorb gelegt")."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Entfernen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        working = true
        // Quit the app first.
        for running in NSWorkspace.shared.runningApplications where running.bundleURL?.standardizedFileURL == app.url.standardizedFileURL {
            running.terminate()
        }
        let appItem = FileItem(url: app.url, size: sizes[app.url] ?? 0,
                               needsAdmin: !FileManager.default.isWritableFile(atPath: app.url.deletingLastPathComponent().path))
        let items = [appItem] + leftovers.filter { checked.contains($0.url) }
        DispatchQueue.global(qos: .userInitiated).async {
            Thread.sleep(forTimeInterval: 1.0)
            let firstPass = Cleaner.remove(items.filter { !$0.needsAdmin }, permanently: permanently)
            let adminItems = items.filter(\.needsAdmin).map(\.url) + firstPass.failed
            Task { @MainActor in
                var result = firstPass
                if !adminItems.isEmpty {
                    if Cleaner.adminRemove(adminItems) {
                        result.removed += adminItems
                        result.failed = []
                    }
                }
                self.working = false
                self.message = result.failed.isEmpty
                    ? "✓ \(app.name) wurde entfernt – \(result.freed.formattedBytes) frei."
                    : "\(result.removed.count) entfernt, \(result.failed.count) konnten nicht gelöscht werden."
                if result.failed.isEmpty {
                    self.apps.removeAll { $0 == app }
                    self.selected = nil
                    self.leftovers = []
                    OverlayHUD.shared.show(symbol: "trash.fill", title: "\(app.name) entfernt",
                                           subtitle: "Inklusive aller Reste", tint: .systemGreen)
                }
            }
        }
    }
}

struct UninstallerView: View {
    @StateObject private var model = UninstallerModel()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Programme suchen", text: $model.search).textFieldStyle(.plain)
                }
                .padding(8)
                Toggle("Apple-Apps anzeigen (geschützt)", isOn: $model.showSystem)
                    .font(.caption).padding(.horizontal, 8).padding(.bottom, 6)
                Divider()
                List(model.visibleApps, selection: Binding(
                    get: { model.selected?.url },
                    set: { url in if let app = model.apps.first(where: { $0.url == url }) { model.select(app) } })) { app in
                    HStack(spacing: 8) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(app.name).lineLimit(1)
                            if let used = model.lastUsed[app.url] {
                                Text("Zuletzt: \(used.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        if app.isSystem {
                            Image(systemName: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        } else if let size = model.sizes[app.url] {
                            Text(size.formattedBytes).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                    .tag(app.url)
                }
                .listStyle(.sidebar)
            }
            .frame(minWidth: 280, idealWidth: 300, maxWidth: 360)

            detail
                .frame(minWidth: 440, maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { if model.apps.isEmpty { model.load() } }
    }

    @ViewBuilder
    private var detail: some View {
        if let app = model.selected {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.weight(.semibold))
                        Text(app.bundleID ?? app.url.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        if let size = model.sizes[app.url] {
                            Text("App: \(size.formattedBytes)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if app.isSystem {
                    Label("Diese App gehört zu macOS und ist geschützt.", systemImage: "lock.shield.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                } else {
                    Text("Gefundene Reste").font(.headline)
                    if model.scanningLeftovers {
                        ProgressView("Suche nach Einstellungen, Caches und Hilfsdateien …").controlSize(.small)
                    } else if model.leftovers.isEmpty {
                        Text("Keine weiteren Dateien gefunden – nur die App selbst.").foregroundStyle(.secondary)
                    }
                    List(model.leftovers) { item in
                        HStack {
                            Toggle("", isOn: Binding(
                                get: { model.checked.contains(item.url) },
                                set: { isOn in if isOn { _ = model.checked.insert(item.url) } else { _ = model.checked.remove(item.url) } }))
                                .labelsHidden()
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.name).lineLimit(1)
                                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: Cleaner.home.path, with: "~"))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                            Spacer()
                            if item.needsAdmin {
                                Image(systemName: "key.fill").font(.caption).foregroundStyle(.orange).help("Benötigt Administrator-Passwort")
                            }
                            Text(item.size.formattedBytes).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                                Image(systemName: "magnifyingglass")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .frame(minHeight: 180)

                    if let message = model.message {
                        Text(message).font(.callout).foregroundStyle(message.hasPrefix("✓") ? .green : .orange)
                    }
                    HStack {
                        Text("Gesamt: \(model.totalSelected.formattedBytes)").font(.headline).monospacedDigit()
                        Spacer()
                        if model.working { ProgressView().controlSize(.small) }
                        Button("Endgültig löschen") { model.uninstall(permanently: true) }
                            .disabled(model.working)
                        Button("In den Papierkorb") { model.uninstall(permanently: false) }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .disabled(model.working)
                    }
                }
            }
            .padding(18)
        } else {
            VStack(spacing: 10) {
                Image(systemName: "trash.square").font(.system(size: 54)).foregroundStyle(.tertiary)
                Text("Programm auswählen").font(.title3.weight(.semibold))
                Text("Simplex Suite findet die App und alle Reste: Einstellungen, Caches, Container, Hilfsprogramme und Startobjekte. macOS-Apps sind geschützt.")
                    .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 380)
                if let message = model.message {
                    Text(message).foregroundStyle(.green).padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Large files

@MainActor
final class LargeFilesModel: ObservableObject {
    @Published var root = Cleaner.home
    @Published var minimumMB = 200
    @Published var includeLibrary = false
    @Published var results: [FileItem] = []
    @Published var checked: Set<URL> = []
    @Published var scanning = false
    @Published var scanned = 0
    @Published var message: String?
    private var cancelFlag = CancelFlag()

    final class CancelFlag: @unchecked Sendable { var cancelled = false }

    func scan() {
        cancelFlag.cancelled = true
        let flag = CancelFlag()
        cancelFlag = flag
        scanning = true
        results = []
        checked = []
        scanned = 0
        message = nil
        let root = self.root, min = Int64(minimumMB) * 1_000_000, lib = includeLibrary
        DispatchQueue.global(qos: .userInitiated).async {
            let found = Cleaner.scanLargeFiles(root: root, minimumSize: min, includeLibrary: lib,
                                               progress: { count in Task { @MainActor in self.scanned = count } },
                                               isCancelled: { flag.cancelled })
            Task { @MainActor in
                guard !flag.cancelled || self.cancelFlag === flag else { return }
                self.results = found
                self.scanning = false
            }
        }
    }

    func cancel() {
        cancelFlag.cancelled = true
        scanning = false
    }

    var selectedSize: Int64 { results.filter { checked.contains($0.url) }.reduce(0) { $0 + $1.size } }

    func trashSelected() {
        let items = results.filter { checked.contains($0.url) }
        guard !items.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "\(items.count) Dateien in den Papierkorb legen?"
        alert.informativeText = "Zusammen \(selectedSize.formattedBytes). Du kannst sie aus dem Papierkorb wiederherstellen."
        alert.addButton(withTitle: "In den Papierkorb")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let result = Cleaner.remove(items, permanently: false)
        results.removeAll { result.removed.contains($0.url) }
        checked.subtract(result.removed)
        message = "\(result.removed.count) Dateien entfernt (\(result.freed.formattedBytes))" + (result.failed.isEmpty ? "" : ", \(result.failed.count) fehlgeschlagen")
    }
}

struct LargeFilesView: View {
    @StateObject private var model = LargeFilesModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    panel.directoryURL = model.root
                    if panel.runModal() == .OK, let url = panel.url { model.root = url }
                } label: {
                    Label(model.root.path.replacingOccurrences(of: Cleaner.home.path, with: "~"), systemImage: "folder")
                        .lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: 240)
                Picker("Ab", selection: $model.minimumMB) {
                    Text("100 MB").tag(100)
                    Text("200 MB").tag(200)
                    Text("500 MB").tag(500)
                    Text("1 GB").tag(1000)
                    Text("5 GB").tag(5000)
                }
                .frame(width: 130)
                Toggle("Library einbeziehen", isOn: $model.includeLibrary)
                Spacer()
                if model.scanning {
                    ProgressView().controlSize(.small)
                    Text("\(model.scanned) Dateien geprüft").font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    Button("Stopp") { model.cancel() }
                } else {
                    Button("Scannen") { model.scan() }.buttonStyle(.borderedProminent)
                }
            }
            .padding(12)
            Divider()
            if model.results.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "doc.viewfinder").font(.system(size: 54)).foregroundStyle(.tertiary)
                    Text(model.scanning ? "Suche läuft …" : "Große Dateien finden").font(.title3.weight(.semibold))
                    Text("Scannt den gewählten Ordner (inkl. externer Festplatten) und zeigt die größten Dateien. Gelöscht wird nur, was du auswählst – in den Papierkorb.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.results) {
                    TableColumn("") { item in
                        Toggle("", isOn: Binding(
                            get: { model.checked.contains(item.url) },
                            set: { isOn in if isOn { _ = model.checked.insert(item.url) } else { _ = model.checked.remove(item.url) } }))
                            .labelsHidden()
                    }
                    .width(24)
                    TableColumn("Datei") { item in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: item.url.path)).resizable().frame(width: 18, height: 18)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(item.name).lineLimit(1)
                                Text(item.url.deletingLastPathComponent().path.replacingOccurrences(of: Cleaner.home.path, with: "~"))
                                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }
                    }
                    TableColumn("Größe") { item in
                        Text(item.size.formattedBytes).monospacedDigit()
                    }
                    .width(90)
                    TableColumn("Geändert") { item in
                        Text(item.date?.formatted(date: .abbreviated, time: .omitted) ?? "–").foregroundStyle(.secondary)
                    }
                    .width(100)
                    TableColumn("") { item in
                        Button { NSWorkspace.shared.activateFileViewerSelecting([item.url]) } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                    }
                    .width(28)
                }
            }
            Divider()
            HStack {
                if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("Ausgewählt: \(model.selectedSize.formattedBytes)").monospacedDigit()
                Button("In den Papierkorb") { model.trashSelected() }
                    .buttonStyle(.borderedProminent).tint(.red)
                    .disabled(model.checked.isEmpty)
            }
            .padding(10)
        }
    }
}

// MARK: - Junk

@MainActor
final class JunkModel: ObservableObject {
    @Published var categories: [JunkCategory] = []
    @Published var selected: Set<String> = [JunkCategory.Kind.caches.rawValue, JunkCategory.Kind.logs.rawValue, JunkCategory.Kind.developer.rawValue]
    @Published var scanning = false
    @Published var message: String?

    func scan() {
        scanning = true
        message = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Cleaner.scanJunk()
            Task { @MainActor in
                self.categories = result
                self.scanning = false
            }
        }
    }

    var selectedTotal: Int64 {
        categories.filter { selected.contains($0.id) }.reduce(0) { $0 + $1.total }
    }

    func clean() {
        let chosen = categories.filter { selected.contains($0.id) }
        guard !chosen.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = "\(selectedTotal.formattedBytes) aufräumen?"
        alert.informativeText = chosen.map(\.title).joined(separator: ", ") + ". Caches und Protokolle werden endgültig gelöscht; alte Installer kommen in den Papierkorb. Tipp: Apps vorher beenden."
        alert.addButton(withTitle: "Aufräumen")
        alert.addButton(withTitle: "Abbrechen")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            var freed: Int64 = 0
            var failed = 0
            for category in chosen {
                let result = Cleaner.remove(category.items, permanently: category.deletesPermanently)
                freed += result.freed
                failed += result.failed.count
            }
            let summary = "✓ \(freed.formattedBytes) freigegeben" + (failed > 0 ? " · \(failed) Elemente waren gesperrt (in Benutzung oder geschützt)" : "")
            Task { @MainActor in
                self.message = summary
                OverlayHUD.shared.show(symbol: "sparkles", title: "Aufgeräumt", subtitle: "\(freed.formattedBytes) freigegeben", tint: .systemGreen)
                self.scan()
                self.message = summary
            }
        }
    }
}

struct JunkView: View {
    @StateObject private var model = JunkModel()

    var body: some View {
        VStack(spacing: 0) {
            if model.categories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles").font(.system(size: 54)).foregroundStyle(.tertiary)
                    Text("Mac aufräumen").font(.title3.weight(.semibold))
                    Text("Findet Daten, die gefahrlos gelöscht werden können: Caches, Protokolle, Entwickler-Daten, Papierkorb und alte Installer.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary).frame(maxWidth: 420)
                    if model.scanning { ProgressView() } else {
                        Button("Jetzt analysieren") { model.scan() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(model.categories) { category in
                            HStack(spacing: 14) {
                                Toggle("", isOn: Binding(
                                    get: { model.selected.contains(category.id) },
                                    set: { isOn in if isOn { _ = model.selected.insert(category.id) } else { _ = model.selected.remove(category.id) } }))
                                    .labelsHidden()
                                    .toggleStyle(.checkbox)
                                Image(systemName: category.symbol).font(.title2).foregroundStyle(Color.accentColor).frame(width: 34)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(category.title).font(.headline)
                                    Text(category.detail).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(category.total.formattedBytes).font(.title3.weight(.semibold)).monospacedDigit()
                            }
                            .padding(14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
                        }
                    }
                    .padding(16)
                }
                Divider()
                HStack {
                    if let message = model.message { Text(message).font(.callout).foregroundStyle(.green) }
                    Spacer()
                    Button("Neu analysieren") { model.scan() }.disabled(model.scanning)
                    if model.scanning { ProgressView().controlSize(.small) }
                    Button("\(model.selectedTotal.formattedBytes) aufräumen") { model.clean() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.scanning || model.selectedTotal == 0)
                }
                .padding(12)
            }
        }
    }
}
