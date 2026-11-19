import AVFoundation
import CoreVideo
import QuartzCore

/// A video file as a virtual capture card: decoded in real time and sent like an HDMI signal at 60 Hz
/// (a 30 FPS video therefore repeats every frame twice - exactly like a PS5 running a 30 FPS game).
/// The sound track is played through the same sound buffer as a capture card. Loops at the end.
final class VideoFileSource {
    let url: URL
    private let queue = DispatchQueue(label: "video.file.source", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var asset: AVURLAsset?
    private var reader: AVAssetReader?
    private var videoOut: AVAssetReaderTrackOutput?
    private var audioOut: AVAssetReaderTrackOutput?
    private var current: CVPixelBuffer?
    private var currentPTS: Double = -1
    private var nextFrame: (CVPixelBuffer, Double)?
    private var startTime: CFTimeInterval = 0
    private var loopOffset: Double = 0
    private var audioTime: Double = 0
    private weak var store: FrameStore?
    private weak var audio: AudioDelayPlayer?
    private(set) var nominalFPS: Double = 30
    private(set) var size = CGSize.zero
    private(set) var duration: Double = 0
    private(set) var error: String?
    /// signal rate of the virtual HDMI output
    let signalHz: Double = 60

    init(url: URL) { self.url = url }

    var formatDescription: String {
        "Video \(Int(size.width))×\(Int(size.height)) · \(String(format: "%.0f", nominalFPS)) FPS → \(Int(signalHz)) Hz-Signal (\(url.lastPathComponent))"
    }

    /// Opens the file (synchronously, so errors can be shown right away).
    func open() -> Bool {
        let a = AVURLAsset(url: url)
        guard let t = a.tracks(withMediaType: .video).first else { error = "Die Datei enthält kein Video."; return false }
        nominalFPS = Double(t.nominalFrameRate) > 0 ? Double(t.nominalFrameRate) : 30
        let r = CGRect(origin: .zero, size: t.naturalSize).applying(t.preferredTransform)
        size = CGSize(width: abs(r.width), height: abs(r.height))
        duration = a.duration.seconds
        asset = a
        return makeReader()
    }

    private func makeReader() -> Bool {
        guard let a = asset, let v = a.tracks(withMediaType: .video).first else { return false }
        do {
            let r = try AVAssetReader(asset: a)
            let vo = AVAssetReaderTrackOutput(track: v, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferMetalCompatibilityKey as String: true,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]])
            vo.alwaysCopiesSampleData = false
            r.add(vo)
            var ao: AVAssetReaderTrackOutput?
            if let at = a.tracks(withMediaType: .audio).first {
                let o = AVAssetReaderTrackOutput(track: at, outputSettings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                    AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2])
                if r.canAdd(o) { r.add(o); ao = o }
            }
            guard r.startReading() else { error = r.error?.localizedDescription ?? "Video lässt sich nicht lesen."; return false }
            reader = r; videoOut = vo; audioOut = ao
            return true
        } catch {
            self.error = error.localizedDescription
            return false
        }
    }

    func start(store: FrameStore, audio: AudioDelayPlayer?) {
        queue.sync {
            self.stopOnQueue()
            self.store = store; self.audio = audio
            self.startTime = CACurrentMediaTime(); self.loopOffset = 0; self.audioTime = 0
            self.current = nil; self.currentPTS = -1; self.nextFrame = nil
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(Int(1e9 / self.signalHz)), leeway: .microseconds(300))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume(); self.timer = t
        }
    }

    func stop() { queue.sync { self.stopOnQueue() } }

    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        current = nil; nextFrame = nil
    }

    private func readNext() -> (CVPixelBuffer, Double)? {
        guard let vo = videoOut else { return nil }
        while let sb = vo.copyNextSampleBuffer() {
            if let pb = CMSampleBufferGetImageBuffer(sb) {
                return (pb, CMSampleBufferGetPresentationTimeStamp(sb).seconds + loopOffset)
            }
        }
        return nil
    }

    /// one tick of the virtual 60 Hz HDMI signal
    private func tick() {
        guard timer != nil, let store = store else { return }
        let mediaTime = CACurrentMediaTime() - startTime
        // advance to the newest frame whose time has come
        while true {
            if nextFrame == nil { nextFrame = readNext() }
            if nextFrame == nil {
                // end of file -> loop
                if reader?.status == .completed || reader?.status == .failed || reader?.status == .cancelled {
                    loopOffset = max(currentPTS, mediaTime) + 1 / max(nominalFPS, 1)
                    _ = makeReader()
                    nextFrame = readNext()
                    if nextFrame == nil { break }
                } else { break }
            }
            guard let nf = nextFrame, nf.1 <= mediaTime else { break }
            current = nf.0; currentPTS = nf.1; nextFrame = nil
        }
        if let pb = current { store.push(pb) }
        // sound: keep about 50 ms ahead of the picture
        if let ao = audioOut, let player = audio {
            while audioTime < mediaTime + 0.05, let sb = ao.copyNextSampleBuffer() {
                audioTime = CMSampleBufferGetPresentationTimeStamp(sb).seconds + loopOffset
                player.enqueue(sb)
            }
        }
    }
}
