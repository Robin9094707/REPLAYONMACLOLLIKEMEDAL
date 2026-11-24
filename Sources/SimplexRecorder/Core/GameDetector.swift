import AppKit
import CoreGraphics

struct DetectedGame: Equatable, Identifiable {
    let pid: pid_t
    let name: String
    let bundleID: String?
    /// Size (points) of the largest window – window captures adapt their crop to it.
    let windowSize: CGSize
    /// CGWindowID of the game's main (largest) window, 0 if unknown.
    let windowID: UInt32
    var id: pid_t { pid }
}

struct RunningAppInfo: Identifiable {
    let pid: pid_t
    let name: String
    let ruleKey: String
    let icon: NSImage?
    /// Why this app counts as a game (nil = not a game).
    let detection: String?
    var id: pid_t { pid }
    var isGame: Bool { detection != nil }
}

/// Watches running apps and decides whether a game is running.
/// Cheap: one CGWindowList query every few seconds plus workspace notifications.
@MainActor
final class GameDetector: ObservableObject {
    @Published private(set) var currentGame: DetectedGame?
    @Published private(set) var runningApps: [RunningAppInfo] = []

    private let settings: AppSettings
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var categoryCache: [String: Bool] = [:]
    private var missedScans = 0
    private var lastAppsSignature = ""

    // Launchers / stores – never recorded themselves.
    private static let ignoredBundleIDs: Set<String> = [
        "com.mojang.minecraftlauncher",
        "com.valvesoftware.steam",
        "com.valvesoftware.steam.helper",
        "com.epicgames.EpicGamesLauncher",
        "com.blizzard.bna",
        "net.battle.app",
        "com.riotgames.RiotGames.RiotClient",
        "com.riotgames.leagueoflegends",
        "org.prismlauncher.PrismLauncher",
        "com.modrinth.theseus",
        "com.overwolf.curseforge",
        "com.gog.galaxy",
        "com.ea.app",
        "com.ubisoft.connect",
        "com.discordapp.Discord",
        "com.hnc.Discord",
        "com.obsproject.obs-studio",
    ]

    private static let knownGameBundleIDs: Set<String> = [
        "com.riotgames.LeagueofLegends.GameClient",
        "com.roblox.RobloxPlayer",
        "com.blizzard.worldofwarcraft",
        "com.blizzard.starcraft2",
        "com.blizzard.hearthstone",
        "com.blizzard.diablo3",
        "com.blizzard.diablo4",
        "com.apple.Chess",
        "com.innersloth.amongus",
        "com.mojang.minecraftpe",
        "net.minecraft.bedrock",
    ]

    private static let gameBundlePrefixes = [
        "unity.", "com.feralinteractive.", "com.aspyr.", "com.valvesoftware.",
        "com.blizzard.", "com.ea.", "com.capcom.", "com.ubisoft.", "com.paradoxinteractive.",
        "com.larian.", "com.coffeestain.", "com.mihoyo.", "com.hoyoverse.",
    ]

    init(settings: AppSettings) {
        self.settings = settings
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        let names: [Notification.Name] = [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
        ]
        for name in names {
            let token = nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scan() }
            }
            observers.append(token)
        }
        let timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.scan() }
        }
        timer.tolerance = 1
        self.timer = timer
        scan()
    }

    // MARK: Scanning

    private struct WindowSummary {
        var largestSize: CGSize = .zero
        var largestID: UInt32 = 0
        var titles: [String] = []
        var hasGameSizedWindow: Bool { largestSize.width >= 320 && largestSize.height >= 240 }
    }

    func scan() {
        let windows = Self.collectWindows()
        let me = ProcessInfo.processInfo.processIdentifier
        var games: [DetectedGame] = []
        var apps: [RunningAppInfo] = []

        for app in NSWorkspace.shared.runningApplications {
            let pid = app.processIdentifier
            guard pid != me, !app.isTerminated else { continue }
            let summary = windows[pid]
            let detection = classify(app, summary: summary)
            let name = displayName(for: app, detection: detection)

            if app.activationPolicy == .regular {
                apps.append(RunningAppInfo(pid: pid, name: app.localizedName ?? name,
                                           ruleKey: Self.ruleKey(for: app), icon: app.icon,
                                           detection: detection))
            }
            if detection != nil {
                games.append(DetectedGame(pid: pid, name: name, bundleID: app.bundleIdentifier,
                                          windowSize: Self.rounded(summary?.largestSize ?? .zero),
                                          windowID: summary?.largestID ?? 0))
            }
        }

        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let chosen = games.first(where: { $0.pid == front })
            ?? games.first(where: { $0.pid == currentGame?.pid })
            ?? games.max(by: { $0.windowSize.width * $0.windowSize.height < $1.windowSize.width * $1.windowSize.height })

        if let chosen {
            missedScans = 0
            if chosen != currentGame { currentGame = chosen }
        } else if let current = currentGame {
            missedScans += 1
            let stillAlive = NSRunningApplication(processIdentifier: current.pid).map { !$0.isTerminated } ?? false
            if missedScans >= 2 || !stillAlive {
                currentGame = nil
                missedScans = 0
            }
        }

        apps.sort { lhs, rhs in
            if lhs.isGame != rhs.isGame { return lhs.isGame }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
        let signature = apps.map { "\($0.pid):\($0.detection ?? "-")" }.joined(separator: "|")
        if signature != lastAppsSignature {
            lastAppsSignature = signature
            runningApps = apps
        }
    }

    // MARK: Classification

    static func ruleKey(for app: NSRunningApplication) -> String {
        app.bundleIdentifier ?? app.executableURL?.lastPathComponent ?? app.localizedName ?? "pid-\(app.processIdentifier)"
    }

    private func classify(_ app: NSRunningApplication, summary: WindowSummary?) -> String? {
        let key = Self.ruleKey(for: app)
        if settings.excludedApps.contains(key) { return nil }
        if settings.includedApps.contains(key) { return "Manuell als Spiel markiert" }

        guard let summary, summary.hasGameSizedWindow else { return nil }

        let bundleID = app.bundleIdentifier ?? ""
        if Self.ignoredBundleIDs.contains(bundleID) { return nil }

        // Minecraft Java Edition runs inside a plain `java` process.
        if isJavaLike(app),
           summary.titles.contains(where: { $0.localizedCaseInsensitiveContains("minecraft") }),
           !bundleID.localizedCaseInsensitiveContains("launcher") {
            return "Minecraft Java Edition"
        }

        if bundleID.hasPrefix("com.apple.") {
            return Self.knownGameBundleIDs.contains(bundleID) ? "Bekanntes Spiel" : nil
        }
        if Self.knownGameBundleIDs.contains(bundleID) { return "Bekanntes Spiel" }
        if Self.gameBundlePrefixes.contains(where: { bundleID.hasPrefix($0) }) { return "Spiele-Engine / Publisher erkannt" }

        let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
        if path.contains("/steamapps/common/") { return "Steam-Spiel" }
        if path.contains("/Epic Games/") { return "Epic-Games-Spiel" }
        if path.localizedCaseInsensitiveContains("/CrossOver/") || path.localizedCaseInsensitiveContains("/Whisky/") {
            return nil
        }

        if isGameCategory(app) { return "App-Kategorie „Spiele“" }
        return nil
    }

    private func isJavaLike(_ app: NSRunningApplication) -> Bool {
        let exe = app.executableURL?.lastPathComponent.lowercased() ?? ""
        let name = app.localizedName?.lowercased() ?? ""
        let bundle = app.bundleIdentifier?.lowercased() ?? ""
        return exe == "java" || exe == "javaw" || name == "java" || name.hasPrefix("minecraft")
            || bundle.contains("java") || bundle.contains("openjdk") || app.bundleIdentifier == nil
    }

    private func isGameCategory(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let cached = categoryCache[url.path] { return cached }
        let category = Bundle(url: url)?.object(forInfoDictionaryKey: "LSApplicationCategoryType") as? String ?? ""
        let result = category.contains("games")
        categoryCache[url.path] = result
        return result
    }

    private func displayName(for app: NSRunningApplication, detection: String?) -> String {
        if detection == "Minecraft Java Edition" { return "Minecraft" }
        return app.localizedName ?? app.executableURL?.lastPathComponent ?? "Spiel"
    }

    private static func rounded(_ size: CGSize) -> CGSize {
        CGSize(width: (size.width / 8).rounded() * 8, height: (size.height / 8).rounded() * 8)
    }

    private static func collectWindows() -> [pid_t: WindowSummary] {
        guard let list = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [pid_t: WindowSummary] = [:]
        for window in list {
            guard let pidNumber = window[kCGWindowOwnerPID as String] as? Int,
                  let layer = window[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            let pid = pid_t(pidNumber)
            var summary = result[pid] ?? WindowSummary()
            if let boundsDict = window[kCGWindowBounds as String] as? NSDictionary,
               let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
               rect.width * rect.height > summary.largestSize.width * summary.largestSize.height {
                summary.largestSize = rect.size
                summary.largestID = (window[kCGWindowNumber as String] as? UInt32)
                    ?? UInt32(truncatingIfNeeded: (window[kCGWindowNumber as String] as? Int) ?? 0)
            }
            if let title = window[kCGWindowName as String] as? String, !title.isEmpty {
                summary.titles.append(title)
            }
            result[pid] = summary
        }
        return result
    }
}
