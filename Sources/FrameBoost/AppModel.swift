import SwiftUI
import AVFoundation
import Metal

final class AppModel: ObservableObject {
    static let demoID = "demo"
    static let noAudioID = "none"
    private let defaults = UserDefaults.standard

    @Published var videoDevices: [DeviceItem] = []
    @Published var audioDevices: [DeviceItem] = []
    @Published var selectedVideo: String = AppModel.demoID
    @Published var selectedAudio: String = AppModel.noAudioID
    @Published var mode: BoostMode = .auto { didSet { settings.mode = mode; defaults.set(mode.rawValue, forKey: "mode") } }
    @Published var quality: GenQuality = .high { didSet { interp?.quality = quality; defaults.set(quality.rawValue, forKey: "quality") } }
    @Published var sharpen: Double = 0.3 { didSet { settings.sharpen = Float(sharpen); defaults.set(sharpen, forKey: "sharpen") } }
    @Published var dedup = true { didSet { store.dedupEnabled = dedup; defaults.set(dedup, forKey: "dedup") } }
    @Published var compareBlend = false { didSet { settings.blendOnly = compareBlend } }
    @Published var showHUD = true { didSet { defaults.set(showHUD, forKey: "hud") } }
    @Published var volume: Double = 1.0 { didSet { capture.volume = Float(volume); audio.volume = Float(volume); defaults.set(volume, forKey: "volume") } }
    /// Sound through a buffer, delayed exactly like the picture (picture and sound in sync)
    @Published var audioSync = true { didSet { capture.useAudioBuffer = audioSync; defaults.set(audioSync, forKey: "audioSync"); if running { start() } } }
    /// manual fine tuning on top of the automatic delay (milliseconds, + = sound later)
    @Published var audioOffsetMs: Double = 0 { didSet { defaults.set(audioOffsetMs, forKey: "audioOffset"); updateAudioDelay() } }
    @Published var running = false
    @Published var errorText: String?
    @Published var stats = Stats()

    struct Stats { var signal = 0.0, game = 0.0, output = 0.0, gpu = 0.0, dupes = 0.0, audioDelayMs = 0.0, outputLatencyMs = 0.0, displayHz = 0.0, format = "" }

    let store = FrameStore()
    let settings = RenderSettings()
    let capture = CaptureManager()
    let demo = DemoSource()
    let audio = AudioDelayPlayer()
    let device: MTLDevice?
    let interp: Interpolator?
    lazy var renderer: Renderer? = { guard let ip = self.interp else { return nil }; return Renderer(interp: ip, store: self.store, settings: self.settings) }()
    private var statTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var activity: NSObjectProtocol?

    var sourceName: String {
        if selectedVideo == AppModel.demoID { return "Demo-Signal" }
        return videoDevices.first { $0.id == selectedVideo }?.name ?? "Keine Quelle"
    }

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
        // restore settings
        if let m = defaults.string(forKey: "mode"), let v = BoostMode(rawValue: m) { mode = v }
        if let q = defaults.string(forKey: "quality"), let v = GenQuality(rawValue: q) { quality = v }
        if defaults.object(forKey: "sharpen") != nil { sharpen = defaults.double(forKey: "sharpen") }
        if defaults.object(forKey: "dedup") != nil { dedup = defaults.bool(forKey: "dedup") }
        if defaults.object(forKey: "hud") != nil { showHUD = defaults.bool(forKey: "hud") }
        if defaults.object(forKey: "volume") != nil { volume = defaults.double(forKey: "volume") }
        if defaults.object(forKey: "audioSync") != nil { audioSync = defaults.bool(forKey: "audioSync") }
        if defaults.object(forKey: "audioOffset") != nil { audioOffsetMs = defaults.double(forKey: "audioOffset") }
        settings.mode = mode; settings.sharpen = Float(sharpen); store.dedupEnabled = dedup; interp?.quality = quality
        capture.audioPlayer = audio; capture.useAudioBuffer = audioSync
        audio.volume = Float(volume); capture.volume = Float(volume)

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
        let remembered = defaults.string(forKey: "video")
        if let card = videoDevices.first(where: { $0.id == remembered }) ?? videoDevices.first(where: { $0.isCaptureCard }) {
            if selectedVideo == AppModel.demoID || !videoDevices.contains(where: { $0.id == selectedVideo }) {
                selectedVideo = card.id
                selectedAudio = CaptureManager.matchingAudio(forVideoName: card.name, in: audioDevices)?.id ?? AppModel.noAudioID
            }
            if autostart && !running && card.isCaptureCard { start() }
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
        if id != AppModel.demoID { defaults.set(id, forKey: "video") }
        if let item = videoDevices.first(where: { $0.id == id }), let a = CaptureManager.matchingAudio(forVideoName: item.name, in: audioDevices) {
            selectedAudio = a.id
        }
        if running { start() }
    }

    func selectAudio(_ id: String) {
        selectedAudio = id
        if running && selectedVideo != AppModel.demoID { start() }
    }

    func start() {
        errorText = nil
        stopSources()
        store.reset()
        renderer?.reset()
        if selectedVideo == AppModel.demoID {
            audio.stop(); updateAudioDelay()
            demo.start(store: store, audio: audioSync ? audio : nil); setRunning(true)
            stats.format = "Demo 1280×720 @ 60 Hz (Spiel: 30 FPS) · weißes Quadrat + Piepton = Sync-Test"
            return
        }
        CaptureManager.requestAccess { [weak self] ok in
            guard let self = self else { return }
            guard ok else {
                self.errorText = "Kamera-Zugriff verweigert. Systemeinstellungen → Datenschutz & Sicherheit → Kamera → FrameBoost erlauben."
                self.setRunning(false); return
            }
            do {
                self.updateAudioDelay()
                try self.capture.start(videoID: self.selectedVideo,
                                       audioID: self.selectedAudio == AppModel.noAudioID ? nil : self.selectedAudio, store: self.store)
                self.setRunning(true)
                self.stats.format = self.capture.formatDescription
            } catch {
                self.errorText = error.localizedDescription; self.setRunning(false)
            }
        }
    }

    private func stopSources() { demo.stop(); capture.stop(); audio.stop() }

    /// Sound delay = how long the picture is held back + manual fine tuning.
    func updateAudioDelay() {
        let video = renderer?.videoDelay ?? 0.05
        let d = max(0, video + audioOffsetMs / 1000)
        audio.delay = d                       // re-timed only if it changes by more than 8 ms
        stats.audioDelayMs = audioSync ? audio.delay * 1000 : 0
        stats.outputLatencyMs = audio.outputLatency * 1000
    }

    func stop() { stopSources(); setRunning(false); renderer?.reset() }

    private func setRunning(_ on: Bool) {
        running = on
        renderer?.active = on
        // keep the display awake and the app out of App Nap while playing
        if on, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.idleDisplaySleepDisabled, .userInitiated, .latencyCritical],
                                                             reason: "FrameBoost: Gameplay")
        } else if !on, let a = activity {
            ProcessInfo.processInfo.endActivity(a); activity = nil
        }
    }

    private func updateStats() {
        guard running else { return }
        stats.signal = store.signalFPS
        stats.game = store.gameFPS
        stats.output = renderer?.outputFPS ?? 0
        stats.gpu = renderer?.gpuMs ?? 0
        stats.dupes = store.duplicateShare
        stats.displayHz = renderer?.displayHz ?? 0
        updateAudioDelay()
        if stats.signal == 0 && selectedVideo != AppModel.demoID {
            errorText = "Kein Signal – PS5 an? In der PS5: Einstellungen → System → HDMI → „HDCP aktivieren“ AUS."
        } else if errorText?.hasPrefix("Kein Signal") == true { errorText = nil }
    }
}
