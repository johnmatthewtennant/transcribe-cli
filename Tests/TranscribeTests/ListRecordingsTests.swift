import Foundation
import Testing
@testable import transcribe

@Suite("List Recordings")
struct ListRecordingsTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-list-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func nonExistentDirectoryDoesNotThrow() throws {
        let fakeDir = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID())")
        try listRecordings(in: fakeDir)
    }

    @Test func emptyDirectoryDoesNotThrow() throws {
        defer { cleanup() }
        try listRecordings(in: tmpDir)
    }

    @Test func listsMdFilesOnly() throws {
        defer { cleanup() }
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("recording.md").path, contents: nil)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("notes.txt").path, contents: nil)
        FileManager.default.createFile(atPath: tmpDir.appendingPathComponent("data.json").path, contents: nil)

        try listRecordings(in: tmpDir)
    }
}
