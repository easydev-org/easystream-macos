import AppKit
import Foundation

/// Clipboard reads/writes the macOS pasteboard via NSPasteboard — the native
/// equivalent of goa11y's pbcopy/pbpaste backend, with no subprocess.
enum Clipboard {
    static func get() throws -> String {
        NSPasteboard.general.string(forType: .string) ?? ""
    }
    static func set(_ text: String) throws {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }
}
