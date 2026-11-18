import Metal
import simd

struct MEParams {
    var radius: Int32; var blockSize: Int32; var window: Int32; var lambda: Float
    var parentScale: Float = 1; var parentDiv: Int32 = 1; var usePrev: Int32 = 0; var subpixel: Int32 = 0
    var ownPenalty: Float = 0; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0
}
struct SynthParams {
    var t: Float; var cell: Float; var mvScale: Float; var mode: Int32
    var cut: Int32; var sigma: Float; var occLo: Float; var occHi: Float
}
struct PresentParams {
    var offset: SIMD2<Float>; var scale: Float; var sharpen: Float
    var srcSize: SIMD2<Float>; var pad0: Float = 0; var pad1: Float = 0
}

enum SynthMode: Int32 { case passthrough = 0, interpolate = 1, blend = 2 }

enum GenQuality: String, CaseIterable, Identifiable {
    case high = "Hoch (16 px, Sub-Pixel)"
    case fast = "Schnell (32 px)"
    var id: String { rawValue }
}

/// GPU frame generation: motion estimation between the last two real frames
/// and motion compensated synthesis of any in-between moment t.
final class Interpolator {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pLuma, pDown, pCoarse, pRefine, pMedian, pSelect, pCompose, pPresent: MTLComputePipelineState

    private final class Slot {
        let rgb, l2, l4, l8, l16: MTLTexture
        init(_ rgb: MTLTexture, _ l2: MTLTexture, _ l4: MTLTexture, _ l8: MTLTexture, _ l16: MTLTexture) {
            self.rgb = rgb; self.l2 = l2; self.l4 = l4; self.l8 = l8; self.l16 = l16
        }
    }
    private final class Fields {
        var coarse, coarsePrev, ref8, ref, med, fine, fineMed: MTLTexture
        init(_ c: MTLTexture, _ cp: MTLTexture, _ r8: MTLTexture, _ r: MTLTexture, _ m: MTLTexture, _ f: MTLTexture, _ fm: MTLTexture) {
            coarse = c; coarsePrev = cp; ref8 = r8; ref = r; med = m; fine = f; fineMed = fm
        }
    }
    private var a: Slot?, b: Slot?
    private var fw: Fields?, bw: Fields?
    private(set) var output: MTLTexture?
    private var sel: MTLTexture?, selW: MTLTexture?
    private(set) var width = 0, height = 0
    private(set) var hasPair = false
    private(set) var ready = false
    private var pairCount = 0
    /// true if the current pair is a scene cut (menu, camera cut): no interpolation across it
    var pairIsCut = false
    var quality: GenQuality = .high
    var searchRadius: Int32 = 8    // 1/16 px -> +-128 px per real frame (+ temporal predictor)

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "FrameBoost", code: 1) }
        queue = q
        let lib = try device.makeLibrary(source: frameBoostShaderSource, options: nil)
        func pipe(_ n: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: n) else { throw NSError(domain: "FrameBoost", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(n)"]) }
            return try device.makeComputePipelineState(function: f)
        }
        pLuma = try pipe("luma_half"); pDown = try pipe("down2"); pCoarse = try pipe("me_coarse")
        pRefine = try pipe("me_refine"); pMedian = try pipe("median3")
        pSelect = try pipe("select_mv"); pCompose = try pipe("compose"); pPresent = try pipe("present")
    }

    func reset() { a = nil; b = nil; hasPair = false; ready = false; pairCount = 0; width = 0; height = 0 }

    private func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func makeSlot() -> Slot {
        Slot(tex(width, height, .bgra8Unorm), tex((width + 1) / 2, (height + 1) / 2, .r16Float),
             tex((width + 3) / 4, (height + 3) / 4, .r16Float), tex((width + 7) / 8, (height + 7) / 8, .r16Float),
             tex((width + 15) / 16, (height + 15) / 16, .r16Float))
    }

    private func makeFields() -> Fields {
        let gw = (width + 31) / 32, gh = (height + 31) / 32
        let fw = (width + 15) / 16, fh = (height + 15) / 16
        return Fields(tex(gw, gh, .rg16Float), tex(gw, gh, .rg16Float), tex(gw, gh, .rg16Float), tex(gw, gh, .rg16Float),
                      tex(gw, gh, .rg16Float), tex(fw, fh, .rg16Float), tex(fw, fh, .rg16Float))
    }

    private func setup(_ w: Int, _ h: Int) {
        width = w; height = h
        a = makeSlot(); b = makeSlot(); fw = makeFields(); bw = makeFields()
        output = tex(w, h, .bgra8Unorm)
        sel = tex((w + 1) / 2, (h + 1) / 2, .rgba16Float); selW = tex((w + 1) / 2, (h + 1) / 2, .rg16Float)
        hasPair = false; ready = false; pairCount = 0
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(p)
        let tw = p.threadExecutionWidth, th = max(1, min(8, p.maxTotalThreadsPerThreadgroup / tw))
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    /// Push a new real frame (BGRA texture). Encodes copy + luma pyramid + motion estimation into `cmd`.
    func ingest(_ src: MTLTexture, isCut: Bool = false, cmd: MTLCommandBuffer) {
        if src.width != width || src.height != height || a == nil { setup(src.width, src.height) }
        let hadFrame = ready
        swap(&a, &b)
        guard let a = a, let b = b, let fw = fw, let bw = bw else { return }
        if let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: b.rgb, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setTexture(b.rgb, index: 0); enc.setTexture(b.l2, index: 1); dispatch(enc, pLuma, b.l2.width, b.l2.height)
        enc.setTexture(b.l2, index: 0); enc.setTexture(b.l4, index: 1); dispatch(enc, pDown, b.l4.width, b.l4.height)
        enc.setTexture(b.l4, index: 0); enc.setTexture(b.l8, index: 1); dispatch(enc, pDown, b.l8.width, b.l8.height)
        enc.setTexture(b.l8, index: 0); enc.setTexture(b.l16, index: 1); dispatch(enc, pDown, b.l16.width, b.l16.height)
        ready = true
        pairIsCut = isCut
        if hadFrame && !isCut {
            let usePrev = pairCount > 0
            estimate(enc, from: a, to: b, f: fw, usePrev: usePrev)
            estimate(enc, from: b, to: a, f: bw, usePrev: usePrev)
            hasPair = true
            pairCount += 1
        } else if isCut {
            pairCount = 0
        }
        enc.endEncoding()
    }

    private func estimate(_ enc: MTLComputeCommandEncoder, from x: Slot, to y: Slot, f: Fields, usePrev: Bool) {
        let tmp = f.coarse; f.coarse = f.coarsePrev; f.coarsePrev = tmp
        // 1) full search at 1/16 res, 32 px grid (vector unit 1/16 px)
        var pc = MEParams(radius: searchRadius, blockSize: 2, window: 6, lambda: 0.006, usePrev: usePrev ? 1 : 0)
        enc.setTexture(x.l16, index: 0); enc.setTexture(y.l16, index: 1); enc.setTexture(f.coarse, index: 2); enc.setTexture(f.coarsePrev, index: 3)
        enc.setBytes(&pc, length: MemoryLayout<MEParams>.stride, index: 0)
        dispatch(enc, pCoarse, f.coarse.width, f.coarse.height)
        // 2) refine at 1/8
        var p8 = MEParams(radius: 1, blockSize: 4, window: 8, lambda: 0, parentScale: 2, parentDiv: 1, ownPenalty: 0.03)
        enc.setTexture(x.l8, index: 0); enc.setTexture(y.l8, index: 1); enc.setTexture(f.coarse, index: 2); enc.setTexture(f.ref8, index: 3)
        enc.setBytes(&p8, length: MemoryLayout<MEParams>.stride, index: 0)
        dispatch(enc, pRefine, f.ref8.width, f.ref8.height)
        // 3) refine at 1/4 (+ sub-pixel in fast mode), median
        var p4 = MEParams(radius: 1, blockSize: 8, window: 12, lambda: 0, parentScale: 2, parentDiv: 1,
                          subpixel: quality == .fast ? 1 : 0, ownPenalty: 0.05)
        enc.setTexture(x.l4, index: 0); enc.setTexture(y.l4, index: 1); enc.setTexture(f.ref8, index: 2); enc.setTexture(f.ref, index: 3)
        enc.setBytes(&p4, length: MemoryLayout<MEParams>.stride, index: 0)
        dispatch(enc, pRefine, f.ref.width, f.ref.height)
        enc.setTexture(f.ref, index: 0); enc.setTexture(f.med, index: 1)
        dispatch(enc, pMedian, f.med.width, f.med.height)
        guard quality == .high else { return }
        // 4) 16 px grid at 1/2 res with sub-pixel precision, median
        var p2 = MEParams(radius: 1, blockSize: 8, window: 10, lambda: 0, parentScale: 2, parentDiv: 2, subpixel: 1, ownPenalty: 0.04)
        enc.setTexture(x.l2, index: 0); enc.setTexture(y.l2, index: 1); enc.setTexture(f.med, index: 2); enc.setTexture(f.fine, index: 3)
        enc.setBytes(&p2, length: MemoryLayout<MEParams>.stride, index: 0)
        dispatch(enc, pRefine, f.fine.width, f.fine.height)
        enc.setTexture(f.fine, index: 0); enc.setTexture(f.fineMed, index: 1)
        dispatch(enc, pMedian, f.fineMed.width, f.fineMed.height)
    }

    /// Generates the moment t (0 = frame A, 1 = frame B) at source resolution into `target` (default: internal output).
    func synthesize(t: Float, mode: SynthMode, into target: MTLTexture? = nil, cmd: MTLCommandBuffer) {
        guard ready, let a = a, let b = b, let fw = fw, let bw = bw, let out = target ?? output, let sel = sel, let selW = selW,
              let enc = cmd.makeComputeCommandEncoder() else { return }
        let high = quality == .high
        let m: SynthMode = hasPair || pairIsCut ? mode : .passthrough
        var p = SynthParams(t: t, cell: high ? 16 : 32, mvScale: high ? 2 : 4, mode: m.rawValue,
                            cut: pairIsCut ? 1 : 0, sigma: 0.012, occLo: 0.05, occHi: 0.14)
        enc.setBytes(&p, length: MemoryLayout<SynthParams>.stride, index: 0)
        if m == .interpolate && !pairIsCut && t > 0.001 && t < 0.999 {
            enc.setTexture(a.l2, index: 0); enc.setTexture(b.l2, index: 1)
            enc.setTexture(high ? fw.fineMed : fw.med, index: 2); enc.setTexture(high ? bw.fineMed : bw.med, index: 3)
            enc.setTexture(sel, index: 4); enc.setTexture(selW, index: 5)
            dispatch(enc, pSelect, sel.width, sel.height)
        }
        enc.setTexture(a.rgb, index: 0); enc.setTexture(b.rgb, index: 1)
        enc.setTexture(sel, index: 2); enc.setTexture(selW, index: 3); enc.setTexture(out, index: 4)
        dispatch(enc, pCompose, out.width, out.height)
        enc.endEncoding()
    }

    /// Scales `src` aspect-fit into `out` (window / screen) with optional sharpening (0...1).
    func present(_ src: MTLTexture, to out: MTLTexture, sharpen: Float, cmd: MTLCommandBuffer) {
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        let sw = Float(src.width), sh = Float(src.height)
        let scale = min(Float(out.width) / sw, Float(out.height) / sh)
        var p = PresentParams(offset: SIMD2((Float(out.width) - sw * scale) / 2, (Float(out.height) - sh * scale) / 2),
                              scale: scale, sharpen: sharpen, srcSize: SIMD2(sw, sh))
        enc.setTexture(src, index: 0); enc.setTexture(out, index: 1)
        enc.setBytes(&p, length: MemoryLayout<PresentParams>.stride, index: 0)
        dispatch(enc, pPresent, out.width, out.height)
        enc.endEncoding()
    }
}
