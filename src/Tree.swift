import Foundation

/// Tree walks the AX hierarchy with a bounded depth, mirroring goa11y's
/// lazy, on-demand navigation.
enum Tree {
    /// walk visits node and its descendants (depth-limited).
    static func walk(_ root: AXNode, depth: Int, _ visit: (AXNode) -> Void) {
        visit(root)
        if depth <= 0 { return }
        for c in root.children() {
            walk(c, depth: depth - 1, visit)
        }
    }

    /// first returns the first node matching the selector (depth-first).
    static func first(_ root: AXNode, matching sel: Selector) -> AXNode? {
        var found: AXNode?
        walk(root, depth: 999) { n in
            if found == nil && sel.matches(n) { found = n }
        }
        return found
    }

    /// dump renders an indented tree with box-drawing connectors, matching
    /// xa11y's `tree` output. The root prints bare; children get `├── `/`└── `
    /// and the continuation prefix (`│   `/`    `) is threaded down.
    static func dump(_ node: AXNode, depth: Int, prefix: String, lines: inout [String]) {
        // Caller passes the connector for THIS node ("" for the root).
        let label = Role.name(node.role) + (node.displayName.isEmpty ? "" : " \"\(node.displayName)\"")
        lines.append(prefix + label)
        guard depth > 0 else { return }
        let kids = node.children()
        // The prefix children extend from: strip the connector we printed,
        // replacing it with the matching continuation.
        let childBase: String
        if prefix.hasSuffix("├── ") { childBase = String(prefix.dropLast(4)) + "│   " }
        else if prefix.hasSuffix("└── ") { childBase = String(prefix.dropLast(4)) + "    " }
        else { childBase = prefix }
        for (i, k) in kids.enumerated() {
            let last = i == kids.count - 1
            let branch = last ? "└── " : "├── "
            dump(k, depth: depth - 1, prefix: childBase + branch, lines: &lines)
        }
    }
}
