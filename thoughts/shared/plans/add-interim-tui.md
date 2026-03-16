# Plan: Show Interim/Partial Transcription Text in Terminal

**Created:** 2026-03-16
**Session:** `~/.claude/projects/-Users-jtennant-Development/c15d1124-70ee-4610-96c-00e94fd82278/subagents/agent-aba18703dadb1d403.jsonl`
**Status:** Draft
**Reminder:** `Show interim/partial transcription text at bottom of terminal`

## Problem

The transcriber currently only displays finalized transcript lines in the terminal. During live recording, there can be multi-second gaps between when the user speaks and when finalized text appears, because the speech recognizer waits for sentence boundaries before committing. This makes it unclear whether the tool is working, and loses the "live captions" feel.

The speech recognition API (`SpeechTranscriber`) supports interim/partial results via `reportingOptions: [.volatileResults]`, but this option is **currently disabled** -- the transcribers are initialized with `reportingOptions: []` (empty). This means only finalized results are emitted. When `.volatileResults` is enabled, interim results arrive in `transcriber.results` with `result.isFinal == false`.

**Historical context:** Volatile results were previously implemented and then intentionally removed. Per `PLAN.md`, the removal was due to visual bugs: "one speaker's partial overwrites the other's", "finalized results appeared delayed due to the reorder buffer watermark", and "users perceived 'always one result missing' from the display." The PLAN.md recommends considering a two-line volatile display (one per channel) if re-enabling.

## Goal

Add an opt-in `--show-interim` flag that displays in-progress speech recognition text at the bottom of the terminal, overwriting itself as recognition updates. Finalized text continues to print above as permanent lines. The effect should resemble live captions.

## Current Architecture Summary

### How text flows from recognition to display

1. `AudioCapture` / `FileAudioSource` produces `AsyncStream<TimestampedBuffer>`
2. `TranscriptionEngine` feeds buffers to `SpeechAnalyzer` with `SpeechTranscriber` modules
3. `processResults()` iterates `transcriber.results` -- an async sequence of results with `text`, `isFinal`, and `range`
4. Only `isFinal` results are added to `ReorderBuffer`
5. `ReorderBuffer.onFlush` calls `writer.writeLine()` and `terminal.showFinalized()`

### Existing TUI infrastructure

`TerminalUI` already has:
- `showFinalized(speaker:text:)` -- clears the current line, prints a permanent line
- `showVolatile(speaker:text:)` -- overwrites the current line with partial text (ANSI `\033[2K\r`)
- `printInfo()`, `printError()`, `printSummary()` -- utility output
- An `NSLock` for thread-safe terminal access

**Key finding:** `showVolatile()` already exists and does exactly what we need, but it is **never called**. The `SpeechTranscriber` is initialized with `reportingOptions: []` (no `.volatileResults`), so only finalized results are emitted. The `processResults()` method only processes `isFinal` results.

### Terminal rendering approach already in place

The existing `showVolatile()` uses simple ANSI escape codes:
- `\033[2K` (clear entire line) + `\r` (carriage return) to overwrite the current line
- `fflush(stdout)` to ensure immediate display
- No terminating newline (so the next write overwrites it)

When `showFinalized()` is called, it also clears the volatile line first, then prints with a newline, pushing the finalized text up into the permanent scrollback.

This approach is sufficient -- no TUI library (ncurses, etc.) is needed. The ANSI escape code approach:
- Works in all modern terminals (iTerm, Terminal.app, kitty, etc.)
- Has zero dependencies
- Already implemented and tested in the codebase
- Handles the key interaction correctly: volatile text sits on the "current line" and gets replaced when either a new volatile update arrives or finalized text is committed

## Design Decisions

### 1. Opt-in via `--show-interim` flag (not `--live-captions` or `--preview`)

The flag name `--show-interim` is descriptive and matches Apple's API terminology (`isFinal` vs interim). Default is off to preserve the current clean output behavior and avoid confusing users who pipe stdout.

### 2. Use existing ANSI approach, not a TUI framework

A full TUI framework (ncurses, Swift TUI) would be overkill. The existing `showVolatile()` method already implements the right pattern. Benefits:
- Zero new dependencies
- Already handles the volatile-to-finalized transition
- Works with piped/redirected output (volatile calls can be skipped when not a TTY)

### 3. Show interim text for both channels independently

When interim text arrives for the mic speaker, show it. When interim text arrives for system audio, show that instead. Only one volatile line is visible at a time (the most recent interim update from either channel). This is the simplest approach and avoids needing a multi-line status bar.

### 4. Truncate long interim text

`showVolatile()` already truncates to 80 characters. This is fine -- interim text tends to grow as the recognizer accumulates words, and the full text will appear when finalized.

### 5. TTY detection and `effectiveShowInterim`

Compute a single `effectiveShowInterim` boolean at startup in `Transcribe.swift`: `showInterim && isatty(STDOUT_FILENO) != 0`. Pass this single value to both `TerminalUI` and `TranscriptionEngine`. When stdout is not a terminal, this resolves to `false`, which means:
- `.volatileResults` is NOT enabled in the speech recognizer (avoids unnecessary CPU/result volume)
- `showVolatile()` never renders (no ANSI escape codes in piped output)

Note: finalized output (`showFinalized()`) currently always includes ANSI color codes regardless of TTY. That is pre-existing behavior and out of scope for this plan.

### 6. Control character sanitization

Recognized text is printed directly to the terminal. To prevent escape sequence injection and to protect `showVolatile()`'s single-line assumption, strip ALL control characters (including newline and tab) from `text` before passing to `showVolatile()`. Add a small helper in the `else` branch: `let sanitized = text.filter { $0 >= " " }`. This strips everything below ASCII 0x20 (space), including ESC (0x1B), newline (0x0A), and tab (0x09). This is a defense-in-depth measure -- the speech recognizer is unlikely to produce control characters, but it costs nothing to guard against.

## Implementation Plan

### Phase 1: Enable volatile results in `SpeechTranscriber`

**File:** `Sources/Transcribe/TranscriptionEngine.swift`

The transcribers are currently initialized with `reportingOptions: []`. To receive interim results, change to `reportingOptions: [.volatileResults]`.

There are 3 initialization sites to update:
1. `runLiveTranscription()` -- `micTranscriber` (line 84-88)
2. `runLiveTranscription()` -- `systemTranscriber` (line 90-94)
3. `runFileTranscription()` -- `transcriber` (line 147-151)

**Conditionally enable:** Only add `.volatileResults` when `--show-interim` is active. Pass a `showInterim: Bool` to `TranscriptionEngine` and use it to construct `reportingOptions`:

```swift
let reportingOptions: SpeechTranscriber.ReportingOptions = showInterim ? [.volatileResults] : []

let micTranscriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: reportingOptions,
    attributeOptions: [.audioTimeRange]
)
```

This avoids processing interim results when they won't be displayed, which is both cleaner and potentially more efficient (the speech engine may do less work without volatile reporting).

### Phase 2: Wire up interim results in `processResults()`

**File:** `Sources/Transcribe/TranscriptionEngine.swift`

In `processResults()`, add an `else` branch for non-final results to call `showVolatile()`. The `showVolatile()` method already exists in `TerminalUI` and does exactly the right thing.

**Important:** The `showVolatile()` call should be gated in `TerminalUI` itself (approach B below) so that `processResults()` can always call it without checking flags.

### Phase 3: Add `showInterim` flag to `TerminalUI`

**File:** `Sources/Transcribe/TerminalUI.swift`

Add a `showInterim` property and gate `showVolatile()`. Note: the TTY check is done upstream in `Transcribe.swift` when computing `effectiveShowInterim`, so `TerminalUI` only needs to check the single boolean.

```swift
final class TerminalUI: Sendable {
    private let micSpeaker: String
    private let systemSpeaker: String
    private let showInterim: Bool

    init(micSpeaker: String, systemSpeaker: String, showInterim: Bool = false) {
        self.micSpeaker = micSpeaker
        self.systemSpeaker = systemSpeaker
        self.showInterim = showInterim
    }

    func showVolatile(speaker: String, text: String) {
        guard showInterim else { return }
        lock.lock()
        defer { lock.unlock() }
        // ... existing implementation ...
    }
}
```

Changes:
1. Add `showInterim: Bool` parameter to `init` (default `false` for backward compatibility)
2. Add early return guard to `showVolatile()`

### Phase 4: Add `--show-interim` CLI flag

**File:** `Sources/Transcribe/Transcribe.swift`

Add the flag to the `Transcribe` struct:

```swift
@Flag(name: .long, help: "Show in-progress speech recognition text at the bottom of the terminal. Only one speaker's interim text is shown at a time (most recent update wins). Ignored when stdout is not a TTY.")
var showInterim = false
```

Compute `effectiveShowInterim` at startup in `run()`:

```swift
let effectiveShowInterim = showInterim && isatty(STDOUT_FILENO) != 0
```

Pass `effectiveShowInterim` (not `showInterim`) to both `TerminalUI` and `TranscriptionEngine` construction. Call sites:
1. `runLiveRecording()` at line 143: `TerminalUI(micSpeaker:systemSpeaker:showInterim:effectiveShowInterim)`
2. `runFileTranscription()` at line 56: `TerminalUI(micSpeaker:systemSpeaker:showInterim:effectiveShowInterim)`
3. `TranscriptionEngine` init calls (both live and file) -- pass `effectiveShowInterim` so it can conditionally enable `.volatileResults`

### Phase 5: Call `showVolatile()` from `processResults()`

**File:** `Sources/Transcribe/TranscriptionEngine.swift`

In `processResults()`, add the `else` branch for non-final results. The current code (around line 222-227) is:

```swift
if result.isFinal {
    finalCount += 1
    reorderBuffer.add(event)
}
```

Change to:

```swift
if result.isFinal {
    finalCount += 1
    reorderBuffer.add(event)
} else {
    // Interim results: display-only, skip timestamp/event construction
    let sanitized = text.filter { $0 >= " " }
    terminal.showVolatile(speaker: speaker, text: sanitized)
}
```

**Important:** Move the `else` branch BEFORE the wall-clock timestamp computation. The interim path should skip the `originHostTime` lookup, `CMTimeGetSeconds` conversion, and `TranscriptEvent` construction entirely. Only extract `text` from the result, sanitize it, and call `showVolatile()`. This keeps the hot interim path lightweight.

Restructured `processResults()` flow:
```swift
let text = String(result.text.characters)
guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }

if !result.isFinal {
    let sanitized = text.filter { $0 >= " " }
    terminal.showVolatile(speaker: speaker, text: sanitized)
    continue
}

// Final result: compute wall-clock, create event, add to reorder buffer
let originHostTime = getOriginHostTime()
// ... rest of final-result processing ...
```

## Edge Cases

### 1. Rapid interim updates causing flicker

The speech recognizer can emit many interim results per second. The ANSI clear-line approach handles this well -- each update overwrites the previous, creating a smooth typing effect. No debouncing needed for live recording.

**File transcription note:** File transcription can run faster than real-time, potentially producing a burst of interim updates. The terminal should handle this fine (rapid overwrites are visually coalesced), but if it becomes an issue in practice, a future improvement could throttle volatile redraws to ~20 Hz. Not needed for v1.

### 2. Finalized text arriving while interim text is showing

`showFinalized()` already clears the volatile line before printing. The sequence is:
1. Interim: `[Jack] Hello how are y...` (volatile line)
2. Interim: `[Jack] Hello how are you do...` (overwrites)
3. Final: clears volatile line, prints `Jack: Hello, how are you doing today?` with newline

This already works correctly with the existing `showFinalized()` implementation.

### 3. Two channels competing for the volatile line

Both mic and system audio may emit interim results. The most recent one wins the volatile line. This is acceptable because:
- Typically only one person speaks at a time
- The volatile line is ephemeral -- it gets replaced within milliseconds
- When finalized text arrives, it clears the volatile line regardless

### 4. Piped/redirected stdout

The `effectiveShowInterim` computation at startup prevents volatile output and `.volatileResults` from being enabled when stdout is not a TTY. Note: finalized text still prints with ANSI color codes when piped -- that is pre-existing behavior and out of scope for this change.

### 5. Terminal resizing

Not an issue with the ANSI approach -- `\033[2K\r` always clears the current line regardless of width. The 80-character truncation in `showVolatile()` prevents wrapping on standard terminals.

### 6. Signal handler (Ctrl+C) during volatile display

The existing `printSummary()` starts with `clearLine`, so it correctly clears any volatile text before showing the summary.

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/Transcribe/Transcribe.swift` | Add `--show-interim` flag, pass to `TerminalUI` and `TranscriptionEngine` |
| `Sources/Transcribe/TerminalUI.swift` | Add `showInterim` property, gate `showVolatile()` with early return |
| `Sources/Transcribe/TranscriptionEngine.swift` | (1) Accept `showInterim` param, conditionally add `.volatileResults` to `reportingOptions` (3 transcriber init sites). (2) Add `else` branch in `processResults()` to call `showVolatile()` for non-final results |

**No new files needed. No new dependencies.**

## Testing

### Automated tests

1. **Build:** `swift build` must succeed
2. **Existing tests:** `swift test` must pass
3. **CLI parsing test:** Add a test in the existing `FileTranscriptionArgTests` suite in `FileAudioSourceTests.swift`:
   ```swift
   @Test func showInterimFlagIsParsed() throws {
       guard #available(macOS 26.0, *) else { return }
       let command = try Transcribe.parse(["--show-interim"])
       #expect(command.showInterim == true)
   }

   @Test func showInterimDefaultsToFalse() throws {
       guard #available(macOS 26.0, *) else { return }
       let command = try Transcribe.parse([])
       #expect(command.showInterim == false)
   }
   ```

### Manual tests

4. **Default behavior:** Run `transcribe` without `--show-interim` -- behavior should be identical to current (no interim text shown)
5. **Interim display:** Run `transcribe --show-interim` -- speak and observe interim text appearing and being replaced by finalized text
6. **Piped output:** Run `transcribe --show-interim | cat` -- verify no volatile lines appear (the `effectiveShowInterim` should be `false` since stdout is not a TTY). Note: finalized lines will still contain ANSI color codes (pre-existing behavior).
7. **File mode:** Run `transcribe --file some.m4a --show-interim` -- verify interim text appears during file transcription too

## Risks & Notes

- **Previously removed feature:** Volatile results were implemented before and intentionally removed. The prior issues were: (1) one speaker's partial overwrites the other's, (2) finalized results appeared delayed due to reorder buffer watermark, (3) users perceived "always one result missing." Making this opt-in via `--show-interim` mitigates concern (1) by letting users choose. Concern (2) is inherent to the reorder buffer design and won't change. Concern (3) may still occur -- the reorder buffer holds back the most recent finalized result for 500ms to allow cross-channel ordering, so the volatile line may show text that "disappears" briefly before reappearing as finalized.
- **Low risk when flag is off:** All existing behavior is preserved when `--show-interim` is not passed (default). The `reportingOptions` remain `[]` and no volatile results are emitted.
- **Speech API interim results:** When `.volatileResults` is enabled, `SpeechTranscriber.results` yields both interim and final results. Interim results have `isFinal == false`. The text in interim results is a rolling transcript that grows as the recognizer processes more audio -- it is not a diff/delta. Each interim result replaces the previous one for that utterance.
- **Performance:** `showVolatile()` is cheap (string truncation + print). Even at high update rates, the terminal will coalesce rapid writes visually. Enabling `.volatileResults` may cause the speech engine to do slightly more work, but this is negligible on Apple Silicon.
- **Future enhancement:** Could add a two-line status bar showing both mic and system interim text simultaneously. This would require `\033[s` (save cursor) / `\033[u` (restore cursor) or absolute cursor positioning `\033[<row>;1H`. The PLAN.md recommends this approach if the single-line volatile display proves insufficient. Not needed for v1.
