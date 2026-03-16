# Plan: Add Recording Output to the Swift Transcriber

**Created:** 2026-03-16
**Session:** `~/.claude/projects/-Users-jtennant-Development/c15d1124-70ee-4610-966c-00e94fd82278.jsonl`
**Status:** Approved

## Problem

The transcriber currently produces only text transcripts (`~/Documents/transcripts/*.md`). Recordings from Piezo land in `/Volumes/1TBSD/Piezo/` as `.m4a` files, but the transcriber's live recording mode does not save the captured audio. There is no way to go back and re-listen, re-transcribe with a better model (ElevenLabs, FluidAudio), or verify transcript accuracy against the source audio.

The existing folder action (`/Volumes/1TBSD/Piezo/on-new-file.sh`) transcribes Piezo recordings via OpenAI Whisper, producing `.txt` sidecar files. But the Swift transcriber's `--file` mode and live mode operate independently with no recording output.

## Goal

Add the ability for the transcriber to save captured audio as a file alongside the transcript. This applies to two modes:

1. **Live recording mode** (mic + system audio) -- save the captured audio to files
2. **File transcription mode** (`--file`) -- reference the source recording path in the transcript metadata (the file already exists, no need to copy)

## Current Architecture Summary

- **Entry point:** `Transcribe.swift` -- CLI with `--title`, `--resume`, `--file`, `--speakers`, `--list`
- **Audio capture:** `AudioCapture.swift` -- `AVAudioEngine` (mic) + `ScreenCaptureKit` (system audio), produces `AsyncStream<TimestampedBuffer>`
- **File input:** `FileAudioSource.swift` -- reads audio files into the same `AsyncStream<TimestampedBuffer>` format
- **Transcription:** `TranscriptionEngine.swift` -- feeds audio to `SpeechTranscriber`, collects results through `ReorderBuffer`
- **Output:** `MarkdownWriter.swift` -- writes transcript markdown to `~/Documents/transcripts/{slug}-{date}.md`
- **Terminal:** `TerminalUI.swift` -- colored terminal output

Key types:
- `TimestampedBuffer` -- `AVAudioPCMBuffer` + `UInt64` host time
- `TranscriptEvent` -- speaker + text + wall clock time + isFinal

Transcript output directory: `~/Documents/transcripts/`
Recording input directory: `/Volumes/1TBSD/Piezo/`

## Design Decisions

### Recording format: CAF (Core Audio Format)

Use `.caf` for live recording output. Reasons:
- Native Apple format, no external dependencies
- Supports any codec AVFoundation can write (including lossless PCM)
- Can be written incrementally (append-friendly, crash-safe)
- Can be converted to `.m4a` after recording if desired
- `AVAudioFile` supports CAF natively for writing

For file transcription mode, just record the basename of the source file in the transcript metadata -- no need to copy.

### Recording location

Save recordings alongside transcripts in `~/Documents/transcripts/` with matching filenames:
```
~/Documents/transcripts/recording-2026-03-16-1430.md       # transcript
~/Documents/transcripts/recording-2026-03-16-1430.mic.caf  # mic recording
~/Documents/transcripts/recording-2026-03-16-1430.sys.caf  # system audio recording
```

This keeps transcript and recordings together. The alternative (saving to `/Volumes/1TBSD/Piezo/`) was rejected because that volume may not be mounted and is specific to Piezo.

### Two independent mono files (not interleaved stereo)

For live mode, save mic and system audio as **two separate mono CAF files** rather than a single interleaved stereo file:
- `{slug}-{date}.mic.caf` -- Microphone audio (you)
- `{slug}-{date}.sys.caf` -- System audio (remote)

**Rationale:** Writing independent mono files avoids the complexity of realtime stereo alignment. Mic and system audio buffers arrive asynchronously at different rates and potentially different sample rates. Interleaving them into a single stereo file would require a timestamp-based mixer to align frames, which is fragile and error-prone. Two mono files:
- Are trivially simple to write (one `AVAudioFile` per channel)
- Still preserve speaker separation for post-processing (ElevenLabs, FluidAudio)
- Can be merged into stereo offline if needed (`ffmpeg -i mic.caf -i sys.caf -filter_complex amerge out.wav`)
- Each file has correct duration independent of the other channel

### Recording in capture callbacks (not stream tapping)

Record audio **inside `AudioCapture`** on a dedicated serial writer queue, not by tapping the `AsyncStream`. The existing streams use `.bufferingNewest(256)` which drops old buffers under load. Recording via stream tapping would lose audio when transcription is slow. Instead:
- Add an optional `AudioRecorder` reference to `AudioCapture`
- Write buffers to the recorder directly in the `AVAudioEngine` tap callback and `SCStreamOutput` delegate
- The recorder's internal serial `DispatchQueue` handles thread safety
- This ensures every captured buffer is recorded regardless of transcription pipeline backpressure

### Buffer ownership and normalization strategy

`AVAudioEngine` tap callbacks provide buffers that may be recycled after the callback returns. To ensure correctness:

1. **Synchronous normalization:** The `AudioRecorder.write()` method performs **all format normalization synchronously** on the callback thread, producing an owned mono float32 buffer. This includes:
   - Converting any format (int16, int32, float, interleaved, non-interleaved) to non-interleaved float32 mono via `AVAudioConverter`
   - The resulting buffer is newly allocated and fully owned by the recorder

2. **Async file write:** Only the owned, normalized buffer is dispatched to the serial queue for file I/O. The original callback buffer is never accessed after `write()` returns.

This approach eliminates the interleaved buffer copy problem entirely -- we never try to deep-copy arbitrary buffer layouts. Instead, `AVAudioConverter` handles all format variance, and the output is always a clean mono float32 buffer.

### CLI flags

- `--no-recording` -- skip saving the audio file (default: recording is saved)
- No flag needed to enable recording -- it should be the default behavior since recordings enable re-transcription with better models (Path A/B in PLAN.md)

For `--file` mode: embed a `*Source: filename.m4a*` line (basename only, not full path) in the transcript header instead of copying the file. This avoids leaking absolute paths when sharing transcripts.

### Resume policy

When `--resume` is used, **skip recording**. Rationale:
- `AVAudioFile(forWriting:)` truncates existing files -- we cannot safely append to a CAF
- Creating segmented files (`*-part2.caf`) adds complexity with minimal benefit for a first version
- The resumed transcript already has a recording from the original session (or none if `--no-recording` was used)
- Print an info message: "Recording skipped (resume mode)"

This can be revisited later to support segmented recordings if needed.

### File permissions

Recording files must use `0600` permissions (matching transcript files). Create the file with `FileManager.createFile(atPath:contents:attributes:[.posixPermissions: 0o600])` before opening with `AVAudioFile`.

### Shutdown ordering

Shutdown must follow a strict sequence to avoid dropping tail audio or writing to closed files:

1. `engine.stop()` -- stop transcription processing
2. `capture.stop()` -- stop audio capture; must be **synchronous** (see below)
3. `recorder.stop()` -- drain the serial write queue (`queue.sync`) and close the file
4. `writer.flush()` -- flush transcript to disk
5. Print summary

**Making `capture.stop()` synchronous:** The current `AudioCapture.stop()` calls `scStream?.stopCapture { _ in }` which returns immediately -- late ScreenCaptureKit callbacks can race with `recorder.stop()`. This plan requires changing `AudioCapture.stop()` to an async method that awaits `SCStream.stopCapture` completion:

```swift
func stop() async {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    _micContinuation.finish()

    if let scStream {
        await withCheckedContinuation { continuation in
            scStream.stopCapture { _ in
                continuation.resume()
            }
        }
    }
    _systemContinuation.finish()
}
```

This ensures no callbacks fire after `stop()` returns. The signal handler and shutdown code must call `await capture.stop()` instead of `capture.stop()`.

This ordering ensures:
- No new buffers are enqueued after `capture.stop()` returns
- The recorder's `queue.sync` in `stop()` drains all pending writes before closing
- The same ordering applies to the signal handler and error paths

### Startup failure cleanup

If recorder creation succeeds but `capture.start()` fails (e.g., permission denied after partial startup where mic started but system audio failed), clean up safely:

```swift
do {
    try await capture.start()
} catch {
    // Stop any partially started capture first (stops callbacks)
    await capture.stop()
    // Then drain and close recorders
    capture.micRecorder?.stop()
    capture.systemRecorder?.stop()
    // Then remove empty recording files
    if let micPath = micRecordingPath {
        try? FileManager.default.removeItem(at: micPath)
    }
    if let sysPath = sysRecordingPath {
        try? FileManager.default.removeItem(at: sysPath)
    }
    throw error
}
```

This ensures callbacks are fully stopped before we close recorders or delete files.

## Implementation Plan

### Phase 1: Add `AudioRecorder` class

Create a new file `Sources/Transcribe/AudioRecorder.swift`.

**Responsibilities:**
- Write mono PCM audio to a `.caf` file using `AVAudioFile`
- Handle format normalization (any input format -> non-interleaved float32 mono) synchronously
- Dispatch file writes to a dedicated serial `DispatchQueue`

**Key implementation details:**

```swift
// AudioRecorder.swift
import AVFoundation
import Foundation

/// Records a single channel of audio to a mono CAF file.
/// Thread-safe -- all file writes are serialized on an internal queue.
/// Format normalization happens synchronously on the caller's thread to ensure buffer ownership safety.
final class AudioRecorder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.transcriber.recorder", qos: .userInitiated)
    private var audioFile: AVAudioFile?
    private let outputFormat: AVAudioFormat  // mono PCM float32, non-interleaved
    private var sampleRateConverter: AVAudioConverter?
    private var normalizer: AVAudioConverter?  // cached per-format normalizer

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
            // Still need to copy for ownership safety
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

        return error == nil && converted.frameLength > 0 ? converted : nil
    }
}
```

### Phase 2: Integrate recording into `AudioCapture`

Modify `AudioCapture.swift` to accept optional recorders, write buffers in capture callbacks, and make `stop()` synchronous.

**Changes:**

1. Add optional recorder properties:
```swift
nonisolated(unsafe) var micRecorder: AudioRecorder?
nonisolated(unsafe) var systemRecorder: AudioRecorder?
```

2. In `startMicCapture()`, inside the `installTap` callback, add after yielding to continuation:
```swift
self.micRecorder?.write(buffer: buffer)
```

The `write()` method normalizes synchronously (producing an owned buffer) before the callback returns, then dispatches the file write asynchronously.

3. In `SystemAudioDelegate.stream(_:didOutputSampleBuffer:of:)`, add after yielding to continuation:
```swift
recorder?.write(buffer: pcmBuffer)
```

This requires `SystemAudioDelegate` to hold a reference to the recorder. Update its init:
```swift
init(
    continuation: AsyncStream<TimestampedBuffer>.Continuation,
    onFirstBuffer: @escaping (UInt64) -> Void,
    recorder: AudioRecorder? = nil
) {
    self.continuation = continuation
    self.onFirstBuffer = onFirstBuffer
    self.recorder = recorder
    super.init()
}
```

4. **Make `stop()` async and synchronous with respect to callbacks:**
```swift
func stop() async {
    audioEngine?.stop()
    audioEngine?.inputNode.removeTap(onBus: 0)
    _micContinuation.finish()

    if let scStream {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scStream.stopCapture { _ in
                continuation.resume()
            }
        }
    }
    _systemContinuation.finish()
}
```

This ensures no ScreenCaptureKit callbacks fire after `stop()` returns. `AVAudioEngine.stop()` is already synchronous for mic callbacks.

### Phase 3: Wire recording in `Transcribe.swift`

Modify `Transcribe.swift`:

1. **Add `--no-recording` flag:**
```swift
@Flag(name: .long, help: "Skip saving the audio recording.")
var noRecording = false
```

2. **In `runLiveRecording()`**, after creating `AudioCapture` and before `capture.start()`:
```swift
var micRecordingPath: URL? = nil
var sysRecordingPath: URL? = nil

if !noRecording && !isResume {
    let basePath = filePath.deletingPathExtension()
    micRecordingPath = basePath.appendingPathExtension("mic.caf")
    sysRecordingPath = basePath.appendingPathExtension("sys.caf")

    let micRecorder = AudioRecorder()
    try micRecorder.start(filePath: micRecordingPath!)
    capture.micRecorder = micRecorder

    let sysRecorder = AudioRecorder()
    try sysRecorder.start(filePath: sysRecordingPath!)
    capture.systemRecorder = sysRecorder
} else if isResume {
    terminal.printInfo("Recording skipped (resume mode)")
}
```

3. **Wrap `capture.start()` with cleanup on failure:**
```swift
do {
    try await capture.start()
} catch {
    // Stop any partially started capture (stops callbacks)
    await capture.stop()
    // Drain and close recorders
    capture.micRecorder?.stop()
    capture.systemRecorder?.stop()
    // Remove empty recording files
    if let micPath = micRecordingPath {
        try? FileManager.default.removeItem(at: micPath)
    }
    if let sysPath = sysRecordingPath {
        try? FileManager.default.removeItem(at: sysPath)
    }
    throw error
}
```

4. **In the signal handler and normal shutdown**, use correct ordering:
```swift
// 1. Stop transcription
await engine.stop()
// 2. Stop capture synchronously (no more callbacks after this)
await capture.stop()
// 3. Drain and close recording files
capture.micRecorder?.stop()
capture.systemRecorder?.stop()
// 4. Flush transcript
writer.flush()
// 5. Print summary
terminal.printSummary(
    duration: Date().timeIntervalSince(startTime),
    wordCount: writer.wordCount,
    filePath: filePath,
    recordingPaths: [micRecordingPath, sysRecordingPath].compactMap { $0 }
)
```

5. **Update all existing `capture.stop()` call sites** to use `await capture.stop()` since it's now async.

**Note:** `TranscriptionEngine` does NOT need to be refactored. Recording happens at the `AudioCapture` level, so `TranscriptionEngine` continues to accept `AudioCapture` as before. No signature changes needed.

### Phase 4: Handle `--file` mode recording reference

For `--file` transcription mode, instead of recording (the audio already exists), add a source reference line to the transcript.

In `MarkdownWriter.swift`, add an optional source filename parameter:
```swift
init(filePath: URL, title: String, isResume: Bool,
     micSpeaker: String, systemSpeaker: String,
     sourceAudioFilename: String? = nil) throws {
    // ... existing init ...
    if !isResume, let sourceAudioFilename {
        let line = "*Source: \(sourceAudioFilename)*\n\n"
        fileHandle.write(line.data(using: .utf8)!)
    }
}
```

The new parameter has a default value of `nil`, so **existing call sites and tests are not broken**.

Update the call in `runFileTranscription()`:
```swift
let writer = try MarkdownWriter(
    filePath: outputPath,
    title: fileTitle,
    isResume: isResume,
    micSpeaker: speakerName,
    systemSpeaker: speakerName,
    sourceAudioFilename: fileURL.lastPathComponent
)
```

### Phase 5: Update `TerminalUI` summary

Add recording paths to the session summary:

```swift
func printSummary(duration: TimeInterval, wordCount: Int,
                  filePath: URL, recordingPaths: [URL] = []) {
    // ... existing summary ...
    for path in recordingPaths {
        print("  Recording: \(path.path)")
    }
}
```

The new parameter has a default value of `[]`, so **existing call sites and tests are not broken**.

### Phase 6: Update existing tests

Update tests that are affected by signature changes:

1. **`MarkdownWriterTests`**: Verify existing tests still compile (they should, since new parameter defaults to `nil`). Add a new test that verifies the source line is written when `sourceAudioFilename` is provided.

2. **`EndToEndTranscriptionTests`**: These invoke the binary via `Process` and should continue to work unchanged (no breaking CLI changes).

3. **New test file `AudioRecorderTests.swift`**:
   - Test writing mono float32 buffers and reading them back, verify content matches
   - Test writing multi-channel input (verify downmix produces mono output)
   - Test writing int16 format input (verify format normalization)
   - Test `stop()` closes the file properly (subsequent writes are no-ops)
   - Test file has `0600` permissions after creation
   - Test buffer ownership: create a buffer, call `write()`, mutate the original buffer's data after `write()` returns, verify the recorded audio has the pre-mutation values (proves synchronous normalization produces owned buffers)

4. **New test for source reference in transcript**: Write a `MarkdownWriter` with `sourceAudioFilename: "test.m4a"`, read the file, verify `*Source: test.m4a*` appears in header.

5. **Verify all existing tests pass**: `swift test` must succeed with no modifications to existing test code (all new parameters have defaults).

### Phase 7: Update folder action (optional)

Update `/Volumes/1TBSD/Piezo/on-new-file.sh` to use the Swift transcriber instead of OpenAI Whisper:

```bash
# Replace the curl call with:
/usr/local/bin/transcribe --file "$file" --speakers "Speaker"
```

This is optional and can be done separately since the folder action currently works with Whisper. The Swift transcriber's `--file` mode already handles `.m4a` files.

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/Transcribe/AudioRecorder.swift` | **NEW** -- mono CAF writer with synchronous normalization and async file I/O |
| `Sources/Transcribe/AudioCapture.swift` | Add optional `micRecorder`/`systemRecorder` properties, write in capture callbacks, make `stop()` async with `SCStream.stopCapture` awaited |
| `Sources/Transcribe/Transcribe.swift` | Add `--no-recording` flag, create recorders, wire to `AudioCapture`, handle resume skip, startup cleanup, shutdown ordering, update `capture.stop()` calls to async |
| `Sources/Transcribe/MarkdownWriter.swift` | Add optional `sourceAudioFilename` parameter to init (default `nil`) |
| `Sources/Transcribe/TerminalUI.swift` | Add `recordingPaths` parameter to `printSummary` (default `[]`) |
| `Tests/TranscribeTests/AudioRecorderTests.swift` | **NEW** -- unit tests for `AudioRecorder` |

**Files NOT modified** (no changes needed):
| File | Reason |
|------|--------|
| `Sources/Transcribe/TranscriptionEngine.swift` | Recording happens at `AudioCapture` level, no refactor needed |
| `Sources/Transcribe/FileAudioSource.swift` | No changes needed |
| `Sources/Transcribe/ReorderBuffer.swift` | No changes needed |

## Testing

1. **Unit test `AudioRecorder`:** Write mono float32 buffers, read back, verify content and format
2. **Unit test downmix:** Write stereo input, verify mono output
3. **Unit test format normalization:** Write int16 input, verify float32 output
4. **Unit test buffer ownership:** Write buffer, mutate original after write() returns, verify recording has pre-mutation data
5. **Unit test permissions:** Verify `.caf` files are created with `0600`
6. **Unit test `MarkdownWriter` source reference:** Verify `*Source: filename*` appears in header
7. **Integration test:** Run `transcribe --file ~/some-test.m4a` and verify the source reference appears in the transcript
8. **Manual test (live):** Run `transcribe --title "test"`, speak briefly, Ctrl+C, verify `.mic.caf` and `.sys.caf` files exist alongside `.md`, play them back
9. **Manual test (`--no-recording`):** Run `transcribe --no-recording`, verify no `.caf` files are created
10. **Manual test (`--resume`):** Run `transcribe --resume-last`, verify "Recording skipped (resume mode)" message and no new `.caf` files
11. **Verify existing tests still pass:** `swift test` in the project root

## Build & Verify

```bash
cd ~/Development/jtennant-transcriber
swift build          # must compile
swift test           # existing tests must pass
```

## Risks & Notes

- **Disk space:** Live recordings at 48kHz mono PCM can be large (~10MB/min per channel uncompressed). Consider adding a post-recording compression step (convert CAF to AAC m4a via `AVAssetExportSession`) or using a compressed format. This can be a follow-up.
- **Sample rate mismatch:** Mic and system audio may have different sample rates. Each `AudioRecorder` instance handles its own sample rate conversion independently.
- **Channel count variance:** System audio from ScreenCaptureKit may be stereo or multi-channel. The recorder normalizes to mono automatically via `AVAudioConverter`.
- **Format variance:** Input may be int16, int32, float32, interleaved or non-interleaved. The normalization step uses `AVAudioConverter` to handle all cases, with diagnostic logging on failure.
- **Crash safety:** `AVAudioFile` writes are durable -- if the process crashes, the CAF file will contain all audio written up to that point (unlike some container formats that need finalization).
- **Path A/B enablement:** Saving recordings is a prerequisite for Path A (ElevenLabs post-processing) and Path B (FluidAudio post-processing) from `PLAN.md`. Those paths need audio files to re-transcribe.
- **No buffer drops:** Recording happens in capture callbacks with synchronous normalization, independent of the transcription `AsyncStream` pipeline. Every captured buffer is recorded.
- **Buffer ownership:** All format conversion/normalization happens synchronously in `write()`, producing owned buffers. The original callback buffer is never accessed after `write()` returns.
- **Synchronous shutdown:** `AudioCapture.stop()` is async and awaits `SCStream.stopCapture` completion, guaranteeing no late callbacks after it returns.
- **Resume limitation:** Recording is skipped on `--resume`. Segmented recording support can be added later if needed.
- **Callback thread latency:** Format normalization on the capture callback thread adds latency. For typical buffer sizes (4096 frames at 48kHz = ~85ms), `AVAudioConverter` normalization should complete well within the buffer period. If profiling shows issues, normalization can be moved to a separate high-priority queue with owned copies, but this is unlikely to be needed.
