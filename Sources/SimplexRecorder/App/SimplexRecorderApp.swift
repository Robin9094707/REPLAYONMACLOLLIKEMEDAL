import SwiftUI
import AppKit

@main
struct SimplexRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var state = AppState.shared

    var body: some Scene {
        MenuBarExtra {
            DashboardView()
                .environmentObject(state)
                .environmentObject(state.settings)
                .environmentObject(state.library)
                .environmentObject(state.storage)
                .environmentObject(state.detector)
        } label: {
            MenuBarLabel(state: state, settings: state.settings, suite: SuiteSettings.shared,
                         monitor: SystemMonitor.shared, recorder: ScreenRecorder.shared)
        }
        .menuBarExtraStyle(.window)
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

        // An older copy at a different path (e.g. "Simplex Recorder.app" before the rename)
        // is replaced: the launch agent handover below boots it out.
        let myBundle = Bundle.main.bundleURL.standardizedFileURL
        let olderCopies = others.filter { $0.bundleURL?.standardizedFileURL != myBundle }
        if !olderCopies.isEmpty {
            DiagnosticsLog.write("replacing older copy at \(olderCopies.compactMap { $0.bundleURL?.path })")
            if !settings.wantsLaunchAgent || LaunchAgentManager.shouldSkipHandover {
                olderCopies.forEach { $0.terminate() }
            }
        }
        let sameCopies = others.filter { $0.bundleURL?.standardizedFileURL == myBundle }
        if !sameCopies.isEmpty {
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
    @ObservedObject var suite: SuiteSettings
    @ObservedObject var monitor: SystemMonitor
    @ObservedObject var recorder: ScreenRecorder

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            if !statsText.isEmpty {
                Text(statsText).monospacedDigit()
            }
        }
        .accessibilityLabel("Simplex Suite")
    }

    /// Tool icon; while clipping a filled variant (the dot shows the recording state).
    private var symbol: String {
        if state.isSaving { return "arrow.down.circle.fill" }
        switch state.status {
        case .recording: return "wrench.and.screwdriver.fill"
        case .needsPermission, .error: return "exclamationmark.triangle"
        default: return "wrench.and.screwdriver"
        }
    }

    private var statsText: String {
        var parts: [String] = []
        if recorder.isRecording {
            // TimelineView isn't available in menu bar labels – the timer below refreshes via SystemMonitor.
            parts.append("⏺ REC")
        }
        if state.isRecording {
            parts.append(settings.menuBarShowsTimer ? "● \(Int(state.bufferedSeconds))s" : "●")
        }
        if suite.statsInMenuBar {
            let s = monitor.snapshot
            if suite.menuBarShowCPU { parts.append("\(Int(s.cpuUsage * 100))%") }
            if suite.menuBarShowTemp, let t = s.cpuTemperature { parts.append("\(Int(t.rounded()))°") }
            if suite.menuBarShowRAM { parts.append(Int64(s.memoryUsed).compactBytes) }
        }
        return parts.joined(separator: " ")
    }
}
