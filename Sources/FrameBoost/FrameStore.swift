import CoreVideo
import QuartzCore
import Accelerate

struct SourceFrame {
    let buffer: CVPixelBuffer
    let time: CFTimeInterval      // jitter-smoothed arrival time
    let seq: UInt64
    let interval: Double          // average time between real game frames
    let isCut: Bool               // scene change: don't interpolate across it
    var arrival: CFTimeInterval = 0   // unsmoothed arrival time (diagnosis)
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
    private var noiseFloor: Float = 0.1
    private var dropped = 0, total = 0

    var dedupEnabled = true
    /// called (on the delivering thread, outside the lock) when a new real frame is available
    var onNewFrame: (() -> Void)?
    var cutThreshold: Float = 38   // mean abs luma difference (0..255) that counts as a scene cut

    func reset() {
        lock.lock()
        latest = nil; seq = 0; lastSamples = []; arrivals = []; signalArrivals = []
        interval = 1.0 / 30.0; lastUniqueTime = 0; smoothedTime = 0; noiseFloor = 0.1; dropped = 0; total = 0
        lock.unlock()
    }

    /// exact repeats (uncompressed cards) give 0; MJPEG sticks add some noise -> threshold follows the noise
    private var dupThreshold: Float { min(max(noiseFloor * 2.5 + 0.4, 0.6), 3.0) }

    func push(_ pb: CVPixelBuffer, time: CFTimeInterval = CACurrentMediaTime()) {
        if store(pb, time: time) { onNewFrame?() }
    }

    /// true if the frame was a new real frame
    private func store(_ pb: CVPixelBuffer, time: CFTimeInterval) -> Bool {
        let samples = FrameStore.sample(pb)
        lock.lock(); defer { lock.unlock() }
        signalArrivals.append(time); if signalArrivals.count > 150 { signalArrivals.removeFirst() }
        total += 1
        var diff: Float = .infinity
        if samples.count == lastSamples.count, !samples.isEmpty {
            // 144 regions (16×9): a frame is new as soon as ONE region changed - small movements in calm
            // scenes (a walking character, a slow pan) must not get lost in the average of the whole picture
            let (regionMax, mean) = FrameStore.compare(samples, lastSamples)
            diff = mean
            if dedupEnabled && regionMax < dupThreshold {
                noiseFloor = noiseFloor * 0.95 + regionMax * 0.05
                dropped += 1
                return false
            }
        }
        let isCut = diff.isFinite && diff > cutThreshold
        lastSamples = samples

        // average interval between real frames (ignore pauses / loading screens)
        let dt = time - lastUniqueTime
        if lastUniqueTime > 0, dt > 0.004, dt < 0.1 { interval = interval * 0.9 + dt * 0.1 }
        lastUniqueTime = time

        // jitter smoothing (USB / driver delivery jitter): phase-locked timestamp. A frame that is a whole
        // signal period (16.7 ms) early or late is a real stutter of the game, not jitter: take its time as is
        // (0.4 × 33 ms = 13 ms; simulated with 5-10 % game stutter: 97-99.7 % instead of 94-97 % exact timing)
        let predicted = smoothedTime + interval
        if smoothedTime == 0 || abs(time - predicted) > interval * 0.4 {
            smoothedTime = time
        } else {
            smoothedTime = predicted + (time - predicted) * 0.15
        }

        arrivals.append(time); if arrivals.count > 120 { arrivals.removeFirst() }
        seq &+= 1
        latest = SourceFrame(buffer: pb, time: smoothedTime, seq: seq, interval: interval, isCut: isCut, arrival: time)
        return true
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

    static let gridW = 128, gridH = 72

    /// 128×72 area-averaged luma (vImage downscale: every changed pixel counts, also 1-pixel movements)
    static func sample(_ pb: CVPixelBuffer) -> [Float] {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return [] }
        CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return [] }
        var src = vImage_Buffer(data: base, height: vImagePixelCount(CVPixelBufferGetHeight(pb)),
                                width: vImagePixelCount(CVPixelBufferGetWidth(pb)), rowBytes: CVPixelBufferGetBytesPerRow(pb))
        var small = [UInt8](repeating: 0, count: gridW * gridH * 4)
        let err = small.withUnsafeMutableBytes { raw -> vImage_Error in
            var dst = vImage_Buffer(data: raw.baseAddress, height: vImagePixelCount(gridH), width: vImagePixelCount(gridW), rowBytes: gridW * 4)
            return vImageScale_ARGB8888(&src, &dst, nil, vImage_Flags(kvImageNoFlags))
        }
        guard err == kvImageNoError else { return [] }
        var out = [Float](repeating: 0, count: gridW * gridH)
        for i in 0..<(gridW * gridH) {
            let o = i * 4   // BGRA
            out[i] = Float(small[o]) * 0.114 + Float(small[o + 1]) * 0.587 + Float(small[o + 2]) * 0.299
        }
        return out
    }

    /// (largest mean difference of the 16×9 regions, mean difference of the whole picture)
    static func compare(_ a: [Float], _ b: [Float]) -> (Float, Float) {
        var regionMax: Float = 0, total: Float = 0
        for ry in 0..<9 {
            for rx in 0..<16 {
                var s: Float = 0
                for y in 0..<8 {
                    let row = (ry * 8 + y) * gridW + rx * 8
                    for x in 0..<8 { s += abs(a[row + x] - b[row + x]) }
                }
                s /= 64
                regionMax = max(regionMax, s); total += s
            }
        }
        return (regionMax, total / 144)
    }
}
