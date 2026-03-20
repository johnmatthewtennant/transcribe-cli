import AVFoundation
import Foundation

/// Reads an audio file (m4a, wav, mp3, caf, etc.) and produces timestamped audio buffers
/// compatible with the transcription engine.
///
/// When `channelIndex` is set, extracts a single channel from a multi-channel file
/// and emits it as mono buffers. When nil, emits buffers in the file's native format.
@available(macOS 15.0, *)
final class FileAudioSource: Sendable {
    let filePath: URL
    let stream: AsyncStream<TimestampedBuffer>
    private let continuation: AsyncStream<TimestampedBuffer>.Continuation

    /// Which channel to extract (0 = left, 1 = right). Nil means read all channels as-is.
    private let channelIndex: Int?

    /// The mach_continuous_time() recorded when streaming begins.
    /// When using a shared origin (for stereo pairs), this is set at init time.
    nonisolated(unsafe) var originHostTime: UInt64 = 0

    private nonisolated(unsafe) var _isStopped = false

    /// Initialize a file audio source.
    /// - Parameters:
    ///   - filePath: Path to the audio file.
    ///   - channelIndex: If non-nil, extract only this channel (0-based) as mono output.
    ///   - sharedOriginHostTime: If non-nil, use this origin for timestamp computation
    ///     (ensures two channel sources share the same time base).
    init(filePath: URL, channelIndex: Int? = nil, sharedOriginHostTime: UInt64? = nil) throws {
        guard FileManager.default.fileExists(atPath: filePath.path) else {
            throw TranscribeError.captureError("File not found: \(filePath.path)")
        }

        self.filePath = filePath
        self.channelIndex = channelIndex

        if let origin = sharedOriginHostTime {
            self.originHostTime = origin
        }

        var cont: AsyncStream<TimestampedBuffer>.Continuation!
        self.stream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.continuation = cont
    }

    /// Returns the number of audio channels in the file.
    static func channelCount(at filePath: URL) throws -> Int {
        let file = try AVAudioFile(forReading: filePath)
        return Int(file.processingFormat.channelCount)
    }

    /// Read the audio file and emit timestamped buffers. Returns when the file is fully read.
    func start() async throws {
        // Ensure stream is always finished, regardless of success/failure/cancellation.
        // This prevents downstream consumers from waiting forever on an unfinished stream.
        defer { continuation.finish() }

        let file = try AVAudioFile(forReading: filePath)
        let fileFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)

        guard totalFrames > 0 else {
            throw TranscribeError.captureError("Audio file is empty: \(filePath.lastPathComponent)")
        }

        if let idx = channelIndex {
            guard idx < Int(fileFormat.channelCount) else {
                throw TranscribeError.captureError(
                    "Channel \(idx) requested but file only has \(fileFormat.channelCount) channel(s): \(filePath.lastPathComponent)"
                )
            }
        }

        // Ensure we read as non-interleaved Float32 so we can access per-channel data
        let readFormat: AVAudioFormat
        if channelIndex != nil {
            // Need non-interleaved float32 to extract individual channels
            guard let nonInterleaved = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: fileFormat.sampleRate,
                channels: fileFormat.channelCount,
                interleaved: false
            ) else {
                throw TranscribeError.captureError("Failed to create non-interleaved format for channel extraction")
            }
            readFormat = nonInterleaved
        } else {
            readFormat = fileFormat
        }

        let bufferSize: AVAudioFrameCount = 4096

        // Use shared origin if provided, otherwise generate one
        if originHostTime == 0 {
            originHostTime = mach_continuous_time()
        }
        let origin = originHostTime

        // Create a mono output format for channel extraction
        let monoFormat: AVAudioFormat? = if channelIndex != nil {
            AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: fileFormat.sampleRate,
                channels: 1,
                interleaved: false
            )
        } else {
            nil
        }

        // Set up format converter if file's native format differs from readFormat
        let converter: AVAudioConverter? = if readFormat != fileFormat {
            AVAudioConverter(from: fileFormat, to: readFormat)
        } else {
            nil
        }

        var framesRead: AVAudioFrameCount = 0
        while framesRead < totalFrames && !_isStopped && !Task.isCancelled {
            let remaining = totalFrames - framesRead
            let framesToRead = min(bufferSize, remaining)

            let buffer: AVAudioPCMBuffer
            if let converter {
                // Read in native format, then convert
                guard let nativeBuffer = AVAudioPCMBuffer(pcmFormat: fileFormat, frameCapacity: framesToRead) else {
                    throw TranscribeError.captureError("Failed to allocate native audio buffer")
                }
                try file.read(into: nativeBuffer, frameCount: framesToRead)

                guard let convertedBuffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: framesToRead) else {
                    throw TranscribeError.captureError("Failed to allocate converted audio buffer")
                }
                var error: NSError?
                nonisolated(unsafe) var consumed = false
                converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                    if !consumed {
                        consumed = true
                        outStatus.pointee = .haveData
                        return nativeBuffer
                    }
                    outStatus.pointee = .noDataNow
                    return nil
                }
                if let error {
                    throw TranscribeError.captureError("Audio format conversion failed: \(error.localizedDescription)")
                }
                // Guard against 0-frame conversion output to prevent infinite loop
                guard convertedBuffer.frameLength > 0 else {
                    throw TranscribeError.captureError(
                        "Audio format conversion produced 0 frames at position \(framesRead)/\(totalFrames)"
                    )
                }
                buffer = convertedBuffer
            } else {
                guard let readBuffer = AVAudioPCMBuffer(pcmFormat: readFormat, frameCapacity: framesToRead) else {
                    throw TranscribeError.captureError("Failed to allocate audio buffer")
                }
                try file.read(into: readBuffer, frameCount: framesToRead)
                buffer = readBuffer
            }

            // Compute a synthetic host time based on the position in the file.
            // This ensures timestamps in the transcript reflect the audio timeline.
            let secondsIntoFile = Double(framesRead) / fileFormat.sampleRate
            let offsetNanos = UInt64(secondsIntoFile * 1_000_000_000)
            let hostTime = origin + offsetNanos

            if let idx = channelIndex, let monoFmt = monoFormat {
                // Extract the requested channel into a mono buffer
                guard let channelData = buffer.floatChannelData else {
                    throw TranscribeError.captureError("Cannot access float channel data for channel extraction")
                }
                let frameLength = buffer.frameLength
                guard let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFmt, frameCapacity: frameLength) else {
                    throw TranscribeError.captureError("Failed to allocate mono buffer")
                }
                guard let monoData = monoBuffer.floatChannelData else {
                    throw TranscribeError.captureError("Cannot access mono buffer channel data")
                }
                memcpy(monoData[0], channelData[idx], Int(frameLength) * MemoryLayout<Float>.size)
                monoBuffer.frameLength = frameLength

                continuation.yield(TimestampedBuffer(buffer: monoBuffer, hostTime: hostTime))
            } else {
                continuation.yield(TimestampedBuffer(buffer: buffer, hostTime: hostTime))
            }

            framesRead += buffer.frameLength
        }
    }

    func stop() {
        _isStopped = true
        continuation.finish()
    }
}
