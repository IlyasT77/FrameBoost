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
    /// Buffered, delayed playback (picture/sound in sync). If nil, sound plays directly without buffer.
    weak var audioPlayer: AudioDelayPlayer?
    var useAudioBuffer = true
    private let queue = DispatchQueue(label: "capture.video", qos: .userInteractive)
    private weak var store: FrameStore?
    private(set) var formatDescription = ""

    var volume: Float = 1.0 { didSet { audioPreview?.volume = volume; audioPlayer?.volume = volume } }

    static func requestAccess(_ done: @escaping (Bool) -> Void) {
        AVCaptureDevice.requestAccess(for: .video) { v in
            AVCaptureDevice.requestAccess(for: .audio) { _ in DispatchQueue.main.async { done(v) } }
        }
    }

    func start(videoID: String, audioID: String?, store: FrameStore) throws {
        stop()
        self.store = store
        guard let dev = AVCaptureDevice(uniqueID: videoID) else { throw err("Gerät nicht gefunden") }
        session.beginConfiguration()
        let input = try AVCaptureDeviceInput(device: dev)
        guard session.canAddInput(input) else { session.commitConfiguration(); throw err("Gerät ist belegt (OBS / QuickTime schließen)") }
        session.addInput(input)
        configureBestFormat(dev)

        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                                kCVPixelBufferMetalCompatibilityKey as String: true]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }

        if let aid = audioID, let adev = AVCaptureDevice(uniqueID: aid), let ain = try? AVCaptureDeviceInput(device: adev), session.canAddInput(ain) {
            session.addInput(ain)
            if useAudioBuffer, let player = audioPlayer {
                player.volume = volume
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
        session.commitConfiguration()
        queue.async { self.session.startRunning() }
    }

    func stop() {
        if session.isRunning { session.stopRunning() }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        audioPreview = nil
        audioPlayer?.stop()
    }

    /// Prefer 1080p (then 1440p/4K/720p) with the highest frame rate the card offers.
    private func configureBestFormat(_ dev: AVCaptureDevice) {
        func score(_ f: AVCaptureDevice.Format) -> Double {
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            let fps = f.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 0
            let res: Double
            switch (d.width, d.height) {
            case (1920, 1080): res = 1000
            case (2560, 1440): res = 900
            case (1280, 720): res = 700
            case (3840, 2160): res = 600   // 4K costs a lot of GPU time for little gain on the PS5's 30 FPS mode
            default: res = Double(min(Int(d.width) * Int(d.height), 1920 * 1080)) / 4000
            }
            // compressed MJPEG modes (cheap HDMI sticks) add noise + latency -> prefer raw YUV
            let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
            let compressed = sub == kCMVideoCodecType_JPEG_OpenDML || sub == kCMVideoCodecType_JPEG || sub == kCMVideoCodecType_H264
            return res + min(fps, 120) * 3 - (compressed ? 150 : 0)
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
