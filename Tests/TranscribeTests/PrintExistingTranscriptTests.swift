import Foundation
import Testing
@testable import transcribe

@Suite("Print Existing Transcript on Resume")
struct PrintExistingTranscriptTests {
    let mic = "Local"
    let sys = "Remote"

    /// Creates a temporary markdown transcript file with the given content.
    private func makeTempFile(content: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("test-transcript.md")
        try content.write(to: file, atomically: true, encoding: .utf8)
        return file
    }

    @Test func parsesStandardTranscriptLines() throws {
        let content = """
        # Meeting — 2026-03-20 10:00

        **Local** (10:00:05): Hello everyone, welcome to the meeting.

        **Remote** (10:00:12): Thanks, glad to be here.

        **Local** (10:01:30): Let's get started with the agenda.

        """
        let file = try makeTempFile(content: content)
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)

        // Should not crash; prints 3 lines to stdout
        printExistingTranscript(filePath: file, terminal: terminal)

        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func handlesEmptyFile() throws {
        let file = try makeTempFile(content: "")
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)

        // Should not crash, no output
        printExistingTranscript(filePath: file, terminal: terminal)

        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func handlesFileWithNoSpeakerLines() throws {
        let content = """
        # Meeting — 2026-03-20 10:00

        ---

        *Resumed at 10:30*

        """
        let file = try makeTempFile(content: content)
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)

        // Should not crash, no speaker lines to print
        printExistingTranscript(filePath: file, terminal: terminal)

        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func handlesResumedTranscriptWithMultipleSections() throws {
        let content = """
        # Meeting — 2026-03-20 10:00

        **Local** (10:00:05): First section line.

        **Remote** (10:00:12): Another line.

        ---

        *Resumed at 10:30*

        **Local** (10:30:01): After resume line.

        """
        let file = try makeTempFile(content: content)
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)

        // Should print all 3 speaker lines (from both sections)
        printExistingTranscript(filePath: file, terminal: terminal)

        try FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }

    @Test func handlesMissingFile() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).md")
        let terminal = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false)

        // Should not crash on missing file
        printExistingTranscript(filePath: bogus, terminal: terminal)
    }
}
