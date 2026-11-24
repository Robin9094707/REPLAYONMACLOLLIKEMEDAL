import AppKit

struct FileItem: Identifiable, Hashable {
    let url: URL
    var size: Int64
    var date: Date?
    var needsAdmin = false
    var id: URL { url }
    var name: String { url.lastPathComponent }
}

struct JunkCategory: Identifiable {
    enum Kind: String, CaseIterable { case caches, logs, developer, trash, installers }
    let kind: Kind
    var items: [FileItem]
    var id: String { kind.rawValue }
    var total: Int64 { items.reduce(0) { $0 + $1.size } }

    var title: String {
        switch kind {
        case .caches: return "App-Caches"
        case .logs: return "Protokolldateien"
        case .developer: return "Xcode- & Entwickler-Daten"
        case .trash: return "Papierkorb"
        case .installers: return "Alte Installer in Downloads"
        }
    }

    var detail: String {
        switch kind {
        case .caches: return "Zwischenspeicher von Apps – werden bei Bedarf neu erstellt."
        case .logs: return "Alte Protokolle von Apps und Diensten."
        case .developer: return "DerivedData, Geräte-Support-Dateien, Simulator-Caches."
        case .trash: return "Dateien im Papierkorb endgültig löschen."
        case .installers: return ".dmg/.pkg/.zip/.iso, älter als 14 Tage."
        }
    }

    var symbol: String {
        switch kind {
        case .caches: return "internaldrive"
        case .logs: return "doc.text"
        case .developer: return "hammer"
        case .trash: return "trash"
        case .installers: return "shippingbox"
        }
    }

    /// Installers go to the trash; everything else is regenerated and deleted for real.
    var deletesPermanently: Bool { kind != .installers }
}

enum Cleaner {
    static let home = FileManager.default.homeDirectoryForCurrentUser

    // MARK: Sizes

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .isRegularFileKey]
        if !isDir.boolValue {
            let v = try? url.resourceValues(forKeys: keys)
            return Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        if let e = fm.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in true }) {
            for case let file as URL in e {
                let v = try? file.resourceValues(forKeys: keys)
                if v?.isRegularFile == true { total += Int64(v?.totalFileAllocatedSize ?? v?.fileAllocatedSize ?? 0) }
            }
        }
        return total
    }

    private static func children(_ url: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [])) ?? []
    }

    // MARK: Junk

    static func scanJunk() -> [JunkCategory] {
        let lib = home.appendingPathComponent("Library")
        var result: [JunkCategory] = []

        func items(_ urls: [URL]) -> [FileItem] {
            urls.map { FileItem(url: $0, size: size(of: $0)) }.filter { $0.size > 0 }.sorted { $0.size > $1.size }
        }

        result.append(JunkCategory(kind: .caches, items: items(children(lib.appendingPathComponent("Caches")))))
        result.append(JunkCategory(kind: .logs, items: items(children(lib.appendingPathComponent("Logs")))))

        let dev = lib.appendingPathComponent("Developer")
        let devURLs = children(dev.appendingPathComponent("Xcode/DerivedData"))
            + children(dev.appendingPathComponent("Xcode/iOS DeviceSupport"))
            + children(dev.appendingPathComponent("Xcode/watchOS DeviceSupport"))
            + [dev.appendingPathComponent("CoreSimulator/Caches")]
        result.append(JunkCategory(kind: .developer, items: items(devURLs)))

        result.append(JunkCategory(kind: .trash, items: items(children(home.appendingPathComponent(".Trash")))))

        let cutoff = Date().addingTimeInterval(-14 * 24 * 3600)
        let installers = children(home.appendingPathComponent("Downloads")).filter { url in
            guard ["dmg", "pkg", "zip", "iso", "xip", "mpkg"].contains(url.pathExtension.lowercased()) else { return false }
            let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? Date()
            return date < cutoff
        }
        result.append(JunkCategory(kind: .installers, items: items(installers)))
        return result
    }

    // MARK: Large files

    static func scanLargeFiles(root: URL, minimumSize: Int64, includeLibrary: Bool,
                               progress: @escaping (Int) -> Void, isCancelled: () -> Bool) -> [FileItem] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileSizeKey, .contentModificationDateKey]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                     options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                     errorHandler: { _, _ in true }) else { return [] }
        let library = home.appendingPathComponent("Library").path
        var found: [FileItem] = []
        var count = 0
        for case let url as URL in e {
            if isCancelled() { break }
            count += 1
            if count % 2000 == 0 { progress(count) }
            if !includeLibrary, url.path.hasPrefix(library) {
                e.skipDescendants()
                continue
            }
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
            if size >= minimumSize {
                found.append(FileItem(url: url, size: size, date: v.contentModificationDate))
            }
        }
        progress(count)
        return Array(found.sorted { $0.size > $1.size }.prefix(500))
    }

    // MARK: App leftovers

    private static let userLibraryFolders = [
        "Application Support", "Caches", "Preferences", "Preferences/ByHost", "Logs", "Saved Application State",
        "Containers", "Group Containers", "HTTPStorages", "WebKit", "Cookies", "LaunchAgents",
        "Application Scripts", "Internet Plug-Ins", "Logs/DiagnosticReports",
    ]
    private static let systemLibraryFolders = [
        "Application Support", "Caches", "Preferences", "LaunchAgents", "LaunchDaemons",
        "PrivilegedHelperTools", "Logs", "Internet Plug-Ins",
    ]

    /// Everything an app left behind besides its bundle. Only exact/bundle-ID matches.
    static func leftovers(for app: AppEntry) -> [FileItem] {
        guard !app.isSystem else { return [] }
        let bundleID = app.bundleID?.lowercased() ?? ""
        let names = Set([app.name.lowercased(), app.name.lowercased().replacingOccurrences(of: " ", with: ""),
                         app.url.deletingPathExtension().lastPathComponent.lowercased()]).filter { $0.count >= 4 }

        func matches(_ child: URL) -> Bool {
            let n = child.lastPathComponent.lowercased()
            if bundleID.count >= 6, n.contains(bundleID) { return true }
            let base = (n as NSString).deletingPathExtension
            return names.contains(n) || names.contains(base)
        }

        var result: [FileItem] = []
        let userLib = home.appendingPathComponent("Library")
        for folder in userLibraryFolders {
            for child in children(userLib.appendingPathComponent(folder)) where matches(child) {
                result.append(FileItem(url: child, size: size(of: child)))
            }
        }
        let sysLib = URL(fileURLWithPath: "/Library")
        for folder in systemLibraryFolders {
            for child in children(sysLib.appendingPathComponent(folder)) where matches(child) {
                let writable = FileManager.default.isWritableFile(atPath: child.deletingLastPathComponent().path)
                result.append(FileItem(url: child, size: size(of: child), needsAdmin: !writable))
            }
        }
        return result.sorted { $0.size > $1.size }
    }

    // MARK: Removal

    struct RemovalResult {
        var removed: [URL] = []
        var failed: [URL] = []
        var freed: Int64 = 0
    }

    /// Removes files. Never touches anything outside the user's home, /Applications or /Library.
    static func remove(_ items: [FileItem], permanently: Bool) -> RemovalResult {
        var result = RemovalResult()
        let fm = FileManager.default
        for item in items {
            guard isSafeToDelete(item.url) else { result.failed.append(item.url); continue }
            if item.url.path.contains("/LaunchAgents/") {
                _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())", item.url.path])
            }
            do {
                if permanently {
                    try fm.removeItem(at: item.url)
                } else {
                    try fm.trashItem(at: item.url, resultingItemURL: nil)
                }
                result.removed.append(item.url)
                result.freed += item.size
            } catch {
                result.failed.append(item.url)
            }
        }
        return result
    }

    /// Removes the given paths with an administrator password prompt (for root-owned files).
    static func adminRemove(_ urls: [URL]) -> Bool {
        let safe = urls.filter(isSafeToDelete)
        guard !safe.isEmpty else { return false }
        let quoted = safe.map { "'" + $0.path.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let command = "rm -rf \(quoted)"
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "do shell script \"\(escaped)\" with administrator privileges"
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil
    }

    static func isSafeToDelete(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let homePath = home.path
        if path.hasPrefix("/System") || path == "/" || path == homePath { return false }
        let forbidden = ["/Library", "/Applications", homePath + "/Library", homePath + "/Documents",
                         homePath + "/Desktop", homePath + "/Downloads", homePath + "/Library/Application Support"]
        if forbidden.contains(path) { return false }
        return path.hasPrefix(homePath + "/") || path.hasPrefix("/Applications/") || path.hasPrefix("/Library/")
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return -1 }
        p.waitUntilExit()
        return p.terminationStatus
    }

    static func lastUsed(_ url: URL) -> Date? {
        NSMetadataItem(url: url)?.value(forAttribute: "kMDItemLastUsedDate") as? Date
    }
}
