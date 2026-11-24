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
            MenuBarLabel(state: state, settings: state.settings)
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
            // Agent from an older version (or app moved)? Rewrite it once.
            if settings.hasCompletedOnboarding, settings.wantsLaunchAgent,
               !LaunchAgentManager.isUpToDate(runAtLoad: settings.launchAtLogin, keepAlive: settings.keepAlive) {
                let defaults = UserDefaults.standard
                let lastRepair = defaults.double(forKey: "lastAgentRepair")
                if Date().timeIntervalSince1970 - lastRepair > 120 {
                    defaults.set(Date().timeIntervalSince1970, forKey: "lastAgentRepair")
                    LaunchAgentManager.log("agent outdated – rewriting")
                    LaunchAgentManager.applyAndRelaunch(runAtLoad: settings.launchAtLogin, keepAlive: settings.keepAlive)
                }
            }
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
           LaunchAgentManager.isInstalledLocationValid {
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

struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var settings: AppSettings

    var body: some View {
        if settings.menuBarShowsTimer && state.isRecording {
            HStack(spacing: 3) {
                Image(systemName: state.menuBarSymbol)
                Text("\(Int(state.bufferedSeconds))s").monospacedDigit()
            }
            .accessibilityLabel("Simplex Recorder")
        } else {
            Image(systemName: state.menuBarSymbol)
                .accessibilityLabel("Simplex Recorder")
        }
    }
}
