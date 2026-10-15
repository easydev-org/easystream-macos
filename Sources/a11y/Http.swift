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

    init(conn: NWConnection, estPort: UInt16) { self.conn = conn; self.estPort = estPort }

    func start() {
        HTTPConn.lock.lock(); HTTPConn.live[ObjectIdentifier(self)] = self; HTTPConn.lock.unlock()
        conn.start(queue: .global())
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self = self else { return }
            if let data = data { self.buf.append(data) }
            if err != nil || done { self.close(); return }
            self.maybeHandle()
            self.receive()
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
        // Stop the normal receive loop: we own the socket from here.
        buf = Data()
        if path == "/est/ws" {
            wsPipe(headers: headers, leftover: rest)
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

    private func wsPipe(headers: [String: String], leftover: Data) {
        guard let key = headers["sec-websocket-key"] else { close(); return }
        let accept = wsAccept(key)
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        // Connect to our own est listener.
        let params = NWParameters.tcp
        let est = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: estPort)!, using: params)
        conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
        est.start(queue: .global())
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
        // browser -> est
        func pumpWS(_ pending: Data) {
            var acc = pending
            func step() {
                while true {
                    guard let (payload, consumed, isBinary, closed) = wsParse(acc) else { return }
                    acc = acc.dropFirst(consumed)
                    if closed { est.cancel(); close(); return }
                    if isBinary { est.send(content: payload, completion: .contentProcessed { _ in }) }
                }
            }
            step()
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, done, err in
                if let data = data { acc.append(data) }
                if err != nil || done { est.cancel(); self.close(); return }
                pumpWS(acc)
            }
        }
        pumpWS(leftover)
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
