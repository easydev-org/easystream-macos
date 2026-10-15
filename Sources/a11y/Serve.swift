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
    private static let tVideo: UInt8 = 0x02
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
        private static let lock = NSLock()
        private static var live: [ObjectIdentifier: Conn] = [:]

        private let conn: NWConnection
        private let wq = DispatchQueue(label: "est.write")




        init(conn: NWConnection) { self.conn = conn }

        func start() {
            FileHandle.standardError.write("est: conn start\n".data(using: .utf8)!)
            Conn.lock.lock(); Conn.live[ObjectIdentifier(self)] = self; Conn.lock.unlock()
            conn.start(queue: .global())
            // Hello: version, codec(H.264), w, h, fps.
            let (w, h) = screenSize()
            var hello = [UInt8](repeating: 0, count: 7)
            hello[0] = 1; hello[1] = 1
            hello[2] = UInt8(w >> 8); hello[3] = UInt8(w & 0xff)
            hello[4] = UInt8(h >> 8); hello[5] = UInt8(h & 0xff)
            hello[6] = 30
            writeFrame(tHello, Data(hello))
            // One shared video pipeline for the whole daemon (started once).
            Conn.startVideoOnce()
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
