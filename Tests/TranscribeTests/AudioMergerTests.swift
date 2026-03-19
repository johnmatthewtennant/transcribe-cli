import AVFoundation
import Testing

@testable import transcribe

@Suite("AudioMerger")
struct AudioMergerTests {

    private func createMonoCAF(at url: URL, sampleRate: Double = 48000, durationSeconds: Double = 1.0, frequency: Double = 440.0) throws {
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
            data[0][i] = Float(sin(2.0 * .pi * frequency * Double(i) / sampleRate))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func createEmptyCAF(at url: URL, sampleRate: Double = 48000) throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw TranscribeError.captureError("Cannot create test format")
        }
        _ = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    private func createStereoCAF(at url: URL, sampleRate: Double = 48000) throws {
        let frameCount: AVAudioFrameCount = 48000
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw TranscribeError.captureError("Cannot create test buffer")
        }
        buffer.frameLength = frameCount
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test("Merge produces valid M4A")
    func testMergeProducesValidM4A() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.m4a")

        try createMonoCAF(at: micPath, frequency: 440.0)
        try createMonoCAF(at: sysPath, frequency: 880.0)

        let result = try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        #expect(FileManager.default.fileExists(atPath: result.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)

        let outputFile = try AVAudioFile(forReading: result)
        #expect(outputFile.processingFormat.channelCount == 2)
        #expect(outputFile.length > 0)
    }

    @Test("Merge with different sample rates throws")
    func testMergeSampleRateMismatchThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.m4a")

        try createMonoCAF(at: micPath, sampleRate: 48000)
        try createMonoCAF(at: sysPath, sampleRate: 44100)

        #expect(throws: TranscribeError.self) {
            try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: outPath)
        }
    }

    @Test("Merge with non-mono input throws")
    func testMergeNonMonoThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.m4a")

        try createStereoCAF(at: micPath)
        try createMonoCAF(at: sysPath)

        #expect(throws: TranscribeError.self) {
            try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: outPath)
        }
    }

    @Test("Merge with different lengths succeeds")
    func testMergeDifferentLengths() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.m4a")

        try createMonoCAF(at: micPath, durationSeconds: 2.0)
        try createMonoCAF(at: sysPath, durationSeconds: 1.0)

        let result = try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        let outputFile = try AVAudioFile(forReading: result)
        #expect(outputFile.processingFormat.channelCount == 2)
        #expect(outputFile.length > 0)
    }

    @Test("Merge with both empty files throws")
    func testMergeBothEmptyThrows() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.m4a")

        try createEmptyCAF(at: micPath)
        try createEmptyCAF(at: sysPath)

        #expect(throws: TranscribeError.self) {
            try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: outPath)
        }
    }

    @Test("Output file has restrictive permissions")
    func testOutputPermissions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.m4a")

        try createMonoCAF(at: micPath)
        try createMonoCAF(at: sysPath)

        try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: outPath.path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        #expect(perms == 0o600)
    }

    // MARK: - WAV Output Tests

    @Test("Merge produces valid WAV")
    func testMergeProducesValidWAV() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.wav")

        try createMonoCAF(at: micPath, frequency: 440.0)
        try createMonoCAF(at: sysPath, frequency: 880.0)

        let result = try AudioMerger.mergeToStereoWAV(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        #expect(FileManager.default.fileExists(atPath: result.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: result.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0)

        let outputFile = try AVAudioFile(forReading: result)
        #expect(outputFile.processingFormat.channelCount == 2)
        #expect(outputFile.length > 0)
    }

    @Test("WAV merge with different lengths succeeds")
    func testWAVMergeDifferentLengths() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.wav")

        try createMonoCAF(at: micPath, durationSeconds: 2.0)
        try createMonoCAF(at: sysPath, durationSeconds: 1.0)

        let result = try AudioMerger.mergeToStereoWAV(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        let outputFile = try AVAudioFile(forReading: result)
        #expect(outputFile.processingFormat.channelCount == 2)
        // WAV output length should match the longer input
        let expectedFrames = AVAudioFramePosition(48000 * 2.0)  // 2 seconds at 48kHz
        #expect(outputFile.length == expectedFrames)
    }

    @Test("WAV output has restrictive permissions")
    func testWAVOutputPermissions() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let outPath = dir.appendingPathComponent("test.wav")

        try createMonoCAF(at: micPath)
        try createMonoCAF(at: sysPath)

        try AudioMerger.mergeToStereoWAV(micPath: micPath, sysPath: sysPath, outputPath: outPath)

        let attrs = try FileManager.default.attributesOfItem(atPath: outPath.path)
        let perms = attrs[.posixPermissions] as? Int ?? 0
        #expect(perms == 0o600)
    }

    @Test("WAV output is larger than AAC for same input")
    func testWAVLargerThanAAC() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let micPath = dir.appendingPathComponent("test.mic.caf")
        let sysPath = dir.appendingPathComponent("test.sys.caf")
        let wavPath = dir.appendingPathComponent("test.wav")
        let m4aPath = dir.appendingPathComponent("test.m4a")

        try createMonoCAF(at: micPath, durationSeconds: 2.0)
        try createMonoCAF(at: sysPath, durationSeconds: 2.0)

        try AudioMerger.mergeToStereoWAV(micPath: micPath, sysPath: sysPath, outputPath: wavPath)
        try AudioMerger.mergeToStereoAAC(micPath: micPath, sysPath: sysPath, outputPath: m4aPath)

        let wavSize = (try FileManager.default.attributesOfItem(atPath: wavPath.path)[.size] as? Int) ?? 0
        let m4aSize = (try FileManager.default.attributesOfItem(atPath: m4aPath.path)[.size] as? Int) ?? 0

        // WAV (uncompressed) should be larger than AAC (compressed)
        #expect(wavSize > m4aSize)
    }
}
