import Foundation
import Testing
@testable import transcribe

@Suite("Parse Transcript Lines")
struct ParseTranscriptLinesTests {

    // MARK: - Parsing correctness

    @Test func parsesStandardLines() {
        let content = """
        **Local** (10:00:05): Hello everyone, welcome to the meeting.

        **Remote** (10:00:12): Thanks, glad to be here.

        **Local** (10:01:30): Let's get started with the agenda.
        """
        let lines = parseTranscriptLines(from: content)
        #expect(lines.count == 3)
        #expect(lines[0] == TranscriptLine(speaker: "Local", text: "Hello everyone, welcome to the meeting."))
        #expect(lines[1] == TranscriptLine(speaker: "Remote", text: "Thanks, glad to be here."))
        #expect(lines[2] == TranscriptLine(speaker: "Local", text: "Let's get started with the agenda."))
    }

    @Test func parsesLinesAcrossResumeSections() {
        let content = """
        # Meeting — 2026-03-20 10:00

        **Alice** (10:00:05): First section.

        **Bob** (10:00:12): Before resume.

        ---

        *Resumed at 10:30*

        **Alice** (10:30:01): After resume.
        """
        let lines = parseTranscriptLines(from: content)
        #expect(lines.count == 3)
        #expect(lines[0].speaker == "Alice")
        #expect(lines[1].speaker == "Bob")
        #expect(lines[2].text == "After resume.")
    }

    @Test func returnsEmptyForNoSpeakerLines() {
        let content = """
        # Meeting — 2026-03-20 10:00

        ---

        *Resumed at 10:30*
        """
        let lines = parseTranscriptLines(from: content)
        #expect(lines.isEmpty)
    }

    @Test func returnsEmptyForEmptyString() {
        let lines = parseTranscriptLines(from: "")
        #expect(lines.isEmpty)
    }

    @Test func ignoresHeaderAndMetadata() {
        let content = """
        # Recording — 2026-03-20 12:58

        *Source: meeting.m4a*

        **Speaker** (12:58:01): Actual content.
        """
        let lines = parseTranscriptLines(from: content)
        #expect(lines.count == 1)
        #expect(lines[0].speaker == "Speaker")
    }

    // MARK: - Security: control character stripping

    @Test func stripsANSIEscapeSequences() {
        // Simulate a transcript with injected ANSI codes
        let content = "**Evil\u{001B}[31mUser** (10:00:00): Hello\u{001B}[0m world"
        let lines = parseTranscriptLines(from: content)
        #expect(lines.count == 1)
        #expect(lines[0].speaker == "EvilUser")
        #expect(lines[0].text == "Hello world")
    }

    @Test func stripsControlCharacters() {
        let content = "**Speaker** (10:00:00): Text with\u{07}bell and\u{08}backspace"
        let lines = parseTranscriptLines(from: content)
        #expect(lines.count == 1)
        #expect(!lines[0].text.contains("\u{07}"))
        #expect(!lines[0].text.contains("\u{08}"))
    }

    // MARK: - Format variants

    @Test func handlesMultiWordSpeakerNames() {
        let content = "**John T.** (10:00:00): Hello there."
        let lines = parseTranscriptLines(from: content)
        #expect(lines.count == 1)
        #expect(lines[0].speaker == "John T.")
    }

    @Test func handlesVariousTimestampFormats() {
        // HH:mm:ss
        let content1 = "**A** (10:00:05): Text one."
        #expect(parseTranscriptLines(from: content1).count == 1)

        // HH:mm
        let content2 = "**A** (10:00): Text two."
        #expect(parseTranscriptLines(from: content2).count == 1)

        // Longer timestamp
        let content3 = "**A** (2026-03-20 10:00:05): Text three."
        #expect(parseTranscriptLines(from: content3).count == 1)
    }
}

@Suite("Print Existing Transcript Integration")
struct PrintExistingTranscriptIntegrationTests {
    let mic = "Local"
    let sys = "Remote"

    private func makeTempFile(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test-transcript.md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func printDoesNotCrashOnMissingFile() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).md")
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)
        // Should not crash; prints an info message about unreadable file
        printExistingTranscript(filePath: bogus, terminal: terminal)
    }

    @Test func printDoesNotCrashOnEmptyFile() throws {
        let file = try makeTempFile(content: "")
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)
        printExistingTranscript(filePath: file, terminal: terminal)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func printHandlesRealTranscriptContent() throws {
        let content = """
        # Meeting — 2026-03-20 10:00

        **Local** (10:00:05): Hello.

        **Remote** (10:00:12): Hi there.
        """
        let file = try makeTempFile(content: content)
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)
        printExistingTranscript(filePath: file, terminal: terminal)
        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
