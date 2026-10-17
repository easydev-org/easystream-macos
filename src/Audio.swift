import AudioToolbox
import CoreMedia
import Foundation
import ScreenCaptureKit

/// AudioPipeline captures SYSTEM audio with ScreenCaptureKit (capturesAudio)
/// and encodes it to Opus with AudioToolbox's built-in kAudioFormatOpus — no
/// third-party library, matching this daemon's zero-dependency rule.
///
/// One pipeline serves the whole process (like VideoPipeline); every est
/// connection that turns audio on subscribes to the same encoded packets.
final class AudioPipeline: NSObject, SCStreamOutput {
    static let shared = AudioPipeline()

    static let rate: UInt32 = 48_000
    static let channels: UInt32 = 2
    static let frameMs: UInt8 = 20

    private let lock = NSLock()
    private var sink: ((Data) -> Void)?
    private var started = false
    private var stream: SCStream?
    private var converter: AudioConverterRef?
    private var asbd = AudioStreamBasicDescription()

    private override init() {}

    /// params reports the audio parameters advertised in Hello.
    static func params() -> (Bool, UInt32, UInt8, UInt8) {
        (true, rate, UInt8(channels), frameMs)
    }

    /// subscribe registers `sink` (one per process; the packets fan out to all
    /// est connections via Serve's own broadcast).
    func subscribe(_ sink: @escaping (Data) -> Void) {
        lock.lock()
        self.sink = sink
        let first = !started
        started = true
        lock.unlock()
        if first { start() }
    }

    private func start() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, err in
            guard let self = self, let display = content?.displays.first else {
                FileHandle.standardError.write("audio: no display for SCK (\(String(describing: err)))\n".data(using: .utf8)!)
                return
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.sampleRate = Int(Self.rate)
            cfg.channelCount = Int(Self.channels)
            cfg.excludesCurrentProcessAudio = true
            // The audio path does not need video, but SCStream requires a
            // (tiny) video config; keep it minimal to save work.
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let s = SCStream(filter: filter, configuration: cfg, delegate: nil)
            do {
                try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.sck"))
            } catch {
                FileHandle.standardError.write("audio: addStreamOutput \(error)\n".data(using: .utf8)!)
                return
            }
            self.stream = s
            s.startCapture { err in
                if let err = err {
                    FileHandle.standardError.write("audio: startCapture \(err)\n".data(using: .utf8)!)
                } else {
                    FileHandle.standardError.write("audio: SCK audio capture started\n".data(using: .utf8)!)
                }
            }
        }
    }

    /// stream(_:didOutputSampleBuffer:of:) receives PCM buffers; we convert each
    /// to one 20 ms Opus packet and hand it to the sink.
    func stream(_ s: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, let sink = sink else { return }
        guard let fmt = CMSampleBufferGetFormatDescription(sb),
              let asbdIn = CMAudioFormatDescriptionGetStreamBasicDescription(fmt)?.pointee else { return }
        ensureConverter(input: asbdIn)
        guard let conv = converter else { return }

        // Copy the PCM into a contiguous block.
        var abl = AudioBufferList()
        var blockBuffer: CMBlockBuffer?
        let st = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sb, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &blockBuffer)
        guard st == noErr else { return }

        // Feed the converter. We hand it the whole input block and ask for one
        // 20 ms packet; AudioConverter fills outputData.
        var out = [UInt8](repeating: 0, count: 4000)
        let box = InputBox(abl)
        var outABL = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(mNumberChannels: Self.channels,
                                  mDataByteSize: UInt32(out.count),
                                  mData: &out))
        var ioOut: UInt32 = 1
        var pktDesc = AudioStreamPacketDescription()
        // The input callback is a C function pointer (cannot capture); the
        // input buffer list travels through inUserData (an InputBox).
        let r = withExtendedLifetime(box) {
            AudioConverterFillComplexBuffer(
                conv,
                { _, ioNumPackets, ioData, _, userData in
                    guard let userData = userData else { ioNumPackets.pointee = 0; return noErr }
                    let b = Unmanaged<InputBox>.fromOpaque(userData).takeUnretainedValue()
                    if b.provided { ioNumPackets.pointee = 0; return noErr }
                    b.provided = true
                    ioData.pointee = b.abl
                    ioNumPackets.pointee = 1
                    return noErr
                },
                Unmanaged.passUnretained(box).toOpaque(),
                &ioOut, &outABL, &pktDesc)
        }
        if r == noErr, outABL.mBuffers.mDataByteSize > 0 {
            sink(Data(bytes: outABL.mBuffers.mData!, count: Int(outABL.mBuffers.mDataByteSize)))
        }
    }

    /// providedFlag/setProvidedFlag: the fill callback needs to know whether it
    /// already handed over the input. We keep that in a per-call box.
    private final class InputBox {
        var abl: AudioBufferList
        var provided = false
        init(_ a: AudioBufferList) { abl = a }
    }

    /// ensureConverter builds the PCM -> Opus AudioConverter once, from the
    /// actual input format SCK reports.
    private func ensureConverter(input: AudioStreamBasicDescription) {
        if converter != nil { return }
        // Output: Opus, 48 kHz, stereo.
        var out = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.rate),
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: UInt32(Self.rate) / 50,
            mBytesPerFrame: 0, mChannelsPerFrame: Self.channels,
            mBitsPerChannel: 0, mReserved: 0)
        var conv: AudioConverterRef?
        var inFmt = input
        let st = AudioConverterNew(&inFmt, &out, &conv)
        guard st == noErr, let c = conv else {
            FileHandle.standardError.write("audio: AudioConverterNew failed \(st)\n".data(using: .utf8)!)
            return
        }
        // Ask for a moderate bitrate (96 kbps).
        var bitrate: UInt32 = 96_000
        AudioConverterSetProperty(c, kAudioConverterEncodeBitRate, UInt32(MemoryLayout<UInt32>.size), &bitrate)
        asbd = out
        converter = c
        FileHandle.standardError.write("audio: Opus converter ready\n".data(using: .utf8)!)
    }
}
