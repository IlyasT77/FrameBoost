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
        // no App Nap / timer coalescing during the test (the app does the same while playing)
        let activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Selbsttest")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { say("FEHLER: kein Metal-Gerät"); return false }
        say("GPU: \(device.name)")
        let interp: Interpolator
        do { interp = try Interpolator(device: device) } catch { say("FEHLER Shader: \(error)"); return false }
        say("Shader kompiliert: OK")

        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let demo = DemoSource()
        var keep: [Any] = []
        func texture(_ n: Double, fast: Bool = false) -> MTLTexture {
            let pb = demo.render(frame: n, fast: fast)!
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
        let avg = { (a: [Double]) in a.reduce(0, +) / Double(max(a.count, 1)) }
        let median = { (a: [Double]) -> Double in let s = a.sorted(); return s.isEmpty ? 0 : s[s.count / 2] }
        var ok = true

        // --- Quality: generate in-between frames and compare with the true in-between images ---
        var gridImages: [String: [UInt8]] = [:]
        say("Qualität (PSNR in dB, höher = besser) gegen das echte Zwischenbild:")
        for (fast, name) in [(false, "normal"), (true, "schnelle Bewegung")] {
            for q in GenQuality.allCases {
                interp.quality = q; interp.reset()
                var pHold: [Double] = [], pBlend: [Double] = [], pFB: [Double] = []
                for base in [10.0, 23.0, 37.0, 52.0] {
                    // a third earlier frame first, so the temporal predictor is warmed up like in real use
                    _ = run { interp.ingest(texture(base - 1, fast: fast), cmd: $0) }
                    _ = run { interp.ingest(texture(base, fast: fast), cmd: $0) }
                    _ = run { interp.ingest(texture(base + 1, fast: fast), cmd: $0) }
                    for t in [Float(0.25), 0.5, 0.75] {
                        let truth = read(texture(base + Double(t), fast: fast))
                        let o1 = outTex(W, H), o2 = outTex(W, H), o3 = outTex(W, H)
                        _ = run { cmd in
                            interp.synthesize(t: t, mode: .interpolate, into: o1, cmd: cmd)
                            interp.synthesize(t: t, mode: .blend, into: o2, cmd: cmd)
                            interp.synthesize(t: t < 0.5 ? 0 : 1, mode: .interpolate, into: o3, cmd: cmd)
                        }
                        let fb = read(o1), bl = read(o2), hold = read(o3)
                        pFB.append(psnr(fb, truth)); pBlend.append(psnr(bl, truth)); pHold.append(psnr(hold, truth))
                        if base == 10 && t == 0.5 && q == .high {
                            gridImages[name + "A"] = read(texture(base, fast: fast)); gridImages[name + "B"] = read(texture(base + 1, fast: fast))
                            gridImages[name + "truth"] = truth; gridImages[name + "fb"] = fb; gridImages[name + "blend"] = bl
                        }
                    }
                }
                say(String(format: "  [%@ | %@]  Frame wiederholen %.1f · Überblenden %.1f · FrameBoost %.1f",
                           name, q.rawValue, avg(pHold), avg(pBlend), avg(pFB)))
                if avg(pFB) < avg(pBlend) + 3 || (!fast && avg(pFB) < 32) { ok = false; say("    -> zu schwach!") }
            }
        }
        interp.quality = .high

        // --- Images ---
        for (name, file) in [("normal", "vergleich.png"), ("schnelle Bewegung", "vergleich_schnell.png")] {
            if let a = gridImages[name + "A"], let b = gridImages[name + "B"], let tr = gridImages[name + "truth"],
               let fb = gridImages[name + "fb"], let bl = gridImages[name + "blend"] {
                writeGrid([(a, "Echter Frame A (30 FPS)"), (b, "Echter Frame B (30 FPS)"), (tr, "So wäre es richtig (Referenz)"),
                           (bl, "Nur überblenden: Doppelbilder"), (fb, "FrameBoost: generierter Frame"), (diff(fb, tr), "Fehler FrameBoost (schwarz = perfekt)")],
                          w: W, h: H, crop: CGRect(x: 280, y: 380, width: 720, height: 340), to: outputDir + "/" + file)
                if name == "normal" { writePNG(fb, w: W, h: H, to: outputDir + "/generierter_frame.png") }
            }
        }
        // 4x filmstrip
        do {
            interp.reset()
            _ = run { interp.ingest(texture(29), cmd: $0) }; _ = run { interp.ingest(texture(30), cmd: $0) }; _ = run { interp.ingest(texture(31), cmd: $0) }
            var tiles: [([UInt8], String)] = []
            for (i, t) in [Float(0), 0.25, 0.5, 0.75, 1].enumerated() {
                let o = outTex(W, H)
                _ = run { interp.synthesize(t: t, mode: .interpolate, into: o, cmd: $0) }
                tiles.append((read(o), i == 0 || i == 4 ? "echt" : "generiert \(i)/4"))
            }
            writeGrid(tiles, w: W, h: H, crop: CGRect(x: 200, y: 380, width: 880, height: 340), to: outputDir + "/120fps_filmstreifen.png", cols: 5)
        }

        // --- Scene cut: must not morph between unrelated images ---
        do {
            interp.reset()
            let store = FrameStore()
            let p1 = demo.render(frame: 5)!, p2 = demo.render(frame: 5, fast: true)!
            let black = demo.render(frame: 0)!
            CVPixelBufferLockBaseAddress(black, []); memset(CVPixelBufferGetBaseAddress(black), 0, CVPixelBufferGetDataSize(black)); CVPixelBufferUnlockBaseAddress(black, [])
            store.push(p1); store.push(p2); store.push(black)
            let cut = store.take(after: 0)?.isCut ?? false
            say("Szenenwechsel-Erkennung: \(cut ? "OK" : "FEHLER")")
            if !cut { ok = false }
            let s2 = FrameStore()
            s2.push(p1, time: 1.0); s2.push(p1, time: 1.016); s2.push(p1, time: 1.033)
            let dupOK = s2.take(after: 0)?.seq == 1
            say("Doppelte Frames entfernen: \(dupOK ? "OK" : "FEHLER")")
            if !dupOK { ok = false }
        }

        // --- Sound buffer: simulated capture card (10 ms chunks) + sound output (512-frame callbacks,
        //     clock 0.1 % faster), delay 60 ms then 120 ms. Every sample carries its own number, so the
        //     exact delay of each sample is measured.
        do {
            let rate = 48000.0, C = 480, F = 512
            var line = DelayLine(channels: 2, capacity: 96000)
            line.tolerance = max(Int(0.02 * rate), 1536)
            line.target = Int(0.06 * rate)
            var arrival: [Double] = []
            var events: [(Double, Int)] = []           // (time, 0 = write chunk / 1 = read callback)
            var k = 0; while Double(k + 1) * Double(C) / rate < 3 { events.append((Double(k + 1) * Double(C) / rate + Double(k % 3) * 0.001, 0)); k += 1 }
            var m = 0; while Double(m) * Double(F) / rate * 0.999 < 3 { events.append((Double(m) * Double(F) / rate * 0.999, 1)); m += 1 }
            events.sort { $0.0 < $1.0 }
            var lat60: [Double] = [], lat120: [Double] = []
            var written = 0
            let l = UnsafeMutablePointer<Float>.allocate(capacity: F), r = UnsafeMutablePointer<Float>.allocate(capacity: F)
            for (tm, kind) in events {
                if tm > 1.0 { line.target = Int(0.12 * rate) }
                if kind == 0 {
                    var chunk = [Float](repeating: 0, count: C * 2)
                    for j in 0..<C { chunk[2 * j] = Float(written + j + 1); chunk[2 * j + 1] = chunk[2 * j]; arrival.append(tm) }
                    chunk.withUnsafeBufferPointer { line.write($0.baseAddress!, frames: C) }
                    written += C
                } else {
                    line.read(frames: F, into: [l, r])
                    for i in 0..<F where l[i] > 0 {
                        let d = tm + Double(i) / rate - arrival[Int(l[i]) - 1]
                        if tm > 0.3 && tm < 1.0 { lat60.append(d) } else if tm > 1.3 { lat120.append(d) }
                    }
                }
            }
            l.deallocate(); r.deallocate()
            let m60 = avg(lat60) * 1000, m120 = avg(lat120) * 1000
            let spread = max((lat60.max() ?? 0) - (lat60.min() ?? 0), (lat120.max() ?? 0) - (lat120.min() ?? 0)) * 1000
            let good = abs(m60 - 60) < 10 && abs(m120 - 120) < 10 && spread < 30
            say(String(format: "Ton-Puffer (Bild/Ton synchron): Ziel 60 ms -> %.1f ms, Ziel 120 ms -> %.1f ms, Schwankung %.1f ms %@",
                       m60, m120, spread, good ? "OK" : "FEHLER"))
            if !good { ok = false }

            // real sound output: start, play 0.4 s of (silent) sound in real time
            let player = AudioDelayPlayer()
            let gen = SyntheticAudio()
            player.volume = 0
            player.delay = 0.08
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < 0.4 {
                if let sb = gen.nextRealtime() { player.enqueue(sb) }
                Thread.sleep(forTimeInterval: 0.01)
            }
            say("  Audio-Ausgabe: " + (player.failed ? "FEHLER" : "OK") + " · " + player.debugInfo)
            player.stop()
        }

        // --- Speed ---
        say("Geschwindigkeit:")
        for (w, h) in [(1920, 1080), (2560, 1440), (3840, 2160)] {
            for q in GenQuality.allCases {
                interp.quality = q; interp.reset()
                let big1 = outTex(w, h), big2 = outTex(w, h), big3 = outTex(w, h)
                _ = run { cmd in
                    interp.present(texture(40), to: big1, sharpen: 0, cmd: cmd)
                    interp.present(texture(41), to: big2, sharpen: 0, cmd: cmd)
                    interp.present(texture(42), to: big3, sharpen: 0, cmd: cmd)
                }
                _ = run { interp.ingest(big1, cmd: $0) }; _ = run { interp.ingest(big2, cmd: $0) }
                let screen = outTex(1920, 1080)   // 1080p monitor (1:1 for 1080p sources)
                let direct = (w, h) == (1920, 1080)
                var est: [Double] = [], syn: [Double] = [], pre: [Double] = []
                for i in 0..<40 {
                    est.append(run { interp.ingest([big3, big1, big2][i % 3], cmd: $0) })
                    if direct {
                        syn.append(run { interp.synthesize(t: 0.5, mode: .interpolate, into: screen, cmd: $0) }); pre.append(0)
                    } else {
                        syn.append(run { interp.synthesize(t: 0.5, mode: .interpolate, cmd: $0) })
                        pre.append(run { interp.present(interp.output!, to: screen, sharpen: 0.3, cmd: $0) })
                    }
                }
                let e = median(est), s = median(syn) + median(pre)
                // per real frame (33 ms at 30 FPS): one analysis + N output images
                let fps60 = e + 2 * s < 31, fps120 = e + 4 * s < 31, fps180 = e + 6 * s < 31
                say(String(format: "  %dx%d %@: Analyse %.2f ms/Frame, Zwischenbild %.2f ms + Anzeige %.2f ms -> 60 FPS %@, 120 FPS %@, 180 FPS %@",
                           w, h, interp.effectiveQuality == .high ? "Hoch" : (q == .high ? "Hoch→Schnell" : "Schnell"), e, median(syn), median(pre),
                           fps60 ? "JA" : "NEIN", fps120 ? "JA" : "NEIN", fps180 ? "JA" : "NEIN"))
                if w <= 2560 && !fps60 { ok = false }
            }
        }
        interp.quality = .high
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
        var d = px
        var i = 3
        while i < d.count { d[i] = 255; i += 4 }
        let prov = CGDataProvider(data: Data(d) as CFData)!
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

/// Background picture of the installer window (FrameBoost  ──▶  Programme).
/// Finder positions: app icon at (165, 200), Applications at (495, 200); picture is 660x440 so it always fills the window.
enum DMGBackground {
    static func write(to path: String, scale: Int) {
        let W = 660, H = 440, s = CGFloat(scale)
        let ctx = CGContext(data: nil, width: W * scale, height: H * scale, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)
        // dark gaming gradient
        let bg = CGGradient(colorsSpace: sRGB, colors: [CGColor(red: 0.16, green: 0.08, blue: 0.27, alpha: 1),
                                                        CGColor(red: 0.05, green: 0.06, blue: 0.09, alpha: 1)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: CGFloat(H)), end: CGPoint(x: 0, y: 0), options: [])
        // soft glows behind the two icons (CG y is bottom-up: Finder y 200 -> 200)
        let iconY: CGFloat = CGFloat(H) - 200
        func glow(_ x: CGFloat, _ c: CGColor) {
            let g = CGGradient(colorsSpace: sRGB, colors: [c, c.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
            ctx.drawRadialGradient(g, startCenter: CGPoint(x: x, y: iconY), startRadius: 0, endCenter: CGPoint(x: x, y: iconY), endRadius: 120, options: [])
        }
        glow(165, CGColor(red: 1, green: 0.25, blue: 0.55, alpha: 0.45))
        glow(495, CGColor(red: 0.45, green: 0.35, blue: 1, alpha: 0.35))
        // mid-grey pills behind Finder's icon labels: readable with black (light mode) and white (dark mode) text
        ctx.setFillColor(CGColor(gray: 0.47, alpha: 1))
        for x: CGFloat in [165, 495] {
            ctx.addPath(CGPath(roundedRect: CGRect(x: x - 62, y: CGFloat(H) - 274 - 11, width: 124, height: 22),
                               cornerWidth: 11, cornerHeight: 11, transform: nil))
            ctx.fillPath()
        }
        // arrow
        ctx.setLineCap(.round)
        ctx.setLineWidth(9)
        ctx.setStrokeColor(CGColor(red: 1, green: 0.35, blue: 0.6, alpha: 0.95))
        ctx.move(to: CGPoint(x: 258, y: iconY)); ctx.addLine(to: CGPoint(x: 392, y: iconY)); ctx.strokePath()
        ctx.setFillColor(CGColor(red: 1, green: 0.35, blue: 0.6, alpha: 0.95))
        ctx.move(to: CGPoint(x: 410, y: iconY)); ctx.addLine(to: CGPoint(x: 382, y: iconY + 20)); ctx.addLine(to: CGPoint(x: 382, y: iconY - 20))
        ctx.closePath(); ctx.fillPath()
        // texts
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        func text(_ str: String, _ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor, y: CGFloat) {
            let p = NSMutableParagraphStyle(); p.alignment = .center
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color, .paragraphStyle: p]
            (str as NSString).draw(in: NSRect(x: 0, y: y, width: CGFloat(W), height: size * 1.5), withAttributes: a)
        }
        text("FrameBoost", 30, .heavy, NSColor(red: 1, green: 0.4, blue: 0.65, alpha: 1), y: CGFloat(H) - 62)
        text("PS5 Frame Generation · 30 → 60 / 120 FPS", 13, .medium, NSColor(white: 0.75, alpha: 1), y: CGFloat(H) - 84)
        text("Zum Installieren FrameBoost auf „Programme“ ziehen", 15, .semibold, .white, y: CGFloat(H) - 318)
        text("Erster Start: Rechtsklick auf FrameBoost → Öffnen", 12, .regular, NSColor(white: 0.65, alpha: 1), y: CGFloat(H) - 344)
        NSGraphicsContext.restoreGraphicsState()
        if let img = ctx.makeImage() { SelfTest.save(img, to: path) }
    }
}
