import AppKit
import ApplicationServices
import SwiftUI

/// Window management for detected games – "Aero Snap" for the Mac:
/// drag the game window to the top edge → it fills the screen (menu bar and Dock stay
/// visible); left/right edge → half screen. Plus actions for menu and hotkey.
///
/// Drag detection is purely passive: while a game is running and the mouse button is
/// held, we poll the cursor and the window's bounds from the window server (no calls
/// into the game process). Only the final resize uses the Accessibility API.
@MainActor
final class GameWindowAssistant {
    static let shared = GameWindowAssistant()

    enum Zone: Equatable {
        case maximize, leftHalf, rightHalf, center

        var title: String {
            switch self {
            case .maximize: return "Bildschirm füllen"
            case .leftHalf: return "Linke Hälfte"
            case .rightHalf: return "Rechte Hälfte"
            case .center: return "Zentriert"
            }
        }
    }

    private var timer: Timer?
    private var tracking = false
    private var draggingWindow = false
    private var startMouse: NSPoint = .zero
    private var startBounds: CGRect = .zero
    private var currentZone: Zone?
    private var currentScreen: NSScreen?
    private var savedFrames: [pid_t: CGRect] = [:]
    private let preview = SnapPreview()

    private var settings: AppSettings { AppSettings.shared }
    private var game: DetectedGame? { AppState.shared.detector.currentGame }

    // MARK: Permission

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// After an update the ad-hoc signature changes, so an old entry no longer matches.
    static func resetTrust() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.simplex.recorder"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    // MARK: Lifecycle

    /// Called whenever the detected game changes. The poll timer only runs while a game is detected.
    func update() {
        let shouldRun = settings.snapAssistEnabled && game != nil && Self.isTrusted
        if shouldRun, timer == nil {
            let t = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            t.tolerance = 0.01
            timer = t
        } else if !shouldRun, let t = timer {
            t.invalidate()
            timer = nil
            reset()
        }
    }

    private func reset() {
        tracking = false
        draggingWindow = false
        currentZone = nil
        preview.hide()
    }

    // MARK: Drag tracking

    private func tick() {
        guard let game, game.windowID != 0,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == game.pid else {
            if tracking { reset() }
            return
        }
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1
        let mouse = NSEvent.mouseLocation

        if buttonDown && !tracking {
            tracking = true
            draggingWindow = false
            startMouse = mouse
            startBounds = Self.windowBounds(game.windowID) ?? .zero
            return
        }
        guard tracking else { return }

        if !buttonDown {
            // Released.
            if draggingWindow, let zone = currentZone, let screen = currentScreen {
                preview.hide()
                let pid = game.pid
                // Let the window server finish the drag before we resize.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(60))
                    self.apply(zone, pid: pid, screen: screen, animatedFeedback: true)
                }
            } else {
                preview.hide()
            }
            tracking = false
            draggingWindow = false
            currentZone = nil
            return
        }

        // Button held: is the *window* moving (title bar drag), not just the mouse in-game?
        if !draggingWindow {
            guard hypot(mouse.x - startMouse.x, mouse.y - startMouse.y) > 4,
                  let bounds = Self.windowBounds(game.windowID) else { return }
            if abs(bounds.origin.x - startBounds.origin.x) > 2 || abs(bounds.origin.y - startBounds.origin.y) > 2 {
                draggingWindow = true
            } else {
                return
            }
        }

        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let screen else { return }
        let zone = Self.zone(for: mouse, on: screen)
        if zone != currentZone || screen != currentScreen {
            currentZone = zone
            currentScreen = screen
            if let zone {
                preview.show(frame: Self.targetFrame(zone, on: screen), title: zone.title)
            } else {
                preview.hide()
            }
        }
    }

    private static func zone(for mouse: NSPoint, on screen: NSScreen) -> Zone? {
        let f = screen.frame
        let v = screen.visibleFrame
        if mouse.y >= v.maxY - 2 { return .maximize }          // touching the menu bar
        if mouse.x <= f.minX + 3 { return .leftHalf }
        if mouse.x >= f.maxX - 4 { return .rightHalf }
        return nil
    }

    /// Target frame in Cocoa coordinates (bottom-left origin).
    static func targetFrame(_ zone: Zone, on screen: NSScreen) -> CGRect {
        let v = screen.visibleFrame
        switch zone {
        case .maximize: return v
        case .leftHalf: return CGRect(x: v.minX, y: v.minY, width: (v.width / 2).rounded(), height: v.height)
        case .rightHalf:
            let w = (v.width / 2).rounded()
            return CGRect(x: v.maxX - w, y: v.minY, width: w, height: v.height)
        case .center:
            let w = (v.width * 0.8).rounded(), h = (v.height * 0.8).rounded()
            return CGRect(x: v.midX - w / 2, y: v.midY - h / 2, width: w, height: h)
        }
    }

    // MARK: Actions (menu / hotkey)

    func perform(_ zone: Zone) {
        guard let game else { return beepNoGame() }
        guard Self.isTrusted else { return askForTrust() }
        let screen = screenForGame(game) ?? NSScreen.main
        guard let screen else { return }
        apply(zone, pid: game.pid, screen: screen, animatedFeedback: true)
    }

    /// ⌥⇧F: fill the screen, or restore the previous size if it already fills it.
    func toggleMaximize() {
        guard let game else { return beepNoGame() }
        guard Self.isTrusted else { return askForTrust() }
        guard let screen = screenForGame(game) ?? NSScreen.main else { return }
        let target = Self.cocoaToCG(Self.targetFrame(.maximize, on: screen))
        if let bounds = Self.windowBounds(game.windowID), Self.roughlyEqual(bounds, target), savedFrames[game.pid] != nil {
            restore()
        } else {
            apply(.maximize, pid: game.pid, screen: screen, animatedFeedback: true)
        }
    }

    func restore() {
        guard let game else { return beepNoGame() }
        guard Self.isTrusted else { return askForTrust() }
        guard let frame = savedFrames[game.pid], let window = Self.axWindow(pid: game.pid, matching: game.windowID) else {
            NSSound.beep()
            return
        }
        Self.setFrame(window, cgFrame: frame)
        savedFrames[game.pid] = nil
        OverlayHUD.shared.show(symbol: "arrow.down.right.and.arrow.up.left", title: "Fenstergröße wiederhergestellt",
                               subtitle: game.name, tint: .systemBlue)
    }

    /// Called once when a game starts (if enabled in settings).
    func autoMaximizeIfWanted(for game: DetectedGame) {
        guard settings.autoMaximizeGames, Self.isTrusted else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5)) // give the game time to create its window
            guard let current = self.game, current.pid == game.pid,
                  let screen = self.screenForGame(current) ?? NSScreen.main else { return }
            // Leave real fullscreen alone.
            if let bounds = Self.windowBounds(current.windowID),
               Self.roughlyEqual(bounds, Self.cocoaToCG(screen.frame)) { return }
            self.apply(.maximize, pid: current.pid, screen: screen, animatedFeedback: false)
        }
    }

    private func apply(_ zone: Zone, pid: pid_t, screen: NSScreen, animatedFeedback: Bool) {
        let windowID = game?.pid == pid ? (game?.windowID ?? 0) : 0
        guard let window = Self.axWindow(pid: pid, matching: windowID) else {
            DiagnosticsLog.write("snap: no accessible window for pid \(pid)")
            NSSound.beep()
            return
        }
        if let current = Self.frame(of: window), savedFrames[pid] == nil || zone != .maximize {
            let target = Self.cocoaToCG(Self.targetFrame(.maximize, on: screen))
            if !Self.roughlyEqual(current, target) { savedFrames[pid] = current }
        }
        let target = Self.cocoaToCG(Self.targetFrame(zone, on: screen))
        Self.setFrame(window, cgFrame: target)
        DiagnosticsLog.write("snap: \(zone) → \(target)")
        if animatedFeedback {
            OverlayHUD.shared.show(symbol: zone == .maximize ? "arrow.up.left.and.arrow.down.right" : "rectangle.split.2x1",
                                   title: zone.title, subtitle: game?.name, tint: .systemBlue)
        }
    }

    private func screenForGame(_ game: DetectedGame) -> NSScreen? {
        guard let bounds = Self.windowBounds(game.windowID) else { return nil }
        let center = Self.cgToCocoa(bounds)
        let mid = NSPoint(x: center.midX, y: center.midY)
        return NSScreen.screens.first { NSMouseInRect(mid, $0.frame, false) }
    }

    private func beepNoGame() {
        NSSound.beep()
        OverlayHUD.shared.show(symbol: "gamecontroller", title: "Kein Spiel erkannt",
                               subtitle: "Starte zuerst ein Spiel", tint: .systemGray)
    }

    private func askForTrust() {
        Self.requestTrust()
        OverlayHUD.shared.show(symbol: "hand.raised.fill", title: "Bedienungshilfen erlauben",
                               subtitle: "Nötig, damit Spielfenster angeordnet werden können", tint: .systemOrange)
    }

    // MARK: Window server / Accessibility helpers

    /// Window bounds in CG coordinates (top-left origin), straight from the window server.
    static func windowBounds(_ windowID: UInt32) -> CGRect? {
        guard windowID != 0,
              let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(windowID)) as? [[String: Any]],
              let dict = list.first?[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: dict as CFDictionary)
    }

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func cocoaToCG(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    static func cgToCocoa(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    private static func roughlyEqual(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 6 && abs(a.minY - b.minY) < 6 && abs(a.width - b.width) < 6 && abs(a.height - b.height) < 6
    }

    private static func axWindow(pid: pid_t, matching windowID: UInt32) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        let target = windowBounds(windowID)
        if AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
           let windows = value as? [AXUIElement], !windows.isEmpty {
            if let target, let match = windows.first(where: { frame(of: $0).map { roughlyEqual($0, target) } ?? false }) {
                return match
            }
        }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() {
            return (focused as! AXUIElement)
        }
        var main: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXMainWindowAttribute as CFString, &main) == .success,
           let main, CFGetTypeID(main) == AXUIElementGetTypeID() {
            return (main as! AXUIElement)
        }
        return nil
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        var posValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &posValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let posValue, let sizeValue else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &point)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
        return CGRect(origin: point, size: size)
    }

    private static func setFrame(_ window: AXUIElement, cgFrame: CGRect) {
        var point = cgFrame.origin
        var size = cgFrame.size
        guard let pos = AXValueCreate(.cgPoint, &point), let sz = AXValueCreate(.cgSize, &size) else { return }
        // Position → size → position again: some apps clamp the size to the current screen space.
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos)
    }
}

// MARK: - Snap preview

/// Translucent rounded rectangle showing where the window will land.
@MainActor
final class SnapPreview {
    private var panel: NSPanel?
    private let model = SnapPreviewModel()

    func show(frame: CGRect, title: String) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.title = title
        let wasVisible = panel.isVisible && panel.alphaValue > 0.5
        if !wasVisible {
            // Grow out of the cursor position for a smooth "magnet" feel.
            let mouse = NSEvent.mouseLocation
            panel.setFrame(CGRect(x: mouse.x - 40, y: mouse.y - 30, width: 80, height: 60), display: false)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.22
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1.0)
            panel.animator().setFrame(frame.insetBy(dx: 6, dy: 6), display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in if panel.alphaValue == 0 { panel.orderOut(nil) } }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: false)
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.sharingType = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: SnapPreviewView(model: model))
        return panel
    }
}

@MainActor
final class SnapPreviewModel: ObservableObject {
    @Published var title = ""
}

struct SnapPreviewView: View {
    @ObservedObject var model: SnapPreviewModel

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.accentColor.opacity(0.18))
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), lineWidth: 3)
            VStack(spacing: 8) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 34, weight: .semibold))
                Text(model.title).font(.system(size: 15, weight: .semibold))
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.35), radius: 6)
        }
        .environment(\.colorScheme, .dark)
    }
}
