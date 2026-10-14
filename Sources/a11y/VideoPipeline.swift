import Foundation
import CoreGraphics
import CoreVideo

/// VideoPipeline is the SINGLE capture+encode pipeline for the whole daemon.
///
/// Previously every est connection started its own ScreenInput + VTEncoder, so
/// N viewers meant N screen captures and N hardware encoders (and N x CPU).
/// There is exactly one capture device and one encoder per process; each access
/// unit is fanned out to every subscriber (all live connections).
final class VideoPipeline {
    static let shared = VideoPipeline()
    private var started = false
    private let lock = NSLock()

    private init() {}

    /// run starts the pipeline once and delivers every access unit (Annex-B) to
    /// `sink`. Safe to call from every connection; only the first one starts it.
    func run(sink: @escaping (Data) -> Void) {
        lock.lock()
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.loop(sink: sink) }
    }

    private func loop(sink: (Data) -> Void) {
        // Streaming capture via AVFoundation's AVCaptureScreenInput: the system
        // pushes a CVPixelBuffer per frame, which we hand to VideoToolbox.
        let input: ScreenInput
        do { input = try ScreenInput.start(fps: 30) }
        catch {
            FileHandle.standardError.write("est: ScreenInput \(error)\n".data(using: .utf8)!)
            return
        }
        FileHandle.standardError.write("est: ScreenInput started \(input.width)x\(input.height)\n".data(using: .utf8)!)
        guard let enc = VTEncoder(width: input.width, height: input.height, fps: 30, bitrate: 12_000_000) else {
            FileHandle.standardError.write("est: VTEncoder init failed\n".data(using: .utf8)!)
            return
        }
        var skipped = 0
        // VideoToolbox needs a few warm-up frames and AVCaptureScreenInput is
        // change-driven, so force-feed the first frames + a periodic keepalive.
        var warmup = 8
        while true {
            let start = Date()
            if let pb = input.next(timeoutMs: 30) {
                skipped = 0
                for au in enc.encodePixelBuffer(pb) { sink(au) }
            } else if warmup > 0 || skipped >= 15 {
                if warmup > 0 { warmup -= 1 }
                skipped = 0
                if let (_, _, bgra) = Self.grabBGRA() {
                    for au in enc.encode(bgra) { sink(au) }
                }
            } else {
                skipped += 1
            }
            let spent = Date().timeIntervalSince(start)
            let rest = 0.033 - spent
            if rest > 0 { usleep(useconds_t(rest * 1_000_000)) }
        }
    }

    /// grabBGRA is a synchronous CGWindowList capture (the SCK path is async and
    /// would deadlock/crash on this pump thread).
    static func grabBGRA() -> (w: Int, h: Int, bgra: [UInt8])? {
        guard let cg = try? Capture.screenshotCGSync() else { return nil }
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
}
