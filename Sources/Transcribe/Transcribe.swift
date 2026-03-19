import ArgumentParser
import Foundation
import os
import Speech

/// Thread-safe shutdown reentrancy guard.
private let _shutdownLock = OSAllocatedUnfairLock(initialState: false)

@available(macOS 26.0, *)
@main
struct Transcribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Record microphone + system audio and produce a real-time speaker-attributed transcript."
    )

    @Option(name: .long, help: "Title for the recording session.")
    var title: String?

    @Option(name: .long, help: "Resume a previous recording by filename. Use --resume-last for the most recent.")
    var resume: String?

    @Flag(name: .long, help: "Resume the most recent recording.")
    var resumeLast = false

    @Flag(name: .long, help: "List past recordings.")
    var list = false

    @Flag(name: .customLong("install-skill"), help: "Install the Claude Code skill (symlinks to ~/.claude/skills/ and ~/.agents/skills/).")
    var installSkill = false

    @Option(name: .long, help: "Comma-separated speaker names (e.g. \"Jack,Jeanne\"). First is mic, second is system audio.")
    var speakers: String?

    @Option(name: .long, help: "Path to an audio file (m4a, wav, mp3, caf, etc.) to transcribe offline.")
    var file: String?

    @Flag(name: .long, help: "Save the audio recording alongside the transcript.")
    var saveRecording = false

    @Flag(name: .long, help: "Show in-progress speech recognition text at the bottom of the terminal. Ignored when stdout is not a TTY.")
    var showInterim = false

    @Flag(name: .long, help: "Delete original mono CAF files after successful merge to M4A.")
    var deleteRawRecordings = false

    @Option(name: .long, help: "Path to a JSON dictionary file for correcting mistranscribed words. Default: ~/.config/transcribe/dictionary.json")
    var dictionary: String?

    @Flag(name: .long, help: "Disable the custom dictionary, even if the default file exists.")
    var noDictionary = false

    mutating func run() async throws {
        let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/transcripts")

        if list {
            try listRecordings(in: transcriptsDir)
            return
        }

        if installSkill {
            try installSkillFiles()
            return
        }

        let effectiveShowInterim = showInterim && isatty(STDOUT_FILENO) != 0

        // Load custom dictionary
        let customDictionary: CustomDictionary
        if noDictionary {
            customDictionary = .empty
        } else if let dictionaryPath = dictionary {
            customDictionary = try CustomDictionary.load(from: dictionaryPath)
        } else {
            customDictionary = CustomDictionary.loadDefault()
        }

        if customDictionary.count > 0 {
            fputs("Loaded custom dictionary with \(customDictionary.count) entries.\n", stderr)
        }

        if let file {
            try await runFileTranscription(file: file, transcriptsDir: transcriptsDir, effectiveShowInterim: effectiveShowInterim, dictionary: customDictionary)
        } else {
            try await runLiveRecording(transcriptsDir: transcriptsDir, effectiveShowInterim: effectiveShowInterim, dictionary: customDictionary)
        }
    }

    /// Transcribe an existing audio file.
    private func runFileTranscription(file: String, transcriptsDir: URL, effectiveShowInterim: Bool, dictionary: CustomDictionary) async throws {
        let fileURL = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            .standardizedFileURL

        // Use the filename (without extension) as default title
        let fileTitle = sanitizeTitle(title) ?? fileURL.deletingPathExtension().lastPathComponent
        let speakerName = speakers.flatMap { $0.split(separator: ",").first.map { sanitizeSpeakerName(String($0.trimmingCharacters(in: .whitespaces))) } } ?? "Speaker"

        let terminal = TerminalUI(micSpeaker: speakerName, systemSpeaker: speakerName, showInterim: effectiveShowInterim)
        terminal.printInfo("Transcribing file: \(fileURL.path)")

        // Ensure speech model is available
        terminal.printInfo("Checking speech model availability...")
        try await ensureSpeechModel(terminal: terminal)

        // Determine output file
        let resumeTarget: String? = if let resume { resume } else if resumeLast { try mostRecentRecording(in: transcriptsDir) } else { nil }
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
            micSpeaker: speakerName,
            systemSpeaker: speakerName,
            sourceAudioFilename: fileURL.lastPathComponent
        )

        // Set up file audio source
        let fileSource = try FileAudioSource(filePath: fileURL)

        // Set up transcription engine (single-channel)
        let engine = try await TranscriptionEngine(
            fileSource: fileSource,
            writer: writer,
            terminal: terminal,
            speaker: speakerName,
            showInterim: effectiveShowInterim,
            dictionary: dictionary
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

        // Run transcription — will complete when file is fully processed
        try await engine.run()

        // File transcription completes naturally (unlike live recording)
        await engine.stop()
        writer.flush()
        terminal.printSummary(
            duration: Date().timeIntervalSince(startTime),
            wordCount: writer.wordCount,
            filePath: outputPath
        )
    }

    /// Run live mic + system audio recording and transcription.
    private func runLiveRecording(transcriptsDir: URL, effectiveShowInterim: Bool, dictionary: CustomDictionary) async throws {
        // Parse speaker names
        let speakerNames = parseSpeakerNames(speakers)
        let micSpeaker = speakerNames.0
        let systemSpeaker = speakerNames.1

        // Determine output file
        let resumeTarget: String? = if let resume { resume } else if resumeLast { try mostRecentRecording(in: transcriptsDir) } else { nil }

        let (filePath, isResume) = try resolveOutputFile(
            transcriptsDir: transcriptsDir,
            title: sanitizeTitle(title),
            resume: resumeTarget
        )

        let terminal = TerminalUI(micSpeaker: micSpeaker, systemSpeaker: systemSpeaker, showInterim: effectiveShowInterim)

        if isResume {
            terminal.printInfo("Resuming: \(filePath.path)")
        } else {
            terminal.printInfo("Recording to: \(filePath.path)")
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
            showInterim: effectiveShowInterim,
            dictionary: dictionary
        )

        // Build shutdown closure (shared by Ctrl+C and Escape)
        let startTime = Date()
        let recordingPaths = [micRecordingPath, sysRecordingPath].compactMap { $0 }
        let deleteRaw = self.deleteRawRecordings
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
                        finalRecordingPaths = [m4aPath] + (deleteRaw ? [] : recordingPaths)

                        // Delete originals only if --delete-raw-recordings
                        if deleteRaw {
                            try? FileManager.default.removeItem(at: micPath)
                            try? FileManager.default.removeItem(at: sysPath)
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

        terminal.printInfo("Recording... Press Escape or Ctrl+C to stop.\n")

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
            throw ValidationError("--resume accepts filename only (no paths). Use just the filename from ~/.transcripts/")
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

func installSkillFiles() throws {
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
    let targets = [
        home.appendingPathComponent(".claude/skills/transcribe-audio"),
        home.appendingPathComponent(".agents/skills/transcribe-audio"),
    ]

    for dir in targets {
        let dirPath = dir.path
        let targetPath = dir.appendingPathComponent("SKILL.md").path

        // Remove existing symlink/file at the directory path if it's not a real directory
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

        if fm.fileExists(atPath: targetPath) {
            try fm.removeItem(atPath: targetPath)
        }
        try fm.createSymbolicLink(atPath: targetPath, withDestinationPath: sourcePath.path)
        print("Installed: \(targetPath) -> \(sourcePath.path)")
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
