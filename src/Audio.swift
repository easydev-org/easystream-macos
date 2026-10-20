import AudioToolbox
import CoreAudio
import Foundation

/// AudioPipeline captures SYSTEM audio and encodes it to Opus with
/// AudioToolbox's built-in kAudioFormatOpus — no third-party library, matching
/// this daemon's zero-dependency rule.
///
/// ScreenCaptureKit's `capturesAudio` is NOT usable inside a VM: this guest's
/// software renderer makes replayd's DisplayStream fail ("Start stream failed",
/// CoreGraphics error 1003), so the audio side never starts either.
///
/// Instead the guest is wired with the standard macOS "virtual audio device"
/// technique — but note WHO does each part:
///
///   guest (oem.sh, once at boot)          this daemon (consume only)
///   -----------------------------         ------------------------
///   1. install the BlackHole 2ch          3. open the DEFAULT OUTPUT and read
///      loopback HAL plug-in                  its capture side with an AUHAL
///   2. run `aggregate`, which wraps          (kAudioUnitSubType_HALOutput) unit
///      BlackHole in an aggregate              in duplex, then encode the
///      clocked by the real output and         looped-back PCM to 20 ms Opus
///      makes it the default output            packets with AudioConverter
///
/// The split matters: BlackHole alone has no clock and stays silent, so it must
/// be aggregated with a real output — but doing that HERE made the system's
/// default output a side effect of a daemon restart (destroy + recreate under
/// every running app) and forced the clock source to be guessed from device
/// names. The daemon therefore builds nothing: it reads the default output,
/// whatever that happens to be.
///
/// One pipeline serves the whole process (like VideoPipeline); every est
/// connection that turns audio on subscribes to the same encoded packets.
final class AudioPipeline: NSObject {
    static let shared = AudioPipeline()

    static let rate: UInt32 = 48_000
    static let channels: UInt32 = 2
    static let frameMs: UInt8 = 20

    private let lock = NSLock()
    private var sink: ((Data) -> Void)?
    private var started = false
    private var unit: AudioUnit?
    private var converter: AudioConverterRef?
    private var asbd = AudioStreamBasicDescription()
    /// Scratch buffer handed to AudioUnitRender in the input callback.
    private var scratch: UnsafeMutableRawPointer?
    /// PCM left over between pull calls, so we can hand the converter exactly
    /// one 20 ms Opus frame at a time regardless of the device's buffer size.
    private var pending = Data()
    private let scratchFrames: UInt32 = 4096

    private override init() {}

    /// params reports the audio parameters advertised in Hello.
    ///
    /// hasAudio is false when no BlackHole device is present, because then the
    /// capture path cannot work at all (see the class comment) and Hello must
    /// not promise 0x05 frames.
    static func params() -> (Bool, UInt32, UInt8, UInt8) {
        (probeBlackHole(), rate, UInt8(channels), frameMs)
    }

    // MARK: - /capabilities support

    private static let probeLock = NSLock()
    private static var probedBlackHole: Bool?

    /// audioPath reports which capture backend produced PCM, for
    /// /capabilities. It mirrors the Linux daemon's AudioPath: the answer is
    /// only known once the (cheap) device check has run, so before that it says
    /// "Probing".
    ///
    /// The value names the MECHANISM (a BlackHole loopback), not the device we
    /// happen to open: the daemon reads whatever the system's default output is,
    /// which oem.sh has pointed at the aggregate containing BlackHole.
    static func audioPath() -> String {
        probeLock.lock()
        defer { probeLock.unlock() }
        guard let ok = probedBlackHole else { return "Probing" }
        return ok ? "BlackHole" : "None"
    }

    /// ensureProbed runs the device check once at startup so /capabilities can
    /// resolve without waiting for a viewer to enable audio.
    static func ensureProbed() {
        _ = probeBlackHole()
    }

    /// probeBlackHole reports whether system-audio capture is POSSIBLE.
    ///
    /// Two things must hold, and the second is the one that actually matters now
    /// that oem.sh does the wiring:
    ///
    ///   1. a BlackHole loopback device is installed (the mechanism), and
    ///   2. the default output device exposes a capture side — because that is
    ///      literally the device start() opens. If oem.sh has not pointed the
    ///      default output at the aggregate, opening it would yield nothing, and
    ///      reporting "BlackHole" would be a lie.
    ///
    /// Cheap: it only enumerates devices and reads one property.
    @discardableResult
    static func probeBlackHole() -> Bool {
        probeLock.lock()
        if let ok = probedBlackHole {
            probeLock.unlock()
            return ok
        }
        probeLock.unlock()
        let hasLoopback = allDevices().contains { deviceName($0).contains("BlackHole") }
        let def = defaultOutputDevice()
        let readable = def != AudioObjectID(kAudioObjectUnknown) && hasInputChannels(def)
        let ok = hasLoopback && readable
        probeLock.lock()
        probedBlackHole = ok
        probeLock.unlock()
        return ok
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

    private func log(_ s: String) {
        FileHandle.standardError.write("audio: \(s)\n".data(using: .utf8)!)
    }

    // MARK: - Device helpers

    /// defaultOutputDevice returns the system's current default output device,
    /// which is what the guest's audio is actually routed to.
    ///
    /// On a sandbox that is the "easystream Audio" aggregate that oem.sh builds
    /// (BlackHole clocked by the real output), and reading its input side yields
    /// the looped-back system audio. On a plain Mac it is the speakers, which have
    /// no capture side — the caller checks that and falls back.
    private static func defaultOutputDevice() -> AudioObjectID {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev) != noErr {
            return AudioObjectID(kAudioObjectUnknown)
        }
        return dev
    }

    /// hasInputChannels reports whether a device exposes any input channels —
    /// i.e. whether there is a capture side to read the loopback from.
    private static func hasInputChannels(_ dev: AudioObjectID) -> Bool {
        var size: UInt32 = 0
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &size) != noErr || size == 0 {
            return false
        }
        let bl = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bl.deallocate() }
        let abl = bl.bindMemory(to: AudioBufferList.self, capacity: 1)
        if AudioObjectGetPropertyData(dev, &a, 0, nil, &size, abl) != noErr {
            return false
        }
        var ch: UInt32 = 0
        let bufs = UnsafeMutableAudioBufferListPointer(abl)
        for b in bufs { ch += b.mNumberChannels }
        return ch > 0
    }

    private static func allDevices() -> [AudioObjectID] {
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
        return ids
    }

    private static func deviceName(_ id: AudioObjectID) -> String {
        var name: CFString = "" as CFString
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &name)
        return name as String
    }

    // MARK: - Start

    private func start() {
        // CONSUME ONLY. This daemon does not create, destroy or reconfigure any
        // audio device: wiring the guest is oem.sh's job, done once at boot by
        // the `aggregate` helper (BlackHole clocked by the real output, made the
        // default output). We just open whatever the system's default output is
        // and read its capture side.
        //
        // That boundary is deliberate. When the daemon built the aggregate
        // itself, the system's default output became a side effect of a daemon
        // restart — it destroyed and re-created the device underneath every
        // running app and briefly left no default output at all. It also had to
        // guess the clock source from device NAME strings. Both are gone: we now
        // need to know nothing about clocks, aggregates or names.
        let captureDevice = Self.defaultOutputDevice()
        guard captureDevice != AudioObjectID(kAudioObjectUnknown) else {
            log("no default output device; audio capture unavailable")
            return
        }
        guard Self.hasInputChannels(captureDevice) else {
            // Normal on a real Mac: the default output is the speakers, and
            // macOS exposes no system-audio loopback. In a sandbox this means the
            // guest was not wired (oem.sh / aggregate did not run) — say so
            // rather than silently producing silence.
            Self.deviceName(captureDevice).withCString {
                log("default output \"\(String(cString: $0))\" has no capture side; guest audio is not wired")
            }
            return
        }
        Self.deviceName(captureDevice).withCString {
            log("capturing system audio from \"\(String(cString: $0))\"")
        }
        let aggID = captureDevice

        // Open an AUHAL unit in duplex mode on the capture device.
        var comp = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0, componentFlagsMask: 0)
        guard let comp_ = AudioComponentFindNext(nil, &comp) else {
            log("no HALOutput component")
            return
        }
        var u: AudioUnit?
        guard AudioComponentInstanceNew(comp_, &u) == noErr, let unit = u else {
            log("AudioComponentInstanceNew failed")
            return
        }
        self.unit = unit

        var one: UInt32 = 1
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &one, 4)
        AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &one, 4)
        var dev = aggID
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev,
            UInt32(MemoryLayout<AudioObjectID>.size))

        // PCM s16le, 48 kHz, stereo on both directions.
        var fmt = AudioStreamBasicDescription(
            mSampleRate: Float64(Self.rate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: Self.channels, mBitsPerChannel: 16, mReserved: 0)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size))
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &fmt,
            UInt32(MemoryLayout<AudioStreamBasicDescription>.size))

        ensureConverter(input: fmt)
        scratch = UnsafeMutableRawPointer.allocate(
            byteCount: Int(scratchFrames) * Int(Self.channels) * 2, alignment: 4)

        // Input callback: pull the looped-back PCM with AudioUnitRender (ioData
        // is always nil for an input callback) and encode it to Opus.
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var cbs = AURenderCallbackStruct(
            inputProc: { (refcon, flags, ts, bus, frames, _) -> OSStatus in
                let me = Unmanaged<AudioPipeline>.fromOpaque(refcon).takeUnretainedValue()
                return me.pull(flags: flags, ts: ts, bus: bus, frames: frames)
            },
            inputProcRefCon: refcon)
        AudioUnitSetProperty(
            unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cbs,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        // A silent render callback keeps the output side of the duplex running.
        var rcbs = AURenderCallbackStruct(inputProc: { (_, _, _, _, _, ioData) -> OSStatus in
            if let ioData = ioData {
                let abl = UnsafeMutableAudioBufferListPointer(ioData)
                for i in 0..<Int(abl.count) where abl[i].mData != nil {
                    memset(abl[i].mData, 0, Int(abl[i].mDataByteSize))
                }
            }
            return noErr
        }, inputProcRefCon: nil)
        AudioUnitSetProperty(
            unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &rcbs,
            UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        let ir = AudioUnitInitialize(unit)
        let sr = AudioOutputUnitStart(unit)
        log("AUHAL on aggregate: init=\(ir) start=\(sr)")
    }

    /// pull renders one buffer from the aggregate and encodes it to Opus.
    private func pull(flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>, ts: UnsafePointer<AudioTimeStamp>,
                      bus: UInt32, frames: UInt32) -> OSStatus {
        guard let scratch = scratch, frames <= scratchFrames, let unit = unit else { return noErr }
        var abl = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: Self.channels,
                mDataByteSize: frames * Self.channels * 2,
                mData: scratch))
        let rc = AudioUnitRender(unit, flags, ts, bus, frames, &abl)
        guard rc == noErr, abl.mBuffers.mDataByteSize > 0, let conv = converter, let sink = sink else {
            return noErr
        }
        // Accumulate PCM, then encode one 20 ms Opus frame at a time.
        pending.append(Data(bytes: scratch, count: Int(abl.mBuffers.mDataByteSize)))
        let frameBytes = Int(Self.rate / 50) * Int(Self.channels) * 2  // 960 frames * 4
        while pending.count >= frameBytes {
            let frame = pending.prefix(frameBytes)
            pending.removeFirst(frameBytes)
            encode(conv: conv, input: frame, sink: sink)
        }
        return noErr
    }

    /// encode feeds one PCM block to the Opus converter and emits packets.
    private func encode(conv: AudioConverterRef, input: Data, sink: (Data) -> Void) {
        let box = InputBox(data: input)
        var out = [UInt8](repeating: 0, count: 4000)
        var outABL = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: Self.channels,
                mDataByteSize: UInt32(out.count),
                mData: &out))
        var ioOut: UInt32 = 1
        var pktDesc = AudioStreamPacketDescription()
        let r = withExtendedLifetime(box) {
            AudioConverterFillComplexBuffer(
                conv,
                { _, ioNumPackets, ioData, _, userData in
                    guard let userData = userData else { ioNumPackets.pointee = 0; return noErr }
                    let b = Unmanaged<InputBox>.fromOpaque(userData).takeUnretainedValue()
                    if b.provided { ioNumPackets.pointee = 0; return noErr }
                    b.provided = true
                    b.data.withUnsafeMutableBytes { raw in
                        ioData.pointee = AudioBufferList(
                            mNumberBuffers: 1,
                            mBuffers: AudioBuffer(
                                mNumberChannels: 2,
                                mDataByteSize: UInt32(raw.count),
                                mData: raw.baseAddress))
                    }
                    ioNumPackets.pointee = UInt32(b.data.count / 4)
                    return noErr
                },
                Unmanaged.passUnretained(box).toOpaque(),
                &ioOut, &outABL, &pktDesc)
        }
        if r == noErr, outABL.mBuffers.mDataByteSize > 0, let p = outABL.mBuffers.mData {
            sink(Data(bytes: p, count: Int(outABL.mBuffers.mDataByteSize)))
        }
    }

    /// InputBox carries the PCM pointer into the C fill callback.
    private final class InputBox {
        var data: Data
        var provided = false
        init(data: Data) { self.data = data }
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
