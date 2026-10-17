import Foundation

/// Capability probe.
///
/// Mirrors the Linux daemon's /capabilities endpoint (see easydev-org/easystream
/// A11Y_HTTP.md) so a viewer or the Go worker can ask "which path did each
/// capability resolve to?" without reading logs.
///
/// Most answers on macOS are fixed, but the AUDIO one is not: it depends on the
/// BlackHole loopback device being installed (see Audio.swift), which is checked
/// once at startup.
enum Probe {
    enum Session: String {
        case macos = "MacOS"
        case none = "None"
    }

    enum CapturePath: String {
        /// AVCaptureScreenInput (AVFoundation) — used instead of ScreenCaptureKit
        /// because this VM's software renderer breaks SCStream.
        case avCapture = "AVCaptureScreenInput"
        case none = "None"
    }

    enum InputPath: String {
        /// CGEventPost.
        case cgEvent = "CGEvent"
        case none = "None"
    }

    enum A11yPath: String {
        /// The AX (Accessibility) API.
        case ax = "AX"
        case none = "None"
    }

    enum ClipboardPath: String {
        /// NSPasteboard.
        case pasteboard = "NSPasteboard"
        case none = "None"
    }

    /// capabilities runs once and caches the result for the process lifetime.
    static let capabilities: (session: Session, capture: CapturePath, input: InputPath,
                              a11y: A11yPath, clipboard: ClipboardPath, notes: [String]) = {
        (
            session: .macos,
            capture: .avCapture,
            input: .cgEvent,
            a11y: .ax,
            clipboard: .pasteboard,
            notes: [
                "macos: AVCaptureScreenInput + VideoToolbox + CGEvent + AX",
                "capture: ScreenCaptureKit unusable in this VM (software renderer)",
                "audio: BlackHole loopback in a clocked aggregate device, read via AUHAL",
            ]
        )
    }()

    /// toJSON renders the same shape the Linux daemon emits. `audio` is queried
    /// lazily so it can say "Probing" until the device check has run.
    static func toJSON() -> String {
        let c = capabilities
        let notes = c.notes
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "'"))\"" }
            .joined(separator: ",")
        return """
        {"session":"\(c.session.rawValue)","capture":"\(c.capture.rawValue)",\
        "input":"\(c.input.rawValue)","a11y":"\(c.a11y.rawValue)",\
        "clipboard":"\(c.clipboard.rawValue)","audio":"\(AudioPipeline.audioPath())",\
        "notes":[\(notes)]}
        """
    }
}
