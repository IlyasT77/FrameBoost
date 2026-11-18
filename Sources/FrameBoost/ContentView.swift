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
    let hideTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            MetalView(model: model).ignoresSafeArea()
            if !model.running { placeholder }
            VStack {
                if controlsVisible { controlBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if let e = model.errorText {
                    Text(e).padding(10).background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).foregroundStyle(.white).padding()
                }
            }
            if model.showHUD && model.running {
                VStack { HStack { Spacer(); hud }; Spacer() }.padding(.top, controlsVisible ? 70 : 12).padding(.trailing, 12)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
        .onContinuousHover { _ in poke() }
        .onReceive(hideTimer) { _ in
            if model.running && Date().timeIntervalSince(lastMove) > 3 { withAnimation { controlsVisible = false } }
        }
        .onAppear { model.refreshDevices(autostart: true) }
    }

    private func poke() {
        lastMove = Date()
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
    }

    private var placeholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "gamecontroller.fill").font(.system(size: 54)).foregroundStyle(.pink)
            Text("FrameBoost").font(.system(size: 34, weight: .heavy))
            Text("PS5 → Capture Card → Mac anschließen.\nDie Karte wird automatisch erkannt und gestartet.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button(action: model.start) { Label("Start", systemImage: "play.fill").frame(width: 140) }
                .controlSize(.large).buttonStyle(.borderedProminent).tint(.pink)
        }.foregroundStyle(.white)
    }

    private var hud: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text("\(Int(model.stats.output.rounded())) FPS").font(.system(size: 26, weight: .bold, design: .monospaced)).foregroundStyle(.green)
            Text("Spiel \(Int(model.stats.game.rounded())) FPS · Signal \(Int(model.stats.signal.rounded())) Hz")
            Text(String(format: "GPU %.1f ms · %@", model.stats.gpu, model.stats.format))
        }
        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white)
        .padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    private var controlBar: some View {
        HStack(spacing: 12) {
            Text("FrameBoost").font(.headline).foregroundStyle(.pink)
            Picker("Quelle", selection: Binding(get: { model.selectedVideo }, set: { model.selectVideo($0) })) {
                ForEach(model.videoDevices) { d in Text((d.isCaptureCard ? "🎮 " : "") + d.name).tag(d.id) }
                Divider()
                Text("Demo-Signal (ohne Capture Card)").tag(AppModel.demoID)
            }.frame(maxWidth: 260)
            Picker("Ton", selection: $model.selectedAudio) {
                Text("Kein Ton").tag(AppModel.noAudioID)
                ForEach(model.audioDevices) { d in Text(d.name).tag(d.id) }
            }.frame(maxWidth: 200)
            Slider(value: $model.volume, in: 0...1) { Image(systemName: "speaker.wave.2.fill") }.frame(width: 90)
            Picker("Frame Gen", selection: $model.mode) {
                ForEach(BoostMode.allCases) { m in Text(m.rawValue).tag(m) }
            }.pickerStyle(.segmented).frame(width: 300)
            Toggle("FPS", isOn: $model.showHUD).toggleStyle(.switch).controlSize(.mini)
            Spacer(minLength: 0)
            Button { model.refreshDevices(autostart: false) } label: { Image(systemName: "arrow.clockwise") }.help("Geräte neu suchen")
            Button { model.running ? model.stop() : model.start() } label: {
                Label(model.running ? "Stop" : "Start", systemImage: model.running ? "stop.fill" : "play.fill")
            }.buttonStyle(.borderedProminent).tint(model.running ? .green : .pink)
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help("Vollbild (⌃⌘F)")
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(10)
        .onChange(of: model.selectedAudio) { _, _ in if model.running { model.start() } }
    }
}
