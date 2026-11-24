import AppKit
import CoreGraphics
import Carbon.HIToolbox

/// Windows keyboard habits on the Mac, via a lightweight CGEvent tap (keyboard only):
///  • Ctrl+C/V/X/A/Z/S/F/… act like ⌘ (Ctrl+Y = redo)
///  • optional: Home/End = line start/end, Ctrl+←/→ = word jump, Ctrl+⌫ = delete word
///  • tapping the Windows key (left ⌘) alone opens the Simplex launcher
/// Terminals, virtual machines and (optionally) games are left untouched.
final class KeyboardRemapper {
    static let shared = KeyboardRemapper()

    // Snapshot of settings, read on the event-tap thread (main run loop).
    struct Config {
        var remap = false
        var navigation = false
        var disableInGames = true
        var exclusions: Set<String> = []
        var launcherKey: Int64?
    }

    var config = Config()
    /// Bundle ID of the frontmost app and whether it is a detected game (kept up to date by AppState).
    var frontmostBundleID: String?
    var frontmostIsGame = false

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?

    // Solo-modifier detection for the launcher key.
    private var soloKeyDown = false
    private var soloKeyDownAt: TimeInterval = 0

    /// Ctrl+<key> → ⌘+<key>
    private static let mappedKeys: Set<Int64> = [
        Int64(kVK_ANSI_A), Int64(kVK_ANSI_C), Int64(kVK_ANSI_V), Int64(kVK_ANSI_X), Int64(kVK_ANSI_Z),
        Int64(kVK_ANSI_S), Int64(kVK_ANSI_F), Int64(kVK_ANSI_P), Int64(kVK_ANSI_N), Int64(kVK_ANSI_T),
        Int64(kVK_ANSI_W), Int64(kVK_ANSI_O), Int64(kVK_ANSI_R), Int64(kVK_ANSI_L), Int64(kVK_ANSI_B),
        Int64(kVK_ANSI_I), Int64(kVK_ANSI_U), Int64(kVK_ANSI_K), Int64(kVK_ANSI_D), Int64(kVK_ANSI_G),
        Int64(kVK_ANSI_E), Int64(kVK_ANSI_J),
        Int64(kVK_ANSI_Equal), Int64(kVK_ANSI_Minus), Int64(kVK_ANSI_0),
        // deliberately NOT mapped: Q (quit), H (hide), M (minimize) – no Windows equivalent
    ]

    var isRunning: Bool { tap != nil }

    /// (Re)creates or removes the tap depending on what is needed.
    func update() {
        let needed = (config.remap || config.navigation || config.launcherKey != nil) && AXIsProcessTrusted()
        if needed && tap == nil {
            start()
        } else if !needed && tap != nil {
            stop()
        }
    }

    private func start() {
        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.rightMouseDown.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let remapper = Unmanaged<KeyboardRemapper>.fromOpaque(refcon).takeUnretainedValue()
            return remapper.handle(type: type, event: event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            DiagnosticsLog.write("keyboard: event tap could not be created (Accessibility?)")
            return
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        DiagnosticsLog.write("keyboard: event tap active")
    }

    private func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: Event handling (must be fast)

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .flagsChanged:
            handleModifier(event)
            return Unmanaged.passUnretained(event)
        case .leftMouseDown, .rightMouseDown:
            soloKeyDown = false
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp:
            if type == .keyDown { soloKeyDown = false }
            remap(event)
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handleModifier(_ event: CGEvent) {
        guard let launcherKey = config.launcherKey else { return }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        guard keyCode == launcherKey else {
            soloKeyDown = false
            return
        }
        let isCommand = launcherKey == 55 || launcherKey == 54
        let pressed = isCommand ? flags.contains(.maskCommand) : flags.contains(.maskAlternate)
        let others: CGEventFlags = isCommand
            ? [.maskShift, .maskControl, .maskAlternate]
            : [.maskShift, .maskControl, .maskCommand]
        if pressed {
            soloKeyDown = flags.intersection(others).isEmpty
            soloKeyDownAt = ProcessInfo.processInfo.systemUptime
        } else if soloKeyDown {
            soloKeyDown = false
            if ProcessInfo.processInfo.systemUptime - soloKeyDownAt < 0.45, !frontmostIsGame {
                DispatchQueue.main.async {
                    Task { @MainActor in LauncherPanel.shared.toggle() }
                }
            }
        }
    }

    private func remap(_ event: CGEvent) {
        guard config.remap || config.navigation else { return }
        if let bundle = frontmostBundleID, config.exclusions.contains(bundle) { return }
        if config.disableInGames && frontmostIsGame { return }

        var flags = event.flags
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let hasControl = flags.contains(.maskControl)
        let hasCommand = flags.contains(.maskCommand)

        if config.remap, hasControl, !hasCommand {
            if keyCode == Int64(kVK_ANSI_Y) {
                // Ctrl+Y (redo) → ⌘⇧Z
                flags.remove(.maskControl)
                flags.insert([.maskCommand, .maskShift])
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(kVK_ANSI_Z))
                event.flags = flags
                return
            }
            if Self.mappedKeys.contains(keyCode) {
                flags.remove(.maskControl)
                flags.insert(.maskCommand)
                event.flags = flags
                return
            }
        }

        guard config.navigation else { return }
        switch keyCode {
        case Int64(kVK_LeftArrow), Int64(kVK_RightArrow):
            // Ctrl+←/→ → ⌥+←/→ (jump word)
            if hasControl && !hasCommand {
                flags.remove(.maskControl)
                flags.insert(.maskAlternate)
                event.flags = flags
            }
        case Int64(kVK_Delete):
            // Ctrl+⌫ → ⌥+⌫ (delete word)
            if hasControl && !hasCommand {
                flags.remove(.maskControl)
                flags.insert(.maskAlternate)
                event.flags = flags
            }
        case Int64(kVK_Home), Int64(kVK_End):
            // Home/End → start/end of line (⌘←/⌘→); Ctrl+Home/End → document start/end (⌘↑/⌘↓)
            guard !hasCommand else { return }
            let isHome = keyCode == Int64(kVK_Home)
            if hasControl {
                flags.remove(.maskControl)
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(isHome ? kVK_UpArrow : kVK_DownArrow))
            } else {
                event.setIntegerValueField(.keyboardEventKeycode, value: Int64(isHome ? kVK_LeftArrow : kVK_RightArrow))
            }
            flags.insert(.maskCommand)
            event.flags = flags
        default:
            break
        }
    }
}
