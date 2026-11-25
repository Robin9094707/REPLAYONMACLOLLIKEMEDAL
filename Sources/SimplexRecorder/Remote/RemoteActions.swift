import AppKit
import Carbon.HIToolbox

/// Quick actions the iPhone can trigger. Simplex Suite itself is never quit.
@MainActor
enum RemoteActions {
    static func perform(_ msg: [String: Any], injector: InputInjector, reply: @escaping (String) -> Void) {
        guard let action = msg["a"] as? String else { return }
        DiagnosticsLog.write("remote action: \(action)")
        switch action {
        case "quitAll":
            let exclusions = Set(SuiteSettings.shared.quitAllExclusions)
            let apps = NSWorkspace.shared.runningApplications.filter {
                $0.activationPolicy == .regular && !$0.isTerminated
                    && !ProtectedApps.isProtected(bundleID: $0.bundleIdentifier)
                    && !exclusions.contains($0.bundleIdentifier ?? "")
            }
            apps.forEach { $0.terminate() }
            reply("\(apps.count) Apps werden beendet")
        case "quitApp":
            guard let pid = msg["pid"] as? Int, let app = NSRunningApplication(processIdentifier: pid_t(pid)) else { return }
            if ProtectedApps.isProtected(bundleID: app.bundleIdentifier) { return reply("Diese App ist geschützt") }
            let force = msg["force"] as? Bool ?? false
            _ = force ? app.forceTerminate() : app.terminate()
            reply("\(app.localizedName ?? "App") wird beendet")
        case "openApp":
            if let bundle = msg["bundle"] as? String,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case "lock":
            // ⌃⌘Q = lock screen
            injector.pressKey("q", modifiers: ["ctrl", "cmd"])
            reply("Bildschirm gesperrt")
        case "displayOff":
            run("/usr/bin/pmset", ["displaysleepnow"])
        case "sleep":
            reply("Mac geht in den Ruhezustand")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { run("/usr/bin/pmset", ["sleepnow"]) }
        case "restart":
            reply("Mac wird neu gestartet")
            appleScript("tell application \"System Events\" to restart")
        case "shutdown":
            reply("Mac wird ausgeschaltet")
            appleScript("tell application \"System Events\" to shut down")
        case "saveClip":
            AppState.shared.saveClip()
            reply(AppState.shared.isRecording ? "Clip wird gespeichert" : "Gerade läuft keine Aufnahme")
        case "longClip":
            AppState.shared.saveLongClip()
        case "screenshot":
            AppState.shared.takeScreenshot()
        case "togglePause":
            AppState.shared.togglePause()
        case "volUp":
            appleScript("set volume output volume ((output volume of (get volume settings)) + 10)")
        case "volDown":
            appleScript("set volume output volume ((output volume of (get volume settings)) - 10)")
        case "mute":
            appleScript("set volume output muted (not (output muted of (get volume settings)))")
        case "playPause":
            injector.mediaKey(16)   // NX_KEYTYPE_PLAY
        case "next":
            injector.mediaKey(17)   // NX_KEYTYPE_NEXT
        case "previous":
            injector.mediaKey(18)   // NX_KEYTYPE_PREVIOUS
        case "missionControl":
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))
        case "launcher":
            LauncherPanel.shared.show()
        case "showDesktop":
            injector.pressKey("f11", modifiers: [])
        case "spotlight":
            injector.pressKey("space", modifiers: ["cmd"])
        case "appSwitcher":
            injector.pressKey("tab", modifiers: ["cmd"])
        case "maximize":
            GameWindowAssistant.shared.perform(.maximize)
        case "copy":
            injector.pressKey("c", modifiers: ["cmd"])
        case "paste":
            injector.pressKey("v", modifiers: ["cmd"])
        case "undo":
            injector.pressKey("z", modifiers: ["cmd"])
        case "closeWindow":
            injector.pressKey("w", modifiers: ["cmd"])
        case "quitFrontApp":
            if let front = NSWorkspace.shared.frontmostApplication,
               !ProtectedApps.isProtected(bundleID: front.bundleIdentifier) {
                front.terminate()
                reply("\(front.localizedName ?? "App") wird beendet")
            }
        default:
            reply("Unbekannte Aktion")
        }
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try? p.run()
    }

    nonisolated private static func appleScript(_ source: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&error)
        }
    }
}
