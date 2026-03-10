import ArgumentParser
import Foundation
import Speech

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

    @Option(name: .long, help: "Comma-separated speaker names (e.g. \"Jack,Jeanne\"). First is mic, second is system audio.")
    var speakers: String?

    mutating func run() async throws {
        let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcripts")

        if list {
            try listRecordings(in: transcriptsDir)
            return
        }

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

        let terminal = TerminalUI(micSpeaker: micSpeaker, systemSpeaker: systemSpeaker)

        if isResume {
            terminal.printInfo("Resuming: \(filePath.lastPathComponent)")
        } else {
            terminal.printInfo("Recording to: \(filePath.lastPathComponent)")
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
        try await capture.checkPermissions()
        try await capture.start()

        // Set up transcription engine
        let engine = try await TranscriptionEngine(
            audioCapture: capture,
            writer: writer,
            terminal: terminal,
            micSpeaker: micSpeaker,
            systemSpeaker: systemSpeaker
        )

        // Handle Ctrl+C
        let startTime = Date()
        setupSignalHandler {
            Task {
                await engine.stop()
                capture.stop()
                writer.flush()
                terminal.printSummary(
                    duration: Date().timeIntervalSince(startTime),
                    wordCount: writer.wordCount,
                    filePath: filePath
                )
                Foundation.exit(0)
            }
        }

        terminal.printInfo("Recording... Press Ctrl+C to stop.\n")

        // Run transcription until stopped
        try await engine.run()
    }
}

// MARK: - Helpers

func parseSpeakerNames(_ raw: String?) -> (String, String) {
    guard let raw, !raw.isEmpty else {
        return ("You", "Remote")
    }
    let parts = raw.split(separator: ",", maxSplits: 1).map {
        sanitizeSpeakerName(String($0.trimmingCharacters(in: .whitespaces)))
    }
    let mic = parts.first ?? "You"
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
    formatter.dateFormat = "yyyy-MM-dd"
    let dateStr = formatter.string(from: Date())
    let titleSlug = slugify(title ?? defaultTitle())
    let filename = "\(dateStr)-\(titleSlug).md"
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

func setupSignalHandler(_ handler: @escaping () -> Void) {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    source.setEventHandler { handler() }
    source.resume()
}

@available(macOS 26.0, *)
func ensureSpeechModel(terminal: TerminalUI) async throws {
    // Check if speech transcription locale is available
    let locales = await SpeechTranscriber.installedLocales
    let englishAvailable = locales.contains { $0.identifier.hasPrefix("en") }
    if !englishAvailable {
        // Check if it's at least supported (can be downloaded)
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
