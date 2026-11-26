import AppKit
import CoreGraphics
import Carbon.HIToolbox
import IOKit.pwr_mgt

/// Turns remote touch/keyboard messages into real mouse and keyboard events (needs Accessibility).
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var buttonDown = false
    private var lastClick: (time: TimeInterval, point: CGPoint, count: Int) = (0, .zero, 0)

    /// The display the phone is looking at.
    var displayID: CGDirectDisplayID = CGMainDisplayID()

    private var bounds: CGRect { CGDisplayBounds(displayID) }

    private func point(_ x: Double, _ y: Double) -> CGPoint {
        let b = bounds
        return CGPoint(x: b.minX + CGFloat(min(max(x, 0), 1)) * b.width,
                       y: b.minY + CGFloat(min(max(y, 0), 1)) * b.height)
    }

    private var currentLocation: CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Mouse

    func handleMouse(_ msg: [String: Any]) {
        let action = msg["a"] as? String ?? "move"
        let hasPosition = msg["x"] != nil && msg["y"] != nil
        var p = hasPosition ? point(msg["x"] as? Double ?? 0, msg["y"] as? Double ?? 0) : currentLocation
        let right = (msg["b"] as? String) == "right"

        switch action {
        case "move":
            post(buttonDown ? .leftMouseDragged : .mouseMoved, at: p)
        case "rel":
            // Trackpad mode: relative movement in display points.
            let dx = CGFloat(msg["dx"] as? Double ?? 0), dy = CGFloat(msg["dy"] as? Double ?? 0)
            let b = CGDisplayBounds(CGMainDisplayID()).union(bounds)
            p = CGPoint(x: min(max(currentLocation.x + dx, b.minX), b.maxX - 1),
                        y: min(max(currentLocation.y + dy, b.minY), b.maxY - 1))
            post(buttonDown ? .leftMouseDragged : .mouseMoved, at: p)
        case "down":
            buttonDown = !right
            post(right ? .rightMouseDown : .leftMouseDown, at: p, button: right ? .right : .left, clicks: 1)
        case "up":
            post(right ? .rightMouseUp : .leftMouseUp, at: p, button: right ? .right : .left, clicks: 1)
            buttonDown = false
        case "click", "rclick":
            let isRight = right || action == "rclick"
            let now = ProcessInfo.processInfo.systemUptime
            var count = 1
            if !isRight, now - lastClick.time < 0.45, hypot(p.x - lastClick.point.x, p.y - lastClick.point.y) < 8 {
                count = min(lastClick.count + 1, 3)
            }
            lastClick = (now, p, count)
            post(.mouseMoved, at: p)
            post(isRight ? .rightMouseDown : .leftMouseDown, at: p, button: isRight ? .right : .left, clicks: count)
            post(isRight ? .rightMouseUp : .leftMouseUp, at: p, button: isRight ? .right : .left, clicks: count)
        case "dclick":
            post(.mouseMoved, at: p)
            for count in 1...2 {
                post(.leftMouseDown, at: p, clicks: count)
                post(.leftMouseUp, at: p, clicks: count)
            }
        case "scroll":
            let dx = Int32(msg["dx"] as? Double ?? 0), dy = Int32(msg["dy"] as? Double ?? 0)
            if hasPosition { post(.mouseMoved, at: p) }
            if let event = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) {
                // Continuous = trackpad-style smooth scrolling instead of mouse-wheel steps.
                event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                event.post(tap: .cghidEventTap)
            }
        default:
            break
        }
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton = .left, clicks: Int = 0) {
        guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if clicks > 0 { event.setIntegerValueField(.mouseEventClickState, value: Int64(clicks)) }
        event.post(tap: .cghidEventTap)
    }

    // MARK: Keyboard

    func typeText(_ text: String) {
        // Chunks of up to 16 UTF-16 units per event.
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            index += 16
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { buffer in
                    event.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: buffer.baseAddress)
                }
                event.post(tap: .cghidEventTap)
            }
        }
    }

    static let keyCodes: [String: Int] = [
        "return": kVK_Return, "enter": kVK_ANSI_KeypadEnter, "tab": kVK_Tab, "space": kVK_Space,
        "backspace": kVK_Delete, "delete": kVK_ForwardDelete, "esc": kVK_Escape,
        "left": kVK_LeftArrow, "right": kVK_RightArrow, "up": kVK_UpArrow, "down": kVK_DownArrow,
        "home": kVK_Home, "end": kVK_End, "pageup": kVK_PageUp, "pagedown": kVK_PageDown,
        "f1": kVK_F1, "f2": kVK_F2, "f3": kVK_F3, "f4": kVK_F4, "f5": kVK_F5, "f6": kVK_F6,
        "f7": kVK_F7, "f8": kVK_F8, "f9": kVK_F9, "f10": kVK_F10, "f11": kVK_F11, "f12": kVK_F12,
        "a": kVK_ANSI_A, "b": kVK_ANSI_B, "c": kVK_ANSI_C, "d": kVK_ANSI_D, "e": kVK_ANSI_E,
        "f": kVK_ANSI_F, "g": kVK_ANSI_G, "h": kVK_ANSI_H, "i": kVK_ANSI_I, "j": kVK_ANSI_J,
        "k": kVK_ANSI_K, "l": kVK_ANSI_L, "m": kVK_ANSI_M, "n": kVK_ANSI_N, "o": kVK_ANSI_O,
        "p": kVK_ANSI_P, "q": kVK_ANSI_Q, "r": kVK_ANSI_R, "s": kVK_ANSI_S, "t": kVK_ANSI_T,
        "u": kVK_ANSI_U, "v": kVK_ANSI_V, "w": kVK_ANSI_W, "x": kVK_ANSI_X, "y": kVK_ANSI_Y,
        "z": kVK_ANSI_Z, "0": kVK_ANSI_0, "1": kVK_ANSI_1, "2": kVK_ANSI_2, "3": kVK_ANSI_3,
        "4": kVK_ANSI_4, "5": kVK_ANSI_5, "6": kVK_ANSI_6, "7": kVK_ANSI_7, "8": kVK_ANSI_8,
        "9": kVK_ANSI_9, "minus": kVK_ANSI_Minus, "equal": kVK_ANSI_Equal, "comma": kVK_ANSI_Comma,
        "period": kVK_ANSI_Period, "slash": kVK_ANSI_Slash,
    ]

    func pressKey(_ name: String, modifiers: [String]) {
        guard let code = Self.keyCodes[name.lowercased()] else { return }
        var flags = CGEventFlags()
        for m in modifiers {
            switch m {
            case "cmd": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "alt", "option": flags.insert(.maskAlternate)
            case "ctrl": flags.insert(.maskControl)
            case "fn": flags.insert(.maskSecondaryFn)
            default: break
            }
        }
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down) else { continue }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
    }

    /// Media keys (play/pause, next, previous) are "system defined" events.
    func mediaKey(_ key: Int32) {
        for down in [true, false] {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = (Int(key) << 16) | ((down ? 0xa : 0xb) << 8)
            let event = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           subtype: 8, data1: data1, data2: -1)
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }

    // MARK: Unlock

    /// Wakes the display and types the login password into the lock screen.
    func unlock(password: String) {
        var assertion: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Simplex Remote" as CFString, kIOPMUserActiveLocal, &assertion)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.pressKey("space", modifiers: [])     // brings up the password field
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            self.typeText(password)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.9) {
            self.pressKey("return", modifiers: [])
            if assertion != 0 { IOPMAssertionRelease(assertion) }
        }
    }

    static var isScreenLocked: Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
