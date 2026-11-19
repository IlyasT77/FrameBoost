import MetalKit
import CoreVideo
import QuartzCore

enum BoostMode: String, CaseIterable, Identifiable {
    case off = "Aus"
    case auto = "Auto"
    case x2 = "2×"
    case x3 = "3×"
    case x4 = "4×"
    case x6 = "6×"
    var id: String { rawValue }
    var steps: Int? { switch self { case .x2: return 2; case .x3: return 3; case .x4: return 4; case .x6: return 6; default: return nil } }
    var help: String {
        switch self {
        case .off: return "Keine Frame Generation (Original)"
        case .auto: return "So viele Bilder wie der Bildschirm kann (60 Hz → 60, 180 Hz → 180 FPS)"
        case .x2: return "Doppelte Bildrate (30 → 60 FPS)"
        case .x3: return "Dreifache Bildrate (30 → 90 FPS)"
        case .x4: return "Vierfache Bildrate (30 → 120 FPS)"
        case .x6: return "Sechsfache Bildrate (30 → 180 FPS, für 180-Hz-Monitore)"
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
    private var timeA: CFTimeInterval = 0
    /// moment of the source timeline that is on screen. Advances by exactly one refresh per refresh
    /// (vsync-locked) and only gently follows the incoming signal, so draw-call jitter never shows twice the same image.
    private var outClock: CFTimeInterval = 0
    private var interval: Double = 1.0 / 30.0
    private var lastShown: (UInt64, Float) = (0, -1)
    private var presentTimes: [CFTimeInterval] = []
    private let statLock = NSLock()
    private var _gpuMs: Double = 0
    var gpuMs: Double { statLock.lock(); defer { statLock.unlock() }; return _gpuMs }
    var active = false
    private var lastDraw: CFTimeInterval = 0
    private var framesSinceFlush = 0
    // frame pacing measurement (video test): when did each new image reach the screen?
    private var measuring = false
    private var measuredPresented: [Double] = []
    private var measuredDrawn: [Double] = []
    private var measuredMedia: [Double] = []
    private var measuredAllDraws: [(time: Double, media: Double)] = []

    func beginMeasure() {
        statLock.lock(); measuredPresented = []; measuredDrawn = []; measuredMedia = []; measuredAllDraws = []; measuring = true; statLock.unlock()
    }
    func endMeasure() -> (presented: [Double], drawn: [Double], media: [Double], allDraws: [(time: Double, media: Double)]) {
        statLock.lock(); defer { statLock.unlock() }
        measuring = false
        return (measuredPresented.sorted(), measuredDrawn, measuredMedia, measuredAllDraws)
    }
    private var drawPeriod: Double = 1.0 / 60.0
    /// exact refresh period of the screen the window is on (from macOS; robust against skipped draw calls)
    private var nominalPeriod: Double = 0

    /// How long the picture is held back compared to the moment it arrived from the capture card:
    /// frame generation shows the moment between the last two real frames (one real frame behind),
    /// plus GPU time and the display pipeline (~1.5 refreshes). The sound buffer uses this value.
    /// measured refresh rate of the screen the window is on
    var displayHz: Double { statLock.lock(); defer { statLock.unlock() }; return 1 / max(nominalPeriod > 0 ? nominalPeriod : drawPeriod, 0.001) }

    var videoDelay: Double {
        statLock.lock(); defer { statLock.unlock() }
        let p = nominalPeriod > 0 ? nominalPeriod : drawPeriod
        let fg = settings.mode == .off ? p : interval + 1.2 * p
        return fg + 1.5 * p + _gpuMs / 1000
    }

    init(interp: Interpolator, store: FrameStore, settings: RenderSettings) {
        self.interp = interp; self.store = store; self.settings = settings
        super.init()
        CVMetalTextureCacheCreate(nil, nil, interp.device, nil, &cache)
        // start the motion analysis the moment a real frame arrives (not only at the next refresh)
        store.onNewFrame = { [weak self] in DispatchQueue.main.async { self?.ingestNow() } }
    }

    func reset() {
        lastSeq = 0; timeB = 0; timeA = 0; outClock = 0; lastShown = (0, -1); pendingPair = nil
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

    private var pendingPair: (a: CFTimeInterval, b: CFTimeInterval, i: Double)?

    private func ingestNow() {
        guard active, let f = store.take(after: lastSeq) else { return }
        analyse(f)
    }

    /// Encodes copy + motion analysis of a new real frame in its own command buffer (same queue = runs
    /// after this refresh's image and before the next refresh's work).
    private func analyse(_ f: SourceFrame) {
        guard let cache = cache, let cmd = interp.queue.makeCommandBuffer() else { return }
        var cvTex: CVMetalTexture?
        let pb = f.buffer
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvt = cvTex, let tex = CVMetalTextureGetTexture(cvt) else { return }
        interp.ingest(tex, isCut: f.isCut, cmd: cmd)
        cmd.addCompletedHandler { _ in _ = cvt; _ = pb }   // keep the capture buffer alive until the copy ran
        cmd.commit()
        lastSeq = f.seq
        let gap = f.time - timeB
        let a = timeB > 0 && gap > 0.004 && gap < 0.1 ? timeB : f.time - f.interval
        pendingPair = (a, f.time, f.interval)
        if !interp.hasPair { timeA = a; timeB = f.time; interval = f.interval; pendingPair = nil }
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let cmd = interp.queue.makeCommandBuffer() else { return }
        let now = CACurrentMediaTime()
        let prevDraw = lastDraw
        if lastDraw > 0 {
            let dp = min(max(now - lastDraw, 0.004), 0.05)
            statLock.lock(); drawPeriod = drawPeriod * 0.95 + dp * 0.05; statLock.unlock()
        }
        lastDraw = now
        framesSinceFlush += 1
        if framesSinceFlush >= 120, let cache = cache { CVMetalTextureCacheFlush(cache, 0); framesSinceFlush = 0 }  // no growth over long sessions
        // The motion analysis of a new real frame is encoded AFTER this refresh's image (see the end of draw):
        // the image goes out without waiting for the analysis, which then uses the free GPU time until the
        // next refresh. The new pair is therefore used from the next refresh on (the output clock is that
        // one refresh further behind).
        if let p = pendingPair { timeA = p.a; timeB = p.b; interval = p.i; pendingPair = nil }
        let newFrame = active ? store.take(after: lastSeq) : nil
        defer { if let f = newFrame { analyse(f) } }
        guard active, interp.ready, let frame = interp.output else {
            // nothing to show: clear to black
            if let rpd = view.currentRenderPassDescriptor, let enc = cmd.makeRenderCommandEncoder(descriptor: rpd) { enc.endEncoding() }
            cmd.present(drawable); cmd.commit()
            return
        }
        // where are we between frame A and frame B?
        let mode = settings.mode
        if let hz = view.window?.screen?.maximumFramesPerSecond, hz > 0 {
            let p = 1 / Double(min(hz, view.preferredFramesPerSecond))
            if abs(p - nominalPeriod) > 1e-6 { statLock.lock(); nominalPeriod = p; statLock.unlock() }
        }
        let dp = nominalPeriod > 0 ? nominalPeriod : drawPeriod
        // vsync-locked output clock, one real frame (+ a little margin) behind the signal
        let target = now - interval - 1.2 * dp
        if outClock == 0 || prevDraw == 0 {
            outClock = target
        } else {
            let steps = max(1, Int(((now - prevDraw) / dp).rounded()))
            outClock += Double(steps) * dp
            let err = target - outClock
            if abs(err) > 2.5 * dp { outClock = target } else { outClock += err * 0.03 }
        }
        var t: Float = 1
        if mode != .off {
            let span = max(timeB - timeA, 0.004)
            let phase = Float(min(max((outClock - timeA) / span, 0), 1))
            if let m = mode.steps { t = min((phase * Float(m)).rounded() / Float(m), 1) } else { t = phase }
        }
        let synthMode: SynthMode = mode == .off ? .passthrough : (settings.blendOnly ? .blend : .interpolate)
        let screen = drawable.texture
        if screen.width == interp.width && screen.height == interp.height {
            // 1:1 (e.g. 1080p capture on a 1080p monitor in fullscreen): no scaling pass at all
            interp.synthesize(t: t, mode: synthMode, into: screen, cmd: cmd)
        } else {
            interp.synthesize(t: t, mode: synthMode, cmd: cmd)
            interp.present(frame, to: screen, sharpen: settings.sharpen, cmd: cmd)
        }

        if measuring { statLock.lock(); measuredAllDraws.append((now, mode == .off ? timeB : timeA + Double(t) * (timeB - timeA))); statLock.unlock() }
        if lastShown.0 != lastSeq || abs(lastShown.1 - t) > 0.001 {
            lastShown = (lastSeq, t)
            statLock.lock()
            presentTimes.append(now); if presentTimes.count > 300 { presentTimes.removeFirst(presentTimes.count - 300) }
            let m = measuring
            if m { measuredDrawn.append(now); measuredMedia.append(mode == .off ? timeB : timeA + Double(t) * (timeB - timeA)) }
            statLock.unlock()
            if m {
                drawable.addPresentedHandler { [weak self] d in
                    guard let self = self, d.presentedTime > 0 else { return }
                    self.statLock.lock(); self.measuredPresented.append(d.presentedTime); self.statLock.unlock()
                }
            }
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
