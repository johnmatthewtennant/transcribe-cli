import AVFoundation
import Testing

@testable import transcribe

@Suite("MergeCommand")
struct MergeCommandTests {

    private func createMonoCAF(at url: URL, sampleRate: Double = 48000, durationSeconds: Double = 0.5) throws {
        let frameCount = AVAudioFrameCount(sampleRate * durationSeconds)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscribeError.captureError("Cannot create test buffer")
        }
        buffer.frameLength = frameCount
        guard let data = buffer.floatChannelData else {
            throw TranscribeError.captureError("Cannot access channel data")
        }
        for i in 0..<Int(frameCount) {
            data[0][i] = Float(sin(2.0 * .pi * 440.0 * Double(i) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Default output derives .wav from .mic.caf path")
    @available(macOS 26.0, *)
    func testDefaultOutputNamingWAV() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("session.mic.caf")
        let sysPath = dir.appendingPathComponent("session.sys.caf")
        try createMonoCAF(at: micPath)
        try createMonoCAF(at: sysPath)

        var cmd = try MergeCommand.parse([micPath.path, sysPath.path])
        try cmd.run()

        let expectedOutput = dir.appendingPathComponent("session.wav")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
    }

    @Test("Default output derives .m4a when --format m4a")
    @available(macOS 26.0, *)
    func testDefaultOutputNamingM4A() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("session.mic.caf")
        let sysPath = dir.appendingPathComponent("session.sys.caf")
        try createMonoCAF(at: micPath)
        try createMonoCAF(at: sysPath)

        var cmd = try MergeCommand.parse([micPath.path, sysPath.path, "--format", "m4a"])
        try cmd.run()

        let expectedOutput = dir.appendingPathComponent("session.m4a")
        #expect(FileManager.default.fileExists(atPath: expectedOutput.path))
    }

    @Test("Invalid format rejected in validation")
    @available(macOS 26.0, *)
    func testInvalidFormatRejected() throws {
        #expect(throws: (any Error).self) {
            var cmd = try MergeCommand.parse(["mic.caf", "sys.caf", "--format", "flac"])
            try cmd.validate()
        }
    }

    @Test("Output extension mismatch rejected")
    @available(macOS 26.0, *)
    func testOutputExtensionMismatchRejected() throws {
        #expect(throws: (any Error).self) {
            var cmd = try MergeCommand.parse(["mic.caf", "sys.caf", "--format", "wav", "-o", "out.m4a"])
            try cmd.validate()
        }
    }

    @Test("Output exists rejected")
    @available(macOS 26.0, *)
    func testOutputExistsRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.wav")
        try createMonoCAF(at: micPath)
        try createMonoCAF(at: sysPath)
        FileManager.default.createFile(atPath: outPath.path, contents: Data())

        var cmd = try MergeCommand.parse([micPath.path, sysPath.path, "-o", outPath.path])
        #expect(throws: (any Error).self) {
            try cmd.run()
        }
    }

    @Test("--delete-originals removes source files")
    @available(macOS 26.0, *)
    func testDeleteOriginalsRemovesFiles() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("del.mic.caf")
        let sysPath = dir.appendingPathComponent("del.sys.caf")
        try createMonoCAF(at: micPath)
        try createMonoCAF(at: sysPath)

        var cmd = try MergeCommand.parse([micPath.path, sysPath.path, "--delete-originals"])
        try cmd.run()

        #expect(!FileManager.default.fileExists(atPath: micPath.path))
        #expect(!FileManager.default.fileExists(atPath: sysPath.path))
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("del.wav").path))
    }

    @Test("WAV output has correct channel data placement")
    func testWAVChannelDataPlacement() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("ch.mic.caf")
        let sysPath = dir.appendingPathComponent("ch.sys.caf")
        let outPath = dir.appendingPathComponent("ch.wav")

        let sampleRate = 48000.0
        let frameCount = AVAudioFrameCount(sampleRate * 0.1)
        guard let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw TranscribeError.captureError("Cannot create format")
        }

        // Mic: all 1.0
        guard let micBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            throw TranscribeError.captureError("Cannot create buffer")
        }
        micBuf.frameLength = frameCount
        for i in 0..<Int(frameCount) { micBuf.floatChannelData![0][i] = 1.0 }
        let micFile = try AVAudioFile(forWriting: micPath, settings: monoFormat.settings)
        try micFile.write(from: micBuf)

        // Sys: all -1.0
        guard let sysBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount) else {
            throw TranscribeError.captureError("Cannot create buffer")
        }
        sysBuf.frameLength = frameCount
        for i in 0..<Int(frameCount) { sysBuf.floatChannelData![0][i] = -1.0 }
        let sysFile = try AVAudioFile(forWriting: sysPath, settings: monoFormat.settings)
        try sysFile.write(from: sysBuf)

        try AudioMerger.mergeToStereoWAV(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        let output = try AVAudioFile(forReading: outPath)
        #expect(output.processingFormat.channelCount == 2)

        guard let readBuf = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: frameCount) else {
            throw TranscribeError.captureError("Cannot create read buffer")
        }
        try output.read(into: readBuf)

        guard let channels = readBuf.floatChannelData else {
            throw TranscribeError.captureError("Cannot access channel data")
        }

        // Left (mic) should be ~1.0, Right (sys) should be ~-1.0
        let leftSample = channels[0][0]
        let rightSample = channels[1][0]
        #expect(abs(leftSample - 1.0) < 0.001, "Left channel should contain mic data (~1.0), got \(leftSample)")
        #expect(abs(rightSample - (-1.0)) < 0.001, "Right channel should contain sys data (~-1.0), got \(rightSample)")
    }

    @Test("Same file for mic and sys rejected")
    @available(macOS 26.0, *)
    func testSameFileRejected() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let cafPath = dir.appendingPathComponent("same.caf")
        try createMonoCAF(at: cafPath)

        var cmd = try MergeCommand.parse([cafPath.path, cafPath.path])
        #expect(throws: (any Error).self) {
            try cmd.run()
        }
    }

    @Test("Partial output cleaned up on merge failure")
    @available(macOS 26.0, *)
    func testPartialOutputCleanedUp() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("fail.mic.caf")
        let sysPath = dir.appendingPathComponent("fail.sys.caf")
        let outPath = dir.appendingPathComponent("fail.wav")

        // Create mic as mono CAF but sys as stereo (will cause merge to fail)
        try createMonoCAF(at: micPath)

        let frameCount: AVAudioFrameCount = 48000
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: frameCount) else {
            throw TranscribeError.captureError("Cannot create stereo buffer")
        }
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: sysPath, settings: stereoFormat.settings)
        try file.write(from: buffer)

        // Merge should fail because sys is stereo
        #expect(throws: (any Error).self) {
            try AudioMerger.mergeToStereoWAV(micPath: micPath, sysPath: sysPath, outputPath: outPath)
        }

        // The AudioMerger itself doesn't clean up, but let's verify MergeCommand does
        // Pre-create the output to simulate partial write
        FileManager.default.createFile(atPath: outPath.path, contents: Data([0x00]))
        #expect(FileManager.default.fileExists(atPath: outPath.path))

        // Now delete it to reset, and test via MergeCommand which has cleanup
        try? FileManager.default.removeItem(at: outPath)

        // Use MergeCommand which wraps mergeToStereo with cleanup
        var cmd = try MergeCommand.parse([micPath.path, sysPath.path, "-o", outPath.path])
        #expect(throws: (any Error).self) {
            try cmd.run()
        }

        // Output file should NOT exist after failed merge (cleanup happened)
        #expect(!FileManager.default.fileExists(atPath: outPath.path))
    }
}
