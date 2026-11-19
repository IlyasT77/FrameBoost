import AVFoundation
import CoreMedia
import QuartzCore
import CoreAudio

/// Plays the capture card's sound through a buffer, delayed by exactly as long as the picture needs
/// (frame generation holds back one real frame + GPU + display). Picture and sound stay in sync.
///
/// Timing: the first audio buffer anchors the mapping "sample timestamp -> host time".
/// Each buffer with timestamp P is then played at (its arrival time + delay). Clock drift between the
/// capture card's audio clock and the Mac is corrected when it grows beyond 15 ms.
final class AudioDelayPlayer {
    private let renderer = AVSampleBufferAudioRenderer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let lock = NSLock()
    private var anchored = false
    private var lastPTS = CMTime.invalid
    private var lastArrival: CFTimeInterval = 0
    private var _delay: Double = 0.06
    private(set) var failed = false
    private(set) var retimeCount = 0

    init() {
        sync.addRenderer(renderer)
        sync.delaysRateChangeUntilHasSufficientMediaData = false   // our timing must apply immediately
    }

    var volume: Float {
        get { renderer.volume }
        set { renderer.volume = newValue }
    }

    /// Seconds between "sound arrives" and "sound is played".
    var delay: Double {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set {
            lock.lock()
            let changed = abs(newValue - _delay) > 0.004
            _delay = max(0, min(newValue, 0.5))
            let pts = lastPTS, arr = lastArrival, anchoredNow = anchored
            lock.unlock()
            if changed && anchoredNow && pts.isValid { retime(pts: pts, arrival: arr) }
        }
    }

    /// Current playback error in seconds (positive = sound too late); for diagnostics.
    private(set) var lastError: Double = 0

    func enqueue(_ sb: CMSampleBuffer, arrival: CFTimeInterval = CACurrentMediaTime()) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        guard pts.isValid else { return }
        lock.lock()
        let first = !anchored
        anchored = true
        lastPTS = pts; lastArrival = arrival
        let d = _delay
        lock.unlock()

        if first {
            retime(pts: pts, arrival: arrival)
        } else {
            // expected media time right now = pts - (delay - time since arrival)
            let now = CACurrentMediaTime()
            let expected = pts.seconds - d + (now - arrival)
            let err = expected - sync.currentTime().seconds   // > 0: playback lags behind the target
            lastError = err
            if abs(err) > 0.015 { retime(pts: pts, arrival: arrival) }
        }
        if renderer.status == .failed { failed = true; return }
        if renderer.isReadyForMoreMediaData { renderer.enqueue(sb) }
    }

    /// Media time `pts` shall be heard at host time `arrival + delay`.
    /// The timebase is set *now* (to the media time that belongs to this moment), so it keeps running
    /// continuously; a future "atHostTime" would freeze it until then.
    private func retime(pts: CMTime, arrival: CFTimeInterval) {
        let now = CACurrentMediaTime()
        let mediaNow = CMTimeAdd(pts, CMTime(seconds: (now - arrival) - delay, preferredTimescale: 1_000_000_000))
        sync.setRate(1.0, time: mediaNow, atHostTime: CMClockGetTime(CMClockGetHostTimeClock()))
        retimeCount += 1
    }

    var debugInfo: String {
        let st: String
        switch renderer.status { case .rendering: st = "rendering"; case .failed: st = "failed"; default: st = "unknown" }
        return String(format: "status=%@ err=%@ rate=%.2f time=%.3f", st, renderer.error?.localizedDescription ?? "-", sync.rate, sync.currentTime().seconds)
    }

    /// true if macOS has a sound output device (test servers often have none)
    static var hasOutputDevice: Bool {
        var dev = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        let r = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &dev)
        return r == noErr && dev != 0
    }

    func stop() {
        sync.setRate(0, time: .zero)
        renderer.flush()
        lock.lock(); anchored = false; lastPTS = .invalid; lock.unlock()
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
