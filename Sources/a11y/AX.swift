import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// AX wraps one AXUIElement: a handle to a node in an app's accessibility tree.
/// AXUIElementRef is a CFType, so it is reference-counted; we keep the raw
/// pointer and rely on ARC of the wrapping class.
final class AXNode {
    let el: AXUIElement
    init(_ el: AXUIElement) { self.el = el }

    /// role returns the AX role (e.g. "AXButton"); the goa11y role vocabulary
    /// is a lower_snake_case mapping of these (see Role.swift).
    var role: String { string("AXRole") }
    var subrole: String { string("AXSubrole") }
    var title: String { string("AXTitle") }
    var desc: String { string("AXDescription") }
    var value: String {
        let s = string("AXValue")
        if !s.isEmpty { return s }
        if let n = cf("AXValue"), CFGetTypeID(n) == CFNumberGetTypeID() {
            return (unsafeBitCast(n, to: NSNumber.self)).stringValue
        }
        return ""
    }
    /// cf reads one attribute as a raw CFTypeRef (nil when absent).
    func cf(_ attr: String) -> CFTypeRef? {
        var ref: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(el, attr as CFString, &ref)
        guard err == .success else { return nil }
        return ref
    }
    /// string reads one attribute coerced to String ("" when it is not one).
    func string(_ attr: String) -> String {
        guard let r = cf(attr), CFGetTypeID(r) == CFStringGetTypeID() else { return "" }
        return (unsafeBitCast(r, to: CFString.self)) as String
    }
    var pid: pid_t? {
        var p: pid_t = 0
        if AXUIElementGetPid(el, &p) == .success { return p }
        return nil
    }
    /// bounds returns the element's frame in SCREEN coordinates (top-left
    /// origin, points) — the same space CGEvent expects.
    var bounds: Rect? {
        // AXPosition / AXSize are AXValue CFTypeRefs; Swift forbids `as?` on
        // CoreFoundation types, so check the type id then bitcast.
        guard let posRef = cf("AXPosition"), CFGetTypeID(posRef) == AXValueGetTypeID(),
              let sizeRef = cf("AXSize"), CFGetTypeID(sizeRef) == AXValueGetTypeID()
        else { return nil }
        let pos: AXValue = unsafeBitCast(posRef, to: AXValue.self)
        let size: AXValue = unsafeBitCast(sizeRef, to: AXValue.self)
        var pt = CGPoint.zero
        var sz = CGSize.zero
        AXValueGetValue(pos, .cgPoint, &pt)
        AXValueGetValue(size, .cgSize, &sz)
        guard sz.width > 0, sz.height > 0 else { return nil }
        return Rect(x: Int32(pt.x), y: Int32(pt.y),
                    w: UInt32(sz.width.rounded()), h: UInt32(sz.height.rounded()))
    }
    /// displayName prefers the human name AX shows: title, else description.
    var displayName: String { title.isEmpty ? desc : title }

    /// children returns direct AX children (AXChildren).
    func children() -> [AXNode] {
        guard let ref = cf("AXChildren"),
              CFGetTypeID(ref) == CFArrayGetTypeID() else { return [] }
        let arr = unsafeBitCast(ref, to: CFArray.self)
        let n = CFArrayGetCount(arr)
        var out: [AXNode] = []
        out.reserveCapacity(n)
        for i in 0..<n {
            let p = CFArrayGetValueAtIndex(arr, i)
            out.append(AXNode(unsafeBitCast(p, to: AXUIElement.self)))
        }
        return out
    }
    /// parent returns the AX parent (AXParent).
    func parent() -> AXNode? {
        guard let ref = cf("AXParent"),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return AXNode(unsafeBitCast(ref, to: AXUIElement.self))
    }

    /// actionNames lists the AX actions the element supports.
    func actionNames() -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success,
              let arr = names else { return [] }
        let n = CFArrayGetCount(arr)
        var out: [String] = []
        for i in 0..<n {
            let p = CFArrayGetValueAtIndex(arr, i)
            let s = unsafeBitCast(p, to: CFString.self)
            out.append(s as String)
        }
        return out
    }
    /// perform runs one AX action.
    @discardableResult
    func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(el, action as CFString)
    }
    /// set writes one attribute (e.g. AXValue, AXFocused).
    @discardableResult
    func set(_ attr: String, _ v: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(el, attr as CFString, v)
    }

    static func app(pid: pid_t) -> AXNode {
        AXNode(AXUIElementCreateApplication(pid))
    }
    static func systemWide() -> AXNode {
        AXNode(AXUIElementCreateSystemWide())
    }
}

/// AX is the macOS accessibility backend (the goa11y Provider equivalent).
enum AX {

    /// focusedApp returns the system-wide focused application.
    static func focusedApp() -> AXNode? {
        guard let ref = AXNode.systemWide().cf("AXFocusedApplication"),
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
        return AXNode(unsafeBitCast(ref, to: AXUIElement.self))
    }

    /// listApps enumerates running apps that expose an accessibility element:
    /// our own pid's AX element for each NSRunningApplication.
    static func listApps() -> [AXNode] {
        let apps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy != .prohibited && $0.processIdentifier > 0
        }
        return apps.map { AXNode.app(pid: $0.processIdentifier) }
    }

    /// appInfo is the (pid, name) a caller prints.
    static func appInfo(_ n: AXNode) -> (pid: pid_t, name: String) {
        let p = n.pid ?? 0
        var name = n.title
        if name.isEmpty {
            name = NSRunningApplication(processIdentifier: p)?.localizedName ?? "pid \(p)"
        }
        return (p, name)
    }
}
