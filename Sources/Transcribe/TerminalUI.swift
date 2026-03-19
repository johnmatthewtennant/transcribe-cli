import Foundation

/// Handles colored terminal output, volatile preview, and session summary.
final class TerminalUI: Sendable {
    private let micSpeaker: String
    private let systemSpeaker: String
    private let showInterim: Bool

    // ANSI color codes
    private let green = "\u{001B}[32m"
    private let blue = "\u{001B}[34m"
    private let gray = "\u{001B}[90m"
    private let bold = "\u{001B}[1m"
    private let reset = "\u{001B}[0m"
    private let clearLine = "\u{001B}[2K\r"

    // Serialization lock for terminal output
    private let lock = NSLock()

    init(micSpeaker: String, systemSpeaker: String, showInterim: Bool = false) {
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
    }

    /// Print an info message.
    func printInfo(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print("\(gray)[\(message)]\(reset)")
    }

    /// Print an error message.
    func printError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write("\(bold)\u{001B}[31mError: \(message)\(reset)\n".data(using: .utf8)!)
    }

    /// Show a volatile (partial) result — overwrites the current line.
    func showVolatile(speaker: String, text: String) {
        guard showInterim else { return }
        lock.lock()
        defer { lock.unlock() }
        let color = speaker == micSpeaker ? green : blue
        let truncated = text.count > 80 ? String(text.prefix(77)) + "..." : text
        print("\(clearLine)\(gray)[\(color)\(speaker)\(gray)] \(truncated)\(reset)", terminator: "")
        fflush(stdout)
    }

    /// Show a finalized result — prints a full line.
    func showFinalized(speaker: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        let color = speaker == micSpeaker ? green : blue
        // Clear volatile line first, then print finalized
        print("\(clearLine)\(bold)\(color)\(speaker)\(reset): \(text)")
        if showInterim {
            // Blank line buffer: volatile text overwrites this instead of the finalized line
            print("")
        }
        fflush(stdout)
    }

    /// Print session summary on exit.
    func printSummary(duration: TimeInterval, wordCount: Int, filePath: URL, recordingPaths: [URL] = []) {
        lock.lock()
        defer { lock.unlock() }
        print("\(clearLine)")
        print("\(bold)Session complete.\(reset)")
        print("  Duration:   \(formatDuration(duration))")
        print("  Words:      \(wordCount)")
        print("  Transcript: \(filePath.path)")
        for path in recordingPaths {
            print("  Recording:  \(path.path)")
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 {
            return String(format: "%dh %02dm %02ds", h, m, s)
        } else if m > 0 {
            return String(format: "%dm %02ds", m, s)
        } else {
            return String(format: "%ds", s)
        }
    }
}
