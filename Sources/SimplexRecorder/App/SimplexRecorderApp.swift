import SwiftUI
import AppKit

@main
struct SimplexRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .environmentObject(state.library)
                .environmentObject(state.storage)
        } label: {
            Image(systemName: state.menuBarSymbol)
                .accessibilityLabel("Simplex Recorder")
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static let showSettingsNotification = Notification.Name("com.simplex.recorder.showSettings")

    func applicationDidFinishLaunching(_ notification: Notification) {
        resolveSingleInstance()

        AppState.shared.launch()

        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showSettingsRequested),
            name: Self.showSettingsNotification,
            object: nil,
            suspensionBehavior: .deliverImmediately)

        if !AppSettings.shared.hasCompletedOnboarding {
            WindowManager.shared.showOnboarding()
        }
    }

    /// Makes sure exactly one instance runs – preferably the one supervised by launchd.
    private func resolveSingleInstance() {
        let settings = AppSettings.shared
        let me = NSRunningApplication.current.processIdentifier
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.simplex.recorder")
            .filter { $0.processIdentifier != me }

        if LaunchAgentManager.isLaunchedByAgent {
            // We are the supervised instance: manually started copies hand over to us.
            others.forEach { $0.terminate() }
            return
        }

        if !others.isEmpty {
            // Already running → just bring up its settings window.
            DistributedNotificationCenter.default().postNotificationName(
                Self.showSettingsNotification, object: nil, userInfo: nil, deliverImmediately: true)
            exit(0)
        }

        if settings.hasCompletedOnboarding,
           settings.wantsLaunchAgent,
           !LaunchAgentManager.shouldSkipHandover,
           !LaunchAgentManager.isTranslocated {
            // Restart under launchd so a force-quit is followed by an automatic restart.
            LaunchAgentManager.applyAndRelaunch(runAtLoad: settings.launchAtLogin, keepAlive: settings.keepAlive)
        }
    }

    @objc private func showSettingsRequested() {
        Task { @MainActor in WindowManager.shared.showSettings() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        WindowManager.shared.showSettings()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
