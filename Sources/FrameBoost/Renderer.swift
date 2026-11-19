import MetalKit
import CoreVideo
import QuartzCore

enum BoostMode: String, CaseIterable, Identifiable {
    case off = "Aus"
    case auto = "Auto"
    case x2 = "2×"
    case x3 = "3×"
    case x4 = "4×"
    var id: String { rawValue }
    var steps: Int? { switch self { case .x2: return 2; case .x3: return 3; case .x4: return 4; default: return nil } }
    var help: String {
        switch self {
        case .off: return "Keine Frame Generation (Original)"
        case .auto: return "So viele Bilder wie der Bildschirm kann (60 Hz → 60, 120 Hz → 120 FPS)"
        case .x2: return "Doppelte Bildrate (30 → 60 FPS)"
        case .x3: return "Dreifache Bildrate (30 → 90 FPS)"
        case .x4: return "Vierfache Bildrate (30 → 120 FPS)"
        }
    }
}

/// Shared settings (written on main thread, read on render thread; plain values).
final class RenderSettings {
    var mode: BoostMode = .auto
    var sharpen: Float = 0.3
    var blendOnly = false
}

/// Draws at the display refresh rate. Each refresh shows the exact moment between the
/// last two real frames -> 30 FPS in, 60/120 FPS out (one real frame of delay).
final class Renderer: NSObject, MTKViewDelegate {
    let interp: Interpolator
    let store: FrameStore
    let settings: RenderSettings
    private var cache: CVMetalTextureCache?
    private var lastSeq: UInt64 = 0
    private var timeB: CFTimeInterval = 0
    private var interval: Double = 1.0 / 30.0
    private var lastShown: (UInt64, Float) = (0, -1)
    private var presentTimes: [CFTimeInterval] = []
    private let statLock = NSLock()
    private var _gpuMs: Double = 0
    var gpuMs: Double { statLock.lock(); defer { statLock.unlock() }; return _gpuMs }
    var active = false
    private var lastDraw: CFTimeInterval = 0
    private var drawPeriod: Double = 1.0 / 60.0

    /// How long the picture is held back compared to the moment it arrived from the capture card:
    /// frame generation shows the moment between the last two real frames (one real frame behind),
    /// plus GPU time and the display pipeline (~1.5 refreshes). The sound buffer uses this value.
    var videoDelay: Double {
        statLock.lock(); defer { statLock.unlock() }
        let fg = settings.mode == .off ? 0 : interval
        return fg + 1.5 * drawPeriod + _gpuMs / 1000
    }

    init(interp: Interpolator, store: FrameStore, settings: RenderSettings) {
        self.interp = interp; self.store = store; self.settings = settings
        super.init()
        CVMetalTextureCacheCreate(nil, nil, interp.device, nil, &cache)
    }

    func reset() {
        lastSeq = 0; timeB = 0; lastShown = (0, -1)
        statLock.lock(); presentTimes.removeAll(); statLock.unlock()
        interp.reset()
    }

    /// Distinct images shown per second.
    var outputFPS: Double {
        statLock.lock(); defer { statLock.unlock() }
        let now = CACurrentMediaTime()
        let r = presentTimes.filter { now - $0 < 1.0 }
        guard r.count > 1, let f = r.first, let l = r.last, now - f < 1.2 else { return 0 }
        return Double(r.count - 1) / max(l - f, 1e-3)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cmd = interp.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        if lastDraw > 0 {
            let dp = min(max(now - lastDraw, 0.004), 0.05)
            statLock.lock(); drawPeriod = drawPeriod * 0.95 + dp * 0.05; statLock.unlock()
        }
        lastDraw = now
        if active, let f = store.take(after: lastSeq), let cache = cache {
            var cvTex: CVMetalTexture?
            let pb = f.buffer
            let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
            if CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
               let cvTex = cvTex, let tex = CVMetalTextureGetTexture(cvTex) {
                interp.ingest(tex, isCut: f.isCut, cmd: cmd)
                cmd.addCompletedHandler { _ in _ = cvTex; _ = pb } // keep the capture buffer alive until the copy ran
                lastSeq = f.seq; timeB = f.time; interval = f.interval
            }
        }
        guard active, interp.ready, let frame = interp.output else {
            // nothing to show: clear to black
            if let rpd = view.currentRenderPassDescriptor, let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) { enc.endEncoding() }
            cmd.present(drawable); cmd.commit()
            return
        }
        // where are we between frame A and frame B?
        let mode = settings.mode
        var t: Float = 1
        if mode != .off {
            let phase = Float(min(max((now - timeB) / max(interval, 0.004), 0), 1))
            if let m = mode.steps { t = min(floor(phase * Float(m) + 0.25) / Float(m), 1) } else { t = phase }
        }
        let synthMode: SynthMode = mode == .off ? .passthrough : (settings.blendOnly ? .blend : .interpolate)
        interp.synthesize(t: t, mode: synthMode, cmd: cmd)
        interp.present(frame, to: drawable.texture, sharpen: settings.sharpen, cmd: cmd)

        if lastShown.0 != lastSeq || abs(lastShown.1 - t) > 0.001 {
            lastShown = (lastSeq, t)
            statLock.lock(); presentTimes.append(now); if presentTimes.count > 300 { presentTimes.removeFirst(presentTimes.count - 300) }; statLock.unlock()
        }
        cmd.addCompletedHandler { [weak self] cb in
            let ms = (cb.gpuEndTime - cb.gpuStartTime) * 1000
            guard let self = self, ms > 0 else { return }
            self.statLock.lock(); self._gpuMs = self._gpuMs * 0.9 + ms * 0.1; self.statLock.unlock()
        }
        cmd.present(drawable)
        cmd.commit()
    }
}
