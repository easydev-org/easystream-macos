import Foundation

/// Runtime video configuration: geometry, frame rate, bitrate and encoder.
///
/// This is the macOS side of the EST.md reconfiguration contract. Until now the
/// encoder was created with literals (VTEncoder(width:height:fps:30,bitrate:25_000_000)),
/// so a viewer could not trade quality for bandwidth at all.
///
/// Two geometries are kept deliberately apart:
///  * CAPTURE geometry - what the screen source produces. AVCaptureScreenInput and
///    CGWindowList both hand back the display size; the daemon cannot ask for
///    another one without restarting the capture session.
///  * OUTPUT geometry  - what the encoder emits. This is what ConfigSet changes.
///
/// Every rule is a REFUSAL, never a clamp: silently substituting a value would
/// make the UI believe it got what it asked for.
final class VideoConfig {
    static let shared = VideoConfig()

    /// Encoder codes, matching the EST.md video block.
    static let encUnknown = 0
    static let encX264 = 1
    static let encVideoToolbox = 4

    private let lock = NSLock()
    private var capW = 0
    private var capH = 0
    private var outW = 0
    private var outH = 0
    private var fps = 30
    private var bitrate = 12_000_000
    private var requestedEnc = 0
    private var activeEnc = 0
    /// Bumped on every accepted change so the pump notices cheaply.
    private var generation: UInt32 = 0

    private static let minBitrate = 100_000
    private static let maxBitrate = 50_000_000
    private static let minDim = 64
    private static let maxDim = 7680
    private static let minFps = 1
    private static let maxFps = 120

    private init() {}

    /// A validated change request, as parsed from a ConfigSet frame.
    struct Patch {
        var width: UInt32?
        var height: UInt32?
        var fps: UInt8?
        var bitrate: UInt32?
        var encoder: UInt8?
    }

    /// Record the capture source size. Called when capture starts; the output
    /// follows it until someone asks for something else.
    func setCapture(_ w: Int, _ h: Int) {
        lock.lock(); defer { lock.unlock() }
        capW = w; capH = h
        if outW == 0 { outW = w; outH = h }
    }

    var capture: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (capW, capH) }
    var output: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (outW, outH) }
    var frameRate: Int { lock.lock(); defer { lock.unlock() }; return fps }
    var bitRate: Int { lock.lock(); defer { lock.unlock() }; return bitrate }
    var generationNow: UInt32 { lock.lock(); defer { lock.unlock() }; return generation }
    var activeEncoder: UInt8 { lock.lock(); defer { lock.unlock() }; return UInt8(activeEnc) }

    func setActiveEncoder(_ e: UInt8) {
        lock.lock(); activeEnc = Int(e); lock.unlock()
    }

    /// Apply a patch, validating it against the capture source.
    ///
    /// Returns a reason and leaves the configuration untouched when any field is
    /// unacceptable: a partial apply would leave the encoder and the Hello
    /// describing different streams.
    func apply(_ p: Patch) -> String? {
        lock.lock(); defer { lock.unlock() }
        var w = outW, h = outH
        // Geometry is all-or-nothing: changing only width would silently
        // distort the aspect ratio, and a scaling client always sends both.
        if p.width != nil || p.height != nil {
            w = Int(p.width ?? UInt32(outW))
            h = Int(p.height ?? UInt32(outH))
            for v in [w, h] {
                if v < Self.minDim || v > Self.maxDim {
                    return "size \(v) outside \(Self.minDim)..\(Self.maxDim)"
                }
                if v % 2 != 0 { return "size \(v) is odd (H.264 4:2:0 needs even)" }
            }
            // Upscaling is refused rather than clamped: asking for more pixels
            // than the source has is a client bug, and a silent cap would make
            // the UI believe it received the larger size.
            if capW != 0 && capH != 0 && (w > capW || h > capH) {
                return "size \(w)x\(h) exceeds capture \(capW)x\(capH)"
            }
        }
        let newFps = Int(p.fps ?? UInt8(fps))
        if newFps < Self.minFps || newFps > Self.maxFps {
            return "fps \(newFps) outside \(Self.minFps)..\(Self.maxFps)"
        }
        let newBitrate = Int(p.bitrate ?? UInt32(bitrate))
        if newBitrate < Self.minBitrate || newBitrate > Self.maxBitrate {
            return "bitrate \(newBitrate) outside \(Self.minBitrate)..\(Self.maxBitrate)"
        }
        if let e = p.encoder {
            if e != 0 && e != UInt8(Self.encX264) && e != UInt8(Self.encVideoToolbox) {
                // The other platforms' codes are valid on the wire but cannot be
                // honoured here, so say so instead of pretending.
                return "encoder \(e) not available on macos"
            }
        }
        outW = w; outH = h; fps = newFps; bitrate = newBitrate
        if let e = p.encoder { requestedEnc = Int(e) }
        generation &+= 1
        return nil
    }

    /// The Hello video block (EST.md offsets 15..23).
    func helloBlock() -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        var b = [UInt8](repeating: 0, count: 8)
        b[0] = 1 // hasVideoConfig
        b[1] = UInt8(activeEnc)
        var flags: UInt8 = 1 // reconfiguration supported
        // VideoToolbox is a platform encoder, so bit1 is always set: the flag
        // tells the UI "this is not software x264".
        if activeEnc == Self.encVideoToolbox { flags |= 2 }
        b[2] = flags
        b[3] = UInt8((bitrate >> 24) & 0xff); b[4] = UInt8((bitrate >> 16) & 0xff)
        b[5] = UInt8((bitrate >> 8) & 0xff);  b[6] = UInt8(bitrate & 0xff)
        b[7] = UInt8(min(255, fps * 2))
        return b
    }
}
