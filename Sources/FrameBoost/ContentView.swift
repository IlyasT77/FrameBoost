import SwiftUI
import MetalKit
import UniformTypeIdentifiers

enum Theme {
    static let accent = Color(red: 1.0, green: 0.31, blue: 0.545)        // #FF4F8B
    static let panel = Color(white: 0.09)
    static let line = Color.white.opacity(0.08)
}

struct MetalView: NSViewRepresentable {
    let model: AppModel
    func makeNSView(context: Context) -> MTKView {
        let v = MTKView(frame: .zero, device: model.device)
        v.colorPixelFormat = .bgra8Unorm
        v.framebufferOnly = false
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.preferredFramesPerSecond = 240   // as fast as the screen allows: 60 / 120 / 144 / 180 / 240 Hz
        v.enableSetNeedsDisplay = false
        v.isPaused = false
        v.delegate = model.renderer
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) {}
}

/// Three stacked frames - the FrameBoost mark.
struct LogoMark: View {
    var size: CGFloat = 44
    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(0..<3) { i in
                RoundedRectangle(cornerRadius: size * 0.2)
                    .fill(Theme.accent.opacity([0.3, 0.6, 1.0][i]))
                    .frame(width: size, height: size * 1.32)
                    .offset(x: CGFloat(i) * size * 0.46)
            }
        }
        .frame(width: size * 1.92, height: size * 1.32, alignment: .leading)
    }
}

struct Wordmark: View {
    var size: CGFloat = 15
    var body: some View {
        (Text("Frame").foregroundColor(.white) + Text("Boost").foregroundColor(Theme.accent))
            .font(.system(size: size, weight: .bold, design: .rounded))
    }
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
            if !model.running { StartScreen(model: model) }
            VStack(spacing: 0) {
                if controlsVisible { TopBar(model: model).transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if let e = model.errorText { ErrorBanner(text: e) { model.errorText = nil }.padding(14) }
            }
            if model.showHUD && model.running {
                VStack { HStack { Spacer(); HUD(model: model) }; Spacer() }
                    .padding(.top, controlsVisible ? 64 : 14).padding(.trailing, 14)
            }
        }
        .frame(minWidth: 900, minHeight: 540)
        .onContinuousHover { _ in poke() }
        .onReceive(hideTimer) { _ in
            if model.running && Date().timeIntervalSince(lastMove) > 3 {
                if controlsVisible { withAnimation(.easeInOut(duration: 0.25)) { controlsVisible = false } }
                NSCursor.setHiddenUntilMouseMoves(true)
            }
        }
        .onAppear { model.refreshDevices(autostart: true) }
    }

    private func poke() {
        lastMove = Date()
        if !controlsVisible { withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true } }
    }
}

// MARK: - Top bar
struct TopBar: View {
    @ObservedObject var model: AppModel

    private var statusColor: Color {
        guard model.running else { return .gray }
        return model.stats.signal > 0 || model.isVirtualSource ? .green : .orange
    }

    var body: some View {
        HStack(spacing: 14) {
            Wordmark()
            Divider().frame(height: 18)
            Menu {
                Section("Video-Quelle") {
                    ForEach(model.videoDevices) { d in
                        Button { model.selectVideo(d.id) } label: {
                            Label(d.name, systemImage: d.isCaptureCard ? "rectangle.connected.to.line.below" : "video")
                        }
                    }
                    Button { model.selectVideo(AppModel.demoID) } label: { Label("Demo-Signal", systemImage: "play.rectangle") }
                    Button { TopBar.chooseVideoFile(model) } label: { Label("Videodatei als Capture Card …", systemImage: "film") }
                }
                Divider()
                Button { model.refreshDevices(autostart: false) } label: { Label("Geräte neu suchen", systemImage: "arrow.clockwise") }
            } label: {
                HStack(spacing: 7) {
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                    Text(model.sourceName).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 240, alignment: .leading)
            .help("Video-Quelle wählen")

            Picker("Frame Generation", selection: $model.mode) {
                ForEach(BoostMode.allCases) { m in Text(m.rawValue).tag(m) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .help(model.mode.help)

            Spacer(minLength: 8)

            SettingsLink { Image(systemName: "gearshape") }
                .buttonStyle(.borderless).help("Einstellungen (⌘,)")
            Button { NSApp.keyWindow?.toggleFullScreen(nil) } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.borderless).help("Vollbild (⌃⌘F)")
            Button { model.running ? model.stop() : model.start() } label: {
                Text(model.running ? "Stop" : "Start").frame(minWidth: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.running ? Color(white: 0.28) : Theme.accent)
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
        .padding(.horizontal, 12).padding(.top, 10)
    }
}

extension TopBar {
    /// Any video file can stand in for a capture card (e.g. a 30 FPS recording to try frame generation).
    static func chooseVideoFile(_ model: AppModel) {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        p.message = "Video auswählen – es läuft wie eine Capture Card (60-Hz-Signal)"
        if p.runModal() == .OK, let url = p.url { model.selectVideoFile(url) }
    }
}

// MARK: - Start screen
struct StartScreen: View {
    @ObservedObject var model: AppModel

    private var card: DeviceItem? { model.videoDevices.first { $0.isCaptureCard } }

    var body: some View {
        VStack(spacing: 22) {
            LogoMark(size: 40)
            VStack(spacing: 6) {
                Text("FrameBoost").font(.system(size: 30, weight: .semibold, design: .rounded))
                HStack(spacing: 6) {
                    Circle().fill(card == nil ? Color.gray : .green).frame(width: 7, height: 7)
                    Text(card.map { "Capture Card erkannt: \($0.name)" } ?? "Keine Capture Card gefunden – einstecken, sie startet automatisch")
                        .foregroundStyle(.secondary)
                }.font(.callout)
            }
            VStack(alignment: .leading, spacing: 10) {
                step("1", "PS5: Einstellungen → System → HDMI → „HDCP aktivieren“ aus")
                step("2", "PS5: Videoausgabe 1080p, HDR aus")
                step("3", "OBS, QuickTime und Elgato-Software schließen")
            }
            .padding(16)
            .frame(width: 440, alignment: .leading)
            .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line))
            HStack(spacing: 10) {
                Button(action: model.start) { Text("Start").frame(width: 120) }
                    .buttonStyle(.borderedProminent).tint(Theme.accent).controlSize(.large)
                    .keyboardShortcut(.return, modifiers: [])
                Button { model.selectVideo(AppModel.demoID); model.start() } label: { Text("Demo-Signal testen").frame(width: 150) }
                    .controlSize(.large)
            }
        }
        .foregroundStyle(.white)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(n).font(.caption.weight(.bold)).frame(width: 18, height: 18)
                .background(Theme.accent.opacity(0.18), in: Circle()).foregroundStyle(Theme.accent)
            Text(text).font(.callout).foregroundStyle(.white.opacity(0.85))
        }
    }
}

// MARK: - HUD
struct HUD: View {
    @ObservedObject var model: AppModel
    var body: some View {
        let s = model.stats
        VStack(alignment: .trailing, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("\(Int(s.output.rounded()))").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                Text("FPS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            .foregroundStyle(Color(red: 0.37, green: 0.88, blue: 0.54))
            Group {
                Text("Spiel \(Int(s.game.rounded())) FPS · Signal \(Int(s.signal.rounded())) Hz · Bildschirm \(Int(s.displayHz.rounded())) Hz")
                Text(String(format: "GPU %.1f ms · Duplikate %d %%%@", s.gpu, Int(s.dupes * 100),
                            model.audioSync ? String(format: " · Ton-Puffer %.0f ms", s.audioDelayMs) : ""))
                Text(s.format)
            }
            .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

struct ErrorBanner: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).font(.callout)
            Spacer(minLength: 8)
            Button(action: dismiss) { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(maxWidth: 760)
        .background(Color(red: 0.36, green: 0.11, blue: 0.15).opacity(0.95), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .foregroundStyle(.white)
    }
}

// MARK: - Settings window (⌘,)
struct SettingsView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TabView {
            general.tabItem { Label("Allgemein", systemImage: "gearshape") }
            sound.tabItem { Label("Ton", systemImage: "speaker.wave.2") }
            help.tabItem { Label("Hilfe", systemImage: "questionmark.circle") }
        }
        .frame(width: 520, height: 430)
    }

    private var general: some View {
        Form {
            Section("Frame Generation") {
                Picker("Modus", selection: $model.mode) { ForEach(BoostMode.allCases) { m in Text(m.rawValue).tag(m) } }
                Text(model.mode.help).font(.caption).foregroundStyle(.secondary)
                Picker("Qualität", selection: $model.quality) { ForEach(GenQuality.allCases) { q in Text(q.rawValue).tag(q) } }
                Toggle("Doppelte Frames entfernen", isOn: $model.dedup)
                Text("Die PS5 sendet immer 60 Hz – bei 30-FPS-Spielen ist jedes Bild doppelt.").font(.caption).foregroundStyle(.secondary)
                Toggle("Vergleich: nur überblenden (zum Testen)", isOn: $model.compareBlend)
            }
            Section("Bild") {
                LabeledContent("Schärfen") { Slider(value: $model.sharpen, in: 0...1) }
                Text("Wirkt nur, wenn das Bild skaliert wird (z. B. 1080p auf einem Retina-Display).").font(.caption).foregroundStyle(.secondary)
                Toggle("FPS-Anzeige", isOn: $model.showHUD)
            }
        }
        .formStyle(.grouped)
    }

    private var sound: some View {
        Form {
            Section("Ton der Capture Card") {
                Picker("Quelle", selection: Binding(get: { model.selectedAudio }, set: { model.selectAudio($0) })) {
                    Text("Kein Ton").tag(AppModel.noAudioID)
                    ForEach(model.audioDevices) { d in Text(d.name).tag(d.id) }
                }
                LabeledContent("Lautstärke") { Slider(value: $model.volume, in: 0...1) }
            }
            Section("Bild und Ton synchron") {
                Toggle("Ton-Puffer", isOn: $model.audioSync)
                if model.audioSync {
                    LabeledContent("Feinabstimmung") {
                        Slider(value: $model.audioOffsetMs, in: -100...200, step: 5) {
                            EmptyView()
                        } minimumValueLabel: { Text("früher").font(.caption2) } maximumValueLabel: { Text("später").font(.caption2) }
                    }
                    Text(String(format: "Der Ton wird um %.0f ms verzögert (automatisch %@%.0f ms).", model.stats.audioDelayMs,
                                model.audioOffsetMs >= 0 ? "+" : "−", abs(model.audioOffsetMs)))
                        .font(.caption).foregroundStyle(.secondary)
                    if model.stats.outputLatencyMs > model.stats.audioDelayMs + 20 {
                        Text(String(format: "Deine Kopfhörer/Lautsprecher haben %.0f ms eigene Verzögerung (z. B. Bluetooth). Mit Kabel oder den Mac-Lautsprechern bleibt es synchron.", model.stats.outputLatencyMs))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("Test: Demo-Signal starten – weißes Quadrat und Piepton müssen gleichzeitig kommen.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var help: some View {
        Form {
            Section("Probleme melden") {
                Button("Fehlerbericht erstellen …") { BugReport.create(model) }
                Text("Speichert Systeminfos, Einstellungen und das Protokoll auf dem Schreibtisch und öffnet die Projektseite.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Protokoll-Ordner öffnen") { NSWorkspace.shared.open(Log.dir) }
            }
            Section("Über") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                LabeledContent("Grafik", value: model.device?.name ?? "–")
                LabeledContent("Eingang", value: model.stats.format.isEmpty ? "–" : model.stats.format)
                Link("FrameBoost auf GitHub", destination: BugReport.repo)
            }
        }
        .formStyle(.grouped)
    }
}
