import AVFoundation
import Foundation
import Testing
@testable import transcribe

@Suite("AudioRecorder")
struct AudioRecorderTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-recorder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    /// Create a mono float32 non-interleaved buffer with known values.
    private func makeMonoFloat32Buffer(sampleRate: Double = 48000, frameCount: Int = 1024) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        if let data = buffer.floatChannelData {
            for i in 0..<frameCount {
                // Write a known pattern: sine wave
                data[0][i] = sin(Float(i) * 0.1)
            }
        }
        return buffer
    }

    @Test func writeAndReadBackMonoFloat32() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("test.caf")
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        let buffer = makeMonoFloat32Buffer(sampleRate: 48000, frameCount: 1024)
        recorder.write(buffer: buffer)
        recorder.stop()

        // Read the file back
        let readFile = try AVAudioFile(forReading: path)
        #expect(readFile.length == 1024)
        #expect(readFile.fileFormat.channelCount == 1)
        #expect(readFile.fileFormat.sampleRate == 48000)

        // Read data and verify
        let readBuffer = AVAudioPCMBuffer(pcmFormat: readFile.processingFormat, frameCapacity: 1024)!
        try readFile.read(into: readBuffer)
        #expect(readBuffer.frameLength == 1024)

        if let srcData = buffer.floatChannelData, let readData = readBuffer.floatChannelData {
            for i in 0..<1024 {
                #expect(abs(srcData[0][i] - readData[0][i]) < 0.001)
            }
        }
    }

    @Test func multipleWritesConcatenate() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("multi.caf")
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        let buffer1 = makeMonoFloat32Buffer(sampleRate: 48000, frameCount: 512)
        let buffer2 = makeMonoFloat32Buffer(sampleRate: 48000, frameCount: 512)
        recorder.write(buffer: buffer1)
        recorder.write(buffer: buffer2)
        recorder.stop()

        let readFile = try AVAudioFile(forReading: path)
        #expect(readFile.length == 1024)
    }

    @Test func stopClosesFile() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("stop.caf")
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        let buffer = makeMonoFloat32Buffer(sampleRate: 48000, frameCount: 256)
        recorder.write(buffer: buffer)
        recorder.stop()

        // Writing after stop should be a no-op (no crash)
        recorder.write(buffer: buffer)

        let readFile = try AVAudioFile(forReading: path)
        #expect(readFile.length == 256)  // only the first write
    }

    @Test func fileHas0600Permissions() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("perms.caf")
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        let buffer = makeMonoFloat32Buffer(sampleRate: 48000, frameCount: 256)
        recorder.write(buffer: buffer)
        recorder.stop()

        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        let perms = attrs[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func bufferOwnershipSafety() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("ownership.caf")
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        let buffer = makeMonoFloat32Buffer(sampleRate: 48000, frameCount: 512)
        let originalValue = buffer.floatChannelData![0][0]

        // Write the buffer
        recorder.write(buffer: buffer)

        // Mutate the original buffer after write() returns
        buffer.floatChannelData![0][0] = 999.0

        recorder.stop()

        // Read back and verify the recorded data has the pre-mutation value
        let readFile = try AVAudioFile(forReading: path)
        let readBuffer = AVAudioPCMBuffer(pcmFormat: readFile.processingFormat, frameCapacity: 512)!
        try readFile.read(into: readBuffer)

        #expect(abs(readBuffer.floatChannelData![0][0] - originalValue) < 0.001)
        #expect(readBuffer.floatChannelData![0][0] != 999.0)
    }

    @Test func sampleRateConversion() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("resample.caf")
        // Recorder outputs at 48kHz, input at 16kHz
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        let inputBuffer = makeMonoFloat32Buffer(sampleRate: 16000, frameCount: 1600)
        recorder.write(buffer: inputBuffer)
        recorder.stop()

        let readFile = try AVAudioFile(forReading: path)
        #expect(readFile.fileFormat.sampleRate == 48000)
        #expect(readFile.fileFormat.channelCount == 1)
        // 1600 frames at 16kHz -> ~4800 frames at 48kHz (3x ratio)
        #expect(readFile.length >= 4700 && readFile.length <= 4900)
    }

    @Test func stereoInputDownmixedToMono() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("stereo.caf")
        let recorder = AudioRecorder(sampleRate: 48000)
        try recorder.start(filePath: path)

        // Create a stereo buffer
        let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let stereoBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 512)!
        stereoBuffer.frameLength = 512
        if let data = stereoBuffer.floatChannelData {
            for i in 0..<512 {
                data[0][i] = 0.5  // left channel
                data[1][i] = -0.5 // right channel
            }
        }

        recorder.write(buffer: stereoBuffer)
        recorder.stop()

        // Verify the output is mono
        let readFile = try AVAudioFile(forReading: path)
        #expect(readFile.fileFormat.channelCount == 1)
        #expect(readFile.length > 0)
    }
}
