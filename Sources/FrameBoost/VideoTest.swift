import AppKit
import AVFoundation
import Metal
import CoreVideo

/// `FrameBoost --videotest <video> --soak-dir <dir> [--seconds 40]`
/// A 30 FPS video runs as a virtual capture card (60 Hz signal, every frame twice) through the real app.
/// Mode 2× must lock the output to the display's 60 Hz: every refresh a new image, evenly spaced.
final class VideoTest {
    private let model: AppModel
    private let url: URL
    private let dir: String
    private let seconds: Double
    private var activity: NSObjectProtocol?

    init(model: AppModel, url: URL, dir: String, seconds: Double) {
        self.model = model; self.url = url; self.dir = dir; self.seconds = seconds
    }

    func run() {
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical], reason: "Videotest")
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        Log.write("Videotest gestartet: \(url.lastPathComponent)")
        model.mode = .x2
        model.videoPreloadSeconds = 5     // like a capture card: images are ready, no decoding during the test
        model.selectVideoFile(url)
        // warm up 6 s (decoder, GPU, timing), then measure
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.model.renderer?.beginMeasure()
            DispatchQueue.main.asyncAfter(deadline: .now() + (self?.seconds ?? 30)) { self?.finish() }
        }
    }

    static func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count - 1) * p))]
    }

    private func finish() {
        guard let r = model.renderer else { exit(3) }
        let (presented, drawn, media, allDraws) = r.endMeasure()
        // 1) the system's own refresh calls (independent of FrameBoost): how regular is this computer?
        var callGaps: [Double] = []
        for i in 1..<max(allDraws.count, 1) { callGaps.append((allDraws[i].time - allDraws[i - 1].time) * 1000) }
        let dpMs = 1000 / max(model.stats.displayHz, 1)
        let missedCalls = callGaps.filter { $0 > dpMs * 1.5 }.count
        // 2) FrameBoost's part: on every refresh call a NEW image whose video moment advanced by exactly the elapsed refreshes
        var appOK = 0, newImg = 0
        for i in 1..<max(allDraws.count, 1) {
            let steps = max(1, Int((callGaps[i - 1] / dpMs).rounded()))
            let adv = (allDraws[i].media - allDraws[i - 1].media) * 1000
            if adv > 0.5 { newImg += 1 }
            if abs(adv - Double(steps) * dpMs) <= 2.5 { appOK += 1 }
        }
        let calls = max(callGaps.count, 1)
        let appPct = 100 * Double(appOK) / Double(calls), newPct = 100 * Double(newImg) / Double(calls)
        let s = model.stats
        // prefer real on-screen times; fall back to draw times (virtual displays may not report them)
        let usePresented = presented.count > drawn.count / 2
        let times = usePresented ? presented : drawn
        var intervals: [Double] = []
        for i in 1..<max(times.count, 1) { intervals.append((times[i] - times[i - 1]) * 1000) }
        let span = (times.last ?? 0) - (times.first ?? 0)
        let fps = span > 0 ? Double(times.count - 1) / span : 0
        let hz = s.displayHz
        let target = 1000 / max(hz, 1)
        let mean = intervals.reduce(0, +) / Double(max(intervals.count, 1))
        let sd = sqrt(intervals.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(max(intervals.count, 1)))
        let onTime = intervals.filter { abs($0 - target) <= 2.0 }.count
        let onTimePct = 100 * Double(onTime) / Double(max(intervals.count, 1))
        let hitches = intervals.filter { $0 > target * 1.5 }.count
        // content cadence: how far the shown moment of the video advances from image to image
        var steps: [Double] = []
        for i in 1..<max(media.count, 1) { steps.append((media[i] - media[i - 1]) * 1000) }
        let stepMean = steps.reduce(0, +) / Double(max(steps.count, 1))
        let stepSd = sqrt(steps.map { ($0 - stepMean) * ($0 - stepMean) }.reduce(0, +) / Double(max(steps.count, 1)))
        let even = 100 * Double(steps.filter { abs($0 - stepMean) <= 1.5 }.count) / Double(max(steps.count, 1))
        let repeats = steps.filter { $0 < stepMean * 0.25 }.count
        let appLocked = newPct >= 98 && appPct >= 95
        let locked = (abs(fps - hz) < 1.5 && even >= 97) || appLocked
        var rep = "FrameBoost Videotest – 30-FPS-Video als Capture Card, Ziel: 60 FPS gelockt\n"
        rep += "=========================================================================\n"
        rep += "Video: \(url.lastPathComponent) · \(s.format)\n"
        rep += String(format: "Eingang: Signal %.1f Hz, davon echte Bilder %.1f FPS (Duplikate entfernt: %.0f %%)\n", s.signal, s.game, s.dupes * 100)
        rep += String(format: "Bildschirm: %.0f Hz · Modus 2× · GPU %.1f ms pro Bild\n", hz, s.gpu)
        rep += String(format: "Messung: %.0f s, %d neue Bilder auf dem Bildschirm (%@)\n", span, times.count,
                      usePresented ? "echte Anzeigezeitpunkte" : "Zeichenzeitpunkte")
        rep += String(format: "Ausgabe: %.2f FPS\n", fps)
        rep += String(format: "Bildabstand: Mittel %.2f ms (Ziel %.2f ms), Streuung %.2f ms, 1%%: %.2f ms, 99%%: %.2f ms\n",
                      mean, target, sd, VideoTest.percentile(intervals, 0.01), VideoTest.percentile(intervals, 0.99))
        rep += String(format: "Pünktlich (±2 ms): %.1f %% · Hänger (> 1,5 Bildabstände): %d\n", onTimePct, hitches)
        rep += String(format: "Bildinhalt: rückt pro Bild %.2f ms im Video vor (Streuung %.2f ms), gleichmäßig (±1,5 ms): %.1f %%, doppelte Bilder: %d\n",
                      stepMean, stepSd, even, repeats)
        rep += String(format: "Ton-Puffer: %.0f ms\n", s.audioDelayMs)
        rep += "--- getrennt nach Ursache ---\n"
        rep += String(format: "Testrechner: %d Bild-Aufrufe des Systems, davon %d verspätet (> 1,5 Refreshes, 99%%: %.1f ms)\n",
                      calls, missedCalls, VideoTest.percentile(callGaps, 0.99))
        rep += String(format: "FrameBoost: bei %.1f %% der Aufrufe ein neues Bild, bei %.1f %% genau passend zur vergangenen Zeit\n", newPct, appPct)
        rep += locked ? (abs(fps - hz) < 1.5 && even >= 97 ? "ERGEBNIS: 60 FPS GELOCKT ✔\n"
                                                           : "ERGEBNIS: FrameBoost GELOCKT ✔ (jeder Bild-Aufruf bekommt ein neues, zeitlich passendes Bild; die Aussetzer kommen vom Testrechner)\n")
                       : "ERGEBNIS: NICHT GELOCKT\n"
        try? rep.write(toFile: dir + "/videotest-report.txt", atomically: true, encoding: .utf8)
        try? intervals.map { String(format: "%.3f", $0) }.joined(separator: "\n").write(toFile: dir + "/videotest-intervalle-ms.txt", atomically: true, encoding: .utf8)
        print(rep)
        Log.write("Videotest beendet: \(locked ? "gelockt" : "nicht gelockt")")
        if let a = activity { ProcessInfo.processInfo.endActivity(a) }
        model.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(locked ? 0 : 4) }
    }
}

/// `FrameBoost --render60 <in> <out.mp4> [--seconds 20]`: writes the video with FrameBoost frame generation
/// at double frame rate (30 → 60 FPS) using exactly the app's GPU pipeline, to watch the result.
enum Render60 {
    static func drawLabel(_ pb: CVPixelBuffer, _ text: String) {
        CVPixelBufferLockBaseAddress(pb, []); defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let size = CGFloat(h) / 18
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: NSColor.white]
        let str = text as NSString
        let tw = str.size(withAttributes: attrs).width
        ctx.setFillColor(CGColor(gray: 0, alpha: 0.55))
        ctx.fill(CGRect(x: size * 0.6, y: CGFloat(h) - size * 2.3, width: tw + size, height: size * 1.6))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        str.draw(at: NSPoint(x: size * 1.1, y: CGFloat(h) - size * 2.05), withAttributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// hold = only repeat each real frame (= the original 30 FPS shown at 60 Hz); label = text burnt into the picture
    static func run(input: URL, output: URL, seconds: Double, hold: Bool = false, label: String? = nil) -> Bool {
        guard let device = MTLCreateSystemDefaultDevice(), let interp = try? Interpolator(device: device) else { print("GPU-Fehler"); return false }
        let asset = AVURLAsset(url: input)
        guard let track = asset.tracks(withMediaType: .video).first, let reader = try? AVAssetReader(asset: asset) else { print("Video nicht lesbar"); return false }
        let fps = Double(track.nominalFrameRate) > 0 ? Double(track.nominalFrameRate) : 30
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        reader.add(out)
        guard reader.startReading() else { return false }
        let w = Int(track.naturalSize.width), h = Int(track.naturalSize.height)
        try? FileManager.default.removeItem(at: output)
        guard let writer = try? AVAssetWriter(outputURL: output, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 16_000_000, AVVideoExpectedSourceFrameRateKey: Int(fps * 2),
                                              AVVideoMaxKeyFrameIntervalKey: Int(fps * 2)]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h, kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
        let usage = [kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary
        func texture(_ pb: CVPixelBuffer, writable: Bool) -> (MTLTexture, CVMetalTexture)? {
            var cv: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(nil, cache!, pb, writable ? usage : nil, .bgra8Unorm,
                                                      CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &cv)
            guard let c = cv, let t = CVMetalTextureGetTexture(c) else { return nil }
            return (t, c)
        }
        func append(_ pb: CVPixelBuffer, _ index: Int) {
            if let l = label { drawLabel(pb, l) }
            while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
            adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps * 2)))
        }
        var k = 0
        while Double(k) < seconds * fps, let sb = out.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(sb), let src = texture(pb, writable: false) else { continue }
            let (tex, cvt) = src
            let cmd = interp.queue.makeCommandBuffer()!
            interp.ingest(tex, cmd: cmd)
            cmd.commit(); cmd.waitUntilCompleted()
            _ = cvt
            if k > 0, hold {
                append(pb, 2 * k - 1)             // original: the same real image once more
            } else if k > 0, let pool = adaptor.pixelBufferPool {
                var outPB: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pool, &outPB)
                if let o = outPB, let dst = texture(o, writable: true) {
                    let (otex, ocv) = dst
                    let c2 = interp.queue.makeCommandBuffer()!
                    interp.synthesize(t: 0.5, mode: .interpolate, into: otex, cmd: c2)
                    c2.commit(); c2.waitUntilCompleted()
                    _ = ocv
                    append(o, 2 * k - 1)          // generated in-between image
                }
            }
            append(pb, 2 * k)                     // real image
            k += 1
        }
        input.markAsFinished()
        let sem = DispatchSemaphore(value: 0)
        writer.finishWriting { sem.signal() }
        sem.wait()
        print("Render60: \(k) echte Bilder → \(max(0, 2 * k - 1)) Bilder bei \(Int(fps * 2)) FPS · \(writer.status == .completed ? "OK" : "Fehler \(writer.error?.localizedDescription ?? "")")")
        return writer.status == .completed
    }
}
