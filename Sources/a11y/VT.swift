import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VTEncoder is a real-time H.264 encoder built on VideoToolbox, the native
/// macOS API (no FFI, no dlopen). It produces Annex-B access units — the form
/// WebRTC/RTP wants — by converting each AVCC length-prefixed sample that
/// VideoToolbox emits.
///
/// This is the Swift counterpart of goa11y's `VideoEncoder`: feed BGRA frames,
/// get zero or more encoded access units back per call.
final class VTEncoder {
    private let width: Int
    private let height: Int
    private let fps: Int
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    /// out collects the AUs produced by the callback during one Encode call.
    private var out: [Data] = []

    init?(width: Int, height: Int, fps: Int, bitrate: Int) {
        self.width = width
        self.height = height
        self.fps = fps
        var s: VTCompressionSession?
        // The output callback is bound at session creation; it appends each
        // encoded AU (Annex-B) to self.out. `refcon` carries `self`.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        let callback: VTCompressionOutputCallback = { refcon, _, status, _, sample in
            guard status == noErr, let sample else { return }
            let enc = Unmanaged<VTEncoder>.fromOpaque(refcon!).takeUnretainedValue()
            if let aus = enc.annexB(from: sample) { enc.out.append(contentsOf: aus) }
        }
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: callback,
            refcon: refcon,
            compressionSessionOut: &s)
        guard status == noErr, let sess = s else { return nil }
        self.session = sess
        // Low-latency, real-time, no reordering (a screen stream must not buffer).
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        // Emit each frame as soon as it is encoded (no lookahead buffering):
        // this is what keeps the glass-to-glass latency low.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_MaxFrameDelayCount, value: 1 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanTrue)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_High_AutoLevel)
        // Emit SPS/PPS inline with each IDR so a mid-stream join works.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AllowTemporalCompression, value: kCFBooleanTrue)
        // Ask for hardware when available (falls back to software silently).
        let spec = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder, value: kCFBooleanTrue)
        _ = spec
        VTCompressionSessionPrepareToEncodeFrames(sess)
    }

    /// Encode takes one BGRA frame (top-down, stride = width*4) and returns the
    /// access units produced (Annex-B). The first frame(s) may return none while
    /// the encoder warms up — exactly like goa11y.
    func encode(_ bgra: [UInt8]) -> [Data] {
        guard session != nil else { return [] }
        out.removeAll(keepingCapacity: true)
        guard let pb = makePixelBuffer(from: bgra) else { return [] }
        return encodePixelBuffer(pb)
    }

    /// encodePixelBuffer encodes a CVPixelBuffer directly (used by the live
    /// SCStream path, which already hands us BGRA CVPixelBuffers — no copy).
    func encodePixelBuffer(_ pb: CVPixelBuffer) -> [Data] {
        guard let session else { return [] }
        out.removeAll(keepingCapacity: true)
        var flagsOut: VTEncodeInfoFlags = []
        let dur = CMTime(value: 1, timescale: CMTimeScale(fps))
        let pts = CMTime(value: frameIndex, timescale: CMTimeScale(fps))
        frameIndex += 1
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: dur,
            frameProperties: nil, sourceFrameRefcon: nil, infoFlagsOut: &flagsOut)
        if st != noErr { return [] }
        // Drain synchronously so the callback has run before we return.
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: pts)
        return out
    }

    func close() {
        if let session {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    // ── internals ─────────────────────────────────────────────────────────

    /// makePixelBuffer wraps the BGRA bytes in a CVPixelBuffer VideoToolbox
    /// accepts (32BGRA, no row padding surprises: we copy row by row).
    private func makePixelBuffer(from bgra: [UInt8]) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let st = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                     kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard st == kCVReturnSuccess, let buf = pb else { return nil }
        CVPixelBufferLockBaseAddress(buf, [])
        defer { CVPixelBufferUnlockBaseAddress(buf, []) }
        guard let base = CVPixelBufferGetBaseAddress(buf) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(buf)
        let dst = base.assumingMemoryBound(to: UInt8.self)
        bgra.withUnsafeBufferPointer { src in
            for y in 0..<height {
                let s = y * width * 4
                let d = y * stride
                memcpy(dst + d, src.baseAddress! + s, width * 4)
            }
        }
        return buf
    }

    /// annexB converts one CMSampleBuffer (AVCC) into an Annex-B access unit
    /// (00 00 00 01 start codes before each NAL) — the form RTP/WebRTC needs.
    /// VideoToolbox keeps SPS/PPS in the format description (not the sample
    /// data), so we prepend them before every IDR: a decoder that joins mid
    /// stream gets the parameter sets, which is what RTP needs.
    private func annexB(from sample: CMSampleBuffer) -> [Data]? {
        guard let fmt = CMSampleBufferGetFormatDescription(sample) else { return nil }
        // Pull SPS/PPS (H.264 parameter sets) out of the format description.
        var paramCount = 0
        var nalLenSize: Int32 = 4
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0, parameterSetPointerOut: nil,
            parameterSetSizeOut: nil, parameterSetCountOut: &paramCount,
            nalUnitHeaderLengthOut: &nalLenSize)
        let nalLen = Int(nalLenSize)
        var params: [Data] = []
        for i in 0..<max(0, paramCount) {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                parameterSetSizeOut: &size, parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil) == noErr, let p = ptr, size > 0 {
                params.append(Data(bytes: p, count: size))
            }
        }
        guard let bb = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var total = 0
        var ptr: UnsafeMutablePointer<Int8>?
        let st = CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil,
                                             totalLengthOut: &total, dataPointerOut: &ptr)
        guard st == kCMBlockBufferNoErr, let p = ptr else { return nil }
        // One CMSampleBuffer may carry SEVERAL coded pictures (VideoToolbox
        // batches when frames are fed faster than it drains), so emit one AU per
        // VCL slice: an AU is the leading parameter NALs + ONE VCL slice.
        var aus: [Data] = []
        var cur = Data()
        var off = 0
        let startCode: [UInt8] = [0, 0, 0, 1]
        while off + nalLen <= total {
            var len = 0
            for i in 0..<nalLen { len = (len << 8) | Int(UInt8(bitPattern: p[off + i])) }
            off += nalLen
            if len <= 0 || off + len > total { break }
            let nalType = UInt8(bitPattern: p[off]) & 0x1f
            let isVCL = (nalType == 1 || nalType == 5)
            if isVCL && !cur.isEmpty { aus.append(cur); cur = Data() }
            // Prepend SPS/PPS before each IDR (type 5) so mid-stream joins work.
            if nalType == 5 {
                for ps in params {
                    cur.append(contentsOf: startCode)
                    cur.append(ps)
                }
            }
            cur.append(contentsOf: startCode)
            cur.append(UnsafeBufferPointer(start: UnsafeRawPointer(p + off).assumingMemoryBound(to: UInt8.self), count: len))
            if isVCL { aus.append(cur); cur = Data() }
            off += len
        }
        if !cur.isEmpty { aus.append(cur) }
        return aus.isEmpty ? nil : aus
    }
}
