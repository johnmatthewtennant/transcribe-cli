import Foundation

/// Handles colored terminal output with inline interim and processing text.
///
/// Three visual states for text:
/// - **Finalized** (bold): permanent, committed by the recognizer
/// - **Processing** (dim italic): was interim, recognizer stopped updating it, awaiting finalization
/// - **Interim** (dim gray): actively being updated by the recognizer
///
/// When interim text stops growing and new interim starts for a different segment,
/// the old interim is promoted to "processing" and stays visible inline. When the
/// recognizer finalizes it, the processing line is replaced with bold finalized text.
final class TerminalUI: Sendable {
    private let micSpeaker: String
    private let systemSpeaker: String
    private let showInterim: Bool
    private let overrideColumns: Int?

    // ANSI codes
    private let green = "\u{001B}[32m"
    private let blue = "\u{001B}[34m"
    private let gray = "\u{001B}[90m"
    private let dim = "\u{001B}[2m"
    private let italic = "\u{001B}[3m"
    private let bold = "\u{001B}[1m"
    private let reset = "\u{001B}[0m"
    private let clearLine = "\u{001B}[2K"
    private let moveUp = "\u{001B}[1A"

    private let lock = NSLock()

    /// Processing lines: interim text that stopped updating and is awaiting finalization.
    /// These are printed inline (dim italic) and replaced when finalized.
    /// Each entry is (speaker, text, terminalLineCount).
    nonisolated(unsafe) private var processingLines: [(speaker: String, text: String, lines: Int)] = []

    /// Current active interim text (the one still being updated by the recognizer).
    nonisolated(unsafe) private var activeInterim: (speaker: String, text: String)?

    /// Terminal lines occupied by the entire non-finalized block (processing + interim).
    nonisolated(unsafe) private var nonFinalizedLineCount = 0

    /// Global reference for SIGWINCH handler (only one TerminalUI exists at a time).
    nonisolated(unsafe) private static var activeInstance: TerminalUI?

    init(micSpeaker: String, systemSpeaker: String, showInterim: Bool = false, overrideColumns: Int? = nil) {
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
        self.overrideColumns = overrideColumns

        if showInterim && overrideColumns == nil {
            TerminalUI.activeInstance = self
            signal(SIGWINCH) { _ in
                TerminalUI.activeInstance?.handleResize()
            }
        }
    }

    /// Re-render the non-finalized block after terminal resize.
    private func handleResize() {
        lock.lock()
        defer { lock.unlock() }
        // Calculate total visible characters in the non-finalized block to get
        // a safe upper bound on lines to clear (assumes minimum 20 columns).
        var totalChars = 0
        for proc in processingLines {
            totalChars += proc.speaker.count + proc.text.count + 5
        }
        if let interim = activeInterim {
            totalChars += interim.speaker.count + interim.text.count + 5
        }
        // Clear at least as many lines as the old count, but also enough for
        // worst-case wrapping (total chars / 20 cols)
        nonFinalizedLineCount = max(nonFinalizedLineCount, totalChars / 20)
        renderNonFinalizedBlock()
    }

    func printInfo(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        print("\(gray)[\(message)]\(reset)")
    }

    func printError(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        FileHandle.standardError.write("\(bold)\u{001B}[31mError: \(message)\(reset)\n".data(using: .utf8)!)
    }

    /// Show interim text inline. When the recognizer starts a new segment (text gets shorter),
    /// the previous interim is promoted to a "processing" line above.
    func showVolatile(speaker: String, text: String) {
        guard showInterim else { return }
        guard speaker != micSpeaker else { return }
        lock.lock()
        defer { lock.unlock() }

        // Detect new segment: if text is shorter than current interim, the old one
        // was for a previous segment that's now in processing.
        if let current = activeInterim, current.speaker == speaker {
            if text.count < current.text.count {
                // Promote old interim to processing
                let procLine = formatProcessing(speaker: current.speaker, text: current.text)
                let lineCount = terminalLineCount(for: procLine)
                processingLines.append((speaker: current.speaker, text: current.text, lines: lineCount))
            }
        }

        activeInterim = (speaker: speaker, text: text)
        renderNonFinalizedBlock()
    }

    /// Show finalized text. Clears the non-finalized block, checks if this finalization
    /// matches a processing line (removes it), prints the finalized line, then re-renders
    /// remaining processing lines and active interim.
    func showFinalized(speaker: String, text: String) {
        lock.lock()
        defer { lock.unlock() }

        // Clear the entire non-finalized block
        clearNonFinalizedBlock()

        // Remove the first processing line for this speaker (it's been finalized)
        if let idx = processingLines.firstIndex(where: { $0.speaker == speaker }) {
            processingLines.remove(at: idx)
        }

        // If the active interim matches this speaker and the finalized text starts
        // with similar content, clear it (it was the same segment)
        if let current = activeInterim, current.speaker == speaker {
            // Check if this finalization consumed the active interim
            // (finalized text is usually a refined version of the interim)
            if text.hasPrefix(String(current.text.prefix(min(20, current.text.count)))) ||
               current.text.hasPrefix(String(text.prefix(min(20, text.count)))) {
                activeInterim = nil
            }
        }

        // Print finalized line (bold, permanent)
        let color = speaker == micSpeaker ? green : blue
        print("\(bold)\(color)\(speaker)\(reset): \(text)")

        // Re-render remaining processing lines and active interim
        renderNonFinalizedBlock()
        fflush(stdout)
    }

    func clearVolatile(speaker: String) {
        lock.lock()
        defer { lock.unlock() }
        if activeInterim?.speaker == speaker {
            activeInterim = nil
        }
        processingLines.removeAll { $0.speaker == speaker }
    }

    func printSummary(duration: TimeInterval, wordCount: Int, filePath: URL, recordingPaths: [URL] = []) {
        lock.lock()
        defer { lock.unlock() }
        clearNonFinalizedBlock()
        processingLines.removeAll()
        activeInterim = nil
        print("\(bold)Session complete.\(reset)")
        print("  Duration:   \(formatDuration(duration))")
        print("  Words:      \(wordCount)")
        print("  Transcript: \(filePath.path)")
        for path in recordingPaths {
            print("  Recording:  \(path.path)")
        }
    }

    // MARK: - Private

    /// Format a processing line (dim italic).
    private func formatProcessing(speaker: String, text: String) -> String {
        let color = speaker == micSpeaker ? green : blue
        return "\(dim)\(italic)\(color)\(speaker)\(reset)\(dim)\(italic): \(text)\(reset)"
    }

    /// Format an interim line (dim gray).
    private func formatInterim(speaker: String, text: String) -> String {
        let color = speaker == micSpeaker ? green : blue
        return "\(dim)\(gray)\(color)\(speaker)\(gray): \(text)\(reset)"
    }

    /// Clear the entire non-finalized block (processing lines + active interim).
    /// Caller must hold lock.
    private func clearNonFinalizedBlock() {
        if nonFinalizedLineCount > 0 {
            for _ in 0..<nonFinalizedLineCount {
                print("\(moveUp)\(clearLine)", terminator: "")
            }
        }
        // Clear current line + everything below (catches any residual from miscounted wraps)
        print("\r\(clearLine)\u{001B}[J", terminator: "")
        nonFinalizedLineCount = 0
    }

    /// Render all non-finalized content: processing lines then active interim.
    /// Caller must hold lock.
    private func renderNonFinalizedBlock() {
        // Clear previous render
        clearNonFinalizedBlock()

        var totalLines = 0

        // Print processing lines (each on its own line with newline)
        for proc in processingLines {
            let line = formatProcessing(speaker: proc.speaker, text: proc.text)
            print(line)
            totalLines += 1 + terminalLineCount(for: line)
        }

        // Print active interim (no newline — stays on current line for updates)
        if let interim = activeInterim {
            let line = formatInterim(speaker: interim.speaker, text: interim.text)
            print(line, terminator: "")
            totalLines += terminalLineCount(for: line)
        }

        nonFinalizedLineCount = totalLines
        fflush(stdout)
    }

    /// Count how many *extra* terminal lines a string occupies from wrapping.
    private func terminalLineCount(for text: String) -> Int {
        let columns = overrideColumns ?? Self.terminalWidth()
        guard columns > 0 else { return 0 }
        let plain = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard plain.count > 0 else { return 0 }
        return (plain.count - 1) / columns
    }

    static func terminalWidth() -> Int {
        var ws = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0, ws.ws_col > 0 {
            return Int(ws.ws_col)
        }
        return 80
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
