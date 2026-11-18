import CoreVideo
import QuartzCore

struct SourceFrame {
    let buffer: CVPixelBuffer
    let time: CFTimeInterval      // jitter-smoothed arrival time
    let seq: UInt64
    let interval: Double          // average time between real game frames
    let isCut: Bool               // scene change: don't interpolate across it
}

/// Thread-safe hand-off of the newest *unique* source frame to the renderer.
///
/// The PS5 always sends a 60 Hz signal; a 30 FPS game therefore repeats every frame twice.
/// Repeated frames are detected and dropped, so the generator sees the real 30 FPS motion.
/// The duplicate threshold adapts to the noise of the capture card (MJPEG sticks are noisy).
final class FrameStore {
    private let lock = NSLock()
    private var latest: SourceFrame?
    private(set) var seq: UInt64 = 0
    private var lastSamples: [Float] = []
    private var lastUniqueTime: CFTimeInterval = 0
    private var smoothedTime: CFTimeInterval = 0
    private var interval: Double = 1.0 / 30.0
    private var arrivals: [CFTimeInterval] = []
    private var signalArrivals: [CFTimeInterval] = []
    private var noiseFloor: Float = 0.3
    private var dropped = 0, total = 0

    var dedupEnabled = true
    var cutThreshold: Float = 38   // mean abs luma difference (0..255) that counts as a scene cut

    func reset() {
        lock.lock()
        latest = nil; seq = 0; lastSamples = []; arrivals = []; signalArrivals = []
        interval = 1.0 / 30.0; lastUniqueTime = 0; smoothedTime = 0; noiseFloor = 0.3; dropped = 0; total = 0
        lock.unlock()
    }

    private var dupThreshold: Float { min(max(noiseFloor * 3 + 0.6, 1.0), 4.0) }

    func push(_ pb: CVPixelBuffer, time: CFTimeInterval = CACurrentMediaTime()) {
        let samples = FrameStore.sample(pb)
        lock.lock(); defer { lock.unlock() }
        signalArrivals.append(time); if signalArrivals.count > 150 { signalArrivals.removeFirst() }
        total += 1
        var diff: Float = .infinity
        if samples.count == lastSamples.count, !samples.isEmpty {
            var d: Float = 0
            for i in 0..<samples.count { d += abs(samples[i] - lastSamples[i]) }
            diff = d / Float(samples.count)
            if dedupEnabled && diff < dupThreshold {
                noiseFloor = noiseFloor * 0.95 + diff * 0.05
                dropped += 1
                return
            }
        }
        let isCut = diff.isFinite && diff > cutThreshold
        lastSamples = samples

        // average interval between real frames (ignore pauses / loading screens)
        let dt = time - lastUniqueTime
        if lastUniqueTime > 0, dt > 0.004, dt < 0.1 { interval = interval * 0.9 + dt * 0.1 }
        lastUniqueTime = time

        // jitter smoothing (USB / driver delivery jitter): phase-locked timestamp
        let predicted = smoothedTime + interval
        if smoothedTime == 0 || abs(time - predicted) > interval * 0.6 {
            smoothedTime = time
        } else {
            smoothedTime = predicted + (time - predicted) * 0.15
        }

        arrivals.append(time); if arrivals.count > 120 { arrivals.removeFirst() }
        seq &+= 1
        latest = SourceFrame(buffer: pb, time: smoothedTime, seq: seq, interval: interval, isCut: isCut)
    }

    /// Returns the newest frame if it is newer than `after`.
    func take(after: UInt64) -> SourceFrame? {
        lock.lock(); defer { lock.unlock() }
        guard let f = latest, f.seq != after else { return nil }
        return f
    }

    private static func rate(_ a: [CFTimeInterval]) -> Double {
        let now = CACurrentMediaTime()
        let recent = a.filter { now - $0 < 1.0 }
        guard recent.count > 1, let f = recent.first, now - f < 1.2 else { return 0 }
        return Double(recent.count - 1) / max(recent.last! - f, 1e-3)
    }
    /// unique (real game) frames per second
    var gameFPS: Double { lock.lock(); defer { lock.unlock() }; return FrameStore.rate(arrivals) }
    /// frames per second of the HDMI signal
    var signalFPS: Double { lock.lock(); defer { lock.unlock() }; return FrameStore.rate(signalArrivals) }
    /// share of repeated frames that were removed
    var duplicateShare: Double { lock.lock(); defer { lock.unlock() }; return total > 0 ? Double(dropped) / Double(total) : 0 }

    /// ~2300 luma samples on a sparse grid (cheap CPU check for repeated frames / scene cuts)
    static func sample(_ pb: CVPixelBuffer) -> [Float] {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return [] }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb), bpr = CVPixelBufferGetBytesPerRow(pb)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var out: [Float] = []; out.reserveCapacity(64 * 36)
        for gy in 0..<36 {
            let y = (gy * 2 + 1) * h / 72
            for gx in 0..<64 {
                let x = (gx * 2 + 1) * w / 128
                let o = y * bpr + x * 4
                out.append(Float(p[o]) * 0.114 + Float(p[o + 1]) * 0.587 + Float(p[o + 2]) * 0.299)
            }
        }
        return out
    }
}
