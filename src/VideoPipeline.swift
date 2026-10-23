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
    /// Set when a NEW viewer subscribes: the pump then forces an IDR so that
    /// viewer can start decoding immediately (VideoToolbox emits none on its
    /// own, and the periodic key is ~2 s away on a slow/static screen).
    private var wantKey = true
    private let lock = NSLock()

    private init() {}

    /// run starts the pipeline once and delivers every access unit (Annex-B) to
    /// `sink`. Safe to call from every connection; only the first one starts it.
    func run(sink: @escaping (Data) -> Void) {
        lock.lock()
        wantKey = true
        if started { lock.unlock(); return }
        started = true
        lock.unlock()
        Thread.detachNewThread { [weak self] in self?.loop(sink: sink) }
    }

    /// requestKeyframe asks the pump to emit an IDR on its next frame.
    func requestKeyframe() {
        lock.lock(); wantKey = true; lock.unlock()
    }

    /// takeKeyRequest consumes the pending keyframe request.
    private func takeKeyRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let k = wantKey; wantKey = false; return k
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
        // Publish the capture size once; VideoConfig keeps capture and OUTPUT
        // geometry apart because the screen source owns the former.
        let capW = Int(input.width), capH = Int(input.height)
        VideoConfig.shared.setCapture(capW, capH)
        var encGen = VideoConfig.shared.generationNow
        func openEncoder() -> VTEncoder? {
            let (ow, oh) = VideoConfig.shared.output
            let w = ow != 0 ? ow : capW
            let h = oh != 0 ? oh : capH
            let e = VTEncoder(width: w, height: h, fps: VideoConfig.shared.frameRate,
                              bitrate: VideoConfig.shared.bitRate)
            if e != nil { VideoConfig.shared.setActiveEncoder(UInt8(VideoConfig.encVideoToolbox)) }
            FileHandle.standardError.write("est pump: encoder opened w=" + String(w) + " h=" + String(h) + " gen=" + String(VideoConfig.shared.generationNow) + "\n")
            return e
        }
        guard var enc = openEncoder() else {
            FileHandle.standardError.write("est: VTEncoder init failed\n".data(using: .utf8)!)
            return
        }
        var skipped = 0
        // VideoToolbox needs a few warm-up frames and AVCaptureScreenInput is
        // change-driven, so force-feed the first frames + a periodic keepalive.
        var warmup = 8
        // Time-based keyframes: a static screen emits very few frames, so a
        // frame-count keyframe interval can leave a fresh viewer without an IDR
        // for many seconds (the decoder then never starts).
        var lastKey = Date.distantPast
        // Hard frame-rate cap. VideoToolbox can return SEVERAL access units from
        // one Encode call (it batches when fed faster than it drains), and the
        // capture delegate can deliver above the requested minFrameDuration, so
        // without this the daemon emitted ~143 AU/s instead of the 30 fps the
        // Hello advertises (needless CPU/bandwidth, and the browser decoded
        // far more frames than the display could show).
        // Safety cap only: never emit faster than this. The capture is
        // change-driven, so the natural rate already matches the display; the
        // cap just prevents a runaway when VideoToolbox returns several AUs.
        // NOTE: a change must NEVER be dropped — dropping it delays the visible
        // update to the NEXT change (that was the "typing lags" symptom).
        let minInterval = 1.0 / Double(max(1, enc.frameRate))
        var lastEmit = Date.distantPast
        while true {
            let start = Date()
            // A ConfigSet landed: rebuild the encoder at the new geometry. Done
            // here, in the pump, because VTEncoder is immutable and every
            // reference to it lives on this thread.
            let gen = VideoConfig.shared.generationNow
            if gen != encGen {
                // Drop the old session BEFORE creating the new one: two hardware
                // encoders at once fail to open on a VM.
                enc.close()
                if let fresh = openEncoder() {
                    enc = fresh
                    encGen = gen
                    // No reference frames in the new session, and every client
                    // reset its decoder on the new Hello: the first frame must
                    // be an IDR.
                    enc.forceKeyframe()
                    lastKey = Date()
                } else {
                    FileHandle.standardError.write("est pump: encoder reopen failed\n".data(using: .utf8)!)
                }
            }
            // Do NOT pre-sleep before capturing: the pump used to wait out the
            // frame interval BEFORE looking for a change AND sleep again at the
            // tail, so a change took up to ~2 intervals (~66ms) to reach the
            // viewer — that is what made input feel laggy. Wait for a change
            // first (short timeout), and only pace the EMIT below.
            if takeKeyRequest() || Date().timeIntervalSince(lastKey) > 1.0 {
                enc.forceKeyframe()
                lastKey = Date()
            }
            if let pb = input.next(timeoutMs: 8) {
                skipped = 0
                // Emit EVERY change; only pace it to the 60fps cap.
                let since = Date().timeIntervalSince(lastEmit)
                if since < minInterval { usleep(useconds_t((minInterval - since) * 1_000_000)) }
                lastEmit = Date()
                // Concatenate all access units of ONE encode call into a
                // single est frame: VideoToolbox returns the SLICES of one
                // coded picture as several AUs, and sending them as separate
                // frames makes the browser decode each slice as its own picture
                // (the missing rows show up as green/white bands). They are
                // Annex-B, so concatenation is one AU.
                let aus = enc.encodePixelBuffer(pb)
                if !aus.isEmpty { sink(aus.reduce(into: Data()) { $0.append($1) }) }
            } else if warmup > 0 || skipped >= 15 {
                if warmup > 0 { warmup -= 1 }
                skipped = 0
                let since = Date().timeIntervalSince(lastEmit)
                if since < minInterval { usleep(useconds_t((minInterval - since) * 1_000_000)) }
                lastEmit = Date()
                if let (_, _, bgra) = Self.grabBGRA() {
                    // Pass the CAPTURE size: the encoder may be emitting a smaller
                    // frame and scales in encodeSized.
                    let aus = enc.encodeSized(bgra, srcW: capW, srcH: capH)
                    if !aus.isEmpty { sink(aus.reduce(into: Data()) { $0.append($1) }) }
                }
            } else {
                skipped += 1
            }
            // Single pacing sleep: only the leftover of the frame interval.
            let spent = Date().timeIntervalSince(start)
            let rest = minInterval - spent
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
