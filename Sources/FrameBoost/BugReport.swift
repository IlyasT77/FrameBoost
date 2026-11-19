import AppKit
import Metal

/// Collects everything needed to understand a problem into one text file on the Desktop.
enum BugReport {
    static let repo = URL(string: "https://github.com/IlyasT77/FrameBoost")!

    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buf = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buf, &size, nil, 0)
        return String(cString: buf)
    }

    /// Newest macOS crash report of FrameBoost (if any).
    static func latestSystemCrashReport() -> String? {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        let mine = files.filter { $0.lastPathComponent.hasPrefix("FrameBoost") }
        guard let newest = mine.max(by: {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) <
            ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }), let text = try? String(contentsOf: newest, encoding: .utf8) else { return nil }
        return "\(newest.lastPathComponent)\n" + text.split(separator: "\n", omittingEmptySubsequences: false).prefix(160).joined(separator: "\n")
    }

    static func text(for m: AppModel) -> String {
        let info = Bundle.main.infoDictionary
        let s = m.stats
        var t = "FrameBoost – Fehlerbericht\n==========================\n"
        t += "Version: \(info?["CFBundleShortVersionString"] as? String ?? "dev")\n"
        t += "macOS: \(ProcessInfo.processInfo.operatingSystemVersionString) · Mac: \(hardwareModel())\n"
        t += "Grafik: \(m.device?.name ?? "–")\n"
        t += "Bildschirme: " + NSScreen.screens.map { "\(Int($0.frame.width))×\(Int($0.frame.height)) @ \($0.maximumFramesPerSecond) Hz" }.joined(separator: ", ") + "\n"
        t += "Videogeräte: " + m.videoDevices.map { $0.name + ($0.isCaptureCard ? " (Capture Card)" : "") }.joined(separator: ", ") + "\n"
        t += "Audiogeräte: " + m.audioDevices.map { $0.name }.joined(separator: ", ") + "\n"
        t += "Quelle: \(m.sourceName) · läuft: \(m.running) · Eingang: \(s.format)\n"
        t += "Einstellungen: Modus \(m.mode.rawValue), Qualität \(m.quality.rawValue), Duplikate \(m.dedup), Schärfen \(String(format: "%.2f", m.sharpen)), "
        t += "Ton-Puffer \(m.audioSync) (\(Int(m.audioOffsetMs)) ms)\n"
        t += String(format: "Messwerte: Ausgabe %.0f FPS, Spiel %.0f FPS, Signal %.0f Hz, GPU %.1f ms, Bildschirm %.0f Hz, Ton-Puffer %.0f ms\n",
                    s.output, s.game, s.signal, s.gpu, s.displayHz, s.audioDelayMs)
        t += "Fehlermeldung: \(m.errorText ?? "–")\n\n"
        t += "Letzter Absturz (FrameBoost):\n\(m.lastCrash ?? "keiner")\n\n"
        t += "macOS-Absturzbericht:\n\(latestSystemCrashReport() ?? "keiner")\n\n"
        t += "Protokoll (letzte Zeilen):\n\(Log.tail(300))\n"
        return t
    }

    static func create(_ m: AppModel) {
        let desk = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser
        let url = desk.appendingPathComponent("FrameBoost-Fehlerbericht.txt")
        do {
            try text(for: m).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
            NSWorkspace.shared.open(repo.appendingPathComponent("issues/new"))
            Log.write("Fehlerbericht erstellt: \(url.path)")
        } catch {
            let a = NSAlert(); a.messageText = "Fehlerbericht konnte nicht gespeichert werden"; a.informativeText = error.localizedDescription; a.runModal()
        }
    }
}
