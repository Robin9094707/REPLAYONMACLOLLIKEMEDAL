import AppKit
import ApplicationServices

/// "Red X quits the app" like on Windows: when you click a window's close button and that
/// was the app's last window, the app is quit completely instead of idling in the Dock.
/// Event-driven (one global mouse monitor) – no polling.
@MainActor
final class CloseToQuit {
    static let shared = CloseToQuit()

    private var downMonitor: Any?
    private var upMonitor: Any?
    private var pendingPID: pid_t?
    private var pendingAt = Date.distantPast

    func update() {
        let enabled = SuiteSettings.shared.closeQuitsApps && AXIsProcessTrusted()
        if enabled, downMonitor == nil {
            downMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in CloseToQuit.shared.mouseDown(at: location) }
            }
            upMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { _ in
                let location = NSEvent.mouseLocation
                Task { @MainActor in CloseToQuit.shared.mouseUp(at: location) }
            }
        } else if !enabled, let down = downMonitor {
            NSEvent.removeMonitor(down)
            if let upMonitor { NSEvent.removeMonitor(upMonitor) }
            downMonitor = nil
            upMonitor = nil
        }
    }

    private func mouseDown(at location: NSPoint) {
        pendingPID = Self.closeButtonOwner(at: location)
        pendingAt = Date()
    }

    private func mouseUp(at location: NSPoint) {
        guard let pid = pendingPID, Date().timeIntervalSince(pendingAt) < 3 else { return }
        pendingPID = nil
        // Released on the same close button?
        guard Self.closeButtonOwner(at: location) == pid || Self.closeButtonOwner(at: location) == nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(600))
            self.quitIfNoWindows(pid: pid)
        }
    }

    private func quitIfNoWindows(pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated,
              app.activationPolicy == .regular else { return }
        let bundleID = app.bundleIdentifier ?? ""
        if ProtectedApps.isProtected(bundleID: bundleID) { return }
        if SuiteSettings.shared.closeExclusions.contains(bundleID) { return }

        let axApp = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return }
        // Ignore invisible helper windows: only count real, standard windows.
        let real = windows.filter { window in
            var subrole: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            let sub = subrole as? String ?? ""
            return sub == (kAXStandardWindowSubrole as String) || sub == (kAXDialogSubrole as String)
        }
        guard real.isEmpty else { return }
        DiagnosticsLog.write("close-to-quit: \(app.localizedName ?? bundleID) had no windows left – quitting")
        app.terminate()
    }

    /// PID of the app whose close button is under the cursor, nil otherwise.
    private static func closeButtonOwner(at location: NSPoint) -> pid_t? {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let system = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(location.x), Float(primaryHeight - location.y), &element) == .success,
              let element else { return nil }
        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard (subrole as? String) == (kAXCloseButtonSubrole as String) else { return nil }
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return pid == ProcessInfo.processInfo.processIdentifier ? nil : pid
    }
}
