import AVFoundation
import Foundation
import Testing
@testable import transcribe

/// Helper to create a minimal WAV file programmatically for testing.
private func createTestWAVFile(
    at url: URL,
    sampleRate: Double = 16000,
    durationSeconds: Double = 0.5
) throws {
    let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
    guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
        throw TestError("Could not create audio format")
    }
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
        throw TestError("Could not create PCM buffer")
    }
    buffer.frameLength = frameCount

    // Fill with a simple sine wave so the file is not silent
    if let floatData = buffer.floatChannelData {
        let frequency: Double = 440.0
        for i in 0..<Int(frameCount) {
            floatData[0][i] = Float(sin(2.0 * Double.pi * frequency * Double(i) / sampleRate) * 0.5)
        }
    }

    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

@Suite("FileAudioSource")
struct FileAudioSourceTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-file-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    @Test func initWithNonexistentFileThrows() throws {
        defer { cleanup() }
        let fakePath = tmpDir.appendingPathComponent("does-not-exist.wav")
        #expect(throws: TranscribeError.self) {
            _ = try FileAudioSource(filePath: fakePath)
        }
    }

    @Test func initWithValidFileSucceeds() throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test.wav")
        try createTestWAVFile(at: wavPath)

        let source = try FileAudioSource(filePath: wavPath)
        #expect(source.filePath == wavPath)
    }

    @Test func startProducesBuffers() async throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test-buffers.wav")
        let sampleRate: Double = 16000
        let duration: Double = 0.5
        try createTestWAVFile(at: wavPath, sampleRate: sampleRate, durationSeconds: duration)

        let source = try FileAudioSource(filePath: wavPath)
        var buffers: [TimestampedBuffer] = []

        // Collect buffers in a task, start in another
        async let reading: Void = {
            for await buf in source.stream {
                buffers.append(buf)
            }
        }()

        try await source.start()
        await reading

        #expect(!buffers.isEmpty, "Should produce at least one buffer")

        // Total frames across all buffers should equal the file length
        let totalFrames = buffers.reduce(0) { $0 + Int($1.buffer.frameLength) }
        let expectedFrames = Int(sampleRate * duration)
        #expect(totalFrames == expectedFrames, "Total frames (\(totalFrames)) should match expected (\(expectedFrames))")
    }

    @Test func syntheticTimestampsAreMonotonicallyIncreasing() async throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test-timestamps.wav")
        try createTestWAVFile(at: wavPath, sampleRate: 16000, durationSeconds: 1.0)

        let source = try FileAudioSource(filePath: wavPath)
        var timestamps: [UInt64] = []

        async let reading: Void = {
            for await buf in source.stream {
                timestamps.append(buf.hostTime)
            }
        }()

        try await source.start()
        await reading

        #expect(timestamps.count > 1, "Should have multiple buffers for a 1-second file")

        // Verify monotonically increasing (or equal for first buffer)
        for i in 1..<timestamps.count {
            #expect(timestamps[i] >= timestamps[i - 1],
                    "Timestamps should be monotonically increasing: index \(i) (\(timestamps[i])) < index \(i-1) (\(timestamps[i-1]))")
        }
    }

    @Test func firstBufferTimestampMatchesOrigin() async throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test-origin.wav")
        try createTestWAVFile(at: wavPath, sampleRate: 16000, durationSeconds: 0.25)

        let source = try FileAudioSource(filePath: wavPath)
        var firstTimestamp: UInt64?

        async let reading: Void = {
            for await buf in source.stream {
                if firstTimestamp == nil {
                    firstTimestamp = buf.hostTime
                }
            }
        }()

        try await source.start()
        await reading

        // The first buffer is at framesRead=0, so secondsIntoFile=0, offset=0
        // Therefore the first buffer's hostTime should equal originHostTime
        #expect(firstTimestamp != nil)
        #expect(firstTimestamp == source.originHostTime,
                "First buffer timestamp should equal originHostTime")
    }

    @Test func timestampSpanMatchesFileDuration() async throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test-span.wav")
        let duration: Double = 1.0
        let sampleRate: Double = 16000
        try createTestWAVFile(at: wavPath, sampleRate: sampleRate, durationSeconds: duration)

        let source = try FileAudioSource(filePath: wavPath)
        var firstTimestamp: UInt64?
        var lastTimestamp: UInt64?
        var lastFrameLength: AVAudioFrameCount = 0

        async let reading: Void = {
            for await buf in source.stream {
                if firstTimestamp == nil {
                    firstTimestamp = buf.hostTime
                }
                lastTimestamp = buf.hostTime
                lastFrameLength = buf.buffer.frameLength
            }
        }()

        try await source.start()
        await reading

        guard let first = firstTimestamp, let last = lastTimestamp else {
            Issue.record("No timestamps captured")
            return
        }

        // The last buffer's timestamp corresponds to framesRead at the start of that buffer,
        // not the end. So the span is from 0 to (totalFrames - lastFrameLength) / sampleRate.
        let spanNanos = last - first
        let expectedTotalFrames = Int(sampleRate * duration)
        let lastBufferStartFrame = expectedTotalFrames - Int(lastFrameLength)
        let expectedSpanSeconds = Double(lastBufferStartFrame) / sampleRate
        let expectedSpanNanos = UInt64(expectedSpanSeconds * 1_000_000_000)

        // Allow 1ms tolerance for rounding
        let tolerance: UInt64 = 1_000_000
        let diff = spanNanos > expectedSpanNanos ? spanNanos - expectedSpanNanos : expectedSpanNanos - spanNanos
        #expect(diff <= tolerance,
                "Timestamp span \(spanNanos)ns should be close to expected \(expectedSpanNanos)ns (diff: \(diff)ns)")
    }

    @Test func stopFinishesStream() async throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test-stop.wav")
        // Make a longer file so we can stop mid-stream
        try createTestWAVFile(at: wavPath, sampleRate: 16000, durationSeconds: 0.25)

        let source = try FileAudioSource(filePath: wavPath)

        // Calling stop should cause the stream to finish
        source.stop()

        var count = 0
        for await _ in source.stream {
            count += 1
        }
        // After stop, the stream should end (it was finished before any buffers were yielded)
        #expect(count == 0, "Stream should be empty after stop() before start()")
    }

    @Test func bufferSizeIs4096OrLess() async throws {
        defer { cleanup() }
        let wavPath = tmpDir.appendingPathComponent("test-bufsize.wav")
        try createTestWAVFile(at: wavPath, sampleRate: 16000, durationSeconds: 0.5)

        let source = try FileAudioSource(filePath: wavPath)
        var maxFrameLength: AVAudioFrameCount = 0

        async let reading: Void = {
            for await buf in source.stream {
                if buf.buffer.frameLength > maxFrameLength {
                    maxFrameLength = buf.buffer.frameLength
                }
            }
        }()

        try await source.start()
        await reading

        #expect(maxFrameLength <= 4096, "Buffer frames should not exceed 4096, got \(maxFrameLength)")
    }
}

@Suite("File Transcription Argument Parsing")
struct FileTranscriptionArgTests {
    @Test func fileOptionIsParsed() throws {
        guard #available(macOS 26.0, *) else { return }
        let args = ["--file", "/path/to/audio.m4a"]
        let command = try Transcribe.parse(args)
        #expect(command.file == "/path/to/audio.m4a")
    }

    @Test func fileOptionDefaultsToNil() throws {
        guard #available(macOS 26.0, *) else { return }
        let command = try Transcribe.parse([])
        #expect(command.file == nil)
    }

    @Test func fileWithTitle() throws {
        guard #available(macOS 26.0, *) else { return }
        let args = ["--file", "/path/to/audio.m4a", "--title", "My Recording"]
        let command = try Transcribe.parse(args)
        #expect(command.file == "/path/to/audio.m4a")
        #expect(command.title == "My Recording")
    }

    @Test func fileWithSpeakers() throws {
        guard #available(macOS 26.0, *) else { return }
        let args = ["--file", "/path/to/audio.wav", "--speakers", "Alice,Bob"]
        let command = try Transcribe.parse(args)
        #expect(command.file == "/path/to/audio.wav")
        #expect(command.speakers == "Alice,Bob")
    }

    @Test func showInterimFlagIsParsed() throws {
        guard #available(macOS 26.0, *) else { return }
        let command = try Transcribe.parse(["--show-interim"])
        #expect(command.showInterim == true)
    }

    @Test func showInterimDefaultsToFalse() throws {
        guard #available(macOS 26.0, *) else { return }
        let command = try Transcribe.parse([])
        #expect(command.showInterim == false)
    }
}
