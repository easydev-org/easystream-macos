import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Capture grabs screen pixels. Modern path: ScreenCaptureKit (macOS 14+),
/// which is the only API that works cleanly without deprecated window-server
/// shortcuts. Falls back to CGWindowListCreateImage when SCK is unavailable
/// (headless CI without a display).
enum Capture {

    /// LiveCapture keeps ONE SCStream open and publishes the newest frame. The
    /// per-frame `SCScreenshotManager.captureImage` path spins up a stream every
    /// call (far too slow for a 30fps video stream), so the stream pump uses
    /// this instead.
    final class LiveCapture: NSObject, SCStreamOutput, SCStreamDelegate {
        private let stream: SCStream
        private let lock = NSLock()
        private var latest: CVPixelBuffer?
        private let sem = DispatchSemaphore(value: 0)
        private(set) var width = 0
        private(set) var height = 0

        static func start() async throws -> LiveCapture {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { throw A11yError("no display") }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.width = display.width
            cfg.height = display.height
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
            cfg.queueDepth = 3
            cfg.showsCursor = true
            let stream = SCStream(filter: filter, configuration: cfg, delegate: nil)
            let cap = LiveCapture(stream: stream)
            cap.width = display.width
            cap.height = display.height
            try stream.addStreamOutput(cap, type: .screen, sampleHandlerQueue: DispatchQueue(label: "sc.screen"))
            try await stream.startCapture()
            return cap
        }

        private init(stream: SCStream) { self.stream = stream }

        func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sb.isValid else { return }
            guard let pb = CMSampleBufferGetImageBuffer(sb) else { return }
            lock.lock(); latest = pb; lock.unlock()
            sampleCount += 1
            if sampleCount <= 3 || sampleCount % 60 == 0 {
                FileHandle.standardError.write("sc: frame \(sampleCount) \(CVPixelBufferGetWidth(pb))x\(CVPixelBufferGetHeight(pb))\n".data(using: .utf8)!)
            }
            sem.signal()
        }

        func stream(_ s: SCStream, didStopWithError error: Error) {
            FileHandle.standardError.write("sc: STOPPED \(error)\n".data(using: .utf8)!)
        }

        private var sampleCount = 0

        /// next returns the newest frame, waiting up to `timeoutMs`. Returns nil
        /// when the screen did not change (SCStream is change-driven).
        func next(timeoutMs: Int) -> CVPixelBuffer? {
            if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut { return nil }
            lock.lock(); defer { lock.unlock() }
            return latest
        }

        /// latestFrame returns the most recent frame without waiting (for the
        /// keepalive re-encode on a static screen).
        func latestFrame() -> CVPixelBuffer? {
            lock.lock(); defer { lock.unlock() }
            return latest
        }

        func stop() { stream.stopCapture { _ in } }
    }

    /// writePNG captures (optionally a region) and writes a PNG; returns size.
    static func writePNG(to path: String, region: Rect?) throws -> (Int, Int) {
        if let cg = try? captureSCK(region: region) {
            try write(cg, to: path)
            return (cg.width, cg.height)
        }
        let cg = try captureCGWindowList(region: region)
        try write(cg, to: path)
        return (cg.width, cg.height)
    }

    private static func write(_ img: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw A11yError("cannot create PNG at \(path)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        if !CGImageDestinationFinalize(dest) {
            throw A11yError("cannot write PNG at \(path)")
        }
    }

    // ── ScreenCaptureKit ──────────────────────────────────────────────────
    // SCK is async (SCScreenshotManager.captureImage); we bridge with a
    // semaphore since the CLI is synchronous.
    private static func captureSCK(region: Rect?) throws -> CGImage? {
        var result: CGImage?
        var failure: Error?
        let sem = DispatchSemaphore(value: 0)
        Task {
            defer { sem.signal() }
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(
                    false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    throw A11yError("no display")
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let cfg = SCStreamConfiguration()
                cfg.width = display.width
                cfg.height = display.height
                cfg.showsCursor = true
                let img = try await SCScreenshotManager.captureImage(
                    contentFilter: filter, configuration: cfg)
                result = region.map { crop($0, img) } ?? img
            } catch {
                failure = error
            }
        }
        sem.wait()
        if let f = failure { throw f }
        return result
    }

    private static func crop(_ r: Rect, _ img: CGImage) -> CGImage? {
        // SCK origin is top-left; crop directly.
        img.cropping(to: r.cg)
    }

    /// screenshotCG returns one full-screen CGImage (SCK, else CGWindowList),
    /// for callers that want raw pixels (e.g. the encoder) rather than a file.
    static func screenshotCG() throws -> CGImage {
        if let cg = (try? captureSCK(region: nil)) ?? nil { return cg }
        return try captureCGWindowList(region: nil)
    }

    /// screenshotCGSync returns one full-screen CGImage WITHOUT ScreenCaptureKit
    /// (CGWindowListCreateImage is synchronous and needs no message pump). The
    /// SCK path bridges an async call with a semaphore, which deadlocks or
    /// crashes when called from the video-pump thread, so the pump uses this.
    static func screenshotCGSync() throws -> CGImage {
        return try captureCGWindowList(region: nil)
    }

    // Reused capture buffers/context: allocating an 8 MB array + a CGContext per
    // frame is a large part of the per-frame cost on the CGWindowList path.
    private static var buf: [UInt8] = []

    /// grabBGRA captures the screen into a REUSED BGRA buffer (top-down).
    static func grabBGRA() throws -> (w: Int, h: Int, bgra: [UInt8]) {
        let cg = try captureCGWindowList(region: nil)
        let w = cg.width, h = cg.height
        // Read the pixels straight out of the CGImage's data provider, exactly
        // like the Go worker did: a per-frame CGContext.draw() costs ~40ms at
        // 1080p, which is what made the stream crawl. The window-list CGImage is
        // BGRA (premultiplied; screen pixels are opaque, so BGRA == straight).
        guard let provider = cg.dataProvider, let data = provider.data,
              let ptr = CFDataGetBytePtr(data) else {
            throw A11yError("CGImage has no data provider")
        }
        let rowBytes = cg.bytesPerRow
        if buf.count != w * h * 4 {
            buf = [UInt8](repeating: 0, count: w * h * 4)
        }
        buf.withUnsafeMutableBufferPointer { dst in
            let d = dst.baseAddress!
            for y in 0..<h {
                let src = ptr + y * rowBytes
                let drow = y * w * 4
                for x in 0..<w {
                    let s = x * 4
                    d[drow + s + 0] = src[s + 0]
                    d[drow + s + 1] = src[s + 1]
                    d[drow + s + 2] = src[s + 2]
                    d[drow + s + 3] = 0xff
                }
            }
        }
        return (w, h, buf)
    }

    // ── CGWindowListCreateImage fallback ──────────────────────────────────
    private static func captureCGWindowList(region: Rect?) throws -> CGImage {
        let rect = region?.cg ?? CGRect.infinite
        guard let img = CGWindowListCreateImage(
            rect, .optionOnScreenOnly, kCGNullWindowID, [.boundsIgnoreFraming]) else {
            throw A11yError("CGWindowListCreateImage failed (Screen Recording permission?)")
        }
        return img
    }
}
