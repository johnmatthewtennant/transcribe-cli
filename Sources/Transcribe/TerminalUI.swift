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

    // Serialization lock for terminal output and mutable state
    private let lock = NSLock()
    // Track last volatile text per speaker — never show less than what was already visible
    // Protected by lock; nonisolated(unsafe) suppresses Sendable warning
    nonisolated(unsafe) private var lastVolatile: [String: String] = [:]

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
    /// Keeps the longest interim text visible until finalized replaces it,
    /// so text doesn't vanish when the recognizer retracts while re-processing.
    /// Renders ALL active speakers on the volatile line so dual-channel interims
    /// don't fight over a single terminal line.
    func showVolatile(speaker: String, text: String) {
        guard showInterim else { return }
        lock.lock()
        defer { lock.unlock() }
        let previous = lastVolatile[speaker] ?? ""
        // Only update if new text is at least as long — never retract visible text
        let display = text.count >= previous.count ? text : previous
        lastVolatile[speaker] = display
        renderVolatileLine()
    }

    /// Show a finalized result — prints a full line.
    /// Clears the volatile tracking for this speaker so the next interim starts fresh.
    /// Re-renders the volatile line if the other speaker still has active interim text.
    func showFinalized(speaker: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        lastVolatile[speaker] = nil
        let color = speaker == micSpeaker ? green : blue
        // Clear volatile line first, then print finalized
        print("\(clearLine)\(bold)\(color)\(speaker)\(reset): \(text)")
        if showInterim {
            // Blank line buffer: volatile text overwrites this instead of the finalized line
            print("")
            // If the other speaker still has volatile text, re-render it
            renderVolatileLine()
        }
        fflush(stdout)
    }

    /// Render all active volatile texts on the current (bottom) line.
    /// When both speakers have active interims, both are shown side-by-side
    /// so neither channel's text vanishes while the other updates.
    /// Caller must hold lock.
    private func renderVolatileLine() {
        let active = lastVolatile.filter { !$0.value.isEmpty }
        guard !active.isEmpty else { return }

        // Give each speaker roughly half the width when both are active
        let maxTextWidth = active.count > 1 ? 35 : 77

        var segments: [String] = []
        for speaker in [micSpeaker, systemSpeaker] {
            guard let text = active[speaker] else { continue }
            let color = speaker == micSpeaker ? green : blue
            let truncated = text.count > maxTextWidth
                ? String(text.prefix(maxTextWidth - 3)) + "..."
                : text
            segments.append("\(gray)[\(color)\(speaker)\(gray)] \(truncated)\(reset)")
        }

        print("\(clearLine)\(segments.joined(separator: " "))", terminator: "")
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
