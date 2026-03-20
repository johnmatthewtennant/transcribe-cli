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
    private let clearToEnd = "\u{001B}[J"  // Clear from cursor to end of screen
    private let clearLine = "\r\u{001B}[J"  // Move to start of line + clear everything below

    // Serialization lock for terminal output and mutable state
    private let lock = NSLock()
    // Track last volatile text per speaker — never show less than what was already visible
    // Protected by lock; nonisolated(unsafe) suppresses Sendable warning
    nonisolated(unsafe) private var lastVolatile: [String: String] = [:]
    // Speakers whose volatile text is "sticky" — survives one repaint after finalization
    // then gets cleared on the next repaint triggered by a different speaker.
    nonisolated(unsafe) private var stickyVolatile: Set<String> = []
    // Most recently updated speaker (for narrow-terminal fallback)
    nonisolated(unsafe) private var lastUpdatedSpeaker: String?

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
        // Skip local/mic interim — only show remote/system
        guard speaker != micSpeaker else { return }
        lock.lock()
        defer { lock.unlock() }
        // If this speaker was sticky (post-finalization), reset its state so the
        // non-retraction rule starts fresh for the new speech segment.
        if stickyVolatile.contains(speaker) {
            lastVolatile[speaker] = nil
            stickyVolatile.remove(speaker)
        }
        let previous = lastVolatile[speaker] ?? ""
        // Only update if new text is at least as long — never retract visible text
        let display = text.count >= previous.count ? text : previous
        lastVolatile[speaker] = display
        lastUpdatedSpeaker = speaker
        // Clear any remaining sticky speakers (other channels that finalized)
        for sticky in stickyVolatile {
            lastVolatile[sticky] = nil
        }
        stickyVolatile.removeAll()
        renderVolatileLine()
    }

    /// Clear volatile state for a speaker. Call this when the next interim
    /// arrives for a new segment (i.e., after finalization has already printed).
    func clearVolatile(speaker: String) {
        lock.lock()
        defer { lock.unlock() }
        lastVolatile[speaker] = nil
        stickyVolatile.remove(speaker)
    }

    /// Show a finalized result — prints a full line.
    /// Marks the speaker as "sticky" — its last interim stays visible on the volatile
    /// line for one more repaint, then gets cleared when another speaker updates.
    /// This prevents a blank gap between finalization and the next speech segment.
    func showFinalized(speaker: String, text: String) {
        lock.lock()
        defer { lock.unlock() }
        // Mark as sticky: survives this repaint, cleared on next showVolatile from other speaker
        stickyVolatile.insert(speaker)
        let color = speaker == micSpeaker ? green : blue
        // Clear volatile line first, then print finalized
        print("\(clearLine)\(bold)\(color)\(speaker)\(reset): \(text)")
        if showInterim {
            // Blank line buffer: volatile text overwrites this instead of the finalized line
            print("")
            // Re-render volatile line (other speaker's interim, or this speaker's sticky interim)
            renderVolatileLine()
        }
        fflush(stdout)
    }

    /// Compute the speaker/text pairs that should appear on the volatile line.
    /// Handles dual-channel layout, narrow-terminal fallback, and truncation.
    /// Caller must hold lock.
    private func computeVolatileSegments() -> [(speaker: String, text: String)] {
        return [micSpeaker, systemSpeaker].compactMap { speaker in
            guard let text = lastVolatile[speaker], !text.isEmpty else { return nil }
            return (speaker: speaker, text: text)
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
