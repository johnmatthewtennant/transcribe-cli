import Foundation
import Testing

/// End-to-end transcription test: generates speech audio with `say`, runs the transcribe binary,
/// and verifies the output transcript contains expected words.
///
/// Requires macOS 26+ with SpeechAnalyzer runtime support.
@Suite("End-to-End Transcription", .enabled(if: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26))
struct EndToEndTranscriptionTests {
    /// Path to the built transcribe binary.
    private static let binaryPath: String = {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // TranscribeTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // package root
        return packageRoot.appendingPathComponent(".build/debug/transcribe").path
    }()

    private let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Generate a speech audio file using macOS `say` command.
    private func generateSpeechFile(text: String, outputPath: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", outputPath.path, text]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "say command failed with status \(process.terminationStatus)")
        #expect(FileManager.default.fileExists(atPath: outputPath.path), "say did not produce output file")
    }

    /// Run the transcribe binary on an audio file with a timeout.
    /// The file transcription may not exit on its own, so we send SIGINT after a grace period
    /// to trigger graceful shutdown (which flushes the transcript).
    private func runTranscribe(
        audioFile: URL,
        title: String,
        timeoutSeconds: Int = 30
    ) throws -> (exitCode: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binaryPath)
        process.arguments = ["--file", audioFile.path, "--title", title]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Wait for the process to finish, or send SIGINT after timeout
        let deadline = Date().addingTimeInterval(TimeInterval(timeoutSeconds))
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
        }

        if process.isRunning {
            // Send SIGINT for graceful shutdown (triggers signal handler which flushes transcript)
            kill(process.processIdentifier, SIGINT)
            // Give it a few seconds to flush
            let flushDeadline = Date().addingTimeInterval(5)
            while process.isRunning && Date() < flushDeadline {
                Thread.sleep(forTimeInterval: 0.25)
            }
            if process.isRunning {
                process.terminate()
            }
        }

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        return (process.terminationStatus, stdout, stderr)
    }

    /// Find the most recently created transcript markdown file matching a title slug.
    private func findTranscriptFile(titleSlug: String) throws -> URL? {
        let transcriptsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Documents/transcripts")
        guard FileManager.default.fileExists(atPath: transcriptsDir.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(
            at: transcriptsDir,
            includingPropertiesForKeys: [.creationDateKey]
        )
        .filter { $0.pathExtension == "md" && $0.lastPathComponent.hasPrefix(titleSlug) }
        .sorted { a, b in
            let da = (try? a.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return da > db
        }
        return files.first
    }

    @Test(.timeLimit(.minutes(3)))
    func transcribeGeneratedSpeech() throws {
        defer { cleanup() }

        // 1. Generate speech audio — use a longer phrase so the speech model has enough
        //    audio to produce at least one finalized transcription result.
        let audioFile = tmpDir.appendingPathComponent("test-speech.aiff")
        let testPhrase = "Hello, this is a test of the transcription system. The quick brown fox jumps over the lazy dog. I am testing whether the speech recognition can accurately transcribe spoken words."
        try generateSpeechFile(text: testPhrase, outputPath: audioFile)

        // Verify the audio file was created and has content
        let attrs = try FileManager.default.attributesOfItem(atPath: audioFile.path)
        let fileSize = attrs[.size] as? UInt64 ?? 0
        #expect(fileSize > 0, "Generated audio file should not be empty")

        // 2. Run transcribe on the audio file
        //    Use a unique title so we can find the transcript file afterwards.
        let testID = UUID().uuidString.prefix(8)
        let title = "e2e-test-\(testID)"
        let titleSlug = title.lowercased()
        let result = try runTranscribe(audioFile: audioFile, title: title, timeoutSeconds: 45)

        // 3. Check stdout for transcribed text.
        //    showFinalized prints lines like "Speaker: <transcribed text>"
        //    Strip ANSI escape codes for matching.
        let ansiPattern = try NSRegularExpression(pattern: "\u{001B}\\[[0-9;]*m")
        let plainStdout = ansiPattern.stringByReplacingMatches(
            in: result.stdout,
            range: NSRange(result.stdout.startIndex..., in: result.stdout),
            withTemplate: ""
        ).lowercased()

        // 4. Also check the transcript file on disk
        var transcriptContent = ""
        if let transcriptFile = try findTranscriptFile(titleSlug: titleSlug) {
            transcriptContent = (try? String(contentsOf: transcriptFile, encoding: .utf8).lowercased()) ?? ""
            // Clean up the transcript file we created
            try? FileManager.default.removeItem(at: transcriptFile)
        }

        // 5. Combine stdout and transcript content for word matching
        let combinedOutput = plainStdout + " " + transcriptContent

        // 6. Assert key words are present (fuzzy matching)
        let expectedWords = ["quick", "brown", "fox", "lazy", "dog"]
        var matchedWords: [String] = []
        for word in expectedWords {
            if combinedOutput.contains(word) {
                matchedWords.append(word)
            }
        }

        // We expect at least 3 out of 5 key words to be recognized
        #expect(matchedWords.count >= 3,
                "Expected at least 3 of \(expectedWords) in output, but only found \(matchedWords). stdout:\n\(plainStdout)\ntranscript:\n\(transcriptContent)")
    }
}
