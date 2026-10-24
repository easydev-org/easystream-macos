import CoreGraphics
import Foundation
import Network

/// The unified easystream daemon (EST.md): one TCP connection multiplexes the
/// video stream (0x02), input (0x10-0x14) and clipboard (0x30-0x32). Capture,
/// encode and input share this one process (no cross-backend conflict).
///
/// Built on Network.framework (NWListener) — no third-party deps.
enum Serve {
    // Message types (EST.md).
    private static let tHello: UInt8 = 0x01
    /// Run-time reconfiguration (EST.md 0x08/0x09).
    static let tConfigSet: UInt8 = 0x08
    static let tConfigAck: UInt8 = 0x09
    private static let tVideo: UInt8 = 0x02
    private static let tAuth: UInt8 = 0x03
    private static let tAuthOk: UInt8 = 0x04
    private static let tAudio: UInt8 = 0x05
    private static let tAudioReq: UInt8 = 0x06
    private static let tAudioOff: UInt8 = 0x07
    private static let tMove: UInt8 = 0x10
    private static let tButton: UInt8 = 0x11
    private static let tScroll: UInt8 = 0x12
    private static let tKey: UInt8 = 0x13
    private static let tText: UInt8 = 0x14
    private static let tClipGet: UInt8 = 0x30
    private static let tClipData: UInt8 = 0x31
    private static let tClipSet: UInt8 = 0x32
    private static let tPing: UInt8 = 0x50
    private static let tPong: UInt8 = 0x51

    /// Build a Hello for the CURRENT video configuration (EST.md).
    ///
    /// 23 bytes: the v1 core (7), the audio block (8) and the video block at
    /// offset 15 (8). The video block is APPENDED, so a client that stops at the
    /// audio block parses this exactly as before.
    static func helloPayload(capW: UInt32, capH: UInt32) -> Data {
        let cfg = VideoConfig.shared
        var hello = [UInt8](repeating: 0, count: 7 + 8 + 8)
        hello[0] = 1; hello[1] = 1
        // Report what the encoder EMITS, not the capture size: once someone picks
        // a preset the two differ, and a decoder configured for the capture size
        // rejects every frame.
        let (ow, oh) = cfg.output
        let w = ow != 0 ? ow : Int(capW)
        let h = oh != 0 ? oh : Int(capH)
        hello[2] = UInt8((w >> 8) & 0xff); hello[3] = UInt8(w & 0xff)
        hello[4] = UInt8((h >> 8) & 0xff); hello[5] = UInt8(h & 0xff)
        hello[6] = UInt8(cfg.frameRate)
        let (hasAudio, aRate, aCh, aMs) = AudioPipeline.params()
        hello[7] = hasAudio ? 1 : 0
        hello[8] = 1
        hello[9] = UInt8((aRate >> 24) & 0xff); hello[10] = UInt8((aRate >> 16) & 0xff)
        hello[11] = UInt8((aRate >> 8) & 0xff); hello[12] = UInt8(aRate & 0xff)
        hello[13] = aCh; hello[14] = aMs
        let vb = cfg.helloBlock()
        for i in 0..<8 { hello[15 + i] = vb[i] }
        return Data(hello)
    }

    /// Re-announce the video configuration to every live connection. Hello is the
    /// only authoritative statement of geometry (EST.md), so viewers that stayed
    /// connected after a ConfigSet would otherwise keep decoding at the old size.
    static func broadcastHello() {
        let (cw, ch) = VideoConfig.shared.capture
        Conn.broadcastHello(payload: helloPayload(capW: UInt32(cw), capH: UInt32(ch)))
    }

    /// Parse a 0x08 ConfigSet body into a Patch.
    ///
    /// The cursor walks the frame strictly: every field knows its own length, and
    /// a frame that ends early is an error, not a partial patch. Truncation is
    /// the likeliest corruption here, and applying half of it would move the
    /// stream somewhere nobody asked for.
    static func parseConfig(_ b: [UInt8]) -> (VideoConfig.Patch?, String?) {
        var p = VideoConfig.Patch()
        var i = 0
        func need(_ n: Int) -> Bool { i + n <= b.count }
        guard need(1) else { return (nil, "truncated: hasWidth") }
        if b[i] != 0 {
            guard need(3) else { return (nil, "truncated: width") }
            p.width = UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
        }
        i += 3
        guard need(1) else { return (nil, "truncated: hasHeight") }
        if b[i] != 0 {
            guard need(3) else { return (nil, "truncated: height") }
            p.height = UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
        }
        i += 3
        guard need(1) else { return (nil, "truncated: hasFps") }
        if b[i] != 0 {
            guard need(2) else { return (nil, "truncated: fps") }
            p.fps = b[i + 1]
        }
        i += 2
        guard need(1) else { return (nil, "truncated: hasBitrate") }
        if b[i] != 0 {
            guard need(5) else { return (nil, "truncated: bitrate") }
            p.bitrate = UInt32(b[i + 1]) << 24 | UInt32(b[i + 2]) << 16
                      | UInt32(b[i + 3]) << 8 | UInt32(b[i + 4])
        }
        i += 5
        guard need(1) else { return (nil, "truncated: hasEncoder") }
        if b[i] != 0 {
            guard need(2) else { return (nil, "truncated: encoder") }
            let e = b[i + 1]
            // 0xFF is the documented "let the server pick" value.
            p.encoder = (e == 0xFF) ? 0 : e
        }
        return (p, nil)
    }

    /// Build a 0x09 ConfigAck body: ok byte, then a length-prefixed UTF-8 reason.
    static func ackBody(ok: Bool, msg: String) -> Data {
        let m = Array(msg.utf8.prefix(255))
        var d = Data([ok ? 1 : 0, UInt8(m.count)])
        d.append(contentsOf: m)
        return d
    }

    /// applyConfig validates and applies a ConfigSet, returning a refusal reason.
    static func applyConfig(_ b: [UInt8]) -> String? {
        let (p, err) = parseConfig(b)
        if let e = err { return e }
        guard let patch = p else { return "empty" }
        return VideoConfig.shared.apply(patch)
    }

    static func run(port: UInt16) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener.newConnectionHandler = { conn in
            let s = Conn(conn: conn)
            s.start()
        }
        listener.start(queue: .global())
        FileHandle.standardError.write("easystream est server on 127.0.0.1:\(port)\n".data(using: .utf8)!)
        dispatchMain()  // runs forever
    }

    /// Conn is one est session: it owns the encoder + a serialized write path.
    final class Conn {
        // Keep every live connection referenced: NWListener's newConnectionHandler
        // returns immediately, so without this the Conn would deallocate and the
        // video thread (weak self) would never run.
        /// Send a frame to every live connection. Lives here because `lock` and
        /// `live` are private to Conn.
        static func broadcastHello(payload: Data) {
            lock.lock()
            let conns = Array(live.values)
            lock.unlock()
            for c in conns { c.writeFrame(tHello, payload) }
        }

        private static let lock = NSLock()
        private static var live: [ObjectIdentifier: Conn] = [:]

        private let conn: NWConnection
        private let wq = DispatchQueue(label: "est.write")
        /// Access mode for THIS connection (View = read-only); set by Auth.
        private var mode: Auth.Mode = Auth.isOpen ? .control : .view
        /// Whether this connection wants Audio frames (turned on by AudioReq).
        private var audioOn = false




        init(conn: NWConnection) { self.conn = conn }

        func start() {
            FileHandle.standardError.write("est: conn start\n".data(using: .utf8)!)
            Conn.lock.lock(); Conn.live[ObjectIdentifier(self)] = self; Conn.lock.unlock()
            // NOTHING may be sent before the connection is READY.
            //
            // NWConnection.send on a connection still in .preparing/.setup calls
            // its completion with an error and DROPS the data - it does not
            // queue it. Sending Hello immediately after start() therefore worked
            // for the first viewer (the race happened to go our way) and failed
            // for every later one while the encoder kept the CPU busy: the client
            // connected, received no Hello at all, and the stream looked dead
            // from the browser's point of view.
            conn.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.beginSession()
                case .failed, .cancelled:
                    Conn.lock.lock(); Conn.live[ObjectIdentifier(self)] = nil; Conn.lock.unlock()
                default:
                    break
                }
            }
            conn.start(queue: .global())
        }

        /// beginSession runs once the connection is READY. Everything that SENDS
        /// lives here for the reason above; guard stops a second .ready (which
        /// Network.framework can deliver after an interim state) from sending a
        /// second Hello and a duplicate video subscription.
        private var sessionStarted = false
        private func beginSession() {
            if sessionStarted { return }
            sessionStarted = true
            let (w, h) = screenSize()
            writeFrame(tHello, Serve.helloPayload(capW: UInt32(w), capH: UInt32(h)))
            // One shared video pipeline for the whole daemon (started once).
            Conn.startVideoOnce()
            // Audio: subscribe this connection to the shared Opus pipeline.
            let (hasAudioNow, _, _, _) = AudioPipeline.params()
            if hasAudioNow {
                AudioPipeline.shared.subscribe { [weak self] pkt in
                    guard let self = self else { return }
                    if self.audioOn { self.writeFrame(Serve.tAudio, pkt) }
                }
            }
            // This new viewer needs an IDR to start decoding: ask the pump for
            // one (VideoToolbox never emits a keyframe unprompted).
            VideoPipeline.shared.requestKeyframe()
            readLoop(Data())
        }

        private static let videoOnce = { () -> Bool in
            VideoPipeline.shared.run { au in
                Conn.lock.lock()
                let conns = Array(Conn.live.values)
                Conn.lock.unlock()
                for c in conns { c.writeFrame(tVideo, au) }
            }
            return true
        }()

        private static func startVideoOnce() { _ = videoOnce }

        private func screenSize() -> (Int, Int) {
            // Synchronous, cheap: never call SCK here (it is async and would
            // block the connection before the Hello is sent).
            let id = CGMainDisplayID()
            let w = CGDisplayPixelsWide(id)
            let h = CGDisplayPixelsHigh(id)
            return (w > 0 ? w : 1920, h > 0 ? h : 1080)
        }


        // ── control ───────────────────────────────────────────────────────
        private func readLoop(_ buffer: Data) {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else { return }
                var buf = buffer
                if let d = data { buf.append(d) }
                while buf.count >= 6 {
                    let typ = buf[buf.startIndex]
                    let len = (Int(buf[buf.startIndex + 2]) << 24) | (Int(buf[buf.startIndex + 3]) << 16)
                            | (Int(buf[buf.startIndex + 4]) << 8) | Int(buf[buf.startIndex + 5])
                    if buf.count < 6 + len { break }
                    let body = buf.subdata(in: (buf.startIndex + 6)..<(buf.startIndex + 6 + len))
                    buf.removeFirst(6 + len)
                    self.dispatch(typ, body)
                }
                if isComplete || error != nil {
                    self.conn.cancel()
                    Conn.lock.lock(); Conn.live[ObjectIdentifier(self)] = nil; Conn.lock.unlock()
                    return
                }
                self.readLoop(buf)
            }
        }

        private func dispatch(_ typ: UInt8, _ b: Data) {
            let a = [UInt8](b)
            func i16(_ o: Int) -> Int32 { o + 1 < a.count ? Int32(Int16(bitPattern: UInt16(a[o]) << 8 | UInt16(a[o + 1]))) : 0 }
            if typ == Serve.tAuth {
                let tok = String(decoding: a, as: UTF8.self)
                mode = Auth.authorize(tok)
                writeFrame(Serve.tAuthOk, Data([mode.rawValue]))
                FileHandle.standardError.write("est: auth -> \(mode)\n".data(using: .utf8)!)
                return
            }
            if typ == Serve.tConfigSet {
                if let err = Serve.applyConfig(a) {
                    FileHandle.standardError.write("est: ConfigSet rejected: \(err)\n".data(using: .utf8)!)
                    writeFrame(Serve.tConfigAck, Serve.ackBody(ok: false, msg: err))
                } else {
                    let (ow, oh) = VideoConfig.shared.output
                    FileHandle.standardError.write(
                        "est: ConfigSet ok -> \(ow)x\(oh) fps=\(VideoConfig.shared.frameRate) br=\(VideoConfig.shared.bitRate) gen=\(VideoConfig.shared.generationNow)\n".data(using: .utf8)!)
                    writeFrame(Serve.tConfigAck, Serve.ackBody(ok: true, msg: ""))
                    // Tell EVERY viewer, not just the one that asked.
                    Serve.broadcastHello()
                    // The encoder is rebuilt by the pump on its next tick; ask for
                    // an IDR so the new geometry has a starting point.
                    VideoPipeline.shared.requestKeyframe()
                }
                return
            }
            if typ == Serve.tAudioReq { audioOn = true; return }
            if typ == Serve.tAudioOff { audioOn = false; return }
            // View mode: drop every frame that would CHANGE the guest.
            if mode == .view && Auth.isMutation(typ) { return }
            switch typ {
            case tMove:
                Input.warp(x: i16(0), y: i16(2))
            case tButton:
                if a.count >= 2 { Input.button(a[0], down: a[1] != 0) }
            case tScroll:
                Input.scroll(x: i16(4), y: i16(6), dx: i16(8), dy: i16(10))
            case tKey:
                // Key: nameLen:u8, name[nameLen], char:u32 (LE), down:u8.
                // The char field is required so modifier combos (Ctrl+C …) can
                // be typed when `name` is a plain character.
                if a.count >= 1 {
                    let n = Int(a[0])
                    if a.count >= 1 + n + 4 + 1 {
                        let name = String(decoding: a[1..<1 + n], as: UTF8.self)
                        let c0 = Int(a[1 + n]), c1 = Int(a[2 + n]), c2 = Int(a[3 + n]), c3 = Int(a[4 + n])
                        let ch = c0 | (c1 << 8) | (c2 << 16) | (c3 << 24)
                        let down = a[1 + n + 4] != 0
                        if name.count == 1, let scalar = UnicodeScalar(UInt32(ch & 0x10FFFF)) {
                            // A character with modifiers: press it as a key code.
                            Input.keyEvent(String(Character(scalar)), down: down)
                        } else {
                            Input.keyEvent(name, down: down)
                        }
                    }
                }
            case tText:
                Input.typeText(String(decoding: a, as: UTF8.self))
            case tClipGet:
                let text = (try? Clipboard.get()) ?? ""
                var p = Data()
                p.append(contentsOf: [0, 0, 0, 0])
                let n = UInt32(text.utf8.count)
                p.append(contentsOf: [UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
                p.append(contentsOf: Array(text.utf8))
                writeFrame(tClipData, p)
            case tClipSet:
                if a.count >= 4 {
                    let n = Int(a[0]) << 24 | Int(a[1]) << 16 | Int(a[2]) << 8 | Int(a[3])
                    if a.count >= 4 + n { try? Clipboard.set(String(decoding: a[4..<4 + n], as: UTF8.self)) }
                }
            case tPing:
                writeFrame(tPong, b)
            default:
                break
            }
        }

        private func writeFrame(_ typ: UInt8, _ payload: Data) {
            let n = UInt32(payload.count)
            var hdr = Data([typ, 0, UInt8(n >> 24), UInt8((n >> 16) & 0xff), UInt8((n >> 8) & 0xff), UInt8(n & 0xff)])
            hdr.append(payload)
            wq.async { [weak self] in self?.conn.send(content: hdr, completion: .contentProcessed { _ in }) }
        }
    }
}
