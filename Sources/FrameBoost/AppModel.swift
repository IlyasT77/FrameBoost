import SwiftUI
import AVFoundation
import Metal

final class AppModel: ObservableObject {
    static let demoID = "demo"
    static let noAudioID = "none"

    @Published var videoDevices: [DeviceItem] = []
    @Published var audioDevices: [DeviceItem] = []
    @Published var selectedVideo: String = AppModel.demoID
    @Published var selectedAudio: String = AppModel.noAudioID
    @Published var mode: BoostMode = .auto { didSet { settings.mode = mode } }
    @Published var compareBlend = false { didSet { settings.showRaw = compareBlend } }
    @Published var showHUD = true
    @Published var running = false
    @Published var volume: Double = 1.0 { didSet { capture.volume = Float(volume) } }
    @Published var errorText: String?
    @Published var stats = Stats()

    struct Stats { var signal = 0.0, game = 0.0, output = 0.0, gpu = 0.0, format = "" }

    let store = FrameStore()
    let settings = RenderSettings()
    let capture = CaptureManager()
    let demo = DemoSource()
    let device: MTLDevice?
    let interp: Interpolator?
    lazy var renderer: Renderer? = { guard let ip = self.interp else { return nil }; return Renderer(interp: ip, store: self.store, settings: self.settings) }()
    private var statTimer: Timer?
    private var observers: [NSObjectProtocol] = []

    init() {
        let dev = MTLCreateSystemDefaultDevice()
        var ip: Interpolator?
        var err: String?
        if let d = dev {
            do { ip = try Interpolator(device: d) } catch { err = "GPU-Fehler: \(error.localizedDescription)" }
        } else { err = "Kein Metal-Grafikchip gefunden." }
        device = dev
        interp = ip
        errorText = err
        statTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.updateStats() }
        let nc = NotificationCenter.default
        for name in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.devicesChanged() })
        }
    }

    /// Called at launch and whenever something is plugged in: a capture card starts automatically.
    func refreshDevices(autostart: Bool) {
        videoDevices = CaptureManager.videoItems()
        audioDevices = CaptureManager.audioItems()
        if let card = videoDevices.first(where: { $0.isCaptureCard }) {
            if selectedVideo == AppModel.demoID || !videoDevices.contains(where: { $0.id == selectedVideo }) {
                selectedVideo = card.id
                selectedAudio = CaptureManager.matchingAudio(forVideoName: card.name, in: audioDevices)?.id ?? AppModel.noAudioID
            }
            if autostart && !running { start() }
        } else if selectedVideo != AppModel.demoID && !videoDevices.contains(where: { $0.id == selectedVideo }) {
            selectedVideo = AppModel.demoID
        }
    }

    private func devicesChanged() {
        let wasRunningCard = running && selectedVideo != AppModel.demoID
        refreshDevices(autostart: !running)
        if wasRunningCard && !videoDevices.contains(where: { $0.id == selectedVideo }) { stop(); errorText = "Capture Card wurde getrennt." }
    }

    func selectVideo(_ id: String) {
        selectedVideo = id
        if let item = videoDevices.first(where: { $0.id == id }), let a = CaptureManager.matchingAudio(forVideoName: item.name, in: audioDevices) {
            selectedAudio = a.id
        }
        if running { start() }
    }

    func start() {
        errorText = nil
        stopSources()
        store.reset()
        if selectedVideo == AppModel.demoID {
            demo.start(store: store); running = true; stats.format = "Demo 1280×720 @ 60 Hz (Spiel: 30 FPS)"
            return
        }
        CaptureManager.requestAccess { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.errorText = "Kamera-Zugriff verweigert. Systemeinstellungen → Datenschutz & Sicherheit → Kamera → FrameBoost erlauben."
                self.running = false; return
            }
            do {
                try self.capture.start(videoID: self.selectedVideo,
                                       audioID: self.selectedAudio == AppModel.noAudioID ? nil : self.selectedAudio, store: self.store)
                self.running = true
                self.stats.format = self.capture.formatDescription
            } catch {
                self.errorText = error.localizedDescription; self.running = false
            }
        }
    }

    private func stopSources() { demo.stop(); capture.stop() }

    func stop() { stopSources(); running = false }

    private func updateStats() {
        guard running else { return }
        stats.signal = store.signalFPS
        stats.game = store.gameFPS
        stats.output = renderer?.outputFPS ?? 0
        stats.gpu = renderer?.gpuMs ?? 0
        if running && stats.signal == 0 && selectedVideo != AppModel.demoID {
            errorText = "Kein Signal – ist die PS5 an und HDCP in den PS5-Einstellungen deaktiviert?"
        } else if errorText?.hasPrefix("Kein Signal") == true { errorText = nil }
    }
}
