import Foundation
import Network
import CryptoKit

/// Http is the macOS easystream daemon's HTTP surface (A11Y_HTTP.md):
///
///   GET /            the embedded easystream web UI
///   GET /app.js      the web UI client
///   GET /est/ws      WebSocket <-> est byte pipe (transparent)
///   GET /a11y/<...>  the a11y API (AX-backed)
///
/// Built on Network.framework; the WebSocket handshake + framing are done here
/// so there is no third-party dependency (matching Serve.swift's style).
enum Http {
    static func run(port: UInt16, estPort: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { conn in
            let s = HTTPConn(conn: conn, estPort: estPort)
            s.start()
        }
        listener.start(queue: .global())
        FileHandle.standardError.write("easystream http on 0.0.0.0:\(port) (est pipe -> 127.0.0.1:\(estPort))\n".data(using: .utf8)!)
    }
}

final class HTTPConn {
    private static let lock = NSLock()
    private static var live: [ObjectIdentifier: HTTPConn] = [:]

    private let conn: NWConnection
    private let estPort: UInt16
    private var buf = Data()
    /// Set once the request has been handed off (e.g. upgraded to the est
    /// WebSocket). The generic receive loop must then STOP re-arming itself —
    /// otherwise it competes with wsPipe's own receive on the same connection
    /// and each loop steals about half of the incoming bytes (which is exactly
    /// how every other keystroke was lost).
    private var upgraded = false
    /// Per-connection serial queue. Running everything on .global() starved the
    /// receive loop once the video pump started flooding sends (input frames
    /// then stopped being delivered after ~a dozen reads).
    private let q = DispatchQueue(label: "http.conn")

    init(conn: NWConnection, estPort: UInt16) { self.conn = conn; self.estPort = estPort }

    func start() {
        HTTPConn.lock.lock(); HTTPConn.live[ObjectIdentifier(self)] = self; HTTPConn.lock.unlock()
        conn.start(queue: q)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let data = data { self.buf.append(data) }
            if err != nil || done { self.close(); return }
            self.maybeHandle()
            // Only continue the generic loop while we still own the socket.
            if !self.upgraded { self.receive() }
        }
    }

    /// maybeHandle dispatches once the request line + headers are complete.
    private func maybeHandle() {
        guard let headEnd = buf.range(of: Data("\r\n\r\n".utf8)) else { return }
        let head = String(data: buf[..<headEnd.lowerBound], encoding: .utf8) ?? ""
        let rest = buf[headEnd.upperBound...]
        guard let firstLine = head.split(separator: "\r\n").first else { return }
        let parts = firstLine.split(separator: " ")
        let url = parts.count >= 2 ? String(parts[1]) : "/"
        var headers: [String: String] = [:]
        for line in head.split(separator: "\r\n").dropFirst() {
            if let c = line.firstIndex(of: ":") {
                headers[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                    line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let path = url.split(separator: "?", maxSplits: 1).first.map(String.init) ?? "/"
        let query = url.contains("?") ? String(url.split(separator: "?", maxSplits: 1)[1]) : ""
        // View is the open default; only the control token upgrades to CONTROL.
        let token = Auth.tokenFrom(headers: headers, query: query)
        let mode = Auth.authorize(token)
        if mode == .view && Auth.a11yIsMutation(path: path, query: query) {
            upgraded = true; buf = Data()
            respond(status: 403, ctype: "text/plain", body: "read-only")
            return
        }
        // Stop the normal receive loop: we own the socket from here.
        upgraded = true
        buf = Data()
        if path == "/est/ws" {
            wsPipe(headers: headers, leftover: rest, mode: mode, wantAudio: query.contains("audio=1"))
            return
        }
        let body: String
        switch path {
        case "/", "/index.html": body = Assets.index
        case "/app.js": body = Assets.js
        case "/health": body = "ok"
        case "/a11y/screenshot":
            // The daemon process itself holds the Screen Recording grant, so a
            // capture from HERE is reliable (a spawned CLI child is not).
            if let png = try? Capture.screenshotPNG() {
                respondBinary(status: 200, ctype: "image/png", body: png)
                return
            }
            respond(status: 500, ctype: "text/plain", body: "screenshot failed")
            return
        default:
            if path.hasPrefix("/a11y/") {
                let r = a11y(path: path, query: query)
                respond(status: r.0, ctype: "text/plain; charset=utf-8", body: r.1)
                return
            }
            respond(status: 404, ctype: "text/plain", body: "not found")
            return
        }
        let ctype = path == "/app.js" ? "application/javascript; charset=utf-8" : "text/html; charset=utf-8"
        respond(status: 200, ctype: ctype, body: body)
    }

    private func respond(status: Int, ctype: String, body: String) {
        let bytes = Array(body.utf8)
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(ctype)\r\nCache-Control: no-store\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + Data(bytes), completion: .contentProcessed { _ in self.close() })
    }

    private func respondBinary(status: Int, ctype: String, body: Data) {
        let head = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Error")\r\nContent-Type: \(ctype)\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in self.close() })
    }

    private func close() {
        conn.cancel()
        HTTPConn.lock.lock(); HTTPConn.live[ObjectIdentifier(self)] = nil; HTTPConn.lock.unlock()
    }

    // ── WebSocket pipe ──────────────────────────────────────────────────────

    private func wsPipe(headers: [String: String], leftover: Data, mode: Auth.Mode, wantAudio: Bool) {
        guard let key = headers["sec-websocket-key"] else { close(); return }
        let accept = wsAccept(key)
        // Browsers REQUIRE the server to echo a subprotocol when the client
        // offered one, or they fail the connection. Echo "est" (never the token).
        var proto = "est"
        if let p = headers["sec-websocket-protocol"] {
            for part in p.split(separator: ",") {
                let t = part.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { proto = t; break }
            }
        }
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: \(proto)\r\n\r\n"
        // Connect to our own est listener.
        let params = NWParameters.tcp
        let est = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: estPort)!, using: params)
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
        est.start(queue: .global())
        // Propagate the mode to est with an Auth frame (defence in depth), and
        // ask for audio if the browser wants it.
        if !Auth.isOpen, let tok = (mode == .control
            ? ProcessInfo.processInfo.environment["EAZYSTREAM_CONTROL_TOKEN"]
            : ProcessInfo.processInfo.environment["EAZYSTREAM_VIEW_TOKEN"]) {
            var hdr = [UInt8](repeating: 0, count: 6)
            hdr[0] = 0x03
            let n = UInt32(tok.utf8.count)
            hdr[2] = UInt8((n >> 24) & 0xff); hdr[3] = UInt8((n >> 16) & 0xff)
            hdr[4] = UInt8((n >> 8) & 0xff); hdr[5] = UInt8(n & 0xff)
            est.send(content: Data(hdr) + Data(tok.utf8), completion: .contentProcessed { _ in })
        }
        if wantAudio {
            var hdr = [UInt8](repeating: 0, count: 6)
            hdr[0] = 0x06
            est.send(content: Data(hdr), completion: .contentProcessed { _ in })
        }
        // est -> browser
        func pumpEst() {
            est.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
                guard let self = self else { return }
                if let data = data, !data.isEmpty { self.sendWSBinary(data) }
                if err != nil || done { est.cancel(); self.close(); return }
                pumpEst()
            }
        }
        pumpEst()
        // browser -> est. ONE shared buffer, appended to as bytes arrive and
        // drained frame-by-frame. A WebSocket read can deliver several est
        // frames at once; the previous recursive version could drop/merge the
        // tail (the browser's input frames then arrived garbled and half of the
        // keystrokes were lost).
        let wsBuf = NSLock()
        var acc = leftover
        func drain() {
            while true {
                guard let (payload, consumed, isBinary, closed) = wsParse(acc) else { return }
                acc = acc.dropFirst(consumed)
                if closed { est.cancel(); self.close(); return }
                if isBinary {
                    // View mode: drop mutation frames before they reach est.
                    if mode == .view, let first = payload.first, Auth.isMutation(first) {
                        continue
                    }
                    est.send(content: payload, completion: .contentProcessed { err in
                        if let err = err {
                        }
                    })
                }
            }
        }
        drain()
        // A dedicated serial queue drives the receive loop. Re-arming the
        // receive from INSIDE the completion handler stopped delivering after a
        // dozen frames (half the keystrokes were lost — the rest stayed unread
        // in the client's socket buffer). Driving it from our own queue keeps
        // the loop alive.
        let wsQ = DispatchQueue(label: "est.ws.read")
        func pumpWS() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
                if let data = data, !data.isEmpty { wsBuf.lock(); acc.append(data); wsBuf.unlock() }
                wsBuf.lock(); drain(); wsBuf.unlock()
                if err != nil || done { est.cancel(); self.close(); return }
                wsQ.async { pumpWS() }
            }
        }
        wsQ.async { pumpWS() }
    }

    private func wsAccept(_ key: String) -> String {
        let magic = key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
        let digest = Insecure.SHA1.hash(data: Data(magic.utf8))
        return Data(digest).base64EncodedString()
    }

    private func sendWSBinary(_ payload: Data) {
        var frame = Data([0x82])
        let n = payload.count
        if n < 126 { frame.append(UInt8(n)) }
        else if n <= 0xffff { frame.append(126); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xff)) }
        else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (8 * i)) & 0xff)) }
        }
        frame.append(payload)
        conn.send(content: frame, completion: .contentProcessed { _ in })
    }

    /// wsParse returns (payload, bytesConsumed, isBinary, closed) or nil if the
    /// buffer does not yet hold a whole frame.
    private func wsParse(_ d: Data) -> (Data, Int, Bool, Bool)? {
        guard d.count >= 2 else { return nil }
        let b0 = d[d.startIndex]
        let b1 = d[d.startIndex + 1]
        let opcode = b0 & 0x0f
        let masked = (b1 & 0x80) != 0
        var len = Int(b1 & 0x7f)
        var off = 2
        if len == 126 {
            guard d.count >= 4 else { return nil }
            len = Int(d[d.startIndex + 2]) << 8 | Int(d[d.startIndex + 3]); off = 4
        } else if len == 127 {
            guard d.count >= 10 else { return nil }
            len = 0
            for i in 2..<10 { len = len << 8 | Int(d[d.startIndex + i]) }
            off = 10
        }
        var mask = [UInt8](repeating: 0, count: 4)
        if masked {
            guard d.count >= off + 4 else { return nil }
            for i in 0..<4 { mask[i] = d[d.startIndex + off + i] }
            off += 4
        }
        guard d.count >= off + len else { return nil }
        var payload = Data(d[(d.startIndex + off)..<(d.startIndex + off + len)])
        if masked { for i in payload.indices { payload[i] ^= mask[(i - payload.startIndex) % 4] } }
        return (payload, off + len, opcode == 0x2, opcode == 0x8)
    }

    // ── a11y ────────────────────────────────────────────────────────────────

    private func a11y(path: String, query: String) -> (Int, String) {
        let q = parseQuery(query)
        do {
            switch path {
            case "/a11y/apps":
                return (200, try CLI.appsText())
            case "/a11y/tree":
                return (200, try CLI.treeText(app: q["app"] ?? "", pid: q["pid"].flatMap { Int32($0) }, depth: Int(q["depth"] ?? "") ?? 999))
            case "/a11y/find":
                return (200, try CLI.findText(sel: q["sel"] ?? "*", app: q["app"] ?? "", pid: q["pid"].flatMap { Int32($0) }, output: q["o"] ?? "pretty"))
            case "/a11y/action":
                return (200, try CLI.actionText(action: q["action"] ?? "press", sel: q["sel"] ?? "*", value: q["value"], app: q["app"] ?? "", pid: q["pid"].flatMap { Int32($0) }))
            // ── input (the same verbs the Linux/Windows daemons expose) ──
            case "/a11y/click":
                Input.click(x: Int32(q["x"] ?? "") ?? 0, y: Int32(q["y"] ?? "") ?? 0,
                            button: q["button"] ?? "left", count: Int(q["count"] ?? "") ?? 1)
                return (200, "ok")
            case "/a11y/type":
                Input.typeText(q["text"] ?? "")
                return (200, "ok")
            case "/a11y/key":
                let held = (q["held"] ?? "").split(separator: ",").map(String.init)
                Input.key(q["name"] ?? "", held: held)
                return (200, "ok")
            case "/a11y/scroll":
                Input.scroll(x: Int32(q["x"] ?? "") ?? 0, y: Int32(q["y"] ?? "") ?? 0,
                             dx: Int32(q["dx"] ?? "") ?? 0, dy: Int32(q["dy"] ?? "") ?? 0)
                return (200, "ok")
            case "/a11y/drag":
                Input.drag(from: (Int32(q["x1"] ?? "") ?? 0, Int32(q["y1"] ?? "") ?? 0),
                           to: (Int32(q["x2"] ?? "") ?? 0, Int32(q["y2"] ?? "") ?? 0),
                           durationMs: Int(q["ms"] ?? "") ?? 200)
                return (200, "ok")
            case "/a11y/clipboard":
                if let set = q["set"] { try Clipboard.set(set); return (200, "ok") }
                return (200, try Clipboard.get())
            default:
                return (404, "unknown a11y path")
            }
        } catch {
            return (500, "error: \(error)")
        }
    }

    private func parseQuery(_ query: String) -> [String: String] {
        var m: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            if kv.count == 2 {
                let k = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let v = String(kv[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(kv[1])
                m[k] = v
            }
        }
        return m
    }
}

// The web UI (Assets) is defined in Assets.swift as INLINE string literals, so
// the single boot-fetched executable needs no SwiftPM resource bundle.
