import Foundation

/// Writes transcript lines to a markdown file with speaker labels and timestamps.
/// Uses line-buffered I/O with explicit flush for crash durability.
final class MarkdownWriter: @unchecked Sendable {
    private let filePath: URL
    private let fileHandle: FileHandle
    private let startDate: Date
    private let referenceMachTime: UInt64
    private let lock = NSLock()
    private(set) var wordCount: Int = 0

    init(filePath: URL, title: String, isResume: Bool, micSpeaker: String, systemSpeaker: String,
         sourceAudioFilename: String? = nil) throws {
        self.filePath = filePath
        self.startDate = Date()
        self.referenceMachTime = mach_continuous_time()

        if isResume {
            // File must already exist
            guard FileManager.default.fileExists(atPath: filePath.path) else {
                throw TranscribeError.captureError("Resume file not found: \(filePath.lastPathComponent)")
            }
            self.fileHandle = try FileHandle(forWritingTo: filePath)
            fileHandle.seekToEndOfFile()

            // Write resume separator
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            let separator = "\n---\n\n*Resumed at \(formatter.string(from: Date()))*\n\n"
            fileHandle.write(separator.data(using: .utf8)!)
        } else {
            // Create new file with 0600 permissions
            let fm = FileManager.default
            fm.createFile(atPath: filePath.path, contents: nil, attributes: [.posixPermissions: 0o600])
            self.fileHandle = try FileHandle(forWritingTo: filePath)

            // Write header
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let header = "# \(title) — \(formatter.string(from: Date()))\n\n"
            fileHandle.write(header.data(using: .utf8)!)

            // Write source audio reference for file transcription mode
            if let sourceAudioFilename {
                let sourceLine = "*Source: \(sourceAudioFilename)*\n\n"
                fileHandle.write(sourceLine.data(using: .utf8)!)
            }
        }
    }

    /// Write a finalized transcript line.
    func writeLine(speaker: String, text: String, wallClockTime: UInt64) {
        lock.lock()
        defer { lock.unlock() }

        let timestamp = formatTimestamp(wallClockTime: wallClockTime)
        let line = "**\(speaker)** (\(timestamp)): \(text)\n\n"
        if let data = line.data(using: .utf8) {
            fileHandle.write(data)
            // Explicit flush for durability
            fileHandle.synchronizeFile()
        }
        wordCount += text.split(separator: " ").count
    }

    /// Flush any pending writes.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        fileHandle.synchronizeFile()
    }

    /// Format a wall-clock mach_continuous_time value as HH:mm:ss.
    private func formatTimestamp(wallClockTime: UInt64) -> String {
        // wallClockTime and referenceMachTime are both in mach_continuous_time units.
        // Compute the offset from session start, then add to startDate.
        let info = machTimebaseInfo()
        let offsetTicks = wallClockTime >= referenceMachTime
            ? wallClockTime - referenceMachTime
            : 0
        let offsetNanos = offsetTicks * UInt64(info.numer) / UInt64(info.denom)
        let offsetSeconds = Double(offsetNanos) / 1_000_000_000

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: startDate.addingTimeInterval(offsetSeconds))
    }

    private func machTimebaseInfo() -> mach_timebase_info_data_t {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }
}
