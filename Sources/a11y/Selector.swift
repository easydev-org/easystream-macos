import Foundation

/// Selector is the goa11y CSS-ish matcher: a comma-separated group of spaces /
/// `>` chains, each segment being `role` or `*` with optional `[attr op "v"]`.
/// We support the common subset the CLI documents (role, *, attribute ops).
struct Selector {
    private let group: [[Segment]]

    struct Segment {
        var role: String?      // nil = any ("*")
        var attrs: [(attr: String, op: Op, value: String)] = []
    }
    enum Op: String { case eq = "=", contains = "*=", starts = "^=", ends = "$=" }

    init(_ s: String) {
        group = s.split(separator: ",").map { clause in
            Selector.parse(String(clause))
        }
    }

    /// parse turns one clause ("window > button[title='OK']") into segments.
    private static func parse(_ clause: String) -> [Segment] {
        var segs: [Segment] = []
        let parts = clause.split(separator: ">").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for p in parts {
            segs.append(parseSimple(p))
        }
        return segs
    }

    private static func parseSimple(_ s: String) -> Segment {
        var seg = Segment()
        var head = s
        // Strip [..] filters.
        while let lb = head.firstIndex(of: "["), let rb = head.firstIndex(of: "]") {
            let inner = String(head[head.index(after: lb)..<rb])
            if let f = parseAttr(inner) { seg.attrs.append(f) }
            head = String(head[head.index(after: rb)...])
        }
        let r = head.trimmingCharacters(in: .whitespaces)
        if !r.isEmpty && r != "*" { seg.role = r }
        return seg
    }

    private static func parseAttr(_ s: String) -> (String, Op, String)? {
        // Form: attr OP "value" — OP is one of =,*=,^=,$=
        let ops: [Op] = [.contains, .starts, .ends, .eq]
        for op in ops where s.contains(op.rawValue) {
            guard let r = s.range(of: op.rawValue) else { continue }
            let attr = String(s[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            var val = String(s[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            val = val.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return (attr, op, val)
        }
        return nil
    }

    /// matches reports whether the element satisfies the whole selector (we
    /// evaluate the LAST segment against the element, which is what a
    /// single-element match needs; chains are honored by walking ancestors).
    func matches(_ node: AXNode) -> Bool {
        for segs in group where matchChain(segs, node) { return true }
        return false
    }

    private func matchChain(_ segs: [Segment], _ node: AXNode) -> Bool {
        guard let last = segs.last else { return false }
        guard matchSimple(last, node) else { return false }
        // Ancestor chain: walk up, matching segments right-to-left.
        var cur = node.parent()
        var i = segs.count - 2
        while i >= 0, let c = cur {
            if matchSimple(segs[i], c) { i -= 1 }
            cur = c.parent()
        }
        return i < 0
    }

    private func matchSimple(_ seg: Segment, _ node: AXNode) -> Bool {
        if let r = seg.role, Role.name(node.role) != r { return false }
        for f in seg.attrs {
            let v: String
            switch f.attr {
            case "title", "name": v = node.displayName
            case "value": v = node.value
            case "desc", "description": v = node.desc
            default: v = ""
            }
            switch f.op {
            case .eq:       if v != f.value { return false }
            case .contains: if !v.contains(f.value) { return false }
            case .starts:   if !v.hasPrefix(f.value) { return false }
            case .ends:     if !v.hasSuffix(f.value) { return false }
            }
        }
        return true
    }
}
