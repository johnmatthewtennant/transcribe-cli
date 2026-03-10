import AVFoundation
import CoreMedia
import Foundation
import Speech

/// A transcript event from one channel, with wall-clock timestamp for cross-channel ordering.
struct TranscriptEvent: Sendable {
    let speaker: String
    let text: String
    let wallClockTime: UInt64  // mach_continuous_time units
    let isFinal: Bool
}

/// Manages two SpeechTranscriber instances (mic + system) and merges results.
@available(macOS 26.0, *)
actor TranscriptionEngine {
    private let audioCapture: AudioCapture
    private let writer: MarkdownWriter
    private let terminal: TerminalUI
    private let micSpeaker: String
    private let systemSpeaker: String

    private var isStopped = false

    // Reorder buffer for chronological file writes (2-second watermark)
    private var reorderBuffer: [TranscriptEvent] = []
    private let watermarkNanos: UInt64 = 2_000_000_000  // 2 seconds approx

    init(
        audioCapture: AudioCapture,
        writer: MarkdownWriter,
        terminal: TerminalUI,
        micSpeaker: String,
        systemSpeaker: String
    ) async throws {
        self.audioCapture = audioCapture
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
    }

    /// Run both transcription streams until stopped.
    func run() async throws {
        // Create transcribers with volatile results and time range attributes
        let micTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )
        let systemTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [.volatileResults],
            attributeOptions: [.audioTimeRange]
        )

        // Get required audio format
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [micTranscriber]) else {
            throw TranscribeError.modelUnavailable("No compatible audio format available. The speech model may not be installed.")
        }

        // Create analyzers
        let micAnalyzer = SpeechAnalyzer(modules: [micTranscriber])
        let systemAnalyzer = SpeechAnalyzer(modules: [systemTranscriber])

        // Create audio input sequences (converting to AnalyzerInput)
        let micInput = makeAnalyzerInputStream(from: audioCapture.micStream, targetFormat: format)
        let systemInput = makeAnalyzerInputStream(from: audioCapture.systemStream, targetFormat: format)

        // Start analyzers and process results concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await micAnalyzer.start(inputSequence: micInput)
            }
            group.addTask {
                try? await systemAnalyzer.start(inputSequence: systemInput)
            }
            group.addTask { [self] in
                await self.processResults(
                    transcriber: micTranscriber,
                    speaker: self.micSpeaker,
                    originHostTime: self.audioCapture.micOriginHostTime
                )
            }
            group.addTask { [self] in
                await self.processResults(
                    transcriber: systemTranscriber,
                    speaker: self.systemSpeaker,
                    originHostTime: self.audioCapture.systemOriginHostTime
                )
            }

            await group.waitForAll()
        }
    }

    /// Process results from a single transcriber.
    private func processResults(
        transcriber: SpeechTranscriber,
        speaker: String,
        originHostTime: UInt64
    ) async {
        do {
            for try await result in transcriber.results {
                guard !isStopped else { break }

                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                // Convert result.range.start to wall-clock using origin host time
                let audioStartSeconds = CMTimeGetSeconds(result.range.start)
                let offsetNanos = UInt64(max(0, audioStartSeconds) * 1_000_000_000)
                let wallClock = originHostTime + offsetNanos

                let event = TranscriptEvent(
                    speaker: speaker,
                    text: text,
                    wallClockTime: wallClock,
                    isFinal: result.isFinal
                )

                if result.isFinal {
                    addToReorderBuffer(event)
                } else {
                    // Volatile: show in terminal immediately
                    terminal.showVolatile(speaker: speaker, text: text)
                }
            }
        } catch {
            if !isStopped {
                terminal.printError("Transcription error for \(speaker): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Reorder Buffer

    private func addToReorderBuffer(_ event: TranscriptEvent) {
        reorderBuffer.append(event)
        flushReorderBuffer(currentTime: event.wallClockTime)
    }

    private func flushReorderBuffer(currentTime: UInt64) {
        let cutoff = currentTime > watermarkNanos ? currentTime - watermarkNanos : 0
        let ready = reorderBuffer.filter { $0.wallClockTime < cutoff }
            .sorted { $0.wallClockTime < $1.wallClockTime }

        for event in ready {
            writer.writeLine(speaker: event.speaker, text: event.text, wallClockTime: event.wallClockTime)
            terminal.showFinalized(speaker: event.speaker, text: event.text)
        }

        reorderBuffer.removeAll { $0.wallClockTime < cutoff }
    }

    func stop() {
        isStopped = true
        // Flush remaining reorder buffer
        let remaining = reorderBuffer.sorted { $0.wallClockTime < $1.wallClockTime }
        for event in remaining {
            writer.writeLine(speaker: event.speaker, text: event.text, wallClockTime: event.wallClockTime)
        }
        reorderBuffer.removeAll()
    }
}

// MARK: - Audio Format Conversion → AnalyzerInput

/// Creates an AsyncSequence of AnalyzerInput from timestamped audio buffers, converting format if needed.
@available(macOS 26.0, *)
func makeAnalyzerInputStream(
    from stream: AsyncStream<TimestampedBuffer>,
    targetFormat: AVAudioFormat
) -> AsyncStream<AnalyzerInput> {
    AsyncStream { continuation in
        Task {
            var converter: AVAudioConverter?

            for await timestamped in stream {
                let sourceFormat = timestamped.buffer.format

                // Initialize converter on first buffer if formats differ
                if converter == nil && sourceFormat != targetFormat {
                    converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                }

                let outputBuffer: AVAudioPCMBuffer
                if let converter {
                    let frameCapacity = AVAudioFrameCount(
                        Double(timestamped.buffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
                    )
                    guard frameCapacity > 0,
                          let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                        continue
                    }

                    var error: NSError?
                    nonisolated(unsafe) var consumed = false
                    converter.convert(to: convertedBuffer, error: &error) { _, outStatus in
                        if !consumed {
                            consumed = true
                            outStatus.pointee = .haveData
                            return timestamped.buffer
                        }
                        outStatus.pointee = .noDataNow
                        return nil
                    }

                    if error != nil || convertedBuffer.frameLength == 0 { continue }
                    outputBuffer = convertedBuffer
                } else {
                    outputBuffer = timestamped.buffer
                }

                // Wrap in AnalyzerInput
                let input = AnalyzerInput(buffer: outputBuffer)
                continuation.yield(input)
            }

            continuation.finish()
        }
    }
}
