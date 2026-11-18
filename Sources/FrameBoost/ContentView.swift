import SwiftUI
import MetalKit

struct MetalView: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: model.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 120   // ProMotion / 120 Hz monitors; 60 Hz displays simply run at 60
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.delegate = model.renderer
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var controlsVisible = true
    @State private var lastMove = Date()
    @State private var showSettings = false
    let hideTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let accent = LinearGradient(colors: [Color(red: 1, green: 0.25, blue: 0.5), Color(red: 0.55, green: 0.3, blue: 1)],
                                        startPoint: .leading, endPoint: .trailing)

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalView(model: model).ignoresSafeArea()
            if !model.running { placeholder }
            VStack(spacing: 0) {
                if controlsVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if let e = model.errorText {
                    Label(e, systemImage: "exclamationmark.triangle.fill")
                        .padding(10).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).padding()
                }
            }
            if model.showHUD && model.running {
                VStack { HStack { Spacer(); hud }; Spacer() }.padding(.top, controlsVisible ? 68 : 12).padding(.trailing, 12)
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .onContinuousHover { _ in poke() }
        .onReceive(hideTimer) { _ in
            if model.running && !showSettings && Date().timeIntervalSince(lastMove) > 3 {
                if controlsVisible { withAnimation { controlsVisible = false } }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .onAppear { model.refreshDevices(autostart: true) }
    }

    private func poke() {
        lastMove = Date()
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
    }

    // MARK: - Start screen
    private var placeholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 56)).foregroundStyle(accent)
            Text("FrameBoost").font(.system(size: 36, weight: .heavy))
            Text(model.videoDevices.contains { $0.isCaptureCard }
                 ? "Capture Card gefunden: \(model.sourceName)"
                 : "PS5 → Capture Card → Mac anschließen.\nDie Karte wird automatisch erkannt und gestartet.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button(action: model.start) { Label("Start", systemImage: "play.fill").frame(width: 120) }
                    .controlSize(.large).buttonStyle(.borderedProminent).tint(.pink)
                    .keyboardShortcut(.return, modifiers: [])
                Button { model.selectVideo(AppModel.demoID); model.start() } label: { Label("Demo testen", systemImage: "sparkles").frame(width: 120) }
                    .controlSize(.large)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("PS5: Einstellungen → System → HDMI → „HDCP aktivieren“ ausschalten")
                Text("OBS / QuickTime vorher schließen, sonst ist die Karte belegt")
            }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
        }.foregroundStyle(.white)
    }

    // MARK: - HUD
    private var hud: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(model.stats.output.rounded())) FPS").font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(.green)
            Text("Spiel \(Int(model.stats.game.rounded())) FPS · Signal \(Int(model.stats.signal.rounded())) Hz")
            Text(String(format: "GPU %.1f ms · Duplikate entfernt %d%%", model.stats.gpu, Int(model.stats.dupes * 100)))
            Text(model.stats.format)
        }
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
        .padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Top bar
    private var topBar: some View {
        HStack(spacing: 12) {
            Text("FrameBoost").font(.system(size: 15, weight: .heavy)).foregroundStyle(accent).fixedSize()
            Menu {
                Section("Video-Quelle") {
                    ForEach(model.videoDevices) { d in
                        Button { model.selectVideo(d.id) } label: {
                            Label(d.name, systemImage: d.isCaptureCard ? "gamecontroller" : "video")
                        }
                    }
                    Button { model.selectVideo(AppModel.demoID) } label: { Label("Demo-Signal (ohne Capture Card)", systemImage: "sparkles") }
                }
                Divider()
                Button { model.refreshDevices(autostart: false) } label: { Label("Geräte neu suchen", systemImage: "arrow.clockwise") }
            } label: {
                Label(model.sourceName, systemImage: "cable.connector").lineLimit(1)
            }
            .menuStyle(.borderlessButton).frame(maxWidth: 230)

            Picker("Frame Gen", selection: $model.mode) {
                ForEach(BoostMode.allCases) { m in Text(m.rawValue).tag(m).help(m.help) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(model.mode.help)

            Spacer(minLength: 8)

            Button { showSettings.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                .help("Einstellungen")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) { SettingsView(model: model) }
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .help("Vollbild (⌃⌘F)")
            Button { model.running ? model.stop() : model.start() } label: {
                Label(model.running ? "Stop" : "Start", systemImage: model.running ? "stop.fill" : "play.fill").fixedSize()
            }
            .buttonStyle(.borderedProminent).tint(model.running ? .green : .pink)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 10).padding(.top, 8)
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Form {
            Section("Ton") {
                Picker("Audio-Quelle", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                    Text("Kein Ton").tag(AppModel.noAudioID)
                    ForEach(model.audioDevices) { d in Text(d.name).tag(d.id) }
                }
                Slider(value: $model.volume, in: 0...1) { Text("Lautstärke") }
            }
            Section("Frame Generation") {
                Picker("Qualität", selection: $model.quality) {
                    ForEach(GenQuality.allCases) { q in Text(q.rawValue).tag(q) }
                }
                Toggle("Doppelte Frames entfernen (PS5 sendet 30 FPS in 60 Hz)", isOn: $model.dedup)
                Toggle("Vergleich: nur überblenden (schlechter, zum Testen)", isOn: $model.compareBlend)
            }
            Section("Bild") {
                Slider(value: $model.sharpen, in: 0...1) { Text("Schärfen") }
                Toggle("FPS-Anzeige", isOn: $model.showHUD)
            }
            Section {
                Text("Eingang: \(model.stats.format.isEmpty ? "–" : model.stats.format)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 470)
    }
}
