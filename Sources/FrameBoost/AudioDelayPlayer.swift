import AVFoundation
import CoreMedia
import QuartzCore
import CoreAudio

/// Plays the capture card's sound through a buffer, delayed by exactly as long as the picture needs
/// (frame generation holds back one real frame + GPU + display). Picture and sound stay in sync.
///
/// Timing: buffer with timestamp P arriving at host time A is heard at A + delay. The renderer itself
/// compensates the output device latency (speakers, headphones); Bluetooth latency above `delay` cannot
/// be compensated (shown as a hint in the settings). Right after (re)timing, the synchronizer's reading is taken as baseline; only when the clocks
/// drift apart by more than 20 ms is it re-timed. Re-timing never runs on the main thread.
final class AudioDelayPlayer {
    private let renderer = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let ctl = DispatchQueue(label: "audio.delay.ctl", qos: .userInteractive)
    private let lock = NSLock()
    private var anchored = false
    private var pending = false
    private var baseline: Double?
    private var lastPTS = CMTime.invalid
    private var lastArrival: CFTimeInterval = 0
    private var _delay: Double = 0.06
    private(set) var outputLatency: Double = 0
    private(set) var failed = false
    private(set) var retimeCount = 0
    /// drift since the last timing in seconds (diagnostics)
    private(set) var lastError: Double = 0

    init() {
        sync.addRenderer(renderer)
        sync.delaysRateChangeUntilHasSufficientMediaData = false   // our timing must apply immediately
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Seconds between "sound arrives" and "sound is heard".
    var delay: Double {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set {
            lock.lock()
            let v = max(0, min(newValue, 0.5))
            let changed = abs(v - _delay) > 0.008
            _delay = v
            let pts = lastPTS, arr = lastArrival, go = changed && anchored && pts.isValid && !pending
            if go { pending = true }
            lock.unlock()
            if go { ctl.async { self.retime(pts: pts, arrival: arr) } }
        }
    }

    private var bufferDelay: Double { delay }

    func enqueue(_ sb: CMSampleBuffer, arrival: CFTimeInterval = CACurrentMediaTime()) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        lock.lock()
        let first = !anchored
        anchored = true
        lastPTS = pts; lastArrival = arrival
        let base = baseline, isPending = pending
        lock.unlock()

        if first {
            outputLatency = AudioDelayPlayer.defaultOutputLatency()
            retime(pts: pts, arrival: arrival)
        } else if let base = base, !isPending {
            let err = offset(pts: pts, arrival: arrival) - base
            lastError = err
            if abs(err) > 0.02 {
                lock.lock(); pending = true; lock.unlock()
                ctl.async { self.retime(pts: pts, arrival: arrival) }
            }
        }
        if renderer.status == .failed { failed = true; return }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sb) }
    }

    /// synchronizer time minus the media time that should be playing right now
    private func offset(pts: CMTime, arrival: CFTimeInterval) -> Double {
        let expected = pts.seconds - bufferDelay + (CACurrentMediaTime() - arrival)
        return sync.currentTime().seconds - expected
    }

    /// Media time `pts` shall be heard at host time `arrival + delay`. The timebase is set *now*
    /// (to the media time that belongs to this moment) so it keeps running continuously.
    private func retime(pts: CMTime, arrival: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let mediaNow = CMTimeAdd(pts, CMTime(seconds: (now - arrival) - bufferDelay, preferredTimescale: 1_000_000_000))
        sync.setRate(1.0, time: mediaNow, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        let b = offset(pts: pts, arrival: arrival)
        lock.lock(); baseline = b; pending = false; retimeCount += 1; lock.unlock()
    }

    var debugInfo: String {
        let st: String
        switch renderer.status { case .rendering: st = "rendering"; case .failed: st = "failed"; default: st = "unknown" }
        return String(format: "status=%@ err=%@ rate=%.2f baseline=%.1fms outLatency=%.1fms", st, renderer.error?.localizedDescription ?? "-",
                      sync.rate, (baseline ?? 0) * 1000, outputLatency * 1000)
    }

    /// true if macOS has a sound output device (test servers often have none)
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
        // first output stream's latency
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
        sync.setRate(0, time: .zero)
        renderer.flush()
        lock.lock(); anchored = false; pending = false; baseline = nil; lastPTS = .invalid; lock.unlock()
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
