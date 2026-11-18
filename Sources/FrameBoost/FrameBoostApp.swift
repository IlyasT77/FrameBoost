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

    init() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--selftest") {
            let dir = i + 1 < args.count ? args[i + 1] : "selftest-output"
            exit(SelfTest.run(outputDir: dir) ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--make-icon"), i + 1 < args.count {
            IconMaker.write(to: args[i + 1]); exit(0)
        }
    }

    var body: some Scene {
        WindowGroup("FrameBoost") {
            ContentView(model: model)
                .preferredColorScheme(.dark)
                .onAppear {
                    if CommandLine.arguments.contains("--demo") { model.selectedVideo = AppModel.demoID; model.start() }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Frame Gen: Aus") { model.mode = .off }.keyboardShortcut("0", modifiers: [.command])
                Button("Frame Gen: Auto") { model.mode = .auto }.keyboardShortcut("1", modifiers: [.command])
                Button("Frame Gen: 2×") { model.mode = .x2 }.keyboardShortcut("2", modifiers: [.command])
                Button("Frame Gen: 4×") { model.mode = .x4 }.keyboardShortcut("4", modifiers: [.command])
            }
        }
    }
}
