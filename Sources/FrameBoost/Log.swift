import Foundation
import Darwin

/// Small log file (~/Library/Logs/FrameBoost/frameboost.log) + crash marker.
/// The log goes into bug reports; the crash marker lets the next start offer a report.
enum Log {
    static let dir: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/FrameBoost")
    static let file = dir.appendingPathComponent("frameboost.log")
    static let crashMarker = dir.appendingPathComponent("last-crash.txt")
    private static let queue = DispatchQueue(label: "frameboost.log")
    private static var crashFD: Int32 = -1
    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"; return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        queue.async {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            // keep the file small: rotate at 1 MB
            if let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int, size > 1_000_000 {
                let old = dir.appendingPathComponent("frameboost.old.log")
                try? FileManager.default.removeItem(at: old)
                try? FileManager.default.moveItem(at: file, to: old)
            }
            if let h = try? FileHandle(forWritingTo: file) {
                h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
            } else {
                try? line.data(using: .utf8)!.write(to: file)
            }
        }
    }

    /// Last lines of the log (for bug reports).
    static func tail(_ lines: Int = 200) -> String {
        queue.sync {}
        guard let s = try? String(contentsOf: file, encoding: .utf8) else { return "(kein Log)" }
        return s.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }

    /// Text of the crash marker of the previous run (nil if the last run ended normally).
    static func takePreviousCrash() -> String? {
        guard let s = try? String(contentsOf: crashMarker, encoding: .utf8), !s.isEmpty else { return nil }
        try? FileManager.default.removeItem(at: crashMarker)
        return s
    }

    /// Writes a marker if the app dies from a fatal signal or an uncaught exception.
    static func installCrashHandlers() {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        crashFD = open(crashMarker.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        NSSetUncaughtExceptionHandler { e in
            let text = "Absturz (Exception): \(e.name.rawValue) – \(e.reason ?? "")\n\(e.callStackSymbols.prefix(25).joined(separator: "\n"))\n"
            if Log.crashFD >= 0 { _ = text.withCString { Darwin.write(Log.crashFD, $0, strlen($0)) } }
        }
        for sig in [SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP] {
            signal(sig) { s in
                // async-signal-safe: fixed buffer + write(2) only
                var buf: (CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar,
                          CChar, CChar, CChar, CChar, CChar, CChar, CChar, CChar) =
                    (65, 98, 115, 116, 117, 114, 122, 32, 40, 83, 105, 103, 110, 97, 108, 32, 0, 0, 41, 10, 0, 0, 0, 0) // "Absturz (Signal __)\n"
                withUnsafeMutableBytes(of: &buf) { raw in
                    let p = raw.bindMemory(to: CChar.self)
                    p[16] = CChar(48 + (s / 10) % 10); p[17] = CChar(48 + s % 10)
                    if Log.crashFD >= 0 { _ = Darwin.write(Log.crashFD, p.baseAddress!, 20) }
                }
                signal(s, SIG_DFL)
                raise(s)
            }
        }
    }
}
