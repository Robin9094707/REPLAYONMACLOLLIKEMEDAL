import AppKit
import Combine

/// Wires the suite modules to their settings and keeps them in sync.
@MainActor
final class SuiteCoordinator {
    static let shared = SuiteCoordinator()
    private var cancellables = Set<AnyCancellable>()
    private var observers: [NSObjectProtocol] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        let suite = SuiteSettings.shared

        suite.objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.apply() }
            .store(in: &cancellables)

        AppState.shared.detector.$currentGame
            .removeDuplicates()
            .sink { [weak self] _ in self?.updateFrontmost() }
            .store(in: &cancellables)

        let token = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in SuiteCoordinator.shared.updateFrontmost() }
        }
        observers.append(token)

        // Accessibility may be granted later – re-check every few seconds while missing.
        Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
            Task { @MainActor in
                let coordinator = SuiteCoordinator.shared
                if AXIsProcessTrusted() != coordinator.lastTrusted { coordinator.apply() }
            }
        }
        apply()
    }

    private(set) var lastTrusted = false

    func apply() {
        let suite = SuiteSettings.shared
        lastTrusted = AXIsProcessTrusted()

        var config = KeyboardRemapper.Config()
        config.remap = suite.windowsKeyboard
        config.navigation = suite.windowsNavigationKeys
        config.disableInGames = suite.remapDisabledInGames
        config.exclusions = Set(suite.remapExclusions)
        config.launcherKey = suite.launcherTrigger.keyCode
        KeyboardRemapper.shared.config = config
        KeyboardRemapper.shared.update()

        CloseToQuit.shared.update()
        DockPreview.shared.update()
        GameWindowAssistant.shared.update()

        if suite.statsInMenuBar {
            SystemMonitor.shared.acquire("menubar", perApp: false)
        } else {
            SystemMonitor.shared.release("menubar")
        }
        updateFrontmost()
    }

    func updateFrontmost() {
        let front = NSWorkspace.shared.frontmostApplication
        KeyboardRemapper.shared.frontmostBundleID = front?.bundleIdentifier
        let game = AppState.shared.detector.currentGame
        KeyboardRemapper.shared.frontmostIsGame = game != nil && game?.pid == front?.processIdentifier
    }
}
