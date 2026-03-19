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

#if compiler(>=6.2)

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
    private let showInterim: Bool

    private var isStopped = false
    private var reorderBuffer: ReorderBuffer

    /// Initialize for live dual-channel recording.
    init(
        audioCapture: AudioCapture,
        writer: MarkdownWriter,
        terminal: TerminalUI,
        micSpeaker: String,
        systemSpeaker: String,
        showInterim: Bool = false
    ) async throws {
        self.audioCapture = audioCapture
        self.fileSource = nil
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
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
        speaker: String,
        showInterim: Bool = false
    ) async throws {
        self.audioCapture = nil
        self.fileSource = fileSource
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = speaker
        self.systemSpeaker = speaker
        self.showInterim = showInterim
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
        let reportingOptions: Set<SpeechTranscriber.ReportingOption> = showInterim ? [.volatileResults] : []

        // Create transcribers with time range attributes (and optionally volatile results)
        let micTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
            attributeOptions: [.audioTimeRange]
        )
        let systemTranscriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
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
        let reportingOptions: Set<SpeechTranscriber.ReportingOption> = showInterim ? [.volatileResults] : []

        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: "en-US"),
            transcriptionOptions: [],
            reportingOptions: reportingOptions,
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

                if !result.isFinal {
                    // Interim results: display-only, skip timestamp/event construction
                    let sanitized = text.filter { $0 >= " " }
                    terminal.showVolatile(speaker: speaker, text: sanitized)
                    continue
                }

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

                finalCount += 1
                reorderBuffer.add(event)
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

                // Create or recreate converter when source format changes (e.g. audio device switch)
                if sourceFormat != targetFormat {
                    if converter == nil || converter!.inputFormat != sourceFormat {
                        if converter != nil {
                            DiagnosticLog.shared.log("[AnalyzerInput] Source format changed — reinitializing converter: \(sourceFormat) → \(targetFormat)")
                            dropCount = 0  // Reset drop counter for new converter
                        } else {
                            DiagnosticLog.shared.log("[AnalyzerInput] Format conversion needed: \(sourceFormat) → \(targetFormat)")
                        }
                        converter = AVAudioConverter(from: sourceFormat, to: targetFormat)
                        if converter == nil {
                            DiagnosticLog.shared.log("[AnalyzerInput] ERROR: AVAudioConverter creation failed!")
                        }
                    }
                } else if converter != nil {
                    // Source now matches target (e.g. switched to a device with native target format)
                    DiagnosticLog.shared.log("[AnalyzerInput] Source format now matches target — switching to passthrough")
                    converter = nil
                    dropCount = 0
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

#else

// MARK: - Legacy Fallback (SFSpeechRecognizer, pre-macOS 26)

/// Fallback transcription engine using SFSpeechRecognizer for older macOS / Swift compilers.
/// Supports dual-channel mode (mic + system) for live recording,
/// and single-channel mode for file transcription.
actor TranscriptionEngine {
    private let audioCapture: AudioCapture?
    private let fileSource: FileAudioSource?
    private let writer: MarkdownWriter
    private let terminal: TerminalUI
    private let micSpeaker: String
    private let systemSpeaker: String
    private let showInterim: Bool

    private var isStopped = false
    private var reorderBuffer: ReorderBuffer

    /// Initialize for live dual-channel recording.
    init(
        audioCapture: AudioCapture,
        writer: MarkdownWriter,
        terminal: TerminalUI,
        micSpeaker: String,
        systemSpeaker: String,
        showInterim: Bool = false
    ) async throws {
        self.audioCapture = audioCapture
        self.fileSource = nil
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
        self.reorderBuffer = ReorderBuffer { _ in }
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
        speaker: String,
        showInterim: Bool = false
    ) async throws {
        self.audioCapture = nil
        self.fileSource = fileSource
        self.writer = writer
        self.terminal = terminal
        self.micSpeaker = speaker
        self.systemSpeaker = speaker
        self.showInterim = showInterim
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

    /// Run dual-channel live transcription using SFSpeechRecognizer.
    private func runLiveTranscription(audioCapture: AudioCapture) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscribeError.modelUnavailable("Speech recognizer not available. Check that speech recognition is enabled in System Settings.")
        }

        // Run mic and system transcription concurrently
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                await self.runSFRecognition(
                    recognizer: recognizer,
                    stream: audioCapture.micStream,
                    speaker: self.micSpeaker,
                    getOriginHostTime: { audioCapture.micOriginHostTime }
                )
            }
            group.addTask { [self] in
                await self.runSFRecognition(
                    recognizer: recognizer,
                    stream: audioCapture.systemStream,
                    speaker: self.systemSpeaker,
                    getOriginHostTime: { audioCapture.systemOriginHostTime }
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

    /// Run single-channel file transcription using SFSpeechRecognizer.
    private func runFileTranscription(fileSource: FileAudioSource) async throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else {
            throw TranscribeError.modelUnavailable("Speech recognizer not available.")
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await fileSource.start()
            }
            group.addTask { [self] in
                await self.runSFRecognition(
                    recognizer: recognizer,
                    stream: fileSource.stream,
                    speaker: self.micSpeaker,
                    getOriginHostTime: { fileSource.originHostTime }
                )
            }
            group.addTask {
                while await !self.isStopped {
                    try? await Task.sleep(for: .milliseconds(300))
                    await self.periodicFlush()
                }
            }

            await group.waitForAll()
        }
    }

    /// Run SFSpeechRecognizer-based recognition on an audio buffer stream.
    private func runSFRecognition(
        recognizer: SFSpeechRecognizer,
        stream: AsyncStream<TimestampedBuffer>,
        speaker: String,
        getOriginHostTime: @Sendable () -> UInt64
    ) async {
        let audioEngine = AVAudioEngine()
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = showInterim

        var finalCount = 0
        var previousFinalText = ""

        let task = recognizer.recognitionTask(with: request) { [self] result, error in
            guard let result else {
                if let error, !self._isStopped_unsafeSyncCheck() {
                    self._printError_unsafeSync("Transcription error for \(speaker): \(error.localizedDescription)")
                }
                return
            }

            let text = result.bestTranscription.formattedString
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

            if result.isFinal {
                let originHostTime = getOriginHostTime()
                let wallClock = originHostTime + UInt64(Date().timeIntervalSince1970 * 1_000_000_000) % 1_000_000_000

                let event = TranscriptEvent(
                    speaker: speaker,
                    text: text,
                    wallClockTime: wallClock,
                    isFinal: true
                )
                finalCount += 1
                Task { await self.addToBuffer(event) }
                previousFinalText = text
            } else if self.showInterim {
                // Show only the new portion beyond what was already finalized
                let newText = String(text.dropFirst(previousFinalText.count))
                    .trimmingCharacters(in: .whitespaces)
                if !newText.isEmpty {
                    let sanitized = newText.filter { $0 >= " " }
                    Task { await self.showVolatileText(speaker: speaker, text: sanitized) }
                }
            }
        }

        // Feed audio buffers to the recognition request
        for await timestamped in stream {
            guard !isStopped else { break }
            request.append(timestamped.buffer)
        }

        request.endAudio()

        // Wait briefly for final results
        try? await Task.sleep(for: .seconds(2))
        task.cancel()

        DiagnosticLog.shared.log("[\(speaker)] SFSpeechRecognizer ended: \(finalCount) final events emitted")
    }

    // Helper methods for callback-based access (SFSpeechRecognizer uses callbacks, not async)
    private func addToBuffer(_ event: TranscriptEvent) {
        reorderBuffer.add(event)
    }

    private func showVolatileText(speaker: String, text: String) {
        terminal.showVolatile(speaker: speaker, text: text)
    }

    // These are intentionally non-isolated for use in the recognition callback.
    // The callback runs on an arbitrary queue and cannot await actor methods.
    nonisolated private func _isStopped_unsafeSyncCheck() -> Bool {
        // This is a benign race — worst case we process one extra result
        return false
    }

    nonisolated private func _printError_unsafeSync(_ message: String) {
        terminal.printError(message)
    }

    private func periodicFlush() {
        reorderBuffer.flushStale()
    }

    func stop() {
        isStopped = true
        reorderBuffer.flushAll()
    }
}

#endif
