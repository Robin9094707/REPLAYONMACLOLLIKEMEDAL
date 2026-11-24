import Foundation
import AppKit

enum WindowAssistScope: String, CaseIterable, Identifiable {
    case games, allApps
    var id: String { rawValue }
    var title: String {
        switch self {
        case .games: return "Nur für Spiele"
        case .allApps: return "Für alle Programme"
        }
    }
}

enum LauncherTrigger: String, CaseIterable, Identifiable {
    case leftCommand, rightCommand, leftOption, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .leftCommand: return "Linke ⌘-Taste antippen (Windows-Taste)"
        case .rightCommand: return "Rechte ⌘-Taste antippen"
        case .leftOption: return "Linke ⌥-Taste antippen (Alt)"
        case .off: return "Aus"
        }
    }
    /// Virtual key code of the modifier key.
    var keyCode: Int64? {
        switch self {
        case .leftCommand: return 55
        case .rightCommand: return 54
        case .leftOption: return 58
        case .off: return nil
        }
    }
}

/// Settings of the "Suite" tools (separate from the recorder settings).
@MainActor
final class SuiteSettings: ObservableObject {
    static let shared = SuiteSettings()
    private let d = UserDefaults.standard

    static let defaultCloseExclusions = [
        "com.apple.finder", "com.apple.Music", "com.spotify.client", "com.apple.Podcasts",
        "com.apple.systempreferences", "com.apple.ActivityMonitor",
    ]
    static let defaultRemapExclusions = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty",
        "io.alacritty", "com.mitchellh.ghostty", "com.parallels.desktop.console", "com.utmapp.UTM",
        "com.microsoft.rdc.macos", "com.vmware.fusion", "com.citrix.receiver.icaviewer.mac",
    ]

    @Published var statsInMenuBar: Bool { didSet { d.set(statsInMenuBar, forKey: "suite.statsInMenuBar") } }
    @Published var menuBarShowCPU: Bool { didSet { d.set(menuBarShowCPU, forKey: "suite.mbCPU") } }
    @Published var menuBarShowTemp: Bool { didSet { d.set(menuBarShowTemp, forKey: "suite.mbTemp") } }
    @Published var menuBarShowRAM: Bool { didSet { d.set(menuBarShowRAM, forKey: "suite.mbRAM") } }

    @Published var closeQuitsApps: Bool { didSet { d.set(closeQuitsApps, forKey: "suite.closeQuits") } }
    @Published var closeExclusions: [String] { didSet { d.set(closeExclusions, forKey: "suite.closeExclusions") } }

    @Published var windowAssistScope: WindowAssistScope { didSet { d.set(windowAssistScope.rawValue, forKey: "suite.windowScope") } }
    @Published var dockPreviews: Bool { didSet { d.set(dockPreviews, forKey: "suite.dockPreviews") } }

    @Published var windowsKeyboard: Bool { didSet { d.set(windowsKeyboard, forKey: "suite.winKeyboard") } }
    @Published var windowsNavigationKeys: Bool { didSet { d.set(windowsNavigationKeys, forKey: "suite.winNavKeys") } }
    @Published var remapDisabledInGames: Bool { didSet { d.set(remapDisabledInGames, forKey: "suite.remapNoGames") } }
    @Published var remapExclusions: [String] { didSet { d.set(remapExclusions, forKey: "suite.remapExclusions") } }
    @Published var launcherTrigger: LauncherTrigger { didSet { d.set(launcherTrigger.rawValue, forKey: "suite.launcherTrigger") } }

    @Published var taskManagerShowBackground: Bool { didSet { d.set(taskManagerShowBackground, forKey: "suite.tmBackground") } }
    @Published var quitAllExclusions: [String] { didSet { d.set(quitAllExclusions, forKey: "suite.quitAllExclusions") } }

    private init() {
        let d = UserDefaults.standard
        d.register(defaults: [
            "suite.statsInMenuBar": false,
            "suite.mbCPU": true,
            "suite.mbTemp": true,
            "suite.mbRAM": false,
            "suite.closeQuits": true,
            "suite.windowScope": WindowAssistScope.games.rawValue,
            "suite.dockPreviews": true,
            "suite.winKeyboard": true,
            "suite.winNavKeys": true,
            "suite.remapNoGames": true,
            "suite.launcherTrigger": LauncherTrigger.leftCommand.rawValue,
            "suite.tmBackground": false,
        ])
        statsInMenuBar = d.bool(forKey: "suite.statsInMenuBar")
        menuBarShowCPU = d.bool(forKey: "suite.mbCPU")
        menuBarShowTemp = d.bool(forKey: "suite.mbTemp")
        menuBarShowRAM = d.bool(forKey: "suite.mbRAM")
        closeQuitsApps = d.bool(forKey: "suite.closeQuits")
        closeExclusions = d.stringArray(forKey: "suite.closeExclusions") ?? SuiteSettings.defaultCloseExclusions
        windowAssistScope = WindowAssistScope(rawValue: d.string(forKey: "suite.windowScope") ?? "") ?? .games
        dockPreviews = d.bool(forKey: "suite.dockPreviews")
        windowsKeyboard = d.bool(forKey: "suite.winKeyboard")
        windowsNavigationKeys = d.bool(forKey: "suite.winNavKeys")
        remapDisabledInGames = d.bool(forKey: "suite.remapNoGames")
        remapExclusions = d.stringArray(forKey: "suite.remapExclusions") ?? SuiteSettings.defaultRemapExclusions
        launcherTrigger = LauncherTrigger(rawValue: d.string(forKey: "suite.launcherTrigger") ?? "") ?? .leftCommand
        taskManagerShowBackground = d.bool(forKey: "suite.tmBackground")
        quitAllExclusions = d.stringArray(forKey: "suite.quitAllExclusions") ?? ["com.apple.finder"]
    }
}

/// Apps that must never be quit/uninstalled by the suite's bulk actions.
enum ProtectedApps {
    static func isProtected(bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        if bundleID == Bundle.main.bundleIdentifier { return true }
        return bundleID == "com.apple.finder" || bundleID == "com.apple.dock"
            || bundleID == "com.apple.loginwindow" || bundleID == "com.apple.WindowManager"
            || bundleID == "com.apple.controlcenter" || bundleID == "com.apple.systemuiserver"
    }

    static func isSystemApp(bundleID: String?, path: String) -> Bool {
        if path.hasPrefix("/System/") { return true }
        if let bundleID, bundleID.hasPrefix("com.apple.") { return true }
        return false
    }
}
