import Metal
import simd

struct MEParams { var radius: Int32; var blockSize: Int32; var window: Int32; var lambda: Float }
struct SynthParams {
    var t: Float; var scale: Float; var offset: SIMD2<Float>
    var srcSize: SIMD2<Float>; var cell: Float; var mvScale: Float
    var mode: Int32; var pad0: Int32 = 0; var pad1: Int32 = 0; var pad2: Int32 = 0
}

enum SynthMode: Int32 { case passthrough = 0, interpolate = 1, blend = 2 }

/// GPU frame generation: motion estimation between the last two source frames
/// and motion compensated synthesis of any in-between moment t.
final class Interpolator {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let pLuma, pDown, pCoarse, pRefine, pMedian, pSynth: MTLComputePipelineState

    private final class Slot {
        let rgb, l4, l8: MTLTexture
        init(_ rgb: MTLTexture, _ l4: MTLTexture, _ l8: MTLTexture) { self.rgb = rgb; self.l4 = l4; self.l8 = l8 }
    }
    private var a: Slot?, b: Slot?
    private var coarse01, coarse10, ref01, ref10, f01, f10: MTLTexture?
    private(set) var width = 0, height = 0
    private(set) var hasPair = false
    var frameA: MTLTexture? { a?.rgb }
    var frameB: MTLTexture? { b?.rgb }

    // block grid: one vector per 32x32 full-res pixels
    let cell: Float = 32

    init(device: MTLDevice) throws {
        self.device = device
        guard let q = device.makeCommandQueue() else { throw NSError(domain: "FrameBoost", code: 1) }
        queue = q
        let lib = try device.makeLibrary(source: frameBoostShaderSource, options: nil)
        func pipe(_ n: String) throws -> MTLComputePipelineState {
            guard let f = lib.makeFunction(name: n) else { throw NSError(domain: "FrameBoost", code: 2, userInfo: [NSLocalizedDescriptionKey: "missing \(n)"]) }
            return try device.makeComputePipelineState(function: f)
        }
        pLuma = try pipe("luma_down4"); pDown = try pipe("down2"); pCoarse = try pipe("me_coarse")
        pRefine = try pipe("me_refine"); pMedian = try pipe("median3"); pSynth = try pipe("synthesize")
    }

    private func tex(_ w: Int, _ h: Int, _ f: MTLPixelFormat) -> MTLTexture {
        let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: f, width: max(w, 1), height: max(h, 1), mipmapped: false)
        d.usage = [.shaderRead, .shaderWrite]
        d.storageMode = .private
        return device.makeTexture(descriptor: d)!
    }

    private func makeSlot() -> Slot {
        Slot(tex(width, height, .bgra8Unorm), tex((width + 3) / 4, (height + 3) / 4, .r32Float), tex((width + 7) / 8, (height + 7) / 8, .r32Float))
    }

    private func setup(_ w: Int, _ h: Int) {
        width = w; height = h
        a = makeSlot(); b = makeSlot(); hasPair = false; firstDone = false
        let gw = (w + 31) / 32, gh = (h + 31) / 32
        coarse01 = tex(gw, gh, .rg16Float); coarse10 = tex(gw, gh, .rg16Float)
        ref01 = tex(gw, gh, .rg16Float); ref10 = tex(gw, gh, .rg16Float)
        f01 = tex(gw, gh, .rg16Float); f10 = tex(gw, gh, .rg16Float)
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
        enc.setComputePipelineState(p)
        let tw = p.threadExecutionWidth, th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: min(th, 8), depth: 1))
    }

    /// Push a new source frame (BGRA texture). Encodes copy + motion estimation into `cmd`.
    func ingest(_ src: MTLTexture, cmd: MTLCommandBuffer) {
        if src.width != width || src.height != height || a == nil { setup(src.width, src.height) }
        let hadFrame = firstDone
        swap(&a, &b)
        guard let a = a, let b = b else { return }
        // copy new frame (the capture buffer is recycled by the system)
        if src.pixelFormat == .bgra8Unorm, let blit = cmd.makeBlitCommandEncoder() {
            blit.copy(from: src, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: b.rgb, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
        }
        guard let enc = cmd.makeComputeCommandEncoder() else { return }
        enc.setTexture(b.rgb, index: 0); enc.setTexture(b.l4, index: 1)
        dispatch(enc, pLuma, b.l4.width, b.l4.height)
        enc.setTexture(b.l4, index: 0); enc.setTexture(b.l8, index: 1)
        dispatch(enc, pDown, b.l8.width, b.l8.height)
        firstDone = true
        if hadFrame {
            estimate(enc, from: a, to: b, coarse: coarse01!, ref: ref01!, out: f01!)
            estimate(enc, from: b, to: a, coarse: coarse10!, ref: ref10!, out: f10!)
            hasPair = true
        }
        enc.endEncoding()
    }
    private var firstDone = false

    var searchRadius: Int32 = 8   // in 1/8 px  -> +-64 px full res per source frame

    private func estimate(_ enc: MTLComputeCommandEncoder, from x: Slot, to y: Slot, coarse: MTLTexture, ref: MTLTexture, out: MTLTexture) {
        var pc = MEParams(radius: searchRadius, blockSize: 4, window: 8, lambda: 0.004)
        enc.setTexture(x.l8, index: 0); enc.setTexture(y.l8, index: 1); enc.setTexture(coarse, index: 2)
        enc.setBytes(&pc, length: MemoryLayout<MEParams>.stride, index: 0)
        dispatch(enc, pCoarse, coarse.width, coarse.height)
        var pr = MEParams(radius: 2, blockSize: 8, window: 12, lambda: 0)
        enc.setTexture(x.l4, index: 0); enc.setTexture(y.l4, index: 1); enc.setTexture(coarse, index: 2); enc.setTexture(ref, index: 3)
        enc.setBytes(&pr, length: MemoryLayout<MEParams>.stride, index: 0)
        dispatch(enc, pRefine, ref.width, ref.height)
        enc.setTexture(ref, index: 0); enc.setTexture(out, index: 1)
        dispatch(enc, pMedian, out.width, out.height)
    }

    /// Render the moment t (0 = frame A, 1 = frame B) aspect-fit into `out`.
    func synthesize(t: Float, into out: MTLTexture, mode: SynthMode, cmd: MTLCommandBuffer) {
        guard let a = a, let b = b, firstDone, let enc = cmd.makeComputeCommandEncoder() else { return }
        let sw = Float(width), sh = Float(height)
        let scale = min(Float(out.width) / sw, Float(out.height) / sh)
        let off = SIMD2<Float>((Float(out.width) - sw * scale) / 2, (Float(out.height) - sh * scale) / 2)
        let m: SynthMode = hasPair ? mode : .passthrough
        var p = SynthParams(t: t, scale: scale, offset: off, srcSize: SIMD2(sw, sh), cell: cell, mvScale: 4, mode: m.rawValue)
        enc.setTexture(a.rgb, index: 0); enc.setTexture(b.rgb, index: 1)
        enc.setTexture(f01, index: 2); enc.setTexture(f10, index: 3); enc.setTexture(out, index: 4)
        enc.setBytes(&p, length: MemoryLayout<SynthParams>.stride, index: 0)
        dispatch(enc, pSynth, out.width, out.height)
        enc.endEncoding()
    }
}
