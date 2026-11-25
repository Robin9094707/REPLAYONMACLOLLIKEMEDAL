import AppKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, recording, hotkeys, games, windows, keyboard, system, remote, storage, clips

    var title: String {
        switch self {
        case .general: return "Allgemein"
        case .recording: return "Aufnahme"
        case .hotkeys: return "Tastenkürzel"
        case .games: return "Spiele"
        case .windows: return "Fenster"
        case .keyboard: return "Tastatur"
        case .system: return "System"
        case .remote: return "Remote"
        case .storage: return "Speicher"
        case .clips: return "Clips"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .recording: return "record.circle"
        case .hotkeys: return "keyboard"
        case .games: return "gamecontroller"
        case .windows: return "macwindow.on.rectangle"
        case .keyboard: return "command"
        case .system: return "cpu"
        case .remote: return "iphone.radiowaves.left.and.right"
        case .storage: return "externaldrive"
        case .clips: return "film.stack"
        }
    }
}

/// Native AppKit windows (toolbar-style preferences like the system apps).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    static let shared = WindowManager()

    private var settingsWindow: NSWindow?
    private var settingsTabs: NSTabViewController?
    private var onboardingWindow: NSWindow?
    private var taskManagerWindow: NSWindow?
    private var cleanerWindow: NSWindow?

    private func inject<V: View>(_ view: V) -> some View {
        let state = AppState.shared
        return view
            .environmentObject(state)
            .environmentObject(state.settings)
            .environmentObject(state.detector)
            .environmentObject(state.storage)
            .environmentObject(state.library)
    }

    func showSettings(tab: SettingsTab? = nil) {
        if settingsWindow == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            for item in SettingsTab.allCases {
                let controller = NSHostingController(rootView: AnyView(inject(settingsView(for: item))))
                controller.sizingOptions = []
                controller.preferredContentSize = NSSize(width: 860, height: 600)
                let tabItem = NSTabViewItem(viewController: controller)
                tabItem.label = item.title
                tabItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
                tabs.addTabViewItem(tabItem)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.title = "Simplex Suite"
            window.setContentSize(NSSize(width: 860, height: 600))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
            settingsTabs = tabs
        }
        if let tab { settingsTabs?.selectedTabViewItemIndex = tab.rawValue }
        present(settingsWindow)
    }

    func showOnboarding() {
        if onboardingWindow == nil {
            let controller = NSHostingController(rootView: AnyView(inject(OnboardingView())))
            controller.sizingOptions = []
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 620, height: 560))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            onboardingWindow = window
        }
        present(onboardingWindow)
    }

    func showTaskManager() {
        if taskManagerWindow == nil {
            taskManagerWindow = makeToolWindow(title: "Taskmanager", view: AnyView(TaskManagerView()),
                                               size: NSSize(width: 820, height: 600), autosave: "SimplexTaskManager")
        }
        present(taskManagerWindow)
    }

    func showCleaner() {
        if cleanerWindow == nil {
            cleanerWindow = makeToolWindow(title: "Aufräumen & Deinstallieren", view: AnyView(CleanerView()),
                                           size: NSSize(width: 900, height: 640), autosave: "SimplexCleaner")
        }
        present(cleanerWindow)
    }

    private func makeToolWindow(title: String, view: AnyView, size: NSSize, autosave: String) -> NSWindow {
        let controller = NSHostingController(rootView: AnyView(inject(view)))
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = false
        window.title = title
        window.setContentSize(size)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.setFrameAutosaveName(autosave)
        return window
    }

    func closeOnboarding() {
        onboardingWindow?.close()
    }

    private func present(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @ViewBuilder
    private func settingsView(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .recording: RecordingSettingsView()
        case .hotkeys: HotKeySettingsView()
        case .games: GamesSettingsView()
        case .windows: WindowSettingsView()
        case .keyboard: KeyboardSettingsView()
        case .system: SystemSettingsView()
        case .remote: RemoteSettingsView()
        case .storage: StorageSettingsView()
        case .clips: ClipsView()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let ours = [self.settingsWindow, self.onboardingWindow, self.taskManagerWindow, self.cleanerWindow]
            let visible = ours.contains { $0?.isVisible == true }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
