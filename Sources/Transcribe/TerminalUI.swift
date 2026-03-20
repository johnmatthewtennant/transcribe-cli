import Foundation

/// Handles colored terminal output with inline interim text.
///
/// Interim (volatile) text is printed inline in gray/dim, occupying the same
/// position as finalized text. When finalized text arrives, it overwrites the
/// interim block in place (moving up to clear the interim lines, then printing
/// the finalized version in bold). This eliminates the visual gap between
/// interim disappearing and finalized appearing.
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
    private let bold = "\u{001B}[1m"
    private let reset = "\u{001B}[0m"
    private let clearLine = "\u{001B}[2K"
    private let moveUp = "\u{001B}[1A"

    private let lock = NSLock()
    // How many terminal lines the current interim block occupies
    nonisolated(unsafe) private var interimLineCount = 0
    // Last interim text per speaker (for non-retraction guard)
    nonisolated(unsafe) private var lastInterimText: [String: String] = [:]

    init(micSpeaker: String, systemSpeaker: String, showInterim: Bool = false, overrideColumns: Int? = nil) {
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
        self.overrideColumns = overrideColumns
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

    /// Show interim text inline — printed in dim gray at the current position.
    /// Each update clears the previous interim block and reprints.
    /// Only shows remote/system speaker interim.
    func showVolatile(speaker: String, text: String) {
        guard showInterim else { return }
        guard speaker != micSpeaker else { return }
        lock.lock()
        defer { lock.unlock() }

        lastInterimText[speaker] = text

        // Clear previous interim block
        clearInterimBlock()

        // Print new interim inline (dim gray)
        let color = speaker == micSpeaker ? green : blue
        let line = "\(dim)\(gray)\(color)\(speaker)\(gray): \(text)\(reset)"
        print(line, terminator: "")
        fflush(stdout)

        // Track how many lines this occupied
        interimLineCount = terminalLineCount(for: line)
    }

    /// Show finalized text — clears the interim block, prints the finalized line,
    /// then re-renders any remaining interim text below it.
    /// The interim text persists through finalization so there's no visual gap.
    func showFinalized(speaker: String, text: String) {
        lock.lock()
        defer { lock.unlock() }

        // Clear interim block visually
        clearInterimBlock()

        // Print finalized line (bold, with newline — becomes permanent)
        let color = speaker == micSpeaker ? green : blue
        print("\(bold)\(color)\(speaker)\(reset): \(text)")

        // Re-render any remaining interim text below the finalized line.
        // This handles the reorder buffer case: event N+1's interim is already
        // showing when event N finally flushes from the buffer.
        let hasInterim = lastInterimText.values.contains { !$0.isEmpty }
        if hasInterim {
            for s in [micSpeaker, systemSpeaker] {
                guard let interim = lastInterimText[s], !interim.isEmpty else { continue }
                let iColor = s == micSpeaker ? green : blue
                let line = "\(dim)\(gray)\(iColor)\(s)\(gray): \(interim)\(reset)"
                print(line, terminator: "")
                interimLineCount = terminalLineCount(for: line)
            }
        }
        fflush(stdout)
    }

    /// Clear volatile state for a speaker.
    func clearVolatile(speaker: String) {
        lock.lock()
        defer { lock.unlock() }
        lastInterimText[speaker] = nil
    }

    func printSummary(duration: TimeInterval, wordCount: Int, filePath: URL, recordingPaths: [URL] = []) {
        lock.lock()
        defer { lock.unlock() }
        clearInterimBlock()
        print("\(bold)Session complete.\(reset)")
        print("  Duration:   \(formatDuration(duration))")
        print("  Words:      \(wordCount)")
        print("  Transcript: \(filePath.path)")
        for path in recordingPaths {
            print("  Recording:  \(path.path)")
        }
    }

    // MARK: - Private

    /// Clear the current interim block by moving up and clearing each line.
    /// Caller must hold lock.
    private func clearInterimBlock() {
        if interimLineCount > 0 {
            // Move up through wrapped lines
            for _ in 0..<interimLineCount {
                print("\(moveUp)\(clearLine)", terminator: "")
            }
        }
        // Clear the first line (or current line if no wrapping)
        print("\r\(clearLine)", terminator: "")
        interimLineCount = 0
    }

    /// Count how many terminal lines a string occupies (accounting for wrapping).
    private func terminalLineCount(for text: String) -> Int {
        let columns = overrideColumns ?? Self.terminalWidth()
        guard columns > 0 else { return 0 }
        // Strip ANSI codes to get visible character count
        let plain = text.replacingOccurrences(of: "\u{001B}\\[[0-9;]*m", with: "", options: .regularExpression)
        guard plain.count > 0 else { return 0 }
        // Number of *extra* lines beyond the first (wrapping)
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
