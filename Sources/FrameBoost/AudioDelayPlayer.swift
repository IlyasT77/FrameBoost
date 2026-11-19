import AVFoundation
import CoreMedia
import QuartzCore
import CoreAudio
import os

/// Ring buffer that keeps a fixed amount of sound "in flight" (= the delay).
/// Too much in the buffer (clock drift, delay lowered) -> skip ahead; too little -> hold (insert
/// silence) until the target is reached again. Pure logic, also used by the self test.
struct DelayLine {
    let channels: Int
    let capacity: Int
    private var buf: [Float]
    private(set) var writePos: Int64 = 0
    private(set) var readPos: Int64 = 0
    private var primed = false
    private var filling = false
    var target = 0          // frames
    var tolerance = 960     // frames
    private(set) var skips = 0, holds = 0

    init(channels: Int, capacity: Int) {
        self.channels = channels; self.capacity = capacity
        buf = [Float](repeating: 0, count: channels * capacity)
    }

    var available: Int { Int(writePos - readPos) }

    /// interleaved input
    mutating func write(_ p: UnsafePointer<Float>, frames: Int) {
        for i in 0..<frames {
            let idx = Int((writePos + Int64(i)) % Int64(capacity)) * channels
            for c in 0..<channels { buf[idx + c] = p[i * channels + c] }
        }
        writePos += Int64(frames)
        if writePos - readPos > Int64(capacity) { readPos = writePos - Int64(capacity) }
    }

    /// fills `frames` frames into per-channel outputs
    mutating func read(frames: Int, into out: [UnsafeMutablePointer<Float>]) {
        for o in out { o.update(repeating: 0, count: frames) }
        var avail = available
        if !primed {
            guard avail >= target else { return }
            primed = true
        }
        if avail > target + tolerance { readPos += Int64(avail - target); avail = target; skips += 1 }
        if avail < target - tolerance { filling = true; holds += 1 }
        var hold = 0
        if filling {
            hold = min(frames, max(0, target - avail))
            if hold < frames { filling = false }
        }
        for i in hold..<frames {
            guard readPos < writePos else { break }
            let idx = Int(readPos % Int64(capacity)) * channels
            for (c, o) in out.enumerated() { o[i] = buf[idx + min(c, channels - 1)] }
            readPos += 1
        }
    }

    mutating func reset() { writePos = 0; readPos = 0; primed = false; filling = false }
}

/// Plays the capture card's sound delayed by exactly as long as the picture needs
/// (frame generation holds back one real frame + GPU + display): picture and sound in sync.
/// delay = sound in the ring buffer + latency of the output device (speakers / headphones).
final class AudioDelayPlayer {
    private var engine: AVAudioEngine?
    private var line = DelayLine(channels: 2, capacity: 48000 * 2)
    private let lk = OSAllocatedUnfairLock()
    private var rate: Double = 48000
    private var _delay: Double = 0.06
    private var _volume: Float = 1
    private var configObserver: NSObjectProtocol?
    private(set) var outputLatency: Double = 0
    private(set) var failed = false
    private(set) var running = false

    var volume: Float {
        get { _volume }
        set { _volume = newValue; engine?.mainMixerNode.outputVolume = newValue }
    }

    /// Seconds between "sound arrives" and "sound is heard".
    var delay: Double {
        get { lk.lock(); defer { lk.unlock() }; return _delay }
        set {
            lk.lock()
            _delay = max(0, min(newValue, 0.5))
            applyTarget()
            lk.unlock()
        }
    }

    /// call with lock held
    private func applyTarget() {
        line.target = Int(max(0, _delay - outputLatency) * rate)
        line.tolerance = max(Int(0.02 * rate), 1536)
    }

    private func startEngine(sampleRate: Double) {
        let e = AVAudioEngine()
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else { failed = true; return }
        let src = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, abl -> OSStatus in
            guard let self = self else { return noErr }
            let list = UnsafeMutableAudioBufferListPointer(abl)
            var outs: [UnsafeMutablePointer<Float>] = []
            for b in list { if let d = b.mData { outs.append(d.assumingMemoryBound(to: Float.self)) } }
            self.lk.lock()
            self.line.read(frames: Int(frameCount), into: outs)
            self.lk.unlock()
            return noErr
        }
        e.attach(src)
        e.connect(src, to: e.mainMixerNode, format: fmt)
        e.mainMixerNode.outputVolume = _volume
        do {
            e.prepare()
            try e.start()
        } catch { failed = true; return }
        engine = e
        rate = sampleRate
        outputLatency = AudioDelayPlayer.defaultOutputLatency()
        lk.lock(); line.reset(); applyTarget(); lk.unlock()
        running = true
        // output device changed (headphones, AirPods...): restart with the new latency
        configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: e, queue: .main) { [weak self] _ in
            guard let self = self, let e = self.engine else { return }
            self.outputLatency = AudioDelayPlayer.defaultOutputLatency()
            self.lk.lock(); self.line.reset(); self.applyTarget(); self.lk.unlock()
            try? e.start()
        }
    }

    /// Accepts LPCM sample buffers (float32 or int16, mono or stereo, interleaved or not).
    func enqueue(_ sb: CMSampleBuffer) {
        guard let fd = CMSampleBufferGetFormatDescription(sb),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(fd) else { return }
        let asbd = asbdPtr.pointee
        guard asbd.mFormatID == kAudioFormatLinearPCM else { return }
        if !running || abs(asbd.mSampleRate - rate) > 1 {
            stop()
            startEngine(sampleRate: asbd.mSampleRate)
            if failed { return }
        }
        let frames = CMSampleBufferGetNumSamples(sb)
        guard frames > 0 else { return }
        var blockBuffer: CMBlockBuffer?
        var ablSize = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &ablSize, bufferListOut: nil, bufferListSize: 0,
                                                                blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let ablMem = UnsafeMutableRawPointer.allocate(byteCount: ablSize, alignment: 16)
        defer { ablMem.deallocate() }
        let ablPtr = ablMem.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: ablPtr, bufferListSize: ablSize,
                                                                      blockBufferAllocator: nil, blockBufferMemoryAllocator: nil,
                                                                      flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
                                                                      blockBufferOut: &blockBuffer) == noErr else { return }
        let list = UnsafeMutableAudioBufferListPointer(ablPtr)
        let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let ch = Int(asbd.mChannelsPerFrame)
        guard ch > 0, (isFloat && asbd.mBitsPerChannel == 32) || (!isFloat && asbd.mBitsPerChannel == 16) else { return }
        // -> interleaved stereo float
        var stereo = [Float](repeating: 0, count: frames * 2)
        func sample(_ frame: Int, _ c: Int) -> Float {
            let cc = min(c, ch - 1)
            let b = nonInterleaved ? list[cc] : list[0]
            let idx = nonInterleaved ? frame : frame * ch + cc
            guard let d = b.mData else { return 0 }
            return isFloat ? d.assumingMemoryBound(to: Float.self)[idx] : Float(d.assumingMemoryBound(to: Int16.self)[idx]) / 32768
        }
        for f in 0..<frames { stereo[2 * f] = sample(f, 0); stereo[2 * f + 1] = sample(f, 1) }
        lk.lock()
        stereo.withUnsafeBufferPointer { line.write($0.baseAddress!, frames: frames) }
        lk.unlock()
    }

    var debugInfo: String {
        lk.lock(); defer { lk.unlock() }
        return String(format: "engine=%@ rate=%.0f buffered=%.1fms target=%.1fms outLatency=%.1fms skips=%d holds=%d",
                      running ? "an" : "aus", rate, Double(line.available) / rate * 1000, Double(line.target) / rate * 1000,
                      outputLatency * 1000, line.skips, line.holds)
    }

    /// true if macOS has a sound output device
    static var hasOutputDevice: Bool { defaultOutputDevice() != nil }

    private static func defaultOutputDevice() -> AudioObjectID? {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return r == noErr && dev != 0 ? dev : nil
    }

    /// Latency of the current output (speakers / headphones / Bluetooth) in seconds.
    static func defaultOutputLatency() -> Double {
        guard let dev = defaultOutputDevice() else { return 0 }
        func u32(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope) -> UInt32 {
            var v: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
            return AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &v) == noErr ? v : 0
        }
        var rate: Float64 = 48000, rsize = UInt32(MemoryLayout<Float64>.size)
        var raddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                               mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        _ = AudioObjectGetPropertyData(dev, &raddr, 0, nil, &rsize, &rate)
        var frames = u32(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput)
            + u32(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput)
            + u32(dev, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeOutput)
        var ssize: UInt32 = 0
        var saddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput,
                                               mElement: kAudioObjectPropertyElementMain)
        if AudioObjectGetPropertyDataSize(dev, &saddr, 0, nil, &ssize) == noErr, ssize >= UInt32(MemoryLayout<AudioStreamID>.size) {
            var streams = [AudioStreamID](repeating: 0, count: Int(ssize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(dev, &saddr, 0, nil, &ssize, &streams) == noErr, let s0 = streams.first {
                frames += u32(s0, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal)
            }
        }
        return min(max(Double(frames) / max(rate, 8000), 0), 0.4)
    }

    func stop() {
        if let o = configObserver { NotificationCenter.default.removeObserver(o); configObserver = nil }
        engine?.stop(); engine = nil; running = false
        lk.lock(); line.reset(); lk.unlock()
    }
}

/// 48 kHz stereo float PCM generator (demo sound + self test): silence with optional 1 kHz beeps.
final class SyntheticAudio {
    static let rate = 48000
    private var format: CMAudioFormatDescription?
    private(set) var sampleIndex: Int64 = 0
    private var beepUntil: Int64 = -1

    init() {
        var asbd = AudioStreamBasicDescription(mSampleRate: Float64(SyntheticAudio.rate), mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    }

    /// Starts a short beep at the next generated sample.
    func beep(seconds: Double = 0.04) { beepUntil = sampleIndex + Int64(seconds * Double(SyntheticAudio.rate)) }

    /// Generates audio for the real time elapsed since the last call (like a real device).
    private var lastReal: CFTimeInterval = 0
    func nextRealtime() -> CMSampleBuffer? {
        let now = CACurrentMediaTime()
        if lastReal == 0 { lastReal = now - 0.01 }
        let target = Int64((now - lastReal) * Double(SyntheticAudio.rate))
        guard target > 0 else { return nil }
        lastReal += Double(target) / Double(SyntheticAudio.rate)
        return next(frames: Int(target))
    }

    func next(frames: Int) -> CMSampleBuffer? {
        guard let format = format else { return nil }
        let bytes = frames * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let blockBuffer = block else { return nil }
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            let s = sampleIndex + Int64(i)
            if s < beepUntil {
                let v = Float(sin(2 * Double.pi * 1000 * Double(s) / Double(SyntheticAudio.rate)) * 0.25)
                samples[2 * i] = v; samples[2 * i + 1] = v
            }
        }
        samples.withUnsafeBytes { raw in
            _ = CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes)
        }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blockBuffer, formatDescription: format,
                                                             sampleCount: frames,
                                                             presentationTimeStamp: CMTime(value: sampleIndex, timescale: CMTimeScale(SyntheticAudio.rate)),
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        sampleIndex += Int64(frames)
        return sb
    }
}
