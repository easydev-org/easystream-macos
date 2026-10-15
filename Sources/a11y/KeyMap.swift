import CoreGraphics
import Foundation

/// KeyMap maps goa11y named keys / characters to macOS virtual keycodes
/// (kVK_*), matching pure-Go goa11y's macos_pure keymap.
enum KeyMap {
    static func virtualKey(_ name: String) -> (CGKeyCode, Bool)? {
        // Normalise (lowercase, drop '_'/spaces) so every spelling resolves:
        // the frontend sends "Backspace"/"PageUp"/"Shift", X11-style callers
        // used "BackSpace"/"Page_Up"/"Shift_L".
        let n = name.lowercased().replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: " ", with: "")
        if let k = named[n] { return (k, false) }
        if let ch = name.first, let k = char(ch) { return k }
        return nil
    }

    /// flag maps a modifier name to its CGEventFlags bit.
    static func flag(_ name: String) -> CGEventFlags {
        switch name.lowercased() {
        case "shift": return .maskShift
        case "ctrl", "control": return .maskControl
        case "alt", "option": return .maskAlternate
        case "cmd", "command", "meta", "super": return .maskCommand
        default: return []
        }
    }

    private static let named: [String: CGKeyCode] = [
        "return": 0x24, "enter": 0x24, "escape": 0x35, "esc": 0x35, "tab": 0x30,
        // macOS: Backspace (delete the char BEFORE the cursor) = 0x33;
        // Delete / ForwardDelete (delete the char AFTER) = 0x75. They used to
        // share 0x33, so the browser's Delete key deleted backwards.
        "space": 0x31, "backspace": 0x33,
        "delete": 0x75, "forwarddelete": 0x75, "del": 0x75,
        "up": 0x7E, "down": 0x7D, "left": 0x7B, "right": 0x7C,
        "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "shift": 0x38, "ctrl": 0x3B, "control": 0x3B, "alt": 0x3A, "option": 0x3A,
        "cmd": 0x37, "command": 0x37, "meta": 0x37, "super": 0x37,
        // X11/Linux-style modifier aliases (est clients send these names). The
        // lookup strips '_' and spaces, so these keys must have NO underscore
        // ("Meta_L" normalises to "metal").
        "metal": 0x37, "superl": 0x37, "commandl": 0x37,
        "shiftl": 0x38, "shiftr": 0x3C,
        "controll": 0x3B, "ctrll": 0x3B, "controlr": 0x3E,
        "altl": 0x3A, "optionl": 0x3A, "altr": 0x3D,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61,
        "f7": 0x62, "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F,
    ]

    /// charKey is the public entry point for character -> keycode lookups.
    static func charKey(_ c: Character) -> (CGKeyCode, Bool)? { char(c) }

    private static func char(_ c: Character) -> (CGKeyCode, Bool)? {
        if let k = charMap[c] { return (k, false) }
        if let k = shiftMap[c] { return (k, true) }
        if c.isUppercase, let k = charMap[Character(c.lowercased())] { return (k, true) }
        return nil
    }

    private static let charMap: [Character: CGKeyCode] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "1": 0x12,
        "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "=": 0x18,
        "9": 0x19, "7": 0x1A, "-": 0x1B, "8": 0x1C, "0": 0x1D, "]": 0x1E,
        "o": 0x1F, "u": 0x20, "[": 0x21, "i": 0x22, "p": 0x23, "l": 0x25,
        "j": 0x26, "'": 0x27, "k": 0x28, ";": 0x29, "\\": 0x2A, ",": 0x2B,
        "/": 0x2C, "n": 0x2D, "m": 0x2E, ".": 0x2F, "`": 0x32,
    ]

    private static let shiftMap: [Character: CGKeyCode] = [
        "!": 0x12, "@": 0x13, "#": 0x14, "$": 0x15, "%": 0x17, "^": 0x16,
        "&": 0x1A, "*": 0x19, "(": 0x1D, ")": 0x1C, "_": 0x1B, "+": 0x18,
        "{": 0x21, "}": 0x1E, "|": 0x2A, ":": 0x29, "\"": 0x27, "<": 0x2B,
        ">": 0x2E, "?": 0x2C, "~": 0x32,
    ]
}
