import AppKit
import Darwin

/// `FrameBoost --soak <seconds> <dir>`: runs the real app (window, GPU, sound) on the demo signal and
/// clicks through every feature again and again. Every 5 s it records memory, FPS and errors;
/// at the end it writes soak-report.txt + soak-log.csv and quits. A crash shows up as a missing report.
final class SoakTest {
    private let model: AppModel
    private let duration: Double
    private let dir: String
    private var t0 = CACurrentMediaTime()
    private var step = 0
    private var actionTimer: Timer?
    private var sampleTimer: Timer?
    private var csv = "sekunde,aktion,speicher_mb,ausgabe_fps,spiel_fps,signal_hz,gpu_ms,bildschirm_hz,ton_puffer_ms,fehler\n"
    private var samples: [(t: Double, mem: Double, out: Double, running: Bool)] = []
    private var lastAction = "start"
    private var problems: [String] = []
    private var actionsDone = 0

    init(model: AppModel, duration: Double, dir: String) {
        self.model = model; self.duration = duration; self.dir = dir
    }

    static func memoryMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    private var actions: [(String, () -> Void)] {
        let m = model
        return [
            ("Demo starten", { m.selectVideo(AppModel.demoID); m.start() }),
            ("Modus Auto", { m.mode = .auto }),
            ("Modus 2×", { m.mode = .x2 }),
            ("Modus 3×", { m.mode = .x3 }),
            ("Modus 4×", { m.mode = .x4 }),
            ("Modus 6×", { m.mode = .x6 }),
            ("Modus Aus", { m.mode = .off }),
            ("Modus Auto", { m.mode = .auto }),
            ("Qualität Schnell", { m.quality = .fast }),
            ("Qualität Hoch", { m.quality = .high }),
            ("Schärfen 0", { m.sharpen = 0 }),
            ("Schärfen 1", { m.sharpen = 1 }),
            ("Schärfen 0.3", { m.sharpen = 0.3 }),
            ("Duplikate aus", { m.dedup = false }),
            ("Duplikate an", { m.dedup = true }),
            ("Vergleich Überblenden an", { m.compareBlend = true }),
            ("Vergleich Überblenden aus", { m.compareBlend = false }),
            ("FPS-Anzeige aus", { m.showHUD = false }),
            ("FPS-Anzeige an", { m.showHUD = true }),
            ("Ton-Puffer aus", { m.audioSync = false }),
            ("Ton-Puffer an", { m.audioSync = true }),
            ("Ton −100 ms", { m.audioOffsetMs = -100 }),
            ("Ton +200 ms", { m.audioOffsetMs = 200 }),
            ("Ton 0 ms", { m.audioOffsetMs = 0 }),
            ("Lautstärke 0", { m.volume = 0 }),
            ("Lautstärke 1", { m.volume = 1 }),
            ("Stop", { m.stop() }),
            ("Start", { m.start() }),
            ("Stop+Start schnell", { m.stop(); m.start(); m.stop(); m.start() }),
            ("Geräte suchen", { m.refreshDevices(autostart: false) }),
            ("Fenster klein", { SoakTest.resize(900, 540) }),
            ("Fenster groß", { SoakTest.resize(1500, 900) }),
            ("Vollbild an", { NSApp.windows.first { $0.isVisible }?.toggleFullScreen(nil) }),
            ("Vollbild aus", { NSApp.windows.first { $0.isVisible }?.toggleFullScreen(nil) }),
        ]
    }

    private static func resize(_ w: CGFloat, _ h: CGFloat) {
        guard let win = NSApp.windows.first(where: { $0.isVisible }), !win.styleMask.contains(.fullScreen) else { return }
        win.setFrame(NSRect(x: 40, y: 40, width: w, height: h), display: true, animate: false)
    }

    func run() {
        Log.write("Dauertest gestartet: \(Int(duration)) s")
        t0 = CACurrentMediaTime()
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        actions[0].1()
        actionTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in self?.nextAction() }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.sample() }
    }

    private func nextAction() {
        let list = actions
        step = step % (list.count - 1) + 1      // index 0 (demo start) only once
        let (name, action) = list[step]
        lastAction = name
        actionsDone += 1
        action()
        if CACurrentMediaTime() - t0 > duration { finish() }
    }

    private func sample() {
        let t = CACurrentMediaTime() - t0
        let mem = SoakTest.memoryMB()
        let s = model.stats
        samples.append((t, mem, s.output, model.running))
        let err = (model.errorText ?? "").replacingOccurrences(of: ",", with: ";")
        csv += String(format: "%.0f,%@,%.1f,%.1f,%.1f,%.1f,%.2f,%.0f,%.0f,%@\n", t, lastAction, mem, s.output, s.game, s.signal, s.gpu,
                      s.displayHz, s.audioDelayMs, err)
        if let e = model.errorText, !e.isEmpty, !problems.contains(e) { problems.append("Fehlermeldung: \(e)") }
    }

    private func finish() {
        actionTimer?.invalidate(); sampleTimer?.invalidate()
        sample()
        let warm = samples.filter { $0.t > 30 }
        let mems = warm.map { $0.mem }
        let first = mems.prefix(3).reduce(0, +) / Double(max(1, min(3, mems.count)))
        let last = mems.suffix(3).reduce(0, +) / Double(max(1, min(3, mems.count)))
        let minutes = max((warm.last?.t ?? 1) - (warm.first?.t ?? 0), 1) / 60
        let growth = (last - first) / minutes
        // output must not freeze while running (except right after a restart)
        var frozen = 0
        for (i, s) in samples.enumerated() where i > 0 && s.running && samples[i - 1].running && s.out < 1 { frozen += 1 }
        let outs = warm.filter { $0.running && $0.out > 1 }.map { $0.out }
        var report = "FrameBoost Dauertest\n====================\n"
        report += String(format: "Laufzeit: %.0f s, Aktionen: %d (alle %d Funktionen mehrfach durchgeklickt)\n",
                         CACurrentMediaTime() - t0, actionsDone, actions.count)
        report += "Abstürze: keine (App lief bis zum Ende)\n"
        report += String(format: "Speicher: Start %.0f MB, Ende %.0f MB, max %.0f MB, Wachstum %.1f MB/min\n",
                         first, last, mems.max() ?? 0, growth)
        report += String(format: "Ausgabe-FPS (laufend): min %.0f, max %.0f\n", outs.min() ?? 0, outs.max() ?? 0)
        report += "Eingefrorene Messpunkte (läuft, aber 0 FPS): \(frozen)\n"
        let leak = growth > 5
        if leak { problems.append(String(format: "Speicher wächst um %.1f MB/min", growth)) }
        if frozen > 2 { problems.append("Bildausgabe stand \(frozen)× still") }
        report += problems.isEmpty ? "Probleme: keine\nERGEBNIS: BESTANDEN\n" : "Probleme:\n- " + problems.joined(separator: "\n- ") + "\nERGEBNIS: NICHT BESTANDEN\n"
        try? report.write(toFile: dir + "/soak-report.txt", atomically: true, encoding: .utf8)
        try? csv.write(toFile: dir + "/soak-log.csv", atomically: true, encoding: .utf8)
        Log.write("Dauertest beendet")
        print(report)
        model.stop()
        let code: Int32 = problems.isEmpty ? 0 : 2
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { exit(code) }
    }
}
