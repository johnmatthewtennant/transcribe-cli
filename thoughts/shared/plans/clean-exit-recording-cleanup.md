# Plan: Clean Exit and Recording Cleanup

## Summary

On exit (Escape key or Ctrl-C SIGINT), merge the two mono CAF files (.mic.caf + .sys.caf) into a single stereo M4A (AAC-compressed). Raw CAFs are kept by default; add `--delete-raw-recordings` to remove them after merge. Also add Escape as a clean exit trigger alongside Ctrl-C.

## Current State

- **Signal handling:** `setupSignalHandler()` in `Transcribe.swift` (line 446) installs a `DispatchSource.makeSignalSource` for SIGINT. The handler calls `engine.stop()`, `capture.stop()`, recorder stops, `writer.flush()`, prints summary, then `Foundation.exit(0)`.
- **Recording files:** Created in `runLiveRecording()` (line 179-212). Two `AudioRecorder` instances write mono PCM float32 CAF files at 48kHz: `<slug>-<date>.mic.caf` and `<slug>-<date>.sys.caf`. Paths are derived from the transcript `.md` path by replacing the extension.
- **AudioRecorder:** Writes raw PCM to CAF via `AVAudioFile`. `stop()` closes the file synchronously on its internal queue.
- **No Escape key handling** currently exists. The terminal is in cooked mode; there is no raw-mode keyboard listener.
- **Existing merge reminder:** There is a separate reminder for a `transcribe merge` subcommand (manual merge). This plan covers automatic merge on exit. The merge logic can be shared later.

## Design Decisions

1. **Output format: AAC in M4A container.** AVAudioFile supports writing compressed formats when you pass AAC settings and specify the processing format separately. The file type is inferred from the .m4a extension. This avoids shelling out to ffmpeg.
2. **Escape key detection:** Use POSIX `termios` to put stdin into raw mode on a background thread, reading single keystrokes. Guard with `isatty(STDIN_FILENO)` to skip when not interactive. When Escape (0x1B) is detected, trigger the same shutdown path as SIGINT. Restore terminal settings on exit.
3. **Cleanup is best-effort.** If merge fails (corrupt files, disk full), log the error but still exit cleanly. The original CAFs remain as fallback.
4. **Keep raw CAFs by default.** The merged M4A is a convenience output. Add a `--delete-raw-recordings` flag to remove the originals after successful merge. This prevents irreversible data loss.
5. **Chunked merge for memory safety.** Read and write in fixed-size chunks (e.g., 64K frames per chunk) to avoid OOM on long recordings. A 4-hour recording at 48kHz float32 would be ~2.6 GB in memory without chunking.
6. **Thread-safe shutdown reentrancy guard.** Use `OSAllocatedUnfairLock<Bool>` to prevent duplicate shutdown from rapid Ctrl-C / Escape presses. SIGINT is delivered on `.main` via DispatchSourceSignal, while Escape is handled on a global queue, so a proper synchronization primitive is required.

## Implementation Plan

### File 1: New file `Sources/Transcribe/AudioMerger.swift`

A utility that merges two mono CAF files into a single stereo AAC/M4A file using chunked I/O.

```swift
import AVFoundation
import Foundation

/// Merges two mono CAF audio files into a single stereo AAC-compressed M4A file.
/// Left channel = mic (local), Right channel = system (remote).
/// Uses chunked I/O to bound memory usage regardless of recording length.
enum AudioMerger {

    /// Number of frames to process per chunk. 64K frames at 48kHz = ~1.3 seconds.
    private static let chunkSize: AVAudioFrameCount = 65536

    /// Merge two mono CAF files into a stereo M4A.
    /// - Parameters:
    ///   - micPath: Path to the mono mic CAF file
    ///   - sysPath: Path to the mono system audio CAF file
    ///   - outputPath: Desired output path (should have .m4a extension)
    /// - Returns: The output URL on success
    /// - Throws: On read/write/conversion errors
    @discardableResult
    static func mergeToStereoAAC(
        micPath: URL,
        sysPath: URL,
        outputPath: URL
    ) throws -> URL {
        // 1. Open both mono CAF files
        let micFile = try AVAudioFile(forReading: micPath)
        let sysFile = try AVAudioFile(forReading: sysPath)

        // 2. Validate formats
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
        let micLength = AVAudioFrameCount(micFile.length)
        let sysLength = AVAudioFrameCount(sysFile.length)
        let maxFrames = max(micLength, sysLength)

        // 3. Validate at least one input has audio
        guard maxFrames > 0 else {
            throw TranscribeError.captureError("Both recording files are empty — nothing to merge")
        }

        // 4. Create stereo format and output file
        guard let stereoFormat = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: 2
        ) else {
            throw TranscribeError.captureError("Cannot create stereo format")
        }

        // Pre-create with restrictive permissions
        FileManager.default.createFile(
            atPath: outputPath.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        )

        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000  // 128 kbps stereo
        ]

        let outputFile = try AVAudioFile(
            forWriting: outputPath,
            settings: aacSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )

        // 5. Allocate reusable chunk buffers
        guard let micChunk = AVAudioPCMBuffer(pcmFormat: micFormat, frameCapacity: chunkSize),
              let sysChunk = AVAudioPCMBuffer(pcmFormat: sysFormat, frameCapacity: chunkSize),
              let stereoChunk = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: chunkSize) else {
            throw TranscribeError.captureError("Cannot allocate merge buffers")
        }

        // 6. Process in chunks
        var framesWritten: AVAudioFrameCount = 0
        while framesWritten < maxFrames {
            let remaining = maxFrames - framesWritten
            let thisChunk = min(chunkSize, remaining)

            // Read mic chunk (or zero if past end)
            var micActual: AVAudioFrameCount = 0
            if framesWritten < micLength {
                let micAvail = min(thisChunk, micLength - framesWritten)
                micChunk.frameLength = 0
                try micFile.read(into: micChunk, frameCount: micAvail)
                micActual = micChunk.frameLength  // validate actual frames read
            }

            // Read sys chunk (or zero if past end)
            var sysActual: AVAudioFrameCount = 0
            if framesWritten < sysLength {
                let sysAvail = min(thisChunk, sysLength - framesWritten)
                sysChunk.frameLength = 0
                try sysFile.read(into: sysChunk, frameCount: sysAvail)
                sysActual = sysChunk.frameLength  // validate actual frames read
            }

            // Build stereo chunk
            stereoChunk.frameLength = thisChunk
            guard let stereoChannels = stereoChunk.floatChannelData else {
                throw TranscribeError.captureError("Cannot access stereo channel data")
            }

            // Left channel = mic
            if micActual > 0, let micData = micChunk.floatChannelData {
                memcpy(stereoChannels[0], micData[0], Int(micActual) * MemoryLayout<Float>.size)
            }
            if micActual < thisChunk {
                memset(stereoChannels[0].advanced(by: Int(micActual)), 0,
                       Int(thisChunk - micActual) * MemoryLayout<Float>.size)
            }

            // Right channel = sys
            if sysActual > 0, let sysData = sysChunk.floatChannelData {
                memcpy(stereoChannels[1], sysData[0], Int(sysActual) * MemoryLayout<Float>.size)
            }
            if sysActual < thisChunk {
                memset(stereoChannels[1].advanced(by: Int(sysActual)), 0,
                       Int(thisChunk - sysActual) * MemoryLayout<Float>.size)
            }

            // Write stereo chunk to output
            try outputFile.write(from: stereoChunk)
            framesWritten += thisChunk
        }

        // 7. Re-enforce permissions after write (in case AVAudioFile changed them)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: outputPath.path
        )

        return outputPath
    }
}
```

**Key notes:**
- Chunked I/O bounds memory to ~3 x 64K frames x 4 bytes = ~768 KB regardless of recording length.
- Format validation catches mismatched sample rates, non-mono inputs, and empty files early with clear errors.
- If one file is shorter, the shorter channel is zero-padded (silence) for the remaining frames. This is the expected behavior when mic and system recordings have slightly different lengths.
- Output file permissions are set to 0600 both before and after writing, matching the security posture of the existing CAF recordings.
- After each `read(into:frameCount:)`, we use the buffer's actual `frameLength` rather than assuming the requested count was filled.

### File 2: Modify `Sources/Transcribe/Transcribe.swift`

#### Change 1: Add `--delete-raw-recordings` flag

After the existing `noRecording` flag (line 32-33), add:

```swift
@Flag(name: .long, help: "Delete original mono CAF files after successful merge to M4A.")
var deleteRawRecordings = false
```

#### Change 2: Add Escape key listener setup with `isatty` guard

Add a new function alongside `setupSignalHandler`. Use proper `c_cc` access via pointer arithmetic:

```swift
/// Retained globally so the dispatch source isn't deallocated.
private nonisolated(unsafe) var _stdinSource: DispatchSourceRead?
private nonisolated(unsafe) var _savedTermios: termios?

/// Set up raw-mode stdin listener that triggers handler on Escape key.
/// No-op if stdin is not a terminal (e.g., piped input).
/// Restores terminal settings when handler fires or on normal exit.
func setupEscapeKeyHandler(_ handler: @escaping () -> Void) {
    // Only set up raw mode if stdin is a real terminal
    guard isatty(STDIN_FILENO) != 0 else { return }

    // Save current terminal settings
    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    _savedTermios = oldTermios

    // Switch to raw mode (no echo, no canonical processing)
    var raw = oldTermios
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    // Set VMIN=1, VTIME=0 via pointer to avoid tuple indexing fragility
    withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
        let base = UnsafeMutableRawPointer(ptr)
            .assumingMemoryBound(to: cc_t.self)
        base[Int(VMIN)] = 1
        base[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &raw)

    // Register atexit handler as normal-exit fallback for terminal restoration.
    // Note: atexit does NOT run on crashes or SIGKILL — only on normal process
    // termination (exit(), return from main). This is a last-resort fallback,
    // not crash recovery.
    atexit {
        restoreTerminal()
    }

    // Monitor stdin for keystrokes on a background queue
    let source = DispatchSource.makeReadSource(fileDescriptor: STDIN_FILENO, queue: .global(qos: .userInitiated))
    source.setEventHandler {
        var buf = [UInt8](repeating: 0, count: 1)
        let n = read(STDIN_FILENO, &buf, 1)
        if n == 1 && buf[0] == 0x1B {  // Escape key
            restoreTerminal()
            handler()
        }
    }
    source.setCancelHandler {
        restoreTerminal()
    }
    source.resume()
    _stdinSource = source
}

func restoreTerminal() {
    if var saved = _savedTermios {
        tcsetattr(STDIN_FILENO, TCSANOW, &saved)
        _savedTermios = nil
    }
    _stdinSource?.cancel()
    _stdinSource = nil
}
```

#### Change 3: Add thread-safe shutdown reentrancy guard

Use `OSAllocatedUnfairLock` (available since macOS 13/Xcode 14) for proper synchronization between the SIGINT handler (delivered on `.main`) and the Escape handler (delivered on a global queue):

```swift
import os  // for OSAllocatedUnfairLock

private let _shutdownLock = OSAllocatedUnfairLock(initialState: false)
```

#### Change 4: Refactor the shutdown logic into a shared closure

In `runLiveRecording()`, extract the shutdown logic so both SIGINT and Escape trigger the same path. Replace lines 238-258:

```swift
// Build shutdown closure (shared by Ctrl+C and Escape)
let startTime = Date()
let recordingPaths = [micRecordingPath, sysRecordingPath].compactMap { $0 }
let deleteRaw = self.deleteRawRecordings
let hasRecording = !noRecording && !isResume

let shutdown: @Sendable () -> Void = {
    // Thread-safe guard against duplicate shutdown (atomic check-and-set)
    let alreadyShuttingDown = _shutdownLock.withLock { isShuttingDown -> Bool in
        if isShuttingDown { return true }
        isShuttingDown = true
        return false
    }
    guard !alreadyShuttingDown else { return }

    Task {
        await engine.stop()
        await capture.stop()
        capture.micRecorder?.stop()
        capture.systemRecorder?.stop()
        writer.flush()

        // Merge and compress recordings
        var finalRecordingPaths = recordingPaths
        if hasRecording, let micPath = micRecordingPath, let sysPath = sysRecordingPath {
            let m4aPath = filePath.deletingPathExtension().appendingPathExtension("m4a")
            terminal.printInfo("Merging recordings to \(m4aPath.lastPathComponent)...")
            do {
                try AudioMerger.mergeToStereoAAC(
                    micPath: micPath,
                    sysPath: sysPath,
                    outputPath: m4aPath
                )
                finalRecordingPaths = [m4aPath] + (deleteRaw ? [] : recordingPaths)

                // Delete originals only if --delete-raw-recordings
                if deleteRaw {
                    try? FileManager.default.removeItem(at: micPath)
                    try? FileManager.default.removeItem(at: sysPath)
                }
            } catch {
                terminal.printError("Failed to merge recordings: \(error.localizedDescription)")
                terminal.printInfo("Raw recordings preserved at original paths.")
                // Keep finalRecordingPaths as the original CAF paths
            }
        }

        terminal.printSummary(
            duration: Date().timeIntervalSince(startTime),
            wordCount: writer.wordCount,
            filePath: filePath,
            recordingPaths: finalRecordingPaths
        )
        restoreTerminal()
        Foundation.exit(0)
    }
}

// Handle Ctrl+C
setupSignalHandler { shutdown() }

// Handle Escape key
setupEscapeKeyHandler { shutdown() }

terminal.printInfo("Recording... Press Escape or Ctrl+C to stop.\n")
```

**Note on the lock pattern:** The `withLock` closure does an atomic check-and-set. The first caller through gets `alreadyShuttingDown = false` and sets the state to `true` in a single critical section. All subsequent callers see `true` and return immediately. The `isShuttingDown` parameter in `withLock` is an `inout Bool`, so mutating it inside the closure is the correct pattern.

#### Change 5: Ensure terminal restoration on all exit paths

In the `defer` block (lines 261-265), add `restoreTerminal()`:

```swift
defer {
    capture.micRecorder?.stop()
    capture.systemRecorder?.stop()
    writer.flush()
    restoreTerminal()
}
```

### File 3: No changes to `AudioRecorder.swift`

The existing `AudioRecorder` already writes mono float32 PCM at 48kHz to CAF. No modifications needed.

### File 4: No changes to `TerminalUI.swift`

The `printSummary` method already accepts `recordingPaths: [URL]` and prints each one. After merge, we pass the M4A path plus the CAF paths (unless `--delete-raw-recordings`).

## Edge Cases and Considerations

1. **Recording disabled (`--no-recording`):** No CAF files exist, so skip merge entirely. The shutdown closure checks `hasRecording` before attempting merge.

2. **Resume mode:** Recording is already skipped in resume mode (line 206-211), so no merge needed.

3. **Both CAFs empty:** If both recordings are zero-length (e.g., recording started and immediately stopped), `AudioMerger` throws with "Both recording files are empty" and the catch block preserves the empty originals with an error message.

4. **One CAF shorter than the other:** The shorter channel is zero-padded (silence) for the remaining frames. This is expected when mic and system recordings have slightly different lengths.

5. **Format mismatch:** If the CAF files somehow have different sample rates or are not mono, `AudioMerger` validates this upfront and throws with a descriptive error. Raw files are preserved.

6. **Very long recordings:** Chunked I/O means memory usage is bounded to ~768 KB regardless of recording length. No OOM risk.

7. **Terminal state corruption:** If the process crashes between setting raw mode and restoring it, the user's terminal is left in raw mode. Mitigations:
   - `atexit()` handler as a normal-exit fallback (does NOT run on crashes or SIGKILL -- only on `exit()` or return from main)
   - The `defer` block in `runLiveRecording` calls `restoreTerminal()`
   - The SIGINT handler calls `restoreTerminal()`
   - Users can always run `reset` or `stty sane` to recover from a hard crash

8. **Non-interactive stdin:** The `isatty(STDIN_FILENO)` guard skips Escape key setup when stdin is piped or redirected. SIGINT still works.

9. **Escape key conflicts:** In raw mode, we consume ALL stdin. This means piped input or other keyboard shortcuts won't work. Since the transcriber is an interactive terminal app that doesn't read stdin otherwise, this is acceptable. The `isatty` guard prevents issues in non-interactive contexts.

10. **Shutdown reentrancy:** The `OSAllocatedUnfairLock<Bool>` provides thread-safe check-and-set to prevent duplicate merge/cleanup from rapid Ctrl-C or Escape presses, even though SIGINT and Escape are delivered on different queues.

11. **M4A file permissions:** The output M4A is created with 0600 permissions before writing, and permissions are re-enforced via `setAttributes` after writing completes, matching the security posture of the existing CAF recordings.

## Testing

### Unit tests (new file `Tests/TranscribeTests/AudioMergerTests.swift`)

Test the merge logic with programmatically-generated CAF files:

1. **`testMergeProducesValidM4A`:** Create two short mono CAF files (1 second of sine wave), merge them, verify the output M4A exists and is non-empty.
2. **`testMergeSampleRateMismatchThrows`:** Create CAFs with different sample rates, verify merge throws with a descriptive error.
3. **`testMergeNonMonoThrows`:** Create a stereo CAF, verify merge throws.
4. **`testMergeDifferentLengths`:** Create mic (2 sec) and sys (1 sec) CAFs, verify merge succeeds and output length matches the longer file.
5. **`testMergeBothEmptyThrows`:** Create two zero-length CAFs, verify merge throws with "Both recording files are empty".

### Manual tests

1. **Escape exit:** Run `transcribe`, wait a few seconds, press Escape. Verify: clean summary printed, M4A file created, CAFs preserved.
2. **Ctrl-C exit:** Same as above but with Ctrl-C.
3. **`--delete-raw-recordings`:** Run with flag, verify CAFs are deleted after successful merge.
4. **`--no-recording`:** Verify no merge step runs, no crash.
5. **Terminal restoration:** After exit, verify terminal echo is working (type characters, they should appear).
6. **M4A quality:** Play the merged M4A, confirm left channel is mic audio, right channel is system audio.
7. **M4A permissions:** Verify `ls -la` shows `-rw-------` on the M4A file.
8. **Non-interactive stdin:** Run `transcribe < /dev/null`. Verify startup and shutdown work normally without Escape handler interfering.

## Estimated Scope

- **New file:** `AudioMerger.swift` (~120 lines, chunked implementation with validation)
- **New file:** `AudioMergerTests.swift` (~80 lines)
- **Modified file:** `Transcribe.swift` (~100 lines changed/added)
- Total: ~300 lines of new/changed code across 3 files.
