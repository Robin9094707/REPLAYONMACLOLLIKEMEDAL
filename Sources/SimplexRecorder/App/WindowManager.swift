import AppKit
import SwiftUI

enum SettingsTab: Int, CaseIterable {
    case general, recording, hotkeys, games, storage, clips

    var title: String {
        switch self {
        case .general: return "Allgemein"
        case .recording: return "Aufnahme"
        case .hotkeys: return "Tastenkürzel"
        case .games: return "Spiele"
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
                controller.preferredContentSize = NSSize(width: 680, height: 560)
                let tabItem = NSTabViewItem(viewController: controller)
                tabItem.label = item.title
                tabItem.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: item.title)
                tabs.addTabViewItem(tabItem)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.title = "Simplex Recorder"
            window.setContentSize(NSSize(width: 680, height: 560))
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
        case .storage: StorageSettingsView()
        case .clips: ClipsView()
        }
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(150))
            let visible = NSApp.windows.contains { $0.isVisible && ($0 === self.settingsWindow || $0 === self.onboardingWindow) }
            if !visible { NSApp.setActivationPolicy(.accessory) }
        }
    }
}
