import ArgumentParser
import Foundation
import os
import Speech

/// Thread-safe shutdown reentrancy guard.
private let _shutdownLock = OSAllocatedUnfairLock(initialState: false)

#if compiler(>=6.2)
@available(macOS 26.0, *)
#endif
@main
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Record microphone + system audio and produce a real-time speaker-attributed transcript.",
        discussion: """
            Report issues:
              gh api repos/johnmatthewtennant/transcribe-cli/issues --method POST -f title="..." -f body="..."
            """,
        subcommands: _subcommands
    )

    #if compiler(>=6.2)
    private static let _subcommands: [ParsableCommand.Type] = [MergeCommand.self]
    #else
    private static let _subcommands: [ParsableCommand.Type] = []
    #endif

    @Option(name: .long, help: "Title for the recording session.")
    var title: String?

    @Flag(name: .long, help: "Resume a previous recording. Resumes the most recent by default, or specify a file with --resume-file.")
    var resume = false

    @Option(name: .customLong("resume-file"), help: "Resume a specific recording by filename.")
    var resumeFile: String?

    @Flag(name: .customLong("resume-last"), help: .hidden)
    var resumeLast = false

    @Flag(name: .long, help: "List past recordings.")
    var list = false

    @Flag(name: .customLong("install-skill"), help: "Install the skill definition. Use with --claude and/or --agents to choose targets. Defaults to both.")
    var installSkill = false

    @Flag(name: .long, help: "Install skill to ~/.claude/skills/ (use with --install-skill).")
    var claude = false

    @Flag(name: .long, help: "Install skill to ~/.agents/skills/ (use with --install-skill).")
    var agents = false

    @Flag(name: .long, help: "Overwrite existing skill files (use with --install-skill).")
    var force = false

    @Option(name: .long, help: "Comma-separated speaker names (e.g. \"Alice,Bob\"). First is mic, second is system audio.")
    var speakers: String?

    @Option(name: .long, help: "Path to an audio file (m4a, wav, mp3, caf, etc.) to transcribe offline.")
    var file: String?

    @Flag(name: .long, help: "Save the audio recording alongside the transcript.")
    var saveRecording = false

    @Flag(name: .long, help: "Show in-progress speech recognition text at the bottom of the terminal. Ignored when stdout is not a TTY.")
    var showInterim = false

    @Flag(name: .long, help: "Keep original mono CAF files after successful merge to M4A. By default, raw CAFs are deleted after merge.")
    var keepRawRecordings = false

    mutating func run() async throws {
        let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/transcripts")

        if list {
            try listRecordings(in: transcriptsDir)
            return
        }

        if installSkill {
            let installClaude = claude || !agents  // default to both if neither specified
            let installAgents = agents || !claude
            try installSkillFiles(installClaude: installClaude, installAgents: installAgents, force: force)
            return
        }

        let effectiveShowInterim = showInterim && isatty(STDOUT_FILENO) != 0

        if let file {
            try await runFileTranscription(file: file, transcriptsDir: transcriptsDir, effectiveShowInterim: effectiveShowInterim)
        } else {
            try await runLiveRecording(transcriptsDir: transcriptsDir, effectiveShowInterim: effectiveShowInterim)
        }
    }

    /// Transcribe an existing audio file.
    /// Automatically detects stereo files and splits channels for dual-speaker transcription.
    private func runFileTranscription(file: String, transcriptsDir: URL, effectiveShowInterim: Bool) async throws {
        let fileURL = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            .standardizedFileURL

        // Use the filename (without extension) as default title
        let fileTitle = sanitizeTitle(title) ?? fileURL.deletingPathExtension().lastPathComponent

        // Detect channel count for stereo handling
        let channelCount = try FileAudioSource.channelCount(at: fileURL)
        let isStereo = channelCount >= 2

        if channelCount > 2 {
            throw TranscribeError.captureError(
                "File has \(channelCount) channels — only mono (1) and stereo (2) files are supported: \(fileURL.lastPathComponent)"
            )
        }

        // Parse speaker names based on mono vs stereo
        let micSpeaker: String
        let systemSpeaker: String
        if isStereo {
            let names = parseSpeakerNames(speakers)
            micSpeaker = names.0
            systemSpeaker = names.1
        } else {
            let name = speakers.flatMap { $0.split(separator: ",").first.map { sanitizeSpeakerName(String($0.trimmingCharacters(in: .whitespaces))) } } ?? "Speaker"
            micSpeaker = name
            systemSpeaker = name
        }

        let terminal = TerminalUI(micSpeaker: micSpeaker, systemSpeaker: systemSpeaker, showInterim: effectiveShowInterim)
        terminal.printInfo("Transcribing file: \(fileURL.path)")
        if isStereo {
            terminal.printInfo("Stereo file detected — transcribing left channel as \(micSpeaker) and right channel as \(systemSpeaker)")
        }

        // Ensure speech model is available
        terminal.printInfo("Checking speech model availability...")
        try await ensureSpeechModel(terminal: terminal)

        // Determine output file
        let resumeTarget = try resolveResumeTarget(resumeFile: resumeFile, resume: resume, resumeLast: resumeLast, transcriptsDir: transcriptsDir)
        let (outputPath, isResume) = try resolveOutputFile(
            transcriptsDir: transcriptsDir,
            title: fileTitle,
            resume: resumeTarget
        )

        if isResume {
            terminal.printInfo("Appending to: \(outputPath.path)")
        } else {
            terminal.printInfo("Writing to: \(outputPath.path)")
        }

        // Set up markdown writer
        let writer = try MarkdownWriter(
            filePath: outputPath,
            title: fileTitle,
            isResume: isResume,
            micSpeaker: micSpeaker,
            systemSpeaker: systemSpeaker,
            sourceAudioFilename: fileURL.lastPathComponent
        )

        // Print existing transcript lines when resuming
        if isResume {
            printExistingTranscript(filePath: outputPath, terminal: terminal)
        }

        if isStereo {
            // Stereo: split into two channel-specific file sources with shared origin time
            let sharedOrigin = mach_continuous_time()
            let leftSource = try FileAudioSource(filePath: fileURL, channelIndex: 0, sharedOriginHostTime: sharedOrigin)
            let rightSource = try FileAudioSource(filePath: fileURL, channelIndex: 1, sharedOriginHostTime: sharedOrigin)

            let engine = try await TranscriptionEngine(
                leftFileSource: leftSource,
                rightFileSource: rightSource,
                writer: writer,
                terminal: terminal,
                micSpeaker: micSpeaker,
                systemSpeaker: systemSpeaker,
                showInterim: effectiveShowInterim
            )

            let startTime = Date()
            setupSignalHandler {
                Task {
                    await engine.stop()
                    leftSource.stop()
                    rightSource.stop()
                    writer.flush()
                    terminal.printSummary(
                        duration: Date().timeIntervalSince(startTime),
                        wordCount: writer.wordCount,
                        filePath: outputPath
                    )
                    Foundation.exit(0)
                }
            }

            terminal.printInfo("Transcribing...\n")
            try await engine.run()

            await engine.stop()
            writer.flush()
            terminal.printSummary(
                duration: Date().timeIntervalSince(startTime),
                wordCount: writer.wordCount,
                filePath: outputPath
            )
        } else {
            // Mono: single-channel transcription (existing behavior)
            let fileSource = try FileAudioSource(filePath: fileURL)

            let engine = try await TranscriptionEngine(
                fileSource: fileSource,
                writer: writer,
                terminal: terminal,
                speaker: micSpeaker,
                showInterim: effectiveShowInterim
            )

            let startTime = Date()
            setupSignalHandler {
                Task {
                    await engine.stop()
                    fileSource.stop()
                    writer.flush()
                    terminal.printSummary(
                        duration: Date().timeIntervalSince(startTime),
                        wordCount: writer.wordCount,
                        filePath: outputPath
                    )
                    Foundation.exit(0)
                }
            }

            terminal.printInfo("Transcribing...\n")
            try await engine.run()

            await engine.stop()
            writer.flush()
            terminal.printSummary(
                duration: Date().timeIntervalSince(startTime),
                wordCount: writer.wordCount,
                filePath: outputPath
            )
        }
    }

    /// Run live mic + system audio recording and transcription.
    private func runLiveRecording(transcriptsDir: URL, effectiveShowInterim: Bool) async throws {
        // Parse speaker names
        let speakerNames = parseSpeakerNames(speakers)
        let micSpeaker = speakerNames.0
        let systemSpeaker = speakerNames.1

        // Determine output file
        let resumeTarget = try resolveResumeTarget(resumeFile: resumeFile, resume: resume, resumeLast: resumeLast, transcriptsDir: transcriptsDir)

        let (filePath, isResume) = try resolveOutputFile(
            transcriptsDir: transcriptsDir,
            title: sanitizeTitle(title),
            resume: resumeTarget
        )

        let terminal = TerminalUI(micSpeaker: micSpeaker, systemSpeaker: systemSpeaker, showInterim: effectiveShowInterim)

        if isResume {
            terminal.printInfo("Resuming: \(filePath.path)")
        } else {
            terminal.printInfo("Transcribing to: \(filePath.path)")
        }

        // Ensure speech model is available
        terminal.printInfo("Checking speech model availability...")
        try await ensureSpeechModel(terminal: terminal)

        // Set up markdown writer
        let writer = try MarkdownWriter(
            filePath: filePath,
            title: sanitizeTitle(title) ?? defaultTitle(),
            isResume: isResume,
            micSpeaker: micSpeaker,
            systemSpeaker: systemSpeaker
        )

        // Set up audio capture
        terminal.printInfo("Starting audio capture...")
        let capture = AudioCapture()
        do {
            try await capture.checkPermissions()
        } catch let error as TranscribeError {
            printPermissionError(error)
            Foundation.exit(1)
        }

        // Set up recording
        let micRecordingPath: URL?
        let sysRecordingPath: URL?

        if saveRecording && !isResume {
            let basePath = filePath.deletingPathExtension()
            micRecordingPath = basePath.appendingPathExtension("mic.caf")
            sysRecordingPath = basePath.appendingPathExtension("sys.caf")

            let micRecorder = AudioRecorder()
            do {
                try micRecorder.start(filePath: micRecordingPath!)
            } catch {
                try? FileManager.default.removeItem(at: micRecordingPath!)
                throw error
            }
            capture.micRecorder = micRecorder

            let sysRecorder = AudioRecorder()
            do {
                try sysRecorder.start(filePath: sysRecordingPath!)
            } catch {
                micRecorder.stop()
                try? FileManager.default.removeItem(at: micRecordingPath!)
                try? FileManager.default.removeItem(at: sysRecordingPath!)
                throw error
            }
            capture.systemRecorder = sysRecorder
        } else {
            micRecordingPath = nil
            sysRecordingPath = nil
            if isResume {
                terminal.printInfo("Recording skipped (resume mode)")
            }
        }

        do {
            try await capture.start()
        } catch {
            await capture.stop()
            capture.micRecorder?.stop()
            capture.systemRecorder?.stop()
            if let micPath = micRecordingPath {
                try? FileManager.default.removeItem(at: micPath)
            }
            if let sysPath = sysRecordingPath {
                try? FileManager.default.removeItem(at: sysPath)
            }
            throw error
        }

        // Set up transcription engine
        let engine = try await TranscriptionEngine(
            audioCapture: capture,
            writer: writer,
            terminal: terminal,
            micSpeaker: micSpeaker,
            systemSpeaker: systemSpeaker,
            showInterim: effectiveShowInterim
        )

        // Build shutdown closure (shared by Ctrl+C and Escape)
        let startTime = Date()
        let recordingPaths = [micRecordingPath, sysRecordingPath].compactMap { $0 }
        let keepRaw = self.keepRawRecordings
        let hasRecording = saveRecording && !isResume

        let shutdown: @Sendable () -> Void = {
            // Thread-safe guard against duplicate shutdown (atomic check-and-set)
            let alreadyShuttingDown = _shutdownLock.withLock { isShuttingDown -> Bool in
                if isShuttingDown { return true }
                isShuttingDown = true
                return false
            }
            guard !alreadyShuttingDown else { return }

            Task {
                await engine.stop()
                await capture.stop()
                capture.micRecorder?.stop()
                capture.systemRecorder?.stop()
                writer.flush()

                // Merge and compress recordings
                var finalRecordingPaths = recordingPaths
                if hasRecording, let micPath = micRecordingPath, let sysPath = sysRecordingPath {
                    let m4aPath = filePath.deletingPathExtension().appendingPathExtension("m4a")
                    terminal.printInfo("Merging recordings to \(m4aPath.lastPathComponent)...")
                    do {
                        try AudioMerger.mergeToStereoAAC(
                            micPath: micPath,
                            sysPath: sysPath,
                            outputPath: m4aPath
                        )
                        finalRecordingPaths = [m4aPath] + (keepRaw ? recordingPaths : [])

                        // Delete originals unless --keep-raw-recordings
                        if !keepRaw {
                            try? FileManager.default.removeItem(at: micPath)
                            try? FileManager.default.removeItem(at: sysPath)
                            terminal.printInfo("Raw CAF files deleted (use --keep-raw-recordings to preserve).")
                        }
                    } catch {
                        terminal.printError("Failed to merge recordings: \(error.localizedDescription)")
                        terminal.printInfo("Raw recordings preserved at original paths.")
                    }
                }

                terminal.printSummary(
                    duration: Date().timeIntervalSince(startTime),
                    wordCount: writer.wordCount,
                    filePath: filePath,
                    recordingPaths: finalRecordingPaths
                )
                restoreTerminal()
                Foundation.exit(0)
            }
        }

        // Handle Ctrl+C
        setupSignalHandler { shutdown() }

        // Handle Escape key
        setupEscapeKeyHandler { shutdown() }

        terminal.printInfo("Transcribing... Press Escape or Ctrl+C to stop.\n")

        // Print existing transcript lines when resuming (after all status messages)
        if isResume {
            printExistingTranscript(filePath: filePath, terminal: terminal)
        }

        // Ensure cleanup on any exit path (throw, natural return)
        defer {
            capture.micRecorder?.stop()
            capture.systemRecorder?.stop()
            writer.flush()
            restoreTerminal()
        }

        // Run transcription until stopped
        try await engine.run()
    }
}

// MARK: - Helpers

func parseSpeakerNames(_ raw: String?) -> (String, String) {
    guard let raw, !raw.isEmpty else {
        return ("Local", "Remote")
    }
    let parts = raw.split(separator: ",", maxSplits: 1).map {
        sanitizeSpeakerName(String($0.trimmingCharacters(in: .whitespaces)))
    }
    let mic = parts.first ?? "Local"
    let system = parts.count > 1 ? parts[1] : "Remote"
    return (mic, system)
}

func sanitizeSpeakerName(_ name: String) -> String {
    var cleaned = name
    cleaned = cleaned.filter { !$0.isNewline && $0.asciiValue.map({ $0 >= 32 }) ?? true }
    cleaned = cleaned.replacingOccurrences(of: "**", with: "")
    cleaned = cleaned.replacingOccurrences(of: "__", with: "")
    cleaned = cleaned.replacingOccurrences(of: "`", with: "")
    if cleaned.count > 50 { cleaned = String(cleaned.prefix(50)) }
    return cleaned.isEmpty ? "Speaker" : cleaned
}

func sanitizeTitle(_ title: String?) -> String? {
    guard var t = title, !t.isEmpty else { return nil }
    t = t.filter { !$0.isNewline && $0.asciiValue.map({ $0 >= 32 }) ?? true }
    if t.count > 200 { t = String(t.prefix(200)) }
    return t.isEmpty ? nil : t
}

func defaultTitle() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return "Recording — \(formatter.string(from: Date()))"
}

func slugify(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-"))
    return text.lowercased()
        .replacingOccurrences(of: " ", with: "-")
        .unicodeScalars.filter { allowed.contains($0) }
        .map { String($0) }.joined()
}

func resolveOutputFile(transcriptsDir: URL, title: String?, resume: String?) throws -> (URL, Bool) {
    try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

    if let resumeName = resume {
        let filename = (resumeName as NSString).lastPathComponent
        guard !filename.contains(".."), filename == resumeName else {
            throw ValidationError("--resume-file accepts filename only (no paths). Use just the filename from ~/Documents/transcripts/")
        }
        let filePath = transcriptsDir.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            throw ValidationError("File not found: \(filename). Use --list to see available recordings.")
        }
        return (filePath, true)
    }

    // New recording
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd-HHmm"
    let dateTime = formatter.string(from: Date())
    let slug = slugify(title ?? "recording")
    let filename = "\(slug)-\(dateTime).md"
    let filePath = transcriptsDir.appendingPathComponent(filename)

    return (filePath, false)
}

/// Resolve the resume target based on CLI flags.
/// - `resumeFile` takes priority (explicit filename).
/// - `resume` or `resumeLast` flag selects the most recent recording.
/// - Returns nil if no resume flags are set.
func resolveResumeTarget(resumeFile: String?, resume: Bool, resumeLast: Bool, transcriptsDir: URL) throws -> String? {
    if let resumeFile { return resumeFile }
    if resume || resumeLast { return try mostRecentRecording(in: transcriptsDir) }
    return nil
}

func mostRecentRecording(in dir: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: dir.path) else {
        throw ValidationError("No recordings found. Record something first.")
    }
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        .filter { $0.pathExtension == "md" }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }
    guard let most = files.first else {
        throw ValidationError("No recordings found in \(dir.path). Record something first.")
    }
    return most.lastPathComponent
}

/// A parsed transcript line: speaker name and spoken text.
struct TranscriptLine: Equatable {
    let speaker: String
    let text: String
}

/// Parse finalized speaker lines from transcript markdown content.
/// Matches lines like: `**Speaker Name** (12:34:56): Some transcript text`
/// Strips ANSI/control characters from parsed content to prevent terminal injection.
func parseTranscriptLines(from content: String) -> [TranscriptLine] {
    let pattern = #/^\*\*(.+?)\*\*\s*\([^)]*\):\s*(.+)$/#
    var results: [TranscriptLine] = []
    for line in content.components(separatedBy: .newlines) {
        if let match = line.firstMatch(of: pattern) {
            let speaker = stripControlChars(String(match.1))
            let text = stripControlChars(String(match.2))
            results.append(TranscriptLine(speaker: speaker, text: text))
        }
    }
    return results
}

/// Strip ANSI escape sequences and control characters (except space) from a string.
private func stripControlChars(_ str: String) -> String {
    // Remove ANSI escape sequences first
    var cleaned = str.replacingOccurrences(of: "\u{001B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
    // Remove remaining control characters (ASCII < 32, except space isn't < 32)
    cleaned = cleaned.filter { char in
        guard let ascii = char.asciiValue else { return true }
        return ascii >= 32
    }
    return cleaned
}

/// Read an existing transcript file and print all finalized speaker lines to the TUI.
/// Uses line-by-line enumeration to avoid loading large files entirely into memory.
func printExistingTranscript(filePath: URL, terminal: TerminalUI) {
    guard let contents = try? String(contentsOf: filePath, encoding: .utf8) else {
        terminal.printInfo("Could not read previous transcript: \(filePath.lastPathComponent)")
        return
    }

    let lines = parseTranscriptLines(from: contents)
    for line in lines {
        terminal.printExistingLine(speaker: line.speaker, text: line.text)
    }
    if !lines.isEmpty {
        terminal.printInfo("Loaded \(lines.count) previous line\(lines.count == 1 ? "" : "s")")
        // Print a blank line to separate old transcript from new
        print("")
    }
}

func listRecordings(in dir: URL) throws {
    guard FileManager.default.fileExists(atPath: dir.path) else {
        print("No recordings found. Directory does not exist: \(dir.path)")
        return
    }
    let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        .filter { $0.pathExtension == "md" }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da > db
        }

    if files.isEmpty {
        print("No recordings found in \(dir.path)")
        return
    }

    print("Past recordings (\(dir.path)):\n")
    let dateFmt = DateFormatter()
    dateFmt.dateStyle = .medium
    dateFmt.timeStyle = .short
    for file in files {
        let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { dateFmt.string(from: $0) } ?? "unknown date"
        print("  \(file.lastPathComponent)  (\(date))")
    }
}

// MARK: - Install Skill

func installSkillFiles(installClaude: Bool, installAgents: Bool, force: Bool) throws {
    let fm = FileManager.default

    // Find SKILL.md relative to the running binary
    let execURL = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let binDir = execURL.deletingLastPathComponent()
    let skillRelPath = ".agents/skills/transcribe-audio/SKILL.md"
    var candidates: [URL] = []
    // Walk up from binary directory looking for the skill file
    var dir = binDir
    for _ in 0..<5 {
        candidates.append(dir.appendingPathComponent(skillRelPath))
        dir = dir.deletingLastPathComponent()
    }

    guard let sourcePath = candidates.first(where: { fm.fileExists(atPath: $0.path) }) else {
        let searched = candidates.map(\.path).joined(separator: "\n  ")
        throw ValidationError("Could not find SKILL.md relative to binary at \(execURL.path)\nSearched:\n  \(searched)")
    }

    let home = fm.homeDirectoryForCurrentUser
    var targets: [URL] = []
    if installClaude { targets.append(home.appendingPathComponent(".claude/skills/transcribe-audio")) }
    if installAgents { targets.append(home.appendingPathComponent(".agents/skills/transcribe-audio")) }

    var failures = 0
    for targetDir in targets {
        let targetPath = targetDir.appendingPathComponent("SKILL.md")

        // Check if target already exists
        if fm.fileExists(atPath: targetPath.path) || (try? fm.destinationOfSymbolicLink(atPath: targetPath.path)) != nil {
            if !force {
                fputs("Error: \(targetPath.path) already exists (use --force to overwrite)\n", stderr)
                failures += 1
                continue
            }
            try fm.removeItem(at: targetPath)
        }

        // Ensure the directory path is clean (remove broken symlinks or files at directory path)
        let dirPath = targetDir.path
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: dirPath, isDirectory: &isDir) {
            if !isDir.boolValue {
                try fm.removeItem(atPath: dirPath)
            }
        } else {
            // Path doesn't exist but may be a broken symlink
            let attrs = try? fm.attributesOfItem(atPath: dirPath)
            if attrs != nil || (try? fm.destinationOfSymbolicLink(atPath: dirPath)) != nil {
                try fm.removeItem(atPath: dirPath)
            }
        }

        try fm.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: targetPath.path, withDestinationPath: sourcePath.path)
        print("Installed: \(targetPath.path) -> \(sourcePath.path)")
    }

    if failures > 0 {
        throw ExitCode(1)
    }
}

/// Retained globally so the dispatch source isn't deallocated.
private nonisolated(unsafe) var _signalSource: DispatchSourceSignal?

/// Terminal state protected by a lock to prevent data races between
/// the signal handler (main queue), Escape key handler (global queue),
/// cancel handler, and atexit handler.
private struct TerminalState {
    var stdinSource: DispatchSourceRead?
    var savedTermios: termios?
}
private let _terminalLock = OSAllocatedUnfairLock(initialState: TerminalState())

/// Print a detailed permission error with troubleshooting steps to stderr.
func printPermissionError(_ error: TranscribeError) {
    switch error {
    case .permissionsDenied(let errors):
        for err in errors {
            printPermissionError(err)
        }
    case .micPermissionDenied:
        fputs("""
        Error: Microphone access denied.

        Your terminal app needs permission to access the Microphone.

        1. Grant permission — macOS should prompt automatically on first use.
           If it doesn't, try running this app again.

        2. If previously denied, reset the permission first, then re-run:
           tccutil reset Microphone <bundle-id>

           Find your terminal's bundle ID:
           osascript -e 'id of app "iTerm"'  (replace iTerm with your terminal app name)

        3. Check System Settings > Privacy & Security > Microphone
           and ensure your terminal app is allowed.

        Then retry: transcribe

        """, stderr)
    case .screenRecordingPermissionDenied:
        fputs("""
        Error: Screen Recording access denied (needed for system audio capture).

        Your terminal app needs Screen Recording permission to capture system audio.

        1. Grant permission — macOS should prompt automatically on first use.
           If it doesn't, try running this app again.

        2. If previously denied, reset the permission first, then re-run:
           tccutil reset ScreenCapture <bundle-id>

           Find your terminal's bundle ID:
           osascript -e 'id of app "iTerm"'  (replace iTerm with your terminal app name)

        3. Check System Settings > Privacy & Security > Screen Recording
           and ensure your terminal app is allowed. You may need to restart the terminal after granting access.

        Then retry: transcribe

        """, stderr)
    default:
        fputs("Error: \(error.localizedDescription)\n", stderr)
    }
}

func setupSignalHandler(_ handler: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { handler() }
    source.resume()
    _signalSource = source
}

/// Set up raw-mode stdin listener that triggers handler on Escape key.
/// No-op if stdin is not a terminal (e.g., piped input).
/// Restores terminal settings when handler fires or on normal exit.
func setupEscapeKeyHandler(_ handler: @escaping () -> Void) {
    guard isatty(STDIN_FILENO) != 0 else { return }

    var oldTermios = termios()
    guard tcgetattr(STDIN_FILENO, &oldTermios) == 0 else { return }
    let savedOldTermios = oldTermios

    var raw = oldTermios
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
        let base = UnsafeMutableRawPointer(ptr)
            .assumingMemoryBound(to: cc_t.self)
        base[Int(VMIN)] = 1
        base[Int(VTIME)] = 0
    }
    guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return }

    _terminalLock.withLock { state in
        state.savedTermios = savedOldTermios
    }

    atexit {
        restoreTerminal()
    }

    let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInitiated))
    source.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 1)
        let n = read(STDIN_FILENO, &buf, 1)
        if n == 1 && buf[0] == 0x1B {
            restoreTerminal()
            handler()
        }
    }
    source.setCancelHandler {
        restoreTerminal()
    }
    source.resume()
    _terminalLock.withLock { state in
        state.stdinSource = source
    }
}

func restoreTerminal() {
    _terminalLock.withLock { state in
        if var saved = state.savedTermios {
            tcsetattr(STDIN_FILENO, TCSANOW, &saved)
            state.savedTermios = nil
        }
        state.stdinSource?.cancel()
        state.stdinSource = nil
    }
}

#if compiler(>=6.2)
@available(macOS 26.0, *)
func ensureSpeechModel(terminal: TerminalUI) async throws {
    let locales = await SpeechTranscriber.installedLocales
    let englishAvailable = locales.contains { $0.identifier.hasPrefix("en") }
    if !englishAvailable {
        let supported = await SpeechTranscriber.supportedLocales
        if supported.contains(where: { $0.identifier.hasPrefix("en") }) {
            terminal.printInfo("English speech model not yet installed. It will be downloaded on first use.")
            terminal.printInfo("If transcription fails, try using Dictation in System Settings first to trigger model download.")
        } else {
            throw TranscribeError.modelUnavailable("English locale not supported on this system.")
        }
    } else {
        terminal.printInfo("Speech model available.")
    }
}
#else
func ensureSpeechModel(terminal: TerminalUI) async throws {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized ||
          SFSpeechRecognizer.authorizationStatus() == .notDetermined else {
        throw TranscribeError.modelUnavailable("Speech recognition not authorized. Check System Settings > Privacy & Security > Speech Recognition.")
    }
    guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
          recognizer.isAvailable else {
        throw TranscribeError.modelUnavailable("Speech recognizer not available for English.")
    }
    terminal.printInfo("Speech recognizer available.")
}
#endif
