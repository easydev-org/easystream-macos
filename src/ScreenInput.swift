import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

/// ScreenInput is the macOS streaming screen capture built on AVFoundation's
/// AVCaptureScreenInput — the API QuickTime's screen recording uses. The system
/// pushes a CVPixelBuffer per frame (a real stream, not a per-frame grab),
/// which we hand straight to VideoToolbox.
///
/// This is preferred over ScreenCaptureKit here: this VM's display does not
/// deliver SCStream frames, but AVCaptureScreenInput (like the `screencapture`
/// tool) works.
final class ScreenInput: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private let sem = DispatchSemaphore(value: 0)
    private(set) var width = 0
    private(set) var height = 0

    static func start(fps: Int) throws -> ScreenInput {
        let s = ScreenInput()
        try s.configure(fps: fps)
        return s
    }

    private func configure(fps: Int) throws {
        let displayID = CGMainDisplayID()
        width = CGDisplayPixelsWide(displayID)
        height = CGDisplayPixelsHigh(displayID)

        guard let input = AVCaptureScreenInput(displayID: displayID) else {
            throw A11yError("AVCaptureScreenInput init failed")
        }
        input.minFrameDuration = CMTime(value: 1, timescale: CMTimeScale(fps))
        // Include the system cursor in the captured frames.
        input.capturesCursor = true
        input.capturesMouseClicks = false

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "sc.screen"))

        session.beginConfiguration()
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw A11yError("cannot add AVCaptureScreenInput/output")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock(); latest = pb; lock.unlock()
        sem.signal()
    }

    /// next returns the newest frame, waiting up to timeoutMs (nil = no frame).
    func next(timeoutMs: Int) -> CVPixelBuffer? {
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs)) == .timedOut { return nil }
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func latestFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func stop() { session.stopRunning() }
}
