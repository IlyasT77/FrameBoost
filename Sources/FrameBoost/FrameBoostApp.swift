import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct FrameBoostApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = AppModel()

    static var soak: SoakTest?

    init() {
        let args = CommandLine.arguments
        Log.installCrashHandlers()
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        Log.write("FrameBoost \(version) gestartet · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(args.dropFirst().joined(separator: " "))")
        if let i = args.firstIndex(of: "--selftest") {
            let dir = i + 1 < args.count ? args[i + 1] : "selftest-output"
            exit(SelfTest.run(outputDir: dir) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
            IconMaker.write(to: args[i + 1]); exit(0)
        }
        if let i = args.firstIndex(of: "--make-dmg-background"), i + 2 < args.count {
            DMGBackground.write(to: args[i + 1], scale: Int(args[i + 2]) ?? 1); exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("FrameBoost") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear {
                    let args = CommandLine.arguments
                    if !args.contains("--soak"), !args.contains("--demo"), let crash = Log.takePreviousCrash() {
                        model.lastCrash = crash
                        DispatchQueue.main.async {
                            let a = NSAlert()
                            a.messageText = "FrameBoost wurde beim letzten Mal unerwartet beendet"
                            a.informativeText = "Möchtest du einen Fehlerbericht erstellen? Er hilft, den Fehler zu finden."
                            a.addButton(withTitle: "Fehlerbericht erstellen")
                            a.addButton(withTitle: "Später")
                            if a.runModal() == .alertFirstButtonReturn { BugReport.create(model) }
                        }
                    }
                    if args.contains("--demo") { model.selectedVideo = AppModel.demoID; model.start() }
                    if let i = args.firstIndex(of: "--soak"), FrameBoostApp.soak == nil {
                        let secs = i + 1 < args.count ? Double(args[i + 1]) ?? 600 : 600
                        let dir = i + 2 < args.count ? args[i + 2] : "soak-output"
                        let s = SoakTest(model: model, duration: secs, dir: dir)
                        FrameBoostApp.soak = s
                        s.run()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Frame Gen: Aus") { model.mode = .off }.keyboardShortcut("0", modifiers: [.command])
                Button("Frame Gen: Auto") { model.mode = .auto }.keyboardShortcut("1", modifiers: [.command])
                Button("Frame Gen: 2×") { model.mode = .x2 }.keyboardShortcut("2", modifiers: [.command])
                Button("Frame Gen: 3×") { model.mode = .x3 }.keyboardShortcut("3", modifiers: [.command])
                Button("Frame Gen: 4×") { model.mode = .x4 }.keyboardShortcut("4", modifiers: [.command])
                Button("Frame Gen: 6×") { model.mode = .x6 }.keyboardShortcut("6", modifiers: [.command])
                Divider()
                Button("FPS-Anzeige ein/aus") { model.showHUD.toggle() }.keyboardShortcut("i", modifiers: [.command])
                Button(model.running ? "Stop" : "Start") { model.running ? model.stop() : model.start() }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Button("Fehlerbericht erstellen …") { BugReport.create(model) }
                Button("Protokoll-Ordner öffnen") { NSWorkspace.shared.open(Log.dir) }
                Divider()
                Button("FrameBoost auf GitHub") { NSWorkspace.shared.open(BugReport.repo) }
            }
        }
        Settings {
            SettingsView(model: model).preferredColorScheme(.dark)
        }
    }
}
