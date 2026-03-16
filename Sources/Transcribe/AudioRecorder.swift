@preconcurrency import AVFoundation
import Foundation

/// Records a single channel of audio to a mono CAF file.
/// Thread-safe -- normalization/conversion are serialized by `converterLock`,
/// and file writes are serialized on an internal dispatch queue.
final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.transcriber.recorder", qos: .userInitiated)
    private var audioFile: AVAudioFile?
    private let outputFormat: AVAudioFormat  // mono PCM float32, non-interleaved
    private var sampleRateConverter: AVAudioConverter?
    private var normalizer: AVAudioConverter?  // cached per-format normalizer
    private let converterLock = NSLock()  // protects normalizer + sampleRateConverter

    init(sampleRate: Double = 48000.0) {
        self.outputFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 1
        )!
    }

    func start(filePath: URL) throws {
        // Create file with 0600 permissions first
        FileManager.default.createFile(
            atPath: filePath.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )
        audioFile = try AVAudioFile(
            forWriting: filePath,
            settings: outputFormat.settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    /// Write a buffer (any format) to the file.
    /// Format normalization happens synchronously on the caller's thread.
    /// Only the owned, normalized buffer is dispatched for async file I/O.
    func write(buffer: AVAudioPCMBuffer) {
        converterLock.lock()
        defer { converterLock.unlock() }

        // Step 1: Synchronously normalize to mono float32 (produces an owned buffer)
        guard let normalized = normalizeToMonoFloat(buffer: buffer) else {
            DiagnosticLog.shared.log("[AudioRecorder] Failed to normalize buffer format: \(buffer.format)")
            return
        }

        // Step 2: Synchronously convert sample rate if needed (produces another owned buffer)
        let finalBuffer: AVAudioPCMBuffer
        if normalized.format.sampleRate != outputFormat.sampleRate {
            if sampleRateConverter == nil || sampleRateConverter!.inputFormat != normalized.format {
                sampleRateConverter = AVAudioConverter(from: normalized.format, to: outputFormat)
                if sampleRateConverter == nil {
                    DiagnosticLog.shared.log("[AudioRecorder] Failed to create sample rate converter: \(normalized.format) -> \(outputFormat)")
                }
            }
            if let sampleRateConverter,
               let converted = convertSampleRate(buffer: normalized, converter: sampleRateConverter) {
                finalBuffer = converted
            } else {
                return
            }
        } else {
            finalBuffer = normalized
        }

        // Step 3: Dispatch owned buffer for async file write
        queue.async { [self] in
            guard let audioFile else { return }
            do {
                try audioFile.write(from: finalBuffer)
            } catch {
                DiagnosticLog.shared.log("[AudioRecorder] Write error: \(error.localizedDescription)")
            }
        }
    }

    func stop() {
        queue.sync {
            audioFile = nil  // closes the file
        }
    }

    // MARK: - Format Normalization

    /// Convert any buffer format to mono float32 non-interleaved.
    /// Uses AVAudioConverter to handle all format variance:
    /// int16/int32/float, interleaved/non-interleaved, mono/stereo/multi-channel.
    /// Returns a newly allocated owned buffer. Even if the input is already in the
    /// target format (mono float32 non-interleaved), it is copied for ownership safety.
    private func normalizeToMonoFloat(buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let sourceFormat = buffer.format

        // Target: mono float32 non-interleaved at source sample rate
        guard let targetFormat = AVAudioFormat(
            standardFormatWithSampleRate: sourceFormat.sampleRate,
            channels: 1
        ) else { return nil }

        // If already mono float32 non-interleaved, copy for ownership safety
        if sourceFormat.channelCount == 1 &&
           sourceFormat.commonFormat == .pcmFormatFloat32 &&
           !sourceFormat.isInterleaved {
            return copyMonoFloat32Buffer(buffer)
        }

        // Create or reuse normalizer (invalidate if source format changed)
        if normalizer == nil || normalizer!.inputFormat != sourceFormat {
            normalizer = AVAudioConverter(from: sourceFormat, to: targetFormat)
            if normalizer == nil {
                DiagnosticLog.shared.log("[AudioRecorder] Cannot create normalizer: \(sourceFormat) -> \(targetFormat)")
                return nil
            }
        }

        let frameCapacity = buffer.frameLength
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        normalizer!.convert(to: output, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if let error {
            DiagnosticLog.shared.log("[AudioRecorder] Normalization error: \(error.localizedDescription)")
            return nil
        }

        return output.frameLength > 0 ? output : nil
    }

    /// Fast-path copy for mono float32 non-interleaved buffers.
    private func copyMonoFloat32Buffer(_ source: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            return nil
        }
        copy.frameLength = source.frameLength
        if let src = source.floatChannelData, let dst = copy.floatChannelData {
            memcpy(dst[0], src[0], Int(source.frameLength) * MemoryLayout<Float>.size)
        }
        return copy
    }

    /// Convert sample rate using a pre-initialized converter.
    private func convertSampleRate(buffer: AVAudioPCMBuffer, converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let frameCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio)
        guard frameCapacity > 0,
              let converted = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: frameCapacity) else {
            return nil
        }

        var error: NSError?
        nonisolated(unsafe) var consumed = false
        converter.convert(to: converted, error: &error) { _, outStatus in
            if !consumed {
                consumed = true
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        if let error {
            DiagnosticLog.shared.log("[AudioRecorder] Sample rate conversion error: \(error.localizedDescription)")
            return nil
        }
        return converted.frameLength > 0 ? converted : nil
    }
}
