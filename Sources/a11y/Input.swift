import AppKit
import CoreGraphics
import Foundation

/// Input synthesizes pointer/keyboard events via CGEvent — the native macOS
/// equivalent of goa11y's InputProvider (CGEventPost, HID event tap).
enum Input {

    static func click(x: Int32, y: Int32, button: String, count: Int) {
        let pt = CGPoint(x: Double(x), y: Double(y))
        let (down, up, mouseBtn): (CGEventType, CGEventType, CGMouseButton)
        switch button {
        case "right":  (down, up, mouseBtn) = (.rightMouseDown, .rightMouseUp, .right)
        case "middle": (down, up, mouseBtn) = (.otherMouseDown, .otherMouseUp, .center)
        default:       (down, up, mouseBtn) = (.leftMouseDown, .leftMouseUp, .left)
        }
        CGWarpMouseCursorPosition(pt)
        for n in 0..<max(1, count) {
            let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: pt, mouseButton: mouseBtn)
            let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: pt, mouseButton: mouseBtn)
            // Double/triple clicks carry the click state so apps see dblclick.
            d?.setIntegerValueField(.mouseEventClickState, value: Int64(n + 1))
            u?.setIntegerValueField(.mouseEventClickState, value: Int64(n + 1))
            d?.post(tap: .cghidEventTap)
            u?.post(tap: .cghidEventTap)
        }
    }

    static func drag(from: (Int32, Int32), to: (Int32, Int32), durationMs: Int) {
        let a = CGPoint(x: Double(from.0), y: Double(from.1))
        let b = CGPoint(x: Double(to.0), y: Double(to.1))
        CGWarpMouseCursorPosition(a)
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: a, mouseButton: .left)?
            .post(tap: .cghidEventTap)
        let steps = max(1, durationMs / 16)
        for i in 1...steps {
            let t = Double(i) / Double(steps)
            let p = CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
            CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: p, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            usleep(useconds_t(durationMs * 1000 / steps))
        }
        CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: b, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func scroll(x: Int32, y: Int32, dx: Int32, dy: Int32) {
        CGWarpMouseCursorPosition(CGPoint(x: Double(x), y: Double(y)))
        // A line ≈ 10 px of wheel delta.
        let wheelY = Int32(-dy / 10)
        let wheelX = Int32(-dx / 10)
        if let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                           wheel1: wheelY, wheel2: wheelX, wheel3: 0) {
            e.post(tap: .cghidEventTap)
        }
    }

    /// key presses one key with optional held modifiers, then releases.
    static func key(_ name: String, held: [String]) {
        guard let (code, _) = KeyMap.virtualKey(name) else { return }
        var flags: CGEventFlags = []
        for h in held { flags.formUnion(KeyMap.flag(h)) }
        for h in held { if let (c, _) = KeyMap.virtualKey(h) { postKey(c, true, flags) } }
        postKey(code, true, flags)
        postKey(code, false, flags)
        for h in held.reversed() { if let (c, _) = KeyMap.virtualKey(h) { postKey(c, false, flags) } }
    }

    /// typeText sends a unicode string as key events (layout-independent), the
    /// same trick goa11y uses for arbitrary text.
    static func typeText(_ text: String) {
        for scalar in text.unicodeScalars {
            var u = UniChar(scalar.value)
            if let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
               let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) {
                down.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                up.keyboardSetUnicodeString(stringLength: 1, unicodeString: &u)
                down.post(tap: .cghidEventTap)
                up.post(tap: .cghidEventTap)
            }
        }
    }

    private static func postKey(_ code: CGKeyCode, _ down: Bool, _ flags: CGEventFlags) {
        if let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down) {
            e.flags = flags
            e.post(tap: .cghidEventTap)
        }
    }

    // ── est additions (single events, driven by the est daemon) ──────────
    static func warp(x: Int32, y: Int32) {
        CGWarpMouseCursorPosition(CGPoint(x: Double(x), y: Double(y)))
    }

    static func button(_ num: UInt8, down: Bool) {
        let pt = currentCursor()
        let (typ, mb): (CGEventType, CGMouseButton)
        switch num {
        case 2: (typ, mb) = (down ? .otherMouseDown : .otherMouseUp, .center)
        case 3: (typ, mb) = (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (typ, mb) = (down ? .leftMouseDown : .leftMouseUp, .left)
        }
        CGEvent(mouseEventSource: nil, mouseType: typ, mouseCursorPosition: pt, mouseButton: mb)?
            .post(tap: .cghidEventTap)
    }

    static func keyEvent(_ name: String, down: Bool) {
        guard let (code, _) = KeyMap.virtualKey(name) else { return }
        postKey(code, down, [])
    }

    private static func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
