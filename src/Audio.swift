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
/// Instead we use the standard macOS "virtual audio device" technique:
///
///   1. A BlackHole 2ch loopback device must be installed (HAL plug-in).
///   2. BlackHole alone has no clock source and stays silent, so we wrap it in
///      an AGGREGATE DEVICE together with the machine's real output (the QEMU
///      USB sound card), which provides the clock. The aggregate is set as the
///      default output, so every app's sound is routed into BlackHole.
///   3. An AUHAL (kAudioUnitSubType_HALOutput) unit opened in duplex on that
///      aggregate captures the looped-back PCM, which we convert to 20 ms Opus
///      packets with AudioConverter.
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
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
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

    /// probeBlackHole reports whether a BlackHole loopback device is installed.
    /// It is cheap — it only enumerates devices — and does NOT open the
    /// aggregate; that happens lazily in start().
    @discardableResult
    static func probeBlackHole() -> Bool {
        probeLock.lock()
        if let ok = probedBlackHole {
            probeLock.unlock()
            return ok
        }
        probeLock.unlock()
        let ok = allDevices().contains { deviceName($0).contains("BlackHole") }
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

    private static func deviceUID(_ id: AudioObjectID) -> String {
        var uid: CFString = "" as CFString
        var a = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(id, &a, 0, nil, &size, &uid)
        return uid as String
    }

    private static func setDefault(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) {
        var a = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dev = id
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &a, 0, nil,
            UInt32(MemoryLayout<AudioObjectID>.size), &dev)
    }

    // MARK: - Start

    private func start() {
        let devices = Self.allDevices()
        guard let blackhole = devices.first(where: { Self.deviceName($0).contains("BlackHole") }) else {
            log("no BlackHole device; system audio capture unavailable")
            return
        }
        // The real output device (QEMU USB sound card) provides the clock.
        guard let clock = devices.first(where: {
            let n = Self.deviceName($0)
            return n.contains("Audio Output") || n.contains("QEMU")
        }) else {
            log("no clock device for the aggregate")
            return
        }
        _ = AudioDeviceStart(clock, nil)

        // Remove a stale aggregate left by an earlier run (the UID is fixed, so
        // re-creating it without cleanup fails with kAudioHardwareBadObjectError).
        for d in devices where Self.deviceName(d).contains("easystream Audio") {
            AudioHardwareDestroyAggregateDevice(d)
        }

        // Wrap BlackHole in an aggregate device clocked by the real output.
        let aggregateUID = "easystream-audio-aggregate"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "easystream Audio",
            kAudioAggregateDeviceUIDKey as String: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey as String: false,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceClockDeviceKey as String: Self.deviceUID(clock),
            kAudioAggregateDeviceSubDeviceListKey as String: [
                [kAudioSubDeviceUIDKey as String: Self.deviceUID(blackhole)]
            ],
        ]
        var aggID = AudioObjectID(kAudioObjectUnknown)
        let crc = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard crc == noErr, aggID != kAudioObjectUnknown else {
            log("AudioHardwareCreateAggregateDevice failed (\(crc))")
            return
        }
        aggregate = aggID

        // Route all system audio into the aggregate (=> into BlackHole).
        Self.setDefault(aggID, kAudioHardwarePropertyDefaultOutputDevice)
        Self.setDefault(aggID, kAudioHardwarePropertyDefaultSystemOutputDevice)
        _ = AudioDeviceStart(aggID, nil)

        // Open an AUHAL unit in duplex mode on the aggregate.
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
