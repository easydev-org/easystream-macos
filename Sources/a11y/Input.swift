import AppKit
import CoreGraphics
import Foundation

/// Input synthesizes pointer/keyboard events via CGEvent — the native macOS
/// equivalent of goa11y's InputProvider (CGEventPost, HID event tap).
enum Input {
    /// The last position the est client asked for. Pointer BUTTON / SCROLL
    /// events carry NO coordinates of their own, so they must reuse this:
    /// using the system cursor (CGEvent(source:).location) is wrong because
    /// the cursor can be elsewhere (a warp is also rate-limited by macOS),
    /// and the click then lands in the wrong place.
    private static let posLock = NSLock()
    private static var lastX: Int32 = 0
    private static var lastY: Int32 = 0
    private static func setLast(_ x: Int32, _ y: Int32) {
        posLock.lock(); lastX = x; lastY = y; posLock.unlock()
    }
    /// Which pointer button is currently held (0 none, 1 left, 2 middle,
    /// 3 right). A MOVE that arrives while a button is held must be sent as
    /// a DRAG event, not a plain mouseMoved: otherwise the down/up pair has
    /// a move in between and macOS treats a simple click as a press-and-
    /// hold / drag.
    private static var pressed: UInt8 = 0

    private static func lastPoint() -> CGPoint {
        posLock.lock(); defer { posLock.unlock() }
        return CGPoint(x: Double(lastX), y: Double(lastY))
    }

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
        setLast(x, y)
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
            // Prefer a REAL key press for ASCII: the unicode-string trick below
            // is unreliable — macOS frequently swallows the FIRST such event
            // (the user had to type twice for one character to appear).
            if let c = Character(scalar).asciiValue, let (code, shift) = KeyMap.charKey(Character(scalar)) {
                var flags = heldFlags
                if shift { flags.insert(.maskShift) }
                postKey(code, true, flags)
                postKey(code, false, flags)
                _ = c
                continue
            }
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
        setLast(x, y)
        let pt = CGPoint(x: Double(x), y: Double(y))
        // A plain CGWarpMouseCursorPosition moves the cursor but emits NO
        // event, so apps never see the movement (no hover, no drag tracking)
        // — and macOS suppresses synthetic mouse input for ~0.25s after a
        // warp, which swallowed the clicks that followed. Posting a real
        // .mouseMoved event moves the cursor AND delivers the movement.
        let typ: CGEventType
        switch pressed {
        case 1: typ = .leftMouseDragged
        case 2: typ = .otherMouseDragged
        case 3: typ = .rightMouseDragged
        default: typ = .mouseMoved
        }
        CGEvent(mouseEventSource: nil, mouseType: typ,
                mouseCursorPosition: pt, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    static func button(_ num: UInt8, down: Bool) {
        // A synthetic mouse event only registers as a CLICK if it carries a
        // click state (and pressure); otherwise the down/up pair is ignored.
        // The est path never set these (the CLI click() path did).
        if down { pressed = num } else if pressed == num { pressed = 0 }
        let pt = lastPoint()
        let (typ, mb): (CGEventType, CGMouseButton)
        switch num {
        case 2: (typ, mb) = (down ? .otherMouseDown : .otherMouseUp, .center)
        case 3: (typ, mb) = (down ? .rightMouseDown : .rightMouseUp, .right)
        default: (typ, mb) = (down ? .leftMouseDown : .leftMouseUp, .left)
        }
        if let e = CGEvent(mouseEventSource: nil, mouseType: typ, mouseCursorPosition: pt, mouseButton: mb) {
            e.setIntegerValueField(.mouseEventClickState, value: 1)
            e.setDoubleValueField(.mouseEventPressure, value: down ? 1.0 : 0.0)
            e.post(tap: .cghidEventTap)
        }
    }

    /// Modifier flags currently held (maintained across the est key stream,
    /// which sends each key as an independent press/release). A CGEvent must
    /// carry the modifier flags in its `flags` field: pressing the modifier
    /// KEY alone is not enough (macOS then sees, e.g., a bare Space).
    private static var heldFlags: CGEventFlags = []
    private static func isModifier(_ n: String) -> CGEventFlags { KeyMap.flag(n) }

    static func keyEvent(_ name: String, down: Bool) {
        guard let (code, _) = KeyMap.virtualKey(name) else { return }
        let m = KeyMap.flag(name)
        if m != [] {
            if down { heldFlags.formUnion(m) } else { heldFlags.subtract(m) }
        }
        postKey(code, down, heldFlags)
    }

    private static func currentCursor() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
