import CoreGraphics
import Foundation

/// CLI implements the easystream command surface (SPEC.md), matching the
/// goa11y/xa11y argument syntax and stdout formats so the worker can drive it
/// as a drop-in `a11y` backend.
enum CLI {

    /// flag parses `--name value` / `--name=value` out of args.
    struct Args {
        var positional: [String] = []
        var flags: [String: String] = [:]
        var bools: Set<String> = []
        init(_ raw: [String], boolFlags: Set<String> = []) {
            var i = 0
            while i < raw.count {
                let a = raw[i]
                if a.hasPrefix("--") {
                    let body = String(a.dropFirst(2))
                    if let eq = body.firstIndex(of: "=") {
                        flags[String(body[..<eq])] = String(body[body.index(after: eq)...])
                    } else if boolFlags.contains(body) {
                        bools.insert(body)
                    } else if i + 1 < raw.count {
                        flags[body] = raw[i + 1]; i += 1
                    } else {
                        bools.insert(body)
                    }
                } else {
                    positional.append(a)
                }
                i += 1
            }
        }
        func flag(_ k: String) -> String? { flags[k] }
    }

    /// run dispatches one command line (args after the program name).
    static func run(_ args: [String]) throws {
        guard let cmd = args.first else { printUsage(); return }
        let rest = Array(args.dropFirst())
        switch cmd {
        case "apps":         try cmdApps()
        case "windows":      try cmdWindows(Args(rest))
        case "shell":        try cmdShell()
        case "tree":         try cmdTree(Args(rest))
        case "find":         try cmdFind(Args(rest))
        case "action":       try cmdAction(Args(rest))
        case "click":        try cmdClick(Args(rest))
        case "type":         try cmdType(Args(rest))
        case "key":          try cmdKey(Args(rest))
        case "drag":         try cmdDrag(Args(rest))
        case "scroll":       try cmdScroll(Args(rest))
        case "screenshot":   try cmdScreenshot(Args(rest))
        case "clipboard":    try cmdClipboard(Args(rest))
        case "encode":       try cmdEncode(Args(rest))
        case "serve":        try cmdServe(Args(rest))
        case "-h", "--help", "help": printUsage()
        default: throw A11yError("unknown command \"\(cmd)\"")
        }
    }

    // ── tree ──────────────────────────────────────────────────────────────

    static func cmdServe(_ a: Args) throws {
        let port = UInt16(a.flag("--port") ?? ProcessInfo.processInfo.environment["EAZYSTREAM_PORT"] ?? "48079") ?? 48079
        let httpPort = UInt16(ProcessInfo.processInfo.environment["EAZYSTREAM_HTTP_PORT"] ?? "48078") ?? 48078
        // The HTTP surface (webui + /est/ws pipe + /a11y) runs alongside the est
        // listener in the SAME process, so the daemon is the only thing a viewer
        // or the worker connects to.
        try Http.run(port: httpPort, estPort: port)
        try Serve.run(port: port)
    }

    static func cmdApps() throws {
        // Tab-separated pid<TAB>name<TAB>focused (xa11y format).
        let focused = AX.focusedApp()
        let fp = focused?.pid ?? 0
        var any = false
        for app in AX.listApps() {
            let (pid, name) = AX.appInfo(app)
            if name.isEmpty { continue }
            any = true
            print("\(pid)\t\(name)\(pid == fp ? "\tfocused" : "")")
        }
        if !any { print("No applications found.") }
    }

    static func cmdWindows(_ a: Args) throws {
        let app = try resolveApp(a)
        let wins = app.children().filter { $0.role == "AXWindow" }
        if wins.isEmpty { print("No windows found."); return }
        for w in wins { print("\(w.displayName)") }
    }

    static func cmdShell() throws {
        // macOS shell surfaces: the menu bar of the frontmost app.
        guard let front = AX.focusedApp() else { print("No shell surfaces found."); return }
        print("menu_bar\t\(AX.appInfo(front).name)")
    }

    static func cmdTree(_ a: Args) throws {
        let root = try resolveApp(a)
        let depth = Int(a.flag("depth") ?? "") ?? 999
        var lines: [String] = []
        Tree.dump(root, depth: depth, prefix: "", lines: &lines)
        print(lines.joined(separator: "\n"))
    }

    static func cmdFind(_ a: Args) throws {
        let sel = a.positional.first ?? "*"
        let app = try resolveApp(a)
        let output = a.flag("o") ?? a.flag("output") ?? "pretty"
        let matcher = Selector(sel)
        var hits: [AXNode] = []
        Tree.walk(app, depth: 999) { n in
            if matcher.matches(n) { hits.append(n) }
        }
        for n in hits {
            switch output {
            case "bounds":
                if let b = n.bounds { print("\(b.x),\(b.y),\(b.w),\(b.h)") }
            case "center":
                if let b = n.bounds { print("\(b.x + Int32(b.w / 2)),\(b.y + Int32(b.h / 2))") }
            default:
                print("\(Role.name(n.role)) \"\(n.displayName)\"")
            }
        }
    }

    static func cmdAction(_ a: Args) throws {
        guard a.positional.count >= 2 else {
            throw A11yError("usage: a11y action ACTION SELECTOR [--value V]")
        }
        let action = a.positional[0]
        let selector = a.positional[1]
        let app = try resolveApp(a)
        let matcher = Selector(selector)
        guard let el = Tree.first(app, matching: matcher) else {
            throw A11yError("no element matched: \(selector)")
        }
        try Actions.perform(action, on: el, value: a.flag("value"))
    }

    // ── input ─────────────────────────────────────────────────────────────

    static func cmdClick(_ a: Args) throws {
        guard let at = a.flag("at"), let (x, y) = Rect.parsePoint(at) else {
            throw A11yError("usage: a11y click --at X,Y")
        }
        try Input.click(x: x, y: y,
                        button: a.flag("button") ?? "left",
                        count: Int(a.flag("count") ?? "1") ?? 1)
    }

    static func cmdType(_ a: Args) throws {
        let text = a.positional.first ?? a.flag("text") ?? ""
        try Input.typeText(text)
    }

    static func cmdKey(_ a: Args) throws {
        guard let key = a.positional.first else { throw A11yError("usage: a11y key KEY") }
        let held = (a.flag("held") ?? "").split(separator: ",").map(String.init)
        try Input.key(key, held: held)
    }

    static func cmdDrag(_ a: Args) throws {
        guard let f = a.flag("from"), let (fx, fy) = Rect.parsePoint(f),
              let t = a.flag("to"), let (tx, ty) = Rect.parsePoint(t) else {
            throw A11yError("usage: a11y drag --from X,Y --to X,Y")
        }
        try Input.drag(from: (fx, fy), to: (tx, ty),
                       durationMs: Int(a.flag("duration-ms") ?? "300") ?? 300)
    }

    static func cmdScroll(_ a: Args) throws {
        guard let at = a.flag("at"), let (x, y) = Rect.parsePoint(at) else {
            throw A11yError("usage: a11y scroll --at X,Y [--dx N] [--dy N]")
        }
        try Input.scroll(x: x, y: y,
                         dx: Int32(a.flag("dx") ?? "0") ?? 0,
                         dy: Int32(a.flag("dy") ?? "0") ?? 0)
    }

    // ── capture / clipboard ───────────────────────────────────────────────

    static func cmdScreenshot(_ a: Args) throws {
        guard let out = a.flag("out") else { throw A11yError("usage: a11y screenshot --out PATH") }
        let region = a.flag("region").flatMap(Rect.parseRegion)
        let (w, h) = try Capture.writePNG(to: out, region: region)
        // xa11y prints `wrote PATH (WxH @Nx)`; we mirror the (WxH) it parses.
        print("wrote \(out) (\(w)x\(h) @1x)")
    }

    static func cmdClipboard(_ a: Args) throws {
        if let set = a.flag("set") {
            try Clipboard.set(set)
        } else {
            print(try Clipboard.get(), terminator: "")
        }
    }

    /// cmdEncode captures N frames, H.264-encodes them with VideoToolbox, and
    /// writes the Annex-B stream to --out. It is the native, dependency-free
    /// equivalent of goa11y's `record` (minus the MP4 muxer).
    static func cmdEncode(_ a: Args) throws {
        guard let out = a.flag("out") else { throw A11yError("usage: a11y encode --out FILE.h264 [--frames N] [--fps N] [--bitrate N]") }
        let frames = Int(a.flag("frames") ?? "30") ?? 30
        let fps = Int(a.flag("fps") ?? "10") ?? 10
        let bitrate = Int(a.flag("bitrate") ?? "8000000") ?? 8_000_000

        // One capture to learn the size.
        guard let first = try captureFrame() else { throw A11yError("capture failed") }
        let (w, h) = (first.width, first.height)
        guard let enc = VTEncoder(width: w, height: h, fps: fps, bitrate: bitrate) else {
            throw A11yError("VideoToolbox session creation failed")
        }
        defer { enc.close() }

        var file = Data()
        var aus = 0
        var bgra = first.bgra
        for i in 0..<frames {
            if i > 0, let f = try captureFrame() { bgra = f.bgra }
            for au in enc.encode(bgra) {
                file.append(au); aus += 1
            }
            usleep(useconds_t(1_000_000 / fps))
        }
        try file.write(to: URL(fileURLWithPath: out))
        print("encoded \(w)x\(h) frames=\(frames) aus=\(aus) bytes=\(file.count) -> \(out)")
    }

    /// captureFrame grabs one full-screen frame as BGRA (stride = w*4).
    private static func captureFrame() throws -> (width: Int, height: Int, bgra: [UInt8])? {
        guard let cg = try? Capture.screenshotCG() else { return nil }
        let w = cg.width, h = cg.height
        var bgra = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        bgra.withUnsafeMutableBytes { buf in
            if let ctx = CGContext(data: buf.baseAddress, width: w, height: h,
                                   bitsPerComponent: 8, bytesPerRow: w * 4,
                                   space: cs, bitmapInfo: info) {
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            }
        }
        return (w, h, bgra)
    }

    // ── helpers ───────────────────────────────────────────────────────────

    /// resolveApp returns the AX root for --app NAME / --pid PID / focused app.
    static func resolveApp(_ a: Args) throws -> AXNode {
        if let pidStr = a.flag("pid"), let pid = pid_t(pidStr) {
            return AXNode.app(pid: pid)
        }
        if let name = a.flag("app") {
            for app in AX.listApps() {
                let (_, n) = AX.appInfo(app)
                if n == name { return app }
            }
            throw A11yError("application \"\(name)\" not found")
        }
        guard let f = AX.focusedApp() else { throw A11yError("no focused application") }
        return f
    }

    // ── text helpers for the HTTP surface (A11Y_HTTP.md) ────────────────────
    // These return the SAME formats the CLI prints, so the HTTP layer and the
    // one-shot CLI stay in lockstep.

    private static func resolve(app: String, pid: Int32?) throws -> AXNode {
        if let pid = pid { return AXNode.app(pid: pid) }
        if !app.isEmpty {
            for a in AX.listApps() {
                if AX.appInfo(a).name == app { return a }
            }
            throw A11yError("application \"\(app)\" not found")
        }
        guard let f = AX.focusedApp() else { throw A11yError("no focused application") }
        return f
    }

    static func appsText() throws -> String {
        let fp = AX.focusedApp()?.pid ?? 0
        var lines: [String] = []
        for app in AX.listApps() {
            let (pid, name) = AX.appInfo(app)
            if name.isEmpty { continue }
            lines.append("\(pid)\t\(name)\(pid == fp ? "\tfocused" : "")")
        }
        return lines.isEmpty ? "No applications found." : lines.joined(separator: "\n")
    }

    static func treeText(app: String, pid: Int32?, depth: Int) throws -> String {
        let root = try resolve(app: app, pid: pid)
        var lines: [String] = []
        Tree.dump(root, depth: depth, prefix: "", lines: &lines)
        return lines.joined(separator: "\n")
    }

    static func findText(sel: String, app: String, pid: Int32?, output: String) throws -> String {
        let root = try resolve(app: app, pid: pid)
        let matcher = Selector(sel)
        var hits: [AXNode] = []
        Tree.walk(root, depth: 999) { n in if matcher.matches(n) { hits.append(n) } }
        var lines: [String] = []
        for n in hits {
            switch output {
            case "bounds": if let b = n.bounds { lines.append("\(b.x),\(b.y),\(b.w),\(b.h)") }
            case "center": if let b = n.bounds { lines.append("\(b.x + Int32(b.w / 2)),\(b.y + Int32(b.h / 2))") }
            // "value" prints the element's AXValue (its CONTENT). The default
            // (title) is empty for a text area, so this is the only way to read
            // e.g. a TextEdit document over the a11y API.
            case "value": lines.append(n.value)
            default: lines.append("\(Role.name(n.role)) \"\(n.displayName)\"")
            }
        }
        return lines.isEmpty ? "no match" : lines.joined(separator: "\n")
    }

    static func actionText(action: String, sel: String, value: String?, app: String, pid: Int32?) throws -> String {
        let root = try resolve(app: app, pid: pid)
        guard let node = Tree.first(root, matching: Selector(sel)) else {
            throw A11yError("no match for \(sel)")
        }
        try Actions.perform(action, on: node, value: value)
        return "ok"
    }

    static func printUsage() {
        print("""
        a11y — native accessibility CLI (macOS)
          a11y apps
          a11y windows [--app NAME|--pid PID]
          a11y tree    [--app NAME|--pid PID] [--depth N]
          a11y find    SELECTOR [--app NAME|--pid PID] [-o pretty|bounds|center]
          a11y action  ACTION SELECTOR [--app NAME|--pid PID] [--value V]
          a11y click   --at X,Y [--button left|right|middle] [--count N]
          a11y type    TEXT
          a11y key     KEY [--held A,B]
          a11y drag    --from X,Y --to X,Y [--duration-ms N]
          a11y scroll  --at X,Y [--dx N] [--dy N]
          a11y screenshot --out PATH [--region X,Y,W,H]
          a11y clipboard [--set TEXT]
        """)
    }
}
