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
    /// fps is the encoder's configured frame rate (also the pump's emit cap).
    var frameRate: Int { fps }
    private var session: VTCompressionSession?
    private var frameIndex: Int64 = 0
    /// Emit an IDR on the first frame and periodically after, so a decoder that
    /// joins mid-stream (and the very first viewer) always gets a keyframe.
    /// VideoToolbox does NOT emit one on its own when frameProperties is nil —
    /// the stream was all P-frames, which no decoder can start from.
    private var sinceKey: Int = 1_000_000
    // 0 => EVERY frame is an IDR. VideoToolbox's P-frames decode fine in ffmpeg
    // but Chrome's WebCodecs decoder rejects them ("Decoding error"), so the
    // screen stream is all-keyframe: robust and, for screen content, cheap.
    private let keyEvery = 0
    /// out collects the AUs produced by the callback during one Encode call.
    private var out: [Data] = []
    /// The SPS/PPS captured from the FIRST sample's format description. Reused
    /// for every later IDR: VideoToolbox may hand back a slightly different
    /// format description per sample, and re-emitting changing parameter sets
    /// mid-stream makes a decoder reject the frame.
    private var cachedParams: [Data]?

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
        // Do NOT prioritise speed over quality: with it set, VideoToolbox picks
        // fast (coarse) tools and the picture visibly degrades. RealTime + the
        // frame-delay cap already keep the latency low, and the hardware encoder
        // is fast enough at 1080p.
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, value: kCFBooleanFalse)
        // A quality floor so low-motion content does not collapse to a few
        // kbit/s per frame (the encoder is free to spend MORE than the average
        // bitrate, up to this ceiling).
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_Quality, value: 0.75 as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(sess, key: kVTCompressionPropertyKey_ProfileLevel,
                             value: kVTProfileLevel_H264_Baseline_AutoLevel)
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

    /// encodeSized encodes a frame whose CAPTURE geometry may differ from the
    /// encoder's, scaling on the way in.
    ///
    /// Scaling happens here because the screen source hands back the display
    /// size and cannot be asked for another one: AVCaptureScreenInput and
    /// CGWindowList both own their geometry. Bilinear via CGContext rather than
    /// nearest-neighbour, because the presets halve the resolution and a naive
    /// pick makes text shimmer.
    func encodeSized(_ bgra: [UInt8], srcW: Int, srcH: Int) -> [Data] {
        if srcW == width && srcH == height { return encode(bgra) }
        guard session != nil else { return [] }
        out.removeAll(keepingCapacity: true)
        guard let scaled = Self.scaleBGRA(bgra, srcW: srcW, srcH: srcH, dstW: width, dstH: height),
              let pb = makePixelBuffer(from: scaled) else { return [] }
        return encodePixelBuffer(pb)
    }

    /// scaleBGRA resizes a top-down BGRA buffer with CGContext's interpolation.
    static func scaleBGRA(_ src: [UInt8], srcW: Int, srcH: Int, dstW: Int, dstH: Int) -> [UInt8]? {
        var dst = [UInt8](repeating: 0, count: dstW * dstH * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        let ok = src.withUnsafeBufferPointer { sp -> Bool in
            guard let srcCtx = CGContext(data: UnsafeMutableRawPointer(mutating: sp.baseAddress),
                                         width: srcW, height: srcH, bitsPerComponent: 8,
                                         bytesPerRow: srcW * 4, space: cs, bitmapInfo: info),
                  let srcImg = srcCtx.makeImage() else { return false }
            return dst.withUnsafeMutableBufferPointer { dp -> Bool in
                guard let dstCtx = CGContext(data: dp.baseAddress, width: dstW, height: dstH,
                                             bitsPerComponent: 8, bytesPerRow: dstW * 4,
                                             space: cs, bitmapInfo: info) else { return false }
                dstCtx.interpolationQuality = .medium
                dstCtx.draw(srcImg, in: CGRect(x: 0, y: 0, width: dstW, height: dstH))
                return true
            }
        }
        return ok ? dst : nil
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
        let forceKey = sinceKey >= keyEvery
        let frameProps: CFDictionary? = forceKey
            ? ([kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary)
            : nil
        let st = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pb, presentationTimeStamp: pts, duration: dur,
            frameProperties: frameProps, sourceFrameRefcon: nil, infoFlagsOut: &flagsOut)
        if st != noErr { return [] }
        sinceKey = forceKey ? 0 : sinceKey + 1
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

    /// forceKeyframe makes the NEXT encoded frame an IDR (SPS+PPS+IDR). Called
    /// when a new viewer subscribes so it can start decoding immediately.
    func forceKeyframe() { sinceKey = keyEvery }

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
        let params: [Data]
        if let cached = cachedParams {
            params = cached
        } else {
            var ps: [Data] = []
            for i in 0..<max(0, paramCount) {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                if CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr,
                    parameterSetSizeOut: &size, parameterSetCountOut: nil,
                    nalUnitHeaderLengthOut: nil) == noErr, let p = ptr, size > 0 {
                    ps.append(Data(bytes: p, count: size))
                }
            }
            if !ps.isEmpty { cachedParams = ps }
            params = ps
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
        var curHasVCL = false
        var off = 0
        let startCode: [UInt8] = [0, 0, 0, 1]
        while off + nalLen <= total {
            var len = 0
            for i in 0..<nalLen { len = (len << 8) | Int(UInt8(bitPattern: p[off + i])) }
            off += nalLen
            if len <= 0 || off + len > total { break }
            let nalType = UInt8(bitPattern: p[off]) & 0x1f
            let isVCL = (nalType == 1 || nalType == 5)
            if isVCL && !cur.isEmpty {
                if curHasVCL { aus.append(cur) }
                cur = Data(); curHasVCL = false
            }
            // Prepend SPS/PPS before each IDR (type 5) so mid-stream joins work.
            if nalType == 5 {
                for ps in params {
                    cur.append(contentsOf: startCode)
                    cur.append(ps)
                }
            }
            cur.append(contentsOf: startCode)
            cur.append(UnsafeBufferPointer(start: UnsafeRawPointer(p + off).assumingMemoryBound(to: UInt8.self), count: len))
            if isVCL { curHasVCL = true; aus.append(cur); cur = Data(); curHasVCL = false }
            off += len
        }
        // A trailing AU with no VCL NAL (e.g. a lone SEI) carries no picture and
        // makes WebCodecs reject the chunk ("Decoding error") — drop it.
        if !cur.isEmpty && curHasVCL { aus.append(cur) }
        return aus.isEmpty ? nil : aus
    }
}
