import MetalKit
import CoreVideo
import QuartzCore

enum BoostMode: String, CaseIterable, Identifiable {
    case off = "Aus"
    case auto = "Auto (max. Hz)"
    case x2 = "2×"
    case x3 = "3×"
    case x4 = "4×"
    var id: String { rawValue }
    var steps: Int? { switch self { case .x2: return 2; case .x3: return 3; case .x4: return 4; default: return nil } }
}

/// Shared settings (written on main thread, read on render thread; plain values, races are harmless)
final class RenderSettings {
    var mode: BoostMode = .auto
    var showRaw = false
}

/// Draws at the display refresh rate. Each refresh shows the exact moment between the
/// last two real frames -> 30 FPS in, 60/120 FPS out (one source frame of delay).
final class Renderer: NSObject, MTKViewDelegate {
    let interp: Interpolator
    let store: FrameStore
    let settings: RenderSettings
    private var cache: CVMetalTextureCache?
    private var lastSeq: UInt64 = 0
    private var arrivalB: CFTimeInterval = 0
    private var interval: Double = 1.0 / 30.0
    private var lastShown: (UInt64, Float) = (0, -1)
    private var presentTimes: [CFTimeInterval] = []
    private let statLock = NSLock()
    private(set) var gpuMs: Double = 0

    init(interp: Interpolator, store: FrameStore, settings: RenderSettings) {
        self.interp = interp; self.store = store; self.settings = settings
        super.init()
        CVMetalTextureCacheCreate(nil, nil, interp.device, nil, &cache)
    }

    /// Distinct frames shown per second.
    var outputFPS: Double {
        statLock.lock(); defer { statLock.unlock() }
        let now = CACurrentMediaTime()
        let r = presentTimes.filter { now - $0 < 1.0 }
        guard r.count > 1, let f = r.first, now - f < 1.2 else { return 0 }
        return Double(r.count - 1) / max(now - f, 1e-3)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cmd = interp.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if let f = store.take(after: lastSeq), let cache = cache {
            let (pb, time, seq, iv) = f
            var cvTex: CVMetalTexture?
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
               let cvTex = cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
                interp.ingest(tex, cmd: cmd)
                cmd.addCompletedHandler { _ in _ = cvTex; _ = pb } // keep the capture buffer alive until the copy ran
                lastSeq = seq; arrivalB = time; interval = iv
            }
        }
        // where are we between frame A and frame B?
        let mode = settings.mode
        var t: Float = 1
        if mode != .off {
            let phase = Float(min(max((now - arrivalB) / max(interval, 0.004), 0), 1))
            if let m = mode.steps { t = min(floor(phase * Float(m) + 0.25) / Float(m), 1) } else { t = phase }
        }
        let synthMode: SynthMode = mode == .off ? .passthrough : (settings.showRaw ? .blend : .interpolate)
        interp.synthesize(t: t, into: drawable.texture, mode: synthMode, cmd: cmd)
        if lastShown.0 != lastSeq || abs(lastShown.1 - t) > 0.001 {
            lastShown = (lastSeq, t)
            statLock.lock(); presentTimes.append(now); if presentTimes.count > 300 { presentTimes.removeFirst(presentTimes.count - 300) }; statLock.unlock()
        }
        cmd.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            if ms > 0 { self?.gpuMs = (self?.gpuMs ?? 0) * 0.9 + ms * 0.1 }
        }
        cmd.present(drawable)
        cmd.commit()
    }
}
