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

/// Manages SpeechTranscriber instances and merges results.
/// Supports dual-channel mode (mic + system) for live recording,
/// and single-channel mode for file transcription.
@available(macOS 26.0, *)
actor TranscriptionEngine {
    private let audioCapture: AudioCapture?
    private let fileSource: FileAudioSource?
    private let writer: MarkdownWriter
    private let terminal: TerminalUI
    private let micSpeaker: String
    private let systemSpeaker: String

    private var isStopped = false
    private var reorderBuffer: ReorderBuffer

    /// Initialize for live dual-channel recording.
    init(
        audioCapture: AudioCapture,
        writer: MarkdownWriter,
        terminal: TerminalUI,
        micSpeaker: String,
        systemSpeaker: String
    ) async throws {
        self.audioCapture = audioCapture
        self.fileSource = nil
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        // Temporary placeholder — will be replaced after self is fully initialized
        self.reorderBuffer = ReorderBuffer { _ in }
        // Now replace with real callback that captures self
        self.reorderBuffer = ReorderBuffer { [writer, terminal] event in
            writer.writeLine(speaker: event.speaker, text: event.text, wallClockTime: event.wallClockTime)
            terminal.showFinalized(speaker: event.speaker, text: event.text)
        }
    }

    /// Initialize for single-channel file transcription.
    init(
        fileSource: FileAudioSource,
        writer: MarkdownWriter,
        terminal: TerminalUI,
        speaker: String
    ) async throws {
        self.audioCapture = nil
        self.fileSource = fileSource
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = speaker
        self.systemSpeaker = speaker
        self.reorderBuffer = ReorderBuffer { _ in }
        self.reorderBuffer = ReorderBuffer { [writer, terminal] event in
            writer.writeLine(speaker: event.speaker, text: event.text, wallClockTime: event.wallClockTime)
            terminal.showFinalized(speaker: event.speaker, text: event.text)
        }
    }

    /// Run transcription until stopped or input is exhausted.
    func run() async throws {
        if let fileSource {
            try await runFileTranscription(fileSource: fileSource)
        } else if let audioCapture {
            try await runLiveTranscription(audioCapture: audioCapture)
        }
    }

    /// Run dual-channel live transcription.
    private func runLiveTranscription(audioCapture: AudioCapture) async throws {
        // Create transcribers with volatile results and time range attributes
        let micTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
        let systemTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
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
                    getOriginHostTime: { self.audioCapture!.micOriginHostTime }
                )
            }
            group.addTask { [self] in
                await self.processResults(
                    transcriber: systemTranscriber,
                    speaker: self.systemSpeaker,
                    getOriginHostTime: { self.audioCapture!.systemOriginHostTime }
                )
            }

            // Periodic flush: drain any events stuck in the reorder buffer
            group.addTask {
                while await !self.isStopped {
                    try? await Task.sleep(for: .milliseconds(300))
                    await self.periodicFlush()
                }
            }

            await group.waitForAll()
        }
    }

    /// Run single-channel file transcription.
    private func runFileTranscription(fileSource: FileAudioSource) async throws {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscribeError.modelUnavailable("No compatible audio format available. The speech model may not be installed.")
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let inputStream = makeAnalyzerInputStream(from: fileSource.stream, targetFormat: format)

        await withTaskGroup(of: Void.self) { group in
            // Feed audio from file
            group.addTask {
                try? await fileSource.start()
            }
            // Run analyzer
            group.addTask {
                try? await analyzer.start(inputSequence: inputStream)
            }
            // Process results
            group.addTask { [self] in
                await self.processResults(
                    transcriber: transcriber,
                    speaker: self.micSpeaker,
                    getOriginHostTime: { fileSource.originHostTime }
                )
            }
            // Periodic flush
            group.addTask {
                while await !self.isStopped {
                    try? await Task.sleep(for: .milliseconds(300))
                    await self.periodicFlush()
                }
            }

            await group.waitForAll()
        }
    }

    /// Process results from a single transcriber.
    private func processResults(
        transcriber: SpeechTranscriber,
        speaker: String,
        getOriginHostTime: @Sendable () -> UInt64
    ) async {
        var resultCount = 0
        var finalCount = 0
        do {
            for try await result in transcriber.results {
                guard !isStopped else { break }
                resultCount += 1

                let text = String(result.text.characters)
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

                // Read originHostTime lazily — it's set by the audio callback on first buffer
                let originHostTime = getOriginHostTime()
                if originHostTime == 0 {
                    DiagnosticLog.shared.log("[\(speaker)] originHostTime still 0 at result #\(resultCount) — timestamps will be inaccurate")
                }

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
                    finalCount += 1
                    reorderBuffer.add(event)
                }
            }
        } catch {
            if !isStopped {
                terminal.printError("Transcription error for \(speaker): \(error.localizedDescription)")
            }
        }
        DiagnosticLog.shared.log("[\(speaker)] processResults ended: \(resultCount) results, \(finalCount) final events emitted")
    }

    private func periodicFlush() {
        reorderBuffer.flushStale()
    }

    func stop() {
        isStopped = true
        reorderBuffer.flushAll()
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
            var bufferCount = 0
            var dropCount = 0

            for await timestamped in stream {
                bufferCount += 1
                let sourceFormat = timestamped.buffer.format

                // Initialize converter on first buffer if formats differ
                if converter == nil && sourceFormat != targetFormat {
                    DiagnosticLog.shared.log("[AnalyzerInput] Format conversion needed: \(sourceFormat) → \(targetFormat)")
                    converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                    if converter == nil {
                        DiagnosticLog.shared.log("[AnalyzerInput] ERROR: AVAudioConverter creation failed!")
                    }
                }

                let outputBuffer: AVAudioPCMBuffer
                if let converter {
                    let frameCapacity = AVAudioFrameCount(
                        Double(timestamped.buffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate
                    )
                    guard frameCapacity > 0,
                          let convertedBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCapacity) else {
                        dropCount += 1
                        if dropCount <= 5 {
                            DiagnosticLog.shared.log("[AnalyzerInput] Dropped buffer #\(bufferCount): could not allocate converted buffer (frameCapacity=\(frameCapacity))")
                        }
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

                    if let error {
                        dropCount += 1
                        if dropCount <= 5 {
                            DiagnosticLog.shared.log("[AnalyzerInput] Conversion error at buffer #\(bufferCount): \(error.localizedDescription)")
                        }
                        continue
                    }
                    if convertedBuffer.frameLength == 0 {
                        dropCount += 1
                        if dropCount <= 5 {
                            DiagnosticLog.shared.log("[AnalyzerInput] Conversion produced 0 frames at buffer #\(bufferCount)")
                        }
                        continue
                    }
                    outputBuffer = convertedBuffer
                } else {
                    outputBuffer = timestamped.buffer
                }

                // Wrap in AnalyzerInput
                let input = AnalyzerInput(buffer: outputBuffer)
                continuation.yield(input)
            }

            if dropCount > 0 {
                DiagnosticLog.shared.log("[AnalyzerInput] Stream ended: \(bufferCount) buffers received, \(dropCount) dropped")
            }
            continuation.finish()
        }
    }
}
