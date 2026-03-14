import Foundation
import Testing
@testable import transcribe

@Suite("MarkdownWriter")
struct MarkdownWriterTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-writer-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func newFileCreatesHeader() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("test.md")
        let writer = try MarkdownWriter(
            filePath: path,
            title: "Test Meeting",
            isResume: false,
            micSpeaker: "You",
            systemSpeaker: "Remote"
        )
        writer.flush()

        let content = try String(contentsOf: path, encoding: .utf8)
        #expect(content.hasPrefix("# Test Meeting"))
        #expect(content.contains("—"))
    }

    @Test func newFileHas0600Permissions() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("perms.md")
        _ = try MarkdownWriter(
            filePath: path,
            title: "Test",
            isResume: false,
            micSpeaker: "You",
            systemSpeaker: "Remote"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func resumeAppendsSeparator() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("resume.md")
        try "# Original\n\n".write(to: path, atomically: true, encoding: .utf8)

        let writer = try MarkdownWriter(
            filePath: path,
            title: "Test",
            isResume: true,
            micSpeaker: "You",
            systemSpeaker: "Remote"
        )
        writer.flush()

        let content = try String(contentsOf: path, encoding: .utf8)
        #expect(content.hasPrefix("# Original"))
        #expect(content.contains("---"))
        #expect(content.contains("Resumed at"))
    }

    @Test func resumeNonExistentThrows() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("nonexistent.md")
        #expect(throws: (any Error).self) {
            _ = try MarkdownWriter(
                filePath: path,
                title: "Test",
                isResume: true,
                micSpeaker: "You",
                systemSpeaker: "Remote"
            )
        }
    }

    @Test func writeLineFormat() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("format.md")
        let writer = try MarkdownWriter(
            filePath: path,
            title: "Test",
            isResume: false,
            micSpeaker: "You",
            systemSpeaker: "Remote"
        )

        writer.writeLine(speaker: "You", text: "Hello world", wallClockTime: mach_continuous_time())
        writer.flush()

        let content = try String(contentsOf: path, encoding: .utf8)
        #expect(content.contains("**You**"))
        #expect(content.contains("Hello world"))
        let timestampPattern = #/\(\d{2}:\d{2}:\d{2}\)/#
        #expect(content.contains(timestampPattern))
    }

    @Test func wordCountTracking() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("wordcount.md")
        let writer = try MarkdownWriter(
            filePath: path,
            title: "Test",
            isResume: false,
            micSpeaker: "You",
            systemSpeaker: "Remote"
        )

        let time = mach_continuous_time()
        writer.writeLine(speaker: "You", text: "Hello world", wallClockTime: time)
        writer.writeLine(speaker: "Remote", text: "Three more words", wallClockTime: time + 1000)

        #expect(writer.wordCount == 5)
    }

    @Test func multipleWriteLines() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("multi.md")
        let writer = try MarkdownWriter(
            filePath: path,
            title: "Test",
            isResume: false,
            micSpeaker: "You",
            systemSpeaker: "Remote"
        )

        let time = mach_continuous_time()
        writer.writeLine(speaker: "You", text: "First line", wallClockTime: time)
        writer.writeLine(speaker: "Remote", text: "Second line", wallClockTime: time + 1000)
        writer.flush()

        let content = try String(contentsOf: path, encoding: .utf8)
        #expect(content.contains("**You**"))
        #expect(content.contains("**Remote**"))
        #expect(content.contains("First line"))
        #expect(content.contains("Second line"))
    }
}
