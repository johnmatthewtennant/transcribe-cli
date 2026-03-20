import Foundation

/// Handles colored terminal output, volatile preview, and session summary.
final class TerminalUI: Sendable {
    private let micSpeaker: String
    private let systemSpeaker: String
    private let showInterim: Bool
    // Injectable terminal width for testing; nil means query the real terminal
    private let overrideColumns: Int?

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

    init(micSpeaker: String, systemSpeaker: String, showInterim: Bool = false, overrideColumns: Int? = nil) {
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
        self.overrideColumns = overrideColumns
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

    /// Clear volatile state for a speaker. Call this when the next interim
    /// arrives for a new segment (i.e., after finalization has already printed).
    func clearVolatile(speaker: String) {
        lock.lock()
        defer { lock.unlock() }
        lastVolatile[speaker] = nil
    }

    /// Show a finalized result — prints a full line.
    /// Does NOT clear volatile tracking — the last interim stays visible
    /// until the next interim arrives, preventing a blank gap between
    /// finalization and the start of the next speech segment.
    func showFinalized(speaker: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        let color = speaker == micSpeaker ? green : blue
        // Clear volatile line first, then print finalized
        print("\(clearLine)\(bold)\(color)\(speaker)\(reset): \(text)")
        if showInterim {
            // Blank line buffer: volatile text overwrites this instead of the finalized line
            print("")
            // Re-render volatile line (other speaker's interim, or this speaker's last interim)
            renderVolatileLine()
        }
        fflush(stdout)
    }

    /// Compute the speaker/text pairs that should appear on the volatile line.
    /// Handles dual-channel layout, narrow-terminal fallback, and truncation.
    /// Caller must hold lock.
    private func computeVolatileSegments() -> [(speaker: String, text: String)] {
        var speakers = [micSpeaker, systemSpeaker].filter { lastVolatile[$0]?.isEmpty == false }
        guard !speakers.isEmpty else { return [] }

        let columns = overrideColumns ?? Self.terminalWidth()

        // Minimum readable text width per speaker
        let minTextPerSpeaker = 10

        if speakers.count > 1 {
            // Check if both speakers fit on one line
            let labelOverhead = speakers.reduce(0) { $0 + $1.count + 3 } + (speakers.count - 1)
            let availableForText = columns - labelOverhead
            if availableForText < speakers.count * minTextPerSpeaker {
                // Too narrow for both — show only the last speaker in our stable order
                // (systemSpeaker if both active, since it's last in [mic, system])
                speakers = [speakers.last!]
            }
        }

        // Compute per-speaker text budget — never exceed terminal width
        let labelOverhead = speakers.reduce(0) { $0 + $1.count + 3 } + max(speakers.count - 1, 0)
        let maxTextWidth = max(0, (columns - labelOverhead) / speakers.count)

        return speakers.compactMap { speaker in
            guard let text = lastVolatile[speaker] else { return nil }
            let truncated: String
            if maxTextWidth <= 3 {
                truncated = String(text.prefix(maxTextWidth))
            } else if text.count > maxTextWidth {
                truncated = String(text.prefix(maxTextWidth - 3)) + "..."
            } else {
                truncated = text
            }
            return (speaker: speaker, text: truncated)
        }
    }

    /// Render all active volatile texts on the current (bottom) line.
    /// When both speakers have active interims, both are shown side-by-side
    /// so neither channel's text vanishes while the other updates.
    /// On narrow terminals where both won't fit, falls back to a single speaker.
    /// Note: text is sanitized upstream (TranscriptionEngine.sanitizeText) before reaching here.
    /// Caller must hold lock.
    private func renderVolatileLine() {
        let segments = computeVolatileSegments()
        guard !segments.isEmpty else { return }

        var parts: [String] = []
        for seg in segments {
            let color = seg.speaker == micSpeaker ? green : blue
            parts.append("\(gray)[\(color)\(seg.speaker)\(gray)] \(seg.text)\(reset)")
        }

        print("\(clearLine)\(parts.joined(separator: " "))", terminator: "")
        fflush(stdout)
    }

    /// Returns the segments that would be rendered on the volatile line (for testing).
    /// Each entry is (speaker, truncatedText) without ANSI codes.
    func volatileSegments() -> [(speaker: String, text: String)] {
        lock.lock()
        defer { lock.unlock() }
        return computeVolatileSegments()
    }

    /// Query terminal width via ioctl; returns 80 if unavailable.
    private static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
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
