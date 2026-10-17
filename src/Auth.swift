import Foundation

/// Access control: two modes, chosen by the token the client presents.
///
///   * VIEW    — read-only (the DEFAULT): video, a11y reads, screenshots and
///               clipboard READS work with NO token. Every frame that would
///               CHANGE the guest (input, a11y action, clipboard write) is
///               dropped.
///   * CONTROL — everything VIEW can do PLUS input, a11y actions and clipboard
///               writes. Requires the control token.
///
/// Tokens come from the environment:
///   EAZYSTREAM_CONTROL_TOKEN   grants CONTROL
///   EAZYSTREAM_VIEW_TOKEN      (optional) an explicit read-only token
///
/// Behaviour:
///   * no token at all          -> VIEW (read-only), always allowed
///   * the control token        -> CONTROL
///   * anything else            -> VIEW
///   * NEITHER token configured -> CONTROL for everyone (auth off)
enum Auth {
    enum Mode: UInt8 { case view = 0, control = 1 }

    private static let control: String? = {
        let v = ProcessInfo.processInfo.environment["EAZYSTREAM_CONTROL_TOKEN"]
        return (v?.isEmpty == false) ? v : nil
    }()
    private static let view: String? = {
        let v = ProcessInfo.processInfo.environment["EAZYSTREAM_VIEW_TOKEN"]
        return (v?.isEmpty == false) ? v : nil
    }()
    /// True when no token is configured at all (auth disabled).
    static let isOpen: Bool = { control == nil && view == nil }()

    /// authorize maps a presented token to a Mode. It NEVER fails: view is the
    /// open default, so a missing or wrong token simply means read-only.
    static func authorize(_ token: String?) -> Mode {
        if isOpen { return .control }
        let t = token ?? ""
        if let c = control, ctEq(t, c) { return .control }
        return .view
    }

    /// isMutation reports whether an est frame type CHANGES the guest.
    static func isMutation(_ typ: UInt8) -> Bool {
        switch typ {
        case 0x10, 0x11, 0x12, 0x13, 0x14,  // pointer + keyboard
             0x26,                          // a11y ActionReq
             0x32:                          // ClipSet
            return true
        default:
            return false
        }
    }

    /// constant-time equality (avoids leaking the token via timing).
    private static func ctEq(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.count != y.count { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    /// tokenFrom extracts the token from the request: the 2nd item of the
    /// Sec-WebSocket-Protocol header ("est, <token>"), else ?token=.
    static func tokenFrom(headers: [String: String], query: String) -> String? {
        if let proto = headers["sec-websocket-protocol"] {
            for part in proto.split(separator: ",") {
                let p = part.trimmingCharacters(in: .whitespaces)
                if !p.isEmpty && p != "est" { return p }
            }
        }
        for kv in query.split(separator: "&") {
            if kv.hasPrefix("token=") {
                let v = String(kv.dropFirst("token=".count))
                if !v.isEmpty { return v }
            }
        }
        return nil
    }

    /// a11yIsMutation reports whether an /a11y/* request CHANGES the guest.
    static func a11yIsMutation(path: String, query: String) -> Bool {
        switch path {
        case "/a11y/action", "/a11y/click", "/a11y/type", "/a11y/key",
             "/a11y/scroll", "/a11y/drag":
            return true
        case "/a11y/clipboard":
            return query.split(separator: "&").contains { $0.hasPrefix("set=") }
        default:
            return false
        }
    }
}
