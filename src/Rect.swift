import CoreGraphics
import Foundation

/// Rect mirrors goa11y's Rect: a top-left-anchored, logical-coordinate
/// rectangle. CG uses the same origin for the "flipped" screen space we want,
/// so this is a thin alias with parsing helpers.
struct Rect: Equatable {
    var x: Int32
    var y: Int32
    var w: UInt32
    var h: UInt32

    var cg: CGRect {
        CGRect(x: Double(x), y: Double(y), width: Double(w), height: Double(h))
    }

    /// Parses the `x,y,w,h` region form (spaces allowed), matching goa11y.
    static func parseRegion(_ s: String) -> Rect? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 4,
              let x = Int32(parts[0]), let y = Int32(parts[1]),
              let w = UInt32(parts[2]), let h = UInt32(parts[3]) else { return nil }
        return Rect(x: x, y: y, w: w, h: h)
    }

    /// Parses the `x,y` point form.
    static func parsePoint(_ s: String) -> (Int32, Int32)? {
        let parts = s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let x = Int32(parts[0]), let y = Int32(parts[1]) else { return nil }
        return (x, y)
    }
}
