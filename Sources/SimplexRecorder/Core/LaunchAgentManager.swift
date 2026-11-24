import Foundation
import AppKit

/// Autostart + "never goes away" via a per-user LaunchAgent.
///
/// * `RunAtLoad`               → starts at login
/// * `KeepAlive.SuccessfulExit = false` → launchd restarts the app if it crashes or is
///   force-quit, but *not* when you quit it normally from the menu (exit code 0).
enum LaunchAgentManager {
    static let label = "com.simplex.recorder.agent"
    static let agentArgument = "--launched-by-agent"
    static let skipHandoverArgument = "--skip-agent-handover"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isLaunchedByAgent: Bool { CommandLine.arguments.contains(agentArgument) }
    static var shouldSkipHandover: Bool { CommandLine.arguments.contains(skipHandoverArgument) }

    /// Gatekeeper "App Translocation" runs apps from a random read-only path – a LaunchAgent
    /// pointing there would break, so we only use the agent once the app lives somewhere real.
    static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

    static var isInstalled: Bool { FileManager.default.fileExists(atPath: plistURL.path) }

    static func writePlist(runAtLoad: Bool, keepAlive: Bool) throws {
        guard let executable = Bundle.main.executablePath else {
            throw CocoaError(.fileNoSuchFile)
        }
        var dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, agentArgument],
            "RunAtLoad": runAtLoad,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "AbandonProcessGroup": true,
            "ThrottleInterval": 5,
        ]
        dict["KeepAlive"] = keepAlive ? ["SuccessfulExit": false] : false
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    static func removePlist() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Writes (or removes) the agent and restarts the app under the new configuration.
    /// A small detached shell script does the launchctl work after this process exits.
    static func applyAndRelaunch(runAtLoad: Bool, keepAlive: Bool) -> Never {
        if (runAtLoad || keepAlive) && !isTranslocated {
            do { try writePlist(runAtLoad: runAtLoad, keepAlive: keepAlive) } catch { removePlist() }
        } else {
            removePlist()
        }

        let script = """
        sleep 1
        U=$(id -u)
        launchctl bootout "gui/$U/$3" >/dev/null 2>&1
        sleep 1
        if [ -f "$1" ]; then
          if launchctl bootstrap "gui/$U" "$1" >/dev/null 2>&1; then
            launchctl kickstart "gui/$U/$3" >/dev/null 2>&1
            exit 0
          fi
        fi
        open -n "$2" --args \(skipHandoverArgument)
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", plistURL.path, Bundle.main.bundlePath, label]
        try? process.run()

        UserDefaults.standard.synchronize()
        exit(0)
    }

    /// Restart the app (e.g. after granting Screen Recording permission).
    static func relaunch() -> Never {
        let script = """
        sleep 1
        U=$(id -u)
        if [ -f "$1" ] && launchctl print "gui/$U/$3" >/dev/null 2>&1; then
          launchctl kickstart "gui/$U/$3" >/dev/null 2>&1 && exit 0
        fi
        open -n "$2"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", plistURL.path, Bundle.main.bundlePath, label]
        try? process.run()
        UserDefaults.standard.synchronize()
        exit(0)
    }
}
