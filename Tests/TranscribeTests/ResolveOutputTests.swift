import Foundation
import Testing
@testable import transcribe

@Suite("Resolve Output File")
struct ResolveOutputTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func newRecordingCreatesPath() throws {
        defer { cleanup() }
        let (path, isResume) = try resolveOutputFile(transcriptsDir: tmpDir, title: "Test Meeting", resume: nil)
        #expect(!isResume)
        #expect(path.pathExtension == "md")
        #expect(path.lastPathComponent.hasPrefix("test-meeting-"))
        #expect(path.deletingLastPathComponent().path == tmpDir.path)
    }

    @Test func newRecordingWithoutTitleUsesRecordingPrefix() throws {
        defer { cleanup() }
        let (path, isResume) = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: nil)
        #expect(!isResume)
        #expect(path.pathExtension == "md")
        #expect(path.lastPathComponent.hasPrefix("recording-"))
        // Should NOT contain a double date (the old bug)
        let name = path.lastPathComponent
        let datePattern = #/\d{4}-\d{2}-\d{2}/#
        let matches = name.matches(of: datePattern)
        #expect(matches.count == 1, "Date should appear exactly once in filename, got: \(name)")
    }

    @Test func resumeWithValidFile() throws {
        defer { cleanup() }
        let filename = "2026-03-10-test.md"
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent(filename).path, contents: nil)

        let (path, isResume) = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: filename)
        #expect(isResume)
        #expect(path.lastPathComponent == filename)
    }

    @Test func resumeWithPathTraversal() throws {
        defer { cleanup() }
        #expect(throws: (any Error).self) {
            _ = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: "../etc/passwd")
        }
    }

    @Test func resumeWithAbsolutePath() throws {
        defer { cleanup() }
        #expect(throws: (any Error).self) {
            _ = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: "/etc/passwd")
        }
    }

    @Test func resumeWithNonExistentFile() throws {
        defer { cleanup() }
        #expect(throws: (any Error).self) {
            _ = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: "nonexistent.md")
        }
    }

    @Test func resumeWithSubdirectoryPath() throws {
        defer { cleanup() }
        let subdir = tmpDir.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: subdir.appendingPathComponent("file.md").path, contents: nil)

        #expect(throws: (any Error).self) {
            _ = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: "sub/file.md")
        }
    }

    @Test func resumeWithDot() throws {
        defer { cleanup() }
        // "." passes filename validation and exists as the dir itself — accepted behavior
        let (path, isResume) = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: ".")
        #expect(isResume)
        #expect(path.lastPathComponent == ".")
    }

    @Test func resumeWithSymlinkInsideDir() throws {
        defer { cleanup() }
        let outsideFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).md")
        FileManager.default.createFile(atPath: outsideFile.path, contents: "outside".data(using: .utf8))
        defer { try? FileManager.default.removeItem(at: outsideFile) }

        let symlinkPath = tmpDir.appendingPathComponent("evil.md")
        try FileManager.default.createSymbolicLink(at: symlinkPath, withDestinationURL: outsideFile)

        let (path, isResume) = try resolveOutputFile(transcriptsDir: tmpDir, title: nil, resume: "evil.md")
        #expect(isResume)
        #expect(path.deletingLastPathComponent().path == tmpDir.path)
    }
}

@Suite("Most Recent Recording")
struct MostRecentRecordingTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func emptyDirectory() throws {
        defer { cleanup() }
        #expect(throws: (any Error).self) {
            _ = try mostRecentRecording(in: tmpDir)
        }
    }

    @Test func nonExistentDirectory() throws {
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID())")
        #expect(throws: (any Error).self) {
            _ = try mostRecentRecording(in: fakeDir)
        }
    }

    @Test func returnsNewest() throws {
        defer { cleanup() }
        let older = tmpDir.appendingPathComponent("older.md")
        let newer = tmpDir.appendingPathComponent("newer.md")
        FileManager.default.createFile(atPath: older.path, contents: nil)
        Thread.sleep(forTimeInterval: 0.1)
        FileManager.default.createFile(atPath: newer.path, contents: nil)

        let result = try mostRecentRecording(in: tmpDir)
        #expect(result == "newer.md")
    }

    @Test func ignoresNonMdFiles() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("notes.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("data.json").path, contents: nil)

        #expect(throws: (any Error).self) {
            _ = try mostRecentRecording(in: tmpDir)
        }
    }

    @Test func mdOnlyAmongMixed() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("notes.txt").path, contents: nil)
        Thread.sleep(forTimeInterval: 0.1)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("recording.md").path, contents: nil)

        let result = try mostRecentRecording(in: tmpDir)
        #expect(result == "recording.md")
    }
}

@Suite("Resume Target Resolution")
struct ResumeTargetTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func noFlagsReturnsNil() throws {
        defer { cleanup() }
        let result = try resolveResumeTarget(resumeFile: nil, resume: false, resumeLast: false, transcriptsDir: tmpDir)
        #expect(result == nil)
    }

    @Test func resumeFlagSelectsMostRecent() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("old.md").path, contents: nil)
        Thread.sleep(forTimeInterval: 0.1)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("new.md").path, contents: nil)

        let result = try resolveResumeTarget(resumeFile: nil, resume: true, resumeLast: false, transcriptsDir: tmpDir)
        #expect(result == "new.md")
    }

    @Test func resumeLastFlagSelectsMostRecent() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("old.md").path, contents: nil)
        Thread.sleep(forTimeInterval: 0.1)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("new.md").path, contents: nil)

        let result = try resolveResumeTarget(resumeFile: nil, resume: false, resumeLast: true, transcriptsDir: tmpDir)
        #expect(result == "new.md")
    }

    @Test func resumeFileReturnsExplicitFilename() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("new.md").path, contents: nil)

        let result = try resolveResumeTarget(resumeFile: "specific.md", resume: false, resumeLast: false, transcriptsDir: tmpDir)
        #expect(result == "specific.md")
    }

    @Test func resumeFileTakesPriorityOverResumeFlag() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("new.md").path, contents: nil)

        let result = try resolveResumeTarget(resumeFile: "specific.md", resume: true, resumeLast: false, transcriptsDir: tmpDir)
        #expect(result == "specific.md")
    }
}
