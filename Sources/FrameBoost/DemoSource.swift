import AppKit
import CoreVideo
import QuartzCore

/// Test signal without a capture card: a 30 FPS "game" sent inside a 60 Hz signal,
/// exactly like a PS5 running GTA at 30 FPS (every frame is sent twice).
final class DemoSource {
    static let width = 1280, height = 720
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "demo.source", qos: .userInteractive)
    private var tick = 0
    private var pool: CVPixelBufferPool?
    private var current: CVPixelBuffer?

    init() {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: DemoSource.width,
            kCVPixelBufferHeightKey as String: DemoSource.height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
    }

    func start(store: FrameStore) {
        stop(); tick = 0
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now(), repeating: .nanoseconds(16_666_667), leeway: .microseconds(500))
        t.setEventHandler { [weak self, weak store] in
            guard let self = self, let store = store else { return }
            if self.tick % 2 == 0 || self.current == nil { self.current = self.render(frame: Double(self.tick / 2)) }
            if let pb = self.current { store.push(pb) }
            self.tick += 1
        }
        t.resume(); timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    /// Renders game frame `frame` (fractional values give the exact in-between ground truth).
    func render(frame n: Double, fast: Bool = false) -> CVPixelBuffer? {
        var pbOut: CVPixelBuffer?
        guard let pool = pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pbOut) == kCVReturnSuccess, let pb = pbOut else { return nil }
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = DemoSource.width, h = DemoSource.height
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        // flip to top-left origin
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        DemoSource.draw(ctx, w: CGFloat(w), h: CGFloat(h), n: n, fast: fast)
        return pb
    }

    static func draw(_ ctx: CGContext, w: CGFloat, h: CGFloat, n: Double, fast: Bool = false) {
        let horizon = h / 2 + 60
        let sky = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: 0.30, green: 0.18, blue: 0.55, alpha: 1), CGColor(red: 1.0, green: 0.55, blue: 0.45, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sky, start: .zero, end: CGPoint(x: 0, y: horizon), options: [])
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.35, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: w - 280, y: horizon - 220, width: 120, height: 120))
        // parallax skyline (camera pans right)
        var rng = SplitMix(seed: 6)
        let off = CGFloat(n * (fast ? 34 : 9)).truncatingRemainder(dividingBy: 4000)
        var x: CGFloat = 0
        while x < 4000 {
            let bh = CGFloat(rng.next(120, 420)), bw = CGFloat(rng.next(50, 120))
            let col = CGColor(red: CGFloat(rng.next(40, 110)) / 255, green: CGFloat(rng.next(40, 110)) / 255, blue: CGFloat(rng.next(60, 130)) / 255, alpha: 1)
            for rep in [CGFloat(0), 4000] {
                let xx = x - off + rep
                if xx > -bw && xx < w {
                    ctx.setFillColor(col); ctx.fill(CGRect(x: xx, y: horizon - bh, width: bw, height: bh))
                    ctx.setFillColor(CGColor(red: 1, green: 0.9, blue: 0.5, alpha: 1))
                    var wy = horizon - bh + 10
                    while wy < horizon - 12 {
                        var wx = xx + 8
                        while wx < xx + bw - 12 { ctx.fill(CGRect(x: wx, y: wy, width: 6, height: 10)); wx += 16 }
                        wy += 22
                    }
                }
            }
            x += 90
        }
        // road
        ctx.setFillColor(CGColor(gray: 0.24, alpha: 1)); ctx.fill(CGRect(x: 0, y: horizon, width: w, height: h - horizon))
        // asphalt texture (scrolls with the road)
        var grit = SplitMix(seed: 99)
        let roadOff = CGFloat(n * 24).truncatingRemainder(dividingBy: 1600)
        for _ in 0..<420 {
            let gx = CGFloat(grit.next(0, 1600)), gy = horizon + 8 + CGFloat(grit.next(0, Int(h - horizon) - 16))
            let shade = CGFloat(grit.next(15, 40)) / 100
            ctx.setFillColor(CGColor(gray: shade, alpha: 1))
            for rep in [CGFloat(0), 1600] {
                let xx = gx - roadOff + rep
                if xx > -8 && xx < w { ctx.fill(CGRect(x: xx, y: gy, width: 5, height: 3)) }
            }
        }
        ctx.setFillColor(CGColor(gray: 0.9, alpha: 1))
        let dash = CGFloat(n * 24).truncatingRemainder(dividingBy: 120)
        var i: CGFloat = -1
        while i * 120 < w + 120 { ctx.fill(CGRect(x: i * 120 - dash, y: h - 150, width: 60, height: 10)); i += 1 }
        // car
        let cx = w / 2 + (fast ? 380 : 250) * CGFloat(sin(n / (fast ? 9 : 25)))
        ctx.setFillColor(CGColor(red: 0.86, green: 0.16, blue: 0.16, alpha: 1)); ctx.fill(CGRect(x: cx - 90, y: h - 230, width: 180, height: 60))
        ctx.setFillColor(CGColor(red: 0.78, green: 0.24, blue: 0.24, alpha: 1)); ctx.fill(CGRect(x: cx - 50, y: h - 270, width: 100, height: 40))
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1))
        for dx: CGFloat in [-55, 55] { ctx.fillEllipse(in: CGRect(x: cx + dx - 22, y: h - 187, width: 44, height: 44)) }
        // static HUD element (like the GTA minimap) - must stay sharp
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.6)); ctx.fill(CGRect(x: 30, y: h - 200, width: 170, height: 170))
        ctx.setStrokeColor(CGColor(red: 0.3, green: 1, blue: 0.5, alpha: 1)); ctx.setLineWidth(3); ctx.stroke(CGRect(x: 30, y: h - 200, width: 170, height: 170))
    }
}

struct SplitMix {
    var s: UInt64
    init(seed: UInt64) { s = seed }
    mutating func next(_ lo: Int, _ hi: Int) -> Int {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        z ^= z >> 31
        return lo + Int(z % UInt64(hi - lo))
    }
}
