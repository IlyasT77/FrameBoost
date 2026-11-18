import CoreVideo
import QuartzCore

/// Thread-safe hand-off of the newest *unique* source frame to the renderer.
/// The PS5 always sends a 60 Hz signal; a 30 FPS game therefore repeats every frame twice.
/// Repeated frames are detected and dropped, so the generator sees the real 30 FPS motion.
final class FrameStore {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var latestTime: CFTimeInterval = 0
    private(set) var seq: UInt64 = 0
    private var lastSamples: [Float] = []
    private var lastUniqueTime: CFTimeInterval = 0
    private var interval: Double = 1.0 / 30.0
    private var arrivals: [CFTimeInterval] = []
    private var signalArrivals: [CFTimeInterval] = []

    var duplicateThreshold: Float = 1.2 // mean abs diff (0..255) below which a frame is a repeat
    var dedupEnabled = true

    func reset() {
        lock.lock(); latest = nil; seq = 0; lastSamples = []; arrivals = []; signalArrivals = []; interval = 1.0 / 30.0; lock.unlock()
    }

    func push(_ pb: CVPixelBuffer, time: CFTimeInterval = CACurrentMediaTime()) {
        let samples = FrameStore.sample(pb)
        lock.lock(); defer { lock.unlock() }
        signalArrivals.append(time); if signalArrivals.count > 120 { signalArrivals.removeFirst() }
        if dedupEnabled, samples.count == lastSamples.count, !samples.isEmpty {
            var d: Float = 0
            for i in 0..<samples.count { d += abs(samples[i] - lastSamples[i]) }
            if d / Float(samples.count) < duplicateThreshold { return }
        }
        lastSamples = samples
        let dt = time - lastUniqueTime
        if lastUniqueTime > 0, dt > 0.004, dt < 0.1 { interval = interval * 0.85 + dt * 0.15 }
        lastUniqueTime = time
        arrivals.append(time); if arrivals.count > 90 { arrivals.removeFirst() }
        latest = pb; latestTime = time; seq &+= 1
    }

    /// Returns the newest frame if it is newer than `after`.
    func take(after: UInt64) -> (CVPixelBuffer, CFTimeInterval, UInt64, Double)? {
        lock.lock(); defer { lock.unlock() }
        guard seq != after, let pb = latest else { return nil }
        return (pb, latestTime, seq, interval)
    }

    var currentInterval: Double { lock.lock(); defer { lock.unlock() }; return interval }

    private static func rate(_ a: [CFTimeInterval]) -> Double {
        let now = CACurrentMediaTime()
        let recent = a.filter { now - $0 < 1.0 }
        guard recent.count > 1, let f = recent.first else { return 0 }
        return now - f > 1.2 ? 0 : Double(recent.count - 1) / max(now - f, 1e-3) * Double(recent.count) / Double(recent.count)
    }
    /// unique (real game) frames per second
    var gameFPS: Double { lock.lock(); defer { lock.unlock() }; return FrameStore.rate(arrivals) }
    /// frames per second of the HDMI signal
    var signalFPS: Double { lock.lock(); defer { lock.unlock() }; return FrameStore.rate(signalArrivals) }

    /// ~2300 luma samples on a sparse grid (cheap CPU check for repeated frames)
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
