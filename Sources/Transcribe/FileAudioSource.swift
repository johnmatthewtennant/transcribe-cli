import AVFoundation
import Foundation

/// Reads an audio file (m4a, wav, mp3, caf, etc.) and produces timestamped audio buffers
/// compatible with the transcription engine.
@available(macOS 15.0, *)
final class FileAudioSource: Sendable {
    let filePath: URL
    let stream: AsyncStream<TimestampedBuffer>
    private let continuation: AsyncStream<TimestampedBuffer>.Continuation

    /// The mach_continuous_time() recorded when streaming begins.
    nonisolated(unsafe) var originHostTime: UInt64 = 0

    init(filePath: URL) throws {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            throw TranscribeError.captureError("File not found: \(filePath.path)")
        }

        self.filePath = filePath

        var cont: AsyncStream<TimestampedBuffer>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.continuation = cont
    }

    /// Read the audio file and emit timestamped buffers. Returns when the file is fully read.
    func start() async throws {
        let file = try AVAudioFile(forReading: filePath)
        let fileFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)

        guard totalFrames > 0 else {
            throw TranscribeError.captureError("Audio file is empty: \(filePath.lastPathComponent)")
        }

        let bufferSize: AVAudioFrameCount = 4096
        let origin = mach_continuous_time()
        self.originHostTime = origin

        var framesRead: AVAudioFrameCount = 0
        while framesRead < totalFrames {
            let remaining = totalFrames - framesRead
            let framesToRead = min(bufferSize, remaining)

            guard let buffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                throw TranscribeError.captureError("Failed to allocate audio buffer")
            }

            try file.read(into: buffer, frameCount: framesToRead)

            // Compute a synthetic host time based on the position in the file.
            // This ensures timestamps in the transcript reflect the audio timeline.
            let secondsIntoFile = Double(framesRead) / fileFormat.sampleRate
            let offsetNanos = UInt64(secondsIntoFile * 1_000_000_000)
            let hostTime = origin + offsetNanos

            let timestamped = TimestampedBuffer(buffer: buffer, hostTime: hostTime)
            continuation.yield(timestamped)

            framesRead += buffer.frameLength
        }

        continuation.finish()
    }

    func stop() {
        continuation.finish()
    }
}
