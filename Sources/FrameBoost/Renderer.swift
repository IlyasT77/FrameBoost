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
    private var measuredAllDraws: [(time: Double, media: Double, slot: Int, inputLate: Bool)] = []
    /// per-event trace for the video test (main thread only): D = refresh, A = analysis of a new real frame
    private var trace: [String] = []
    func takeTrace() -> [String] { let t = trace; trace = []; return t }

    func beginMeasure() {
        statLock.lock(); measuredPresented = []; measuredDrawn = []; measuredMedia = []; measuredAllDraws = []; measuring = true; statLock.unlock()
        trace = ["typ;jetzt_ms;outClock_ms;A_ms;B_ms;t;paar_neu;quelle_ms_oder_slot;seq;raster"]
    }
    func endMeasure() -> (presented: [Double], drawn: [Double], media: [Double], allDraws: [(time: Double, media: Double, slot: Int, inputLate: Bool)]) {
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
        let grid = settings.mode.steps.map { gridOffset * interval / Double($0) } ?? 0
        let fg = settings.mode == .off ? p : interval + margin(p) + grid
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
        nextNeedsNewPair = true; gridOffset = 0.5; gridVec = (0, 0); slotAnchor = 0; slot = 0
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

    private var pendingPair: (a: CFTimeInterval, b: CFTimeInterval, i: Double, step: UInt64)?
    /// how many new real frames arrived from frame A to frame B (1 = none skipped by FrameBoost)
    private var pairStep: UInt64 = 1
    /// set by every refresh: the NEXT refresh shows a moment after the current pair's frame B. Only then may a new
    /// real frame replace the pair (before that, the current pair is still needed for the in-between images).
    private var nextNeedsNewPair = true
    /// fixed modes (2×, 3× …): where the refreshes fall between two grid points of the output, as a running circular
    /// mean. Rounding is centred on it, so refresh timing jitter can never flip between two neighbouring images.
    private var gridOffset: Double = 0.5
    private var gridVec: (x: Double, y: Double) = (0, 0)
    /// refresh slots: a grid of refresh periods that follows the phase of the draw calls. The number of refreshes
    /// between two calls is the slot difference (0 = a second call within the same refresh, 2 = one was skipped),
    /// robust against irregular call times (e.g. a call 7 ms after the previous one followed by one after 26 ms).
    private var slotAnchor: CFTimeInterval = 0
    private var slotPeriod: Double = 0
    private var slot = 0

    /// how far the output clock stays behind the newest real frame, on top of one frame interval
    private func margin(_ dp: Double) -> Double { max(1.2 * dp, 0.012) }

    /// output grid of the fixed modes in seconds: one real-frame interval / steps (2× at 30 FPS: 16.7 ms).
    /// Absolute time, NOT a fraction of the current pair: if a real frame was skipped, the pair spans two
    /// intervals and simply gets twice as many in-between images.
    private func gridStep(_ mode: BoostMode) -> Double? { mode.steps.map { max(interval, 0.004) / Double($0) } }

    /// position between frame A (0) and frame B (1) shown at output time `clock`, snapped to the grid;
    /// `beyond`: that moment lies after frame B, i.e. it needs the next real frame
    private func position(_ clock: Double, _ mode: BoostMode) -> (pos: Double, beyond: Bool) {
        let span = max(timeB - timeA, 0.004)
        guard let g = gridStep(mode) else { let p = (clock - timeA) / span; return (p, p > 1 + 1e-9) }
        let k = ((clock - timeA) / g - gridOffset).rounded()
        return (k * g / span, k > span / g + 0.5)
    }

    private func ingestNow() {
        // a new real frame may only replace the pair once the current pair is no longer needed
        guard active, nextNeedsNewPair || !interp.hasPair, let f = store.take(after: lastSeq) else { return }
        analyse(f, via: "I")
    }

    /// Encodes copy + motion analysis of a new real frame in its own command buffer (same queue = runs
    /// after this refresh's image and before the next refresh's work).
    private func analyse(_ f: SourceFrame, via: String = "D", into shared: MTLCommandBuffer? = nil) {
        guard let cache = cache, let cmd = shared ?? interp.queue.makeCommandBuffer() else { return }
        var cvTex: CVMetalTexture?
        let pb = f.buffer
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm, w, h, 0, &cvTex) == kCVReturnSuccess,
              let cvt = cvTex, let tex = CVMetalTextureGetTexture(cvt) else { return }
        interp.ingest(tex, isCut: f.isCut, cmd: cmd)
        cmd.addCompletedHandler { _ in _ = cvt; _ = pb }   // keep the capture buffer alive until the copy ran
        if shared == nil { cmd.commit() }
        let step = f.seq &- lastSeq
        lastSeq = f.seq
        let gap = f.time - timeB
        let a = timeB > 0 && gap > 0.004 && gap < 0.1 ? timeB : f.time - f.interval
        if shared != nil || !interp.hasPair {
            // same command buffer as this refresh (or no pair yet): the new pair is valid right away
            timeA = a; timeB = f.time; interval = f.interval; pairStep = step; pendingPair = nil
        } else {
            pendingPair = (a, f.time, f.interval, step)   // own command buffer: valid from the next refresh on
            nextNeedsNewPair = false                 // the next refresh needs exactly this pair
        }
        if measuring && trace.count < 20000 {
            trace.append(String(format: "A%@;%.3f;%.3f;%.3f;%.3f;;;%.3f;%llu", via, CACurrentMediaTime() * 1000, outClock * 1000,
                                a * 1000, f.time * 1000, f.arrival * 1000, f.seq))
        }
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
        // A new real frame replaces the pair only once the current pair is no longer needed (nextNeedsNewPair).
        // Its motion analysis normally runs in its own command buffer after a refresh's image (end of draw, or
        // ingestNow when the frame arrives later), so it never delays an image; the pair is used from the next refresh.
        var applied = 0
        if let p = pendingPair { timeA = p.a; timeB = p.b; interval = p.i; pairStep = p.step; pendingPair = nil; applied = 1 }
        guard active, interp.ready, let frame = interp.output else {
            // nothing to show yet: take every frame as it comes, clear to black
            nextNeedsNewPair = true
            if active, let f = store.take(after: lastSeq) { analyse(f, via: "D", into: cmd) }
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
        let target = now - interval - margin(dp)
        var steps = 1
        if slotAnchor == 0 || prevDraw == 0 || abs(dp - slotPeriod) > 1e-6 || now - prevDraw > 0.25 {
            slotAnchor = now; slotPeriod = dp; slot = 0
        } else {
            let rel = (now - slotAnchor) / dp
            let idx = Int(rel.rounded())
            slotAnchor += (rel - Double(idx)) * dp * 0.05   // follow the phase of the calls slowly
            steps = max(idx - slot, 0)
            slot = max(idx, slot)
        }
        if outClock == 0 || prevDraw == 0 {
            outClock = target
        } else if steps > 0 {
            outClock += Double(steps) * dp
            let err = target - outClock
            if abs(err) > 2.5 * dp { outClock = target } else { outClock += err * 0.03 }
        }
        var t: Float = 1
        var inputLate = false   // this refresh needed a real frame that had not arrived (or the source skipped one)
        if mode != .off {
            if let g = gridStep(mode), interp.hasPair, steps > 0 {
                // track where the refreshes fall between grid points (circular mean) and centre the rounding on it
                let x = (outClock - timeA) / g, f = x - x.rounded(.down)
                gridVec = (gridVec.x * 0.97 + cos(2 * .pi * f) * 0.03, gridVec.y * 0.97 + sin(2 * .pi * f) * 0.03)
                if hypot(gridVec.x, gridVec.y) > 0.5 {
                    // continuous (unwrapped) so it never jumps by a whole image; kept within [-0.25, 1.25)
                    let o = atan2(gridVec.y, gridVec.x) / (2 * .pi)
                    var c = o + (gridOffset - o).rounded()
                    if c >= 1.25 { c -= 1 } else if c < -0.25 { c += 1 }
                    gridOffset = c
                } else {
                    gridOffset = 0.5   // refresh rate is no multiple of the frame rate: plain rounding down
                }
            }
            var p = position(outClock, mode)
            // this refresh needs a moment after frame B and the next real frame is already here: analyse it first,
            // in this refresh's own command buffer (only happens when a frame came late or a refresh was skipped)
            if p.beyond, interp.hasPair, let f = store.take(after: lastSeq) {
                analyse(f, via: "S", into: cmd)
                p = position(outClock, mode)
            }
            t = Float(min(max(p.pos, 0), 1))
            // (a long pair counts only if the source really skipped a frame, not if FrameBoost skipped one)
            inputLate = p.beyond || (timeB - timeA > 1.5 * interval && pairStep == 1)
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

        if measuring && trace.count < 20000 {
            trace.append(String(format: "D;%.3f;%.3f;%.3f;%.3f;%.3f;%d;%d;%llu;%.3f", now * 1000, outClock * 1000, timeA * 1000, timeB * 1000, t, applied, slot, lastSeq, gridOffset))
        }
        if measuring { statLock.lock(); measuredAllDraws.append((now, mode == .off ? timeB : timeA + Double(t) * (timeB - timeA), slot, inputLate)); statLock.unlock() }
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
        // may the next real frame replace the pair? Only if the next refresh shows a moment after frame B.
        nextNeedsNewPair = mode == .off || !interp.hasPair
            || position(outClock + dp, mode).beyond
        cmd.present(drawable)
        cmd.commit()
        // the analysis of an already waiting frame goes in its own command buffer AFTER this refresh's image,
        // so it never delays the image; the new pair is used from the next refresh on
        if nextNeedsNewPair, let f = store.take(after: lastSeq) { analyse(f, via: "D") }
    }
}
