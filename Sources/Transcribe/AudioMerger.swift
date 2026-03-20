import AVFoundation
import Foundation

/// Merges two mono audio files into a single stereo output file.
/// Left channel = mic (local), Right channel = system (remote).
/// Uses chunked I/O to bound memory usage regardless of recording length.
enum AudioMerger {

    /// Number of frames to process per chunk. 64K frames at 48kHz = ~1.3 seconds.
    private static let chunkSize: AVAudioFrameCount = 65536

    /// Supported output formats for merged audio.
    enum OutputFormat: Equatable {
        case aac
        case wav
    }

    /// Merge two mono CAF files into a stereo M4A (AAC-compressed).
    @discardableResult
    static func mergeToStereoAAC(
        micPath: URL,
        sysPath: URL,
        outputPath: URL
    ) throws -> URL {
        try mergeToStereo(micPath: micPath, sysPath: sysPath, outputPath: outputPath, format: .aac)
    }

    /// Merge two mono CAF files into a stereo WAV (uncompressed PCM).
    @discardableResult
    static func mergeToStereoWAV(
        micPath: URL,
        sysPath: URL,
        outputPath: URL
    ) throws -> URL {
        try mergeToStereo(micPath: micPath, sysPath: sysPath, outputPath: outputPath, format: .wav)
    }

    /// Merge two mono audio files into a stereo output file.
    /// - Parameters:
    ///   - micPath: Path to the mono mic audio file (left channel)
    ///   - sysPath: Path to the mono system audio file (right channel)
    ///   - outputPath: Desired output path
    ///   - format: Output format (.aac for M4A, .wav for uncompressed PCM)
    /// - Returns: The output URL on success
    /// - Throws: On read/write/conversion errors
    @discardableResult
    static func mergeToStereo(
        micPath: URL,
        sysPath: URL,
        outputPath: URL,
        format: OutputFormat
    ) throws -> URL {
        let micFile = try AVAudioFile(forReading: micPath)
        let sysFile = try AVAudioFile(forReading: sysPath)

        let micFormat = micFile.processingFormat
        let sysFormat = sysFile.processingFormat
        guard micFormat.channelCount == 1 else {
            throw TranscribeError.captureError("Mic file is not mono (channels: \(micFormat.channelCount))")
        }
        guard sysFormat.channelCount == 1 else {
            throw TranscribeError.captureError("System file is not mono (channels: \(sysFormat.channelCount))")
        }
        guard micFormat.sampleRate == sysFormat.sampleRate else {
            throw TranscribeError.captureError(
                "Sample rate mismatch: mic=\(micFormat.sampleRate), sys=\(sysFormat.sampleRate)"
            )
        }

        let sampleRate = micFormat.sampleRate
        let micLength = micFile.length   // AVAudioFramePosition (Int64)
        let sysLength = sysFile.length
        let maxFrames = max(micLength, sysLength)

        guard maxFrames > 0 else {
            throw TranscribeError.captureError("Both recording files are empty — nothing to merge")
        }

        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            throw TranscribeError.captureError("Cannot create stereo format")
        }

        FileManager.default.createFile(
            atPath: outputPath.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )

        let outputFile: AVAudioFile
        switch format {
        case .aac:
            let aacSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: 128_000
            ]
            outputFile = try AVAudioFile(
                forWriting: outputPath,
                settings: aacSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        case .wav:
            let wavSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 2,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false
            ]
            outputFile = try AVAudioFile(
                forWriting: outputPath,
                settings: wavSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        }

        guard let micChunk = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: chunkSize),
              let sysChunk = AVAudioPCMBuffer(pcmFormat: sysFormat, frameCapacity: chunkSize),
              let stereoChunk = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: chunkSize) else {
            throw TranscribeError.captureError("Cannot allocate merge buffers")
        }

        var framesWritten: AVAudioFramePosition = 0
        while framesWritten < maxFrames {
            let remaining = maxFrames - framesWritten
            let thisChunk = AVAudioFrameCount(min(AVAudioFramePosition(chunkSize), remaining))

            var micActual: AVAudioFrameCount = 0
            if framesWritten < micLength {
                let micAvail = AVAudioFrameCount(min(AVAudioFramePosition(thisChunk), micLength - framesWritten))
                micChunk.frameLength = 0
                try micFile.read(into: micChunk, frameCount: micAvail)
                micActual = micChunk.frameLength
            }

            var sysActual: AVAudioFrameCount = 0
            if framesWritten < sysLength {
                let sysAvail = AVAudioFrameCount(min(AVAudioFramePosition(thisChunk), sysLength - framesWritten))
                sysChunk.frameLength = 0
                try sysFile.read(into: sysChunk, frameCount: sysAvail)
                sysActual = sysChunk.frameLength
            }

            stereoChunk.frameLength = thisChunk
            guard let stereoChannels = stereoChunk.floatChannelData else {
                throw TranscribeError.captureError("Cannot access stereo channel data")
            }

            if micActual > 0, let micData = micChunk.floatChannelData {
                memcpy(stereoChannels[0], micData[0], Int(micActual) * MemoryLayout<Float>.size)
            }
            if micActual < thisChunk {
                memset(stereoChannels[0].advanced(by: Int(micActual)), 0,
                       Int(thisChunk - micActual) * MemoryLayout<Float>.size)
            }

            if sysActual > 0, let sysData = sysChunk.floatChannelData {
                memcpy(stereoChannels[1], sysData[0], Int(sysActual) * MemoryLayout<Float>.size)
            }
            if sysActual < thisChunk {
                memset(stereoChannels[1].advanced(by: Int(sysActual)), 0,
                       Int(thisChunk - sysActual) * MemoryLayout<Float>.size)
            }

            try outputFile.write(from: stereoChunk)
            framesWritten += AVAudioFramePosition(thisChunk)
        }

        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputPath.path
        )

        return outputPath
    }
}
