import AppKit
import Metal
import CoreVideo
import ImageIO
import UniformTypeIdentifiers

/// `FrameBoost --selftest <dir>`: runs the real GPU pipeline on the demo signal and
/// writes comparison images, quality (PSNR vs. ground truth) and timings.
enum SelfTest {
    static func run(outputDir: String) -> Bool {
        var log = ""
        func say(_ s: String) { print(s); log += s + "\n" }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { say("FEHLER: kein Metal-Gerät"); return false }
        say("GPU: \(device.name)")
        let interp: Interpolator
        do { interp = try Interpolator(device: device) } catch { say("FEHLER Shader: \(error)"); return false }
        say("Shader kompiliert: OK")

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let demo = DemoSource()
        var keep: [Any] = []
        func texture(_ n: Double) -> MTLTexture {
            let pb = demo.render(frame: n)!
            var cv: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pb, nil, .bgra8Unorm, DemoSource.width, DemoSource.height, 0, &cv)
            keep.append(pb); keep.append(cv!)
            return CVMetalTextureGetTexture(cv!)!
        }
        func outTex(_ w: Int, _ h: Int) -> MTLTexture {
            let d = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
            d.usage = [.shaderRead, .shaderWrite]; d.storageMode = .private
            return device.makeTexture(descriptor: d)!
        }
        func read(_ t: MTLTexture) -> [UInt8] {
            let bpr = t.width * 4
            let buf = device.makeBuffer(length: bpr * t.height, options: .storageModeShared)!
            let cmd = interp.queue.makeCommandBuffer()!
            let b = cmd.makeBlitCommandEncoder()!
            b.copy(from: t, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(), sourceSize: MTLSize(width: t.width, height: t.height, depth: 1),
                   to: buf, destinationOffset: 0, destinationBytesPerRow: bpr, destinationBytesPerImage: bpr * t.height)
            b.endEncoding(); cmd.commit(); cmd.waitUntilCompleted()
            return Array(UnsafeBufferPointer(start: buf.contents().assumingMemoryBound(to: UInt8.self), count: bpr * t.height))
        }
        func run(_ body: (MTLCommandBuffer) -> Void) -> Double {
            let cmd = interp.queue.makeCommandBuffer()!
            body(cmd); cmd.commit(); cmd.waitUntilCompleted()
            if let e = cmd.error { say("GPU-Fehler: \(e)") }
            return (cmd.gpuEndTime - cmd.gpuStartTime) * 1000
        }
        let W = DemoSource.width, H = DemoSource.height

        // --- Quality: generate the middle frame between 30 FPS frames and compare with the true middle ---
        var psnrFB: [Double] = [], psnrBlend: [Double] = [], psnrHold: [Double] = []
        var images: [String: [UInt8]] = [:]
        for base in [10.0, 23.0, 37.0, 52.0] {
            let tA = texture(base), tB = texture(base + 1)
            _ = run { interp.ingest(tA, cmd: $0) }
            _ = run { interp.ingest(tB, cmd: $0) }
            let truth = read(texture(base + 0.5).self)
            let o1 = outTex(W, H), o2 = outTex(W, H), o3 = outTex(W, H)
            _ = run { cmd in
                interp.synthesize(t: 0.5, into: o1, mode: .interpolate, cmd: cmd)
                interp.synthesize(t: 0.5, into: o2, mode: .blend, cmd: cmd)
                interp.synthesize(t: 0.0, into: o3, mode: .interpolate, cmd: cmd)
            }
            let fb = read(o1), bl = read(o2), hold = read(o3)
            psnrFB.append(psnr(fb, truth)); psnrBlend.append(psnr(bl, truth)); psnrHold.append(psnr(hold, truth))
            if base == 10 {
                images = ["A": hold, "B": read(texture(base + 1)), "truth": truth, "fb": fb, "blend": bl]
            }
        }
        let avg = { (a: [Double]) in a.reduce(0, +) / Double(a.count) }
        say(String(format: "Qualität (PSNR, höher = besser) gegen echtes Zwischenbild:"))
        say(String(format: "  Frame wiederholen (normal 30 FPS): %.2f dB", avg(psnrHold)))
        say(String(format: "  Einfaches Überblenden:            %.2f dB", avg(psnrBlend)))
        say(String(format: "  FrameBoost Frame Generation:      %.2f dB", avg(psnrFB)))

        // --- Images ---
        if let a = images["A"], let b = images["B"], let tr = images["truth"], let fb = images["fb"], let bl = images["blend"] {
            writeGrid([(a, "Echter Frame A (30 FPS)"), (b, "Echter Frame B (30 FPS)"), (tr, "So wäre es richtig (Referenz)"),
                       (bl, "Nur überblenden: Doppelbilder"), (fb, "FrameBoost: generierter Frame"), (diff(fb, tr), "Fehler FrameBoost (schwarz = perfekt)")],
                      w: W, h: H, crop: CGRect(x: 280, y: 380, width: 720, height: 340), to: outputDir + "/vergleich.png")
            writePNG(fb, w: W, h: H, to: outputDir + "/generierter_frame.png")
        }
        // 4x filmstrip
        do {
            let tA = texture(30), tB = texture(31)
            _ = run { interp.ingest(tA, cmd: $0) }; _ = run { interp.ingest(tB, cmd: $0) }
            var tiles: [([UInt8], String)] = []
            for (i, t) in [Float(0), 0.25, 0.5, 0.75, 1].enumerated() {
                let o = outTex(W, H)
                _ = run { interp.synthesize(t: t, into: o, mode: .interpolate, cmd: $0) }
                tiles.append((read(o), i == 0 || i == 4 ? "echt (t=\(t))" : "generiert (t=\(t))"))
            }
            writeGrid(tiles, w: W, h: H, crop: CGRect(x: 200, y: 380, width: 880, height: 340), to: outputDir + "/120fps_filmstreifen.png", cols: 5)
        }

        // --- Speed at 1080p and 1440p ---
        var ok = avg(psnrFB) > avg(psnrBlend) && avg(psnrFB) > avg(psnrHold)
        for (w, h) in [(1920, 1080), (2560, 1440)] {
            let big1 = outTex(w, h), big2 = outTex(w, h)
            let s1 = texture(40), s2 = texture(41)
            // upscale demo frames to the test resolution
            _ = run { interp.ingest(s1, cmd: $0) }; _ = run { interp.ingest(s2, cmd: $0) }
            _ = run { interp.synthesize(t: 0, into: big1, mode: .interpolate, cmd: $0); interp.synthesize(t: 1, into: big2, mode: .interpolate, cmd: $0) }
            _ = run { interp.ingest(big1, cmd: $0) }; _ = run { interp.ingest(big2, cmd: $0) }
            let disp = outTex(w, h)
            var est: [Double] = [], syn: [Double] = []
            for i in 0..<60 {
                est.append(run { interp.ingest(i % 2 == 0 ? big1 : big2, cmd: $0) })
                syn.append(run { interp.synthesize(t: 0.5, into: disp, mode: .interpolate, cmd: $0) })
            }
            let e = avg(Array(est.dropFirst(5))), s = avg(Array(syn.dropFirst(5)))
            say(String(format: "%dx%d: Bewegungsanalyse %.2f ms pro echtem Frame, Bildsynthese %.2f ms pro Ausgabe-Frame", w, h, e, s))
            let budget120 = e / 4 + s   // per 1/120 s slot: analysis amortised over 4 outputs
            say(String(format: "   -> 60 FPS: %@   120 FPS: %@", e + 2 * s < 33 ? "JA" : "NEIN", budget120 < 8.3 ? "JA" : "knapp/NEIN"))
            if w == 1920 && e + 2 * s > 33 { ok = false }
        }
        say(ok ? "ERGEBNIS: BESTANDEN" : "ERGEBNIS: NICHT BESTANDEN")
        try? log.write(toFile: outputDir + "/ergebnis.txt", atomically: true, encoding: .utf8)
        return ok
    }

    static func psnr(_ a: [UInt8], _ b: [UInt8]) -> Double {
        var se = 0.0, n = 0
        var i = 0
        while i < min(a.count, b.count) {
            for c in 0..<3 { let d = Double(a[i + c]) - Double(b[i + c]); se += d * d }
            n += 3; i += 4
        }
        let mse = se / Double(max(n, 1))
        return mse == 0 ? 99 : 10 * log10(255 * 255 / mse)
    }

    static func diff(_ a: [UInt8], _ b: [UInt8]) -> [UInt8] {
        var o = [UInt8](repeating: 255, count: a.count)
        var i = 0
        while i < a.count {
            for c in 0..<3 { o[i + c] = UInt8(min(255, abs(Int(a[i + c]) - Int(b[i + c])) * 3)) }
            i += 4
        }
        return o
    }

    static func cgImage(_ px: [UInt8], w: Int, h: Int) -> CGImage {
        let data = Data(px.enumerated().map { $0.offset % 4 == 3 ? 255 : $0.element })
        let prov = CGDataProvider(data: data as CFData)!
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func save(_ img: CGImage, to path: String) {
        guard let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dst, img, nil); CGImageDestinationFinalize(dst)
    }

    static func writePNG(_ px: [UInt8], w: Int, h: Int, to path: String) { save(cgImage(px, w: w, h: h), to: path) }

    static func writeGrid(_ tiles: [([UInt8], String)], w: Int, h: Int, crop: CGRect, to path: String, cols: Int = 3) {
        let tw = Int(crop.width), th = Int(crop.height), label = 44
        let rows = (tiles.count + cols - 1) / cols
        let W = cols * tw + (cols + 1) * 8, H = rows * (th + label) + (rows + 1) * 8
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        for (i, (px, text)) in tiles.enumerated() {
            let c = i % cols, r = i / cols
            let x = 8 + c * (tw + 8)
            let yTop = H - 8 - r * (th + label + 8)       // CG origin is bottom-left
            if let sub = cgImage(px, w: w, h: h).cropping(to: crop) {
                ctx.draw(sub, in: CGRect(x: x, y: yTop - label - th, width: tw, height: th))
            }
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.white]
            (text as NSString).draw(at: NSPoint(x: x + 6, y: yTop - label + 10), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        if let img = ctx.makeImage() { save(img, to: path) }
    }
}

/// App icon renderer (used by the build script).
enum IconMaker {
    static func write(to path: String) {
        let S = 1024
        let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let r = CGRect(x: 100, y: 100, width: 824, height: 824)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: 185, cornerHeight: 185, transform: nil)); ctx.clip()
        let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [
            CGColor(red: 0.95, green: 0.18, blue: 0.45, alpha: 1), CGColor(red: 0.35, green: 0.12, blue: 0.75, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(g, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
        // three "frames" -> motion
        for (i, a) in [(0, 0.35), (1, 0.6), (2, 1.0)] {
            ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: CGFloat(a)))
            let x = 230 + CGFloat(i) * 150
            ctx.addPath(CGPath(roundedRect: CGRect(x: x, y: 330, width: 260, height: 360), cornerWidth: 40, cornerHeight: 40, transform: nil))
            ctx.fillPath()
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        ("60" as NSString).draw(at: NSPoint(x: 575, y: 420), withAttributes: [.font: NSFont.systemFont(ofSize: 150, weight: .black),
                                                                                .foregroundColor: NSColor(red: 0.45, green: 0.1, blue: 0.6, alpha: 1)])
        NSGraphicsContext.restoreGraphicsState()
        if let img = ctx.makeImage() { SelfTest.save(img, to: path) }
    }
}
