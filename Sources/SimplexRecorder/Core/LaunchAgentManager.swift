import Foundation
import AppKit

/// Autostart + "never goes away" via a per-user LaunchAgent.
///
/// * `RunAtLoad`        → starts at login
/// * `KeepAlive = true` → launchd restarts the app whenever it stops – crash, force quit,
///   ⌘Q, Activity Monitor … The only real way out is "Beenden" in our own menu, which
///   unloads the agent (`launchctl bootout`) until the next login.
enum LaunchAgentManager {
    static let label = "com.simplex.recorder.agent"
    static let agentArgument = "--launched-by-agent"
    static let skipHandoverArgument = "--skip-agent-handover"
    /// Bump when the plist layout changes so existing installs get rewritten.
    static let agentVersion = 2

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/SimplexRecorder/agent.log")
    }

    static var isLaunchedByAgent: Bool { CommandLine.arguments.contains(agentArgument) }
    static var shouldSkipHandover: Bool { CommandLine.arguments.contains(skipHandoverArgument) }

    /// The app must live somewhere permanent and writable-independent for launchd:
    /// not translocated by Gatekeeper and not inside a mounted (read-only) DMG.
    static var isInstalledLocationValid: Bool {
        let path = Bundle.main.bundlePath
        if path.contains("/AppTranslocation/") { return false }
        let values = try? Bundle.main.bundleURL.resourceValues(forKeys: [.volumeIsReadOnlyKey])
        if values?.volumeIsReadOnly == true { return false }
        return true
    }

    static var installedPlist: [String: Any]? {
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    /// True if the installed plist matches what we would write right now.
    static func isUpToDate(runAtLoad: Bool, keepAlive: Bool) -> Bool {
        guard let plist = installedPlist,
              plist["SimplexAgentVersion"] as? Int == agentVersion,
              let args = plist["ProgramArguments"] as? [String],
              args.first == Bundle.main.executablePath,
              plist["RunAtLoad"] as? Bool == runAtLoad,
              plist["KeepAlive"] as? Bool == keepAlive else { return false }
        return true
    }

    static func writePlist(runAtLoad: Bool, keepAlive: Bool) throws {
        guard let executable = Bundle.main.executablePath else {
            throw CocoaError(.fileNoSuchFile)
        }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [executable, agentArgument],
            "RunAtLoad": runAtLoad,
            "KeepAlive": keepAlive,
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Interactive",
            "AbandonProcessGroup": true,
            "ThrottleInterval": 3,
            "StandardErrorPath": logURL.path,
            "SimplexAgentVersion": agentVersion,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
    }

    static func removePlist() {
        try? FileManager.default.removeItem(at: plistURL)
    }

    /// Is the job currently loaded into launchd?
    static func isLoaded() -> Bool {
        run("/bin/launchctl", ["print", "gui/\(getuid())/\(label)"]) == 0
    }

    /// Writes (or removes) the agent and restarts the app under the new configuration.
    /// A detached shell script does the launchctl work; it survives our own termination
    /// because the agent uses `AbandonProcessGroup`.
    static func applyAndRelaunch(runAtLoad: Bool, keepAlive: Bool) -> Never {
        var useAgent = (runAtLoad || keepAlive) && isInstalledLocationValid
        if useAgent {
            do { try writePlist(runAtLoad: runAtLoad, keepAlive: keepAlive) } catch {
                log("writePlist failed: \(error)")
                useAgent = false
            }
        }
        if !useAgent { removePlist() }

        let script = """
        exec >>"$4" 2>&1
        echo "--- $(date) apply (agent: $([ -f "$1" ] && echo yes || echo no))"
        sleep 0.5
        U=$(id -u)
        launchctl bootout "gui/$U/$3" 2>/dev/null
        sleep 1
        if [ -f "$1" ]; then
          if launchctl bootstrap "gui/$U" "$1"; then
            launchctl kickstart "gui/$U/$3"
            echo "agent started"
            exit 0
          fi
          echo "bootstrap failed – starting without agent"
        fi
        open -n "$2" --args \(skipHandoverArgument)
        """
        spawnDetached(script)
        UserDefaults.standard.synchronize()
        exit(0)
    }

    /// Restart the app (e.g. after granting Screen Recording permission).
    static func relaunch() -> Never {
        UserDefaults.standard.synchronize()
        if isLaunchedByAgent && installedPlist?["KeepAlive"] as? Bool == true {
            exit(0) // launchd brings us straight back
        }
        spawnDetached("""
        exec >>"$4" 2>&1
        sleep 1
        U=$(id -u)
        if launchctl print "gui/$U/$3" >/dev/null 2>&1; then
          launchctl kickstart "gui/$U/$3" && exit 0
        fi
        open -n "$2"
        """)
        exit(0)
    }

    /// Really quit: unload the agent so launchd doesn't bring us back (until next login).
    static func quitForReal() -> Never {
        UserDefaults.standard.synchronize()
        if isLaunchedByAgent {
            // bootout sends SIGTERM to this process; exit ourselves right after as a fallback.
            _ = run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        }
        exit(0)
    }

    // MARK: Helpers

    private static func spawnDetached(_ script: String) {
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", plistURL.path, Bundle.main.bundlePath, label, logURL.path]
        do { try process.run() } catch { log("spawn failed: \(error)") }
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        process.waitUntilExit()
        return process.terminationStatus
    }

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: logURL)
        }
    }
}
