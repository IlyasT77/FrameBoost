import AVFoundation
import CoreMedia

struct DeviceItem: Identifiable, Hashable {
    let id: String
    let name: String
    let isCaptureCard: Bool
}

/// Finds capture cards, opens them with the best format and plays their audio.
final class CaptureManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let cardKeywords = ["elgato", "game capture", "hd60", "4k60", "4k x", "4k pro", "4k s", "cam link", "avermedia", "live gamer",
                               "capture", "usb video", "uvc", "hdmi", "razer ripsaw", "genki", "shadowcast", "nzxt", "ezcap", "magewell", "acasis", "guermok"]

    static func isCard(_ name: String) -> Bool {
        let n = name.lowercased()
        return cardKeywords.contains { n.contains($0) }
    }

    static func videoDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external, .builtInWideAngleCamera, .continuityCamera],
                                         mediaType: .video, position: .unspecified).devices
    }

    static func audioDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    }

    static func videoItems() -> [DeviceItem] {
        videoDevices().map { DeviceItem(id: $0.uniqueID, name: $0.localizedName, isCaptureCard: isCard($0.localizedName) || $0.deviceType == .external) }
            .sorted { ($0.isCaptureCard ? 0 : 1, $0.name) < ($1.isCaptureCard ? 0 : 1, $1.name) }
    }

    static func audioItems() -> [DeviceItem] {
        audioDevices().map { DeviceItem(id: $0.uniqueID, name: $0.localizedName, isCaptureCard: isCard($0.localizedName)) }
            .sorted { ($0.isCaptureCard ? 0 : 1, $0.name) < ($1.isCaptureCard ? 0 : 1, $1.name) }
    }

    /// Picks the audio input that belongs to a capture card (same name / keyword).
    static func matchingAudio(forVideoName v: String, in audio: [DeviceItem]) -> DeviceItem? {
        let first = v.lowercased().split(separator: " ").first.map(String.init) ?? ""
        return audio.first { !first.isEmpty && $0.name.lowercased().contains(first) } ?? audio.first { $0.isCaptureCard }
    }

    let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private var audioPreview: AVCaptureAudioPreviewOutput?
    private let audioOut = AVCaptureAudioDataOutput()
    private let audioQueue = DispatchQueue(label: "capture.audio", qos: .userInteractive)
    /// Every AVCaptureSession call happens on this one serial queue (Apple's rule; starting and
    /// stopping from different threads can throw an exception and crash the app).
    private let sessionQueue = DispatchQueue(label: "capture.session", qos: .userInitiated)
    /// Buffered, delayed playback (picture/sound in sync). If nil, sound plays directly without buffer.
    weak var audioPlayer: AudioDelayPlayer?
    var useAudioBuffer = true
    private let queue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    private weak var store: FrameStore?
    private(set) var formatDescription = ""

    var volume: Float = 1.0 {
        didSet {
            let v = volume
            audioPlayer?.volume = v
            sessionQueue.async { self.audioPreview?.volume = v }
        }
    }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { v in
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { done(v) } }
        }
    }

    /// Opens the card asynchronously; `completion` runs on the main thread with the format text or an error.
    func start(videoID: String, audioID: String?, store: FrameStore, completion: @escaping (Result<String, Error>) -> Void) {
        let useBuffer = useAudioBuffer, vol = volume
        sessionQueue.async {
            self.stopOnQueue()
            self.store = store
            do {
                try self.configure(videoID: videoID, audioID: audioID, useBuffer: useBuffer, volume: vol)
                self.session.startRunning()
                let fmt = self.formatDescription
                Log.write("Capture gestartet: \(fmt)")
                DispatchQueue.main.async { completion(.success(fmt)) }
            } catch {
                self.stopOnQueue()
                Log.write("Capture-Fehler: \(error.localizedDescription)")
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    private func configure(videoID: String, audioID: String?, useBuffer: Bool, volume: Float) throws {
        guard let dev = AVCaptureDevice(uniqueID: videoID) else { throw err("Gerät nicht gefunden") }
        let input = try AVCaptureDeviceInput(device: dev)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input) else { throw err("Gerät ist belegt (OBS / QuickTime schließen)") }
        session.addInput(input)
        configureBestFormat(dev)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw err("Videoausgang konnte nicht geöffnet werden") }
        session.addOutput(output)

        if let aid = audioID, let adev = AVCaptureDevice(uniqueID: aid), let ain = try? AVCaptureDeviceInput(device: adev), session.canAddInput(ain) {
            session.addInput(ain)
            if useBuffer, audioPlayer != nil {
                audioOut.audioSettings = [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
                                          AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
                                          AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2]
                audioOut.setSampleBufferDelegate(self, queue: audioQueue)
                if session.canAddOutput(audioOut) { session.addOutput(audioOut) }
            } else {
                let prev = AVCaptureAudioPreviewOutput()
                prev.volume = volume
                if session.canAddOutput(prev) { session.addOutput(prev); audioPreview = prev }
            }
        }
    }

    func stop() { sessionQueue.async { self.stopOnQueue() } }

    private func stopOnQueue() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        audioPreview = nil
    }

    /// How good a capture format is for FrameBoost (higher = better).
    /// 1. The full 60 Hz signal: the PS5 sends every game frame inside a 60 Hz signal; capturing it at 30 Hz or less
    ///    loses the timing (cheap USB 2.0 sticks offer e.g. 1080p only at 5 or 30 FPS, but 720p at 60).
    /// 2. Resolution: 1080p is ideal, 4K costs a lot of GPU time for little gain.
    /// 3. Uncompressed (YUV) before MJPEG/H.264 (less noise and latency).
    static func formatScore(width: Int, height: Int, fps: Double, compressed: Bool) -> Double {
        let rate: Double = fps >= 59 ? 3000 : fps >= 49 ? 2500 : fps * 40
        let res: Double
        switch (width, height) {
        case (1920, 1080): res = 1000
        case (2560, 1440): res = 900
        case (1280, 720): res = 700
        case (3840, 2160): res = 600
        default: res = Double(min(width * height, 1920 * 1080)) / 4000
        }
        return rate + res + min(fps, 60) - (compressed ? 150 : 0)
    }

    /// Picks the card's best format by formatScore and sets its highest frame rate.
    private func configureBestFormat(_ dev: AVCaptureDevice) {
        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let compressed = sub == kCMVideoCodecType_JPEG_OpenDML || sub == kCMVideoCodecType_JPEG || sub == kCMVideoCodecType_H264
            return CaptureManager.formatScore(width: Int(d.width), height: Int(d.height), fps: fps, compressed: compressed)
        }
        guard let best = dev.formats.max(by: { score($0) < score($1) }) else { return }
        do {
            try dev.lockForConfiguration()
            dev.activeFormat = best
            if let r = best.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) {
                dev.activeVideoMinFrameDuration = r.minFrameDuration
                dev.activeVideoMaxFrameDuration = r.minFrameDuration
            }
            dev.unlockForConfiguration()
            let d = CMVideoFormatDescriptionGetDimensions(best.formatDescription)
            let fps = best.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            formatDescription = "\(d.width)×\(d.height) @ \(Int(fps.rounded())) Hz"
        } catch { formatDescription = "Standardformat" }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        if output === audioOut {
            audioPlayer?.enqueue(sampleBuffer)
            return
        }
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        store?.push(pb)
    }

    private func err(_ s: String) -> NSError { NSError(domain: "FrameBoost", code: 10, userInfo: [NSLocalizedDescriptionKey: s]) }
}
