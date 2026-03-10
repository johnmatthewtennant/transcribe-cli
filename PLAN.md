# jtennant-transcriber

A macOS CLI tool that records microphone + system audio and produces a real-time speaker-attributed transcript as a markdown file. Fully on-device using Apple's SpeechAnalyzer API.

## Architecture

Everything is a single Swift CLI binary (no Python, no external services for the default path).

### Audio Capture

Uses two macOS APIs to capture dual-channel audio:

- **System audio** (remote party) — `ScreenCaptureKit` with `SCStreamConfiguration.capturesAudio = true`. Captures all system audio output (the other side of a call). Requires Screen Recording permission.
- **Microphone** (you) — `AVAudioEngine` tapping the default input device. Requires Microphone permission.

Both streams are converted to the format required by SpeechAnalyzer via `AVAudioConverter`.

**Shared reference clock and timestamping strategy:**
1. When each audio stream starts, record an **origin pair**: `(streamStartHostTime: mach_continuous_time(), streamStartSampleTime: CMTime.zero)`.
2. When a `SpeechTranscriber` emits a finalized result with `audioTimeRange.start` (in stream-local sample time), convert to wall-clock: `wallClock = streamStartHostTime + (audioTimeRange.start - streamStartSampleTime)`.
3. All timestamps displayed and written use **utterance start time** consistently.
4. The reorder buffer merges across channels using these wall-clock timestamps.

**Backpressure policy (split by path):**
- **Audio capture → transcription (primary path):** Bounded `AsyncStream` with **blocking** backpressure. If the transcriber falls behind, the producer blocks. This ensures no audio is silently dropped and no transcript content is lost.
- **Transcription → terminal volatile preview:** Bounded channel with **drop-oldest** policy. Dropping partial previews is acceptable since they are ephemeral UI state.

### Transcription (SpeechAnalyzer — macOS Tahoe 26+)

Apple's new on-device speech-to-text API, introduced at WWDC25. Runs on the Neural Engine (Apple Silicon), processes at ~190x real-time speed, 55% faster than Whisper.

**Two `SpeechTranscriber` instances** run in parallel:
1. Mic audio → transcriber #1 → labeled "You"
2. System audio → transcriber #2 → labeled "Remote"

Speaker identification comes from channel separation, not diarization — each transcriber only receives one speaker's audio.

**Key API details:**

```swift
import SpeechAnalyzer

// Initialize transcriber
let transcriber = SpeechTranscriber(
    locale: Locale(identifier: "en-US"),
    transcriptionOptions: [],
    reportingOptions: [.volatileResults],  // enables partial/live results
    attributeOptions: [.audioTimeRange]    // timestamps
)

// Get required audio format
let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])

// Create analyzer and start
let analyzer = SpeechAnalyzer(modules: [transcriber])
try await analyzer.start(inputSequence: audioInputStream)

// Read results
for try await result in transcriber.results {
    let text = result.text           // AttributedString
    let isFinal = result.isFinal     // false = volatile (partial), true = finalized
    let timeRange = result.text.audioTimeRange  // CMTimeRange
}
```

**Model download:** Models are NOT pre-installed. On first run, download via `AssetInventory` API:
```swift
let inventory = AssetInventory()
let status = try await inventory.status(for: speechAsset)
if status != .installed {
    try await inventory.download(speechAsset)
}
```
One-time download, cached by the OS. If the user has used dictation in English before, the model may already be available.

**Result types:**
- **Volatile results** — immediate rough guesses, shown in terminal as live preview (not written to file)
- **Finalized results** — high-accuracy text, written to the markdown file

### Output

Writes to `~/.transcripts/{date}-{slugified-title}.md`:

```markdown
# Weekly sync with Jeanne — 2026-03-10 14:30

**You** (14:30:15): Hey, how's the project going?

**Remote** (14:30:18): It's going well, we just finished the API integration.

**You** (14:30:25): Great, let me share my screen...
```

- Finalized results pass through a **reorder buffer** (2-second watermark) before writing to ensure chronological ordering across channels. When a result arrives with timestamp T, all buffered results with timestamp < T-2s are flushed to file in sorted order.
- Volatile (partial) results are shown in the terminal only (no reorder buffer needed)
- Lines are ordered chronologically by the shared reference clock timestamp
- File writes use line-buffered I/O with explicit `fflush` after each append for crash durability
- Transcript files are created with `0600` permissions (owner read/write only)

## CLI Interface

```bash
# Start a new recording (auto-titled with date/time)
transcribe

# Start with a custom title
transcribe --title "Weekly sync with Jeanne"

# Resume a previous recording (appends with --- separator)
transcribe --resume "2026-03-10-weekly-sync-with-jeanne.md"

# Resume the most recent recording
transcribe --resume

# List past recordings
transcribe --list

# Custom speaker names
transcribe --speakers "Jack,Jeanne"
```

### Behavior:
- Creates `~/.transcripts/{date}-{slugified-title}.md`
- Prints transcript to terminal in real-time (speaker labels, colors, volatile preview)
- Writes finalized transcript lines to the markdown file
- Ctrl+C to stop — prints summary (duration, word count, file path)
- `--resume` reopens an existing file, appends `\n---\n\n*Resumed at HH:MM*\n\n`, and continues
- `--resume` with no argument resumes the most recent file
- `--resume` accepts filename only (no paths), resolved under `~/.transcripts/`. Rejects `..`, absolute paths, and non-existent files with clear error messages

## Project Structure

Single Swift Package Manager project:

```
jtennant-transcriber/
├── Package.swift
├── Sources/
│   └── Transcribe/
│       ├── main.swift              — CLI entry point, argument parsing
│       ├── AudioCapture.swift      — ScreenCaptureKit system audio + AVAudioEngine mic
│       ├── TranscriptionEngine.swift — SpeechAnalyzer setup, dual transcriber management
│       ├── MarkdownWriter.swift    — File output, chronological merge, formatting
│       └── TerminalUI.swift        — Colored terminal output, volatile preview, summary
├── PLAN.md
└── README.md
```

## Implementation Steps

### Phase 1: Audio capture
1. Set up SPM project targeting macOS 26
2. Add `#available(macOS 26, *)` startup gate with clear error message on unsupported OS
3. Implement mic capture via `AVAudioEngine` with `mach_continuous_time()` timestamping per buffer
4. Implement system audio capture via `ScreenCaptureKit` with `mach_continuous_time()` timestamping per buffer
5. Verify both streams produce valid `AVAudioPCMBuffer` output
6. Add permission preflight checks before starting capture:
   - Check mic permission via `AVCaptureDevice.authorizationStatus(for: .audio)`
   - Check screen recording permission via `CGPreflightScreenCaptureAccess()` / `CGRequestScreenCaptureAccess()`
   - Print actionable instructions if denied (e.g., "Open System Settings > Privacy > Screen Recording")
   - Fail fast with clear error rather than silently producing empty audio
7. Use bounded `AsyncStream` channels between capture and transcription with **blocking** backpressure (no audio drops on primary path); separate drop-oldest channel for volatile terminal preview only

### Phase 2: Transcription
1. Initialize `AssetInventory` and download speech model if needed:
   - Show download progress in terminal
   - Handle offline/network errors with clear messaging
   - Retry with backoff on transient failures
   - Fail fast before starting audio capture if model unavailable
2. Create two `SpeechTranscriber` instances (mic + system)
3. Create two `SpeechAnalyzer` instances, feed audio buffers from Phase 1
4. Read volatile + finalized results from both transcribers
5. Merge results chronologically using shared reference clock timestamps (not `audioTimeRange`)

### Phase 3: Output
1. Write finalized results to markdown file with speaker labels + timestamps via reorder buffer
2. Create transcript files with `0600` permissions, line-buffered writes with explicit flush
3. Print to terminal with ANSI colors (e.g., green for "You", blue for "Remote")
4. Show volatile results as an updating line at the bottom of the terminal (serialized to avoid garbled output from concurrent speakers)
5. Handle Ctrl+C gracefully — flush reorder buffer, finalize analyzers, print summary

### Phase 4: CLI polish
1. Argument parsing (--title, --resume, --list, --speakers)
2. Sanitize `--title` and `--speakers` values: strip markdown special characters, escape terminal control sequences, validate length
3. Resume logic (find file under `~/.transcripts/` only, validate filename, append separator, continue)
4. List recordings from ~/.transcripts/
5. Install as `transcribe` in PATH (e.g., symlink or `swift build` + copy)

## Dependencies

- macOS 26 Tahoe (SpeechAnalyzer + ScreenCaptureKit)
- Swift 6.x
- Apple Silicon (Neural Engine for on-device inference)
- Screen Recording permission (for system audio)
- Microphone permission
- No external packages — all Apple frameworks

## Upgrade Paths

The MVP uses SpeechAnalyzer with dual-channel separation (no diarization needed). From there, three independent upgrade paths can be pursued in any order:

```
                    ┌─────────────────────────────────┐
                    │         MVP (Phase 1-4)          │
                    │  SpeechAnalyzer + dual-channel   │
                    │  "You" vs "Remote" only          │
                    └──────┬──────────┬───────────┬────┘
                           │          │           │
                    ┌──────▼──┐  ┌────▼─────┐  ┌──▼──────────────┐
                    │ Path A  │  │ Path B   │  │ Path C          │
                    │ +11Labs │  │ +Fluid   │  │ Switch to Fluid │
                    │ post    │  │ post     │  │ for real-time   │
                    └─────────┘  └──────────┘  └─────────────────┘
```

### Path A: Add ElevenLabs post-processing (`--finalize`)

After recording stops, re-transcribe the saved audio through ElevenLabs Scribe v2 batch API with `diarize=true`. This gives:
- Multi-speaker diarization (distinguishes multiple remote speakers)
- Higher accuracy from a larger cloud model
- Replaces the live transcript with a polished version

**Trade-offs:** Requires API key + costs money. Cloud-based (audio leaves machine). But best accuracy and most languages (90+).

**ElevenLabs batch API details:**
- Endpoint: `POST https://api.elevenlabs.io/v1/speech-to-text`
- Model: `scribe_v2`
- Key params: `diarize=true`, `num_speakers=N` (up to 48), `timestamps_granularity=word`
- Auth: `xi-api-key` header (stored in macOS keychain as `elevenlabs-api-key`)
- Supports up to 3GB file upload
- 90+ languages, audio event tagging, entity detection

### Path B: Add FluidAudio post-processing (`--finalize`)

Same as Path A but fully on-device. After recording stops, re-process the saved audio through FluidAudio's offline diarization pipeline (`OfflineDiarizerManager`) + batch ASR (`AsrManager`). This gives:
- Multi-speaker diarization (on-device, private)
- Free, no API key needed
- Offline capable

**Trade-offs:** Fewer languages (25 European vs 90+). Accuracy may be lower than ElevenLabs. But fully private and free.

### Path C: Switch to FluidAudio for real-time

Replace SpeechAnalyzer with FluidAudio's `StreamingAsrManager` + streaming diarization for the live pass. This gives:
- Real-time speaker diarization during recording (not just "You" vs "Remote")
- Works for in-person meetings with a single audio source
- Distinguishes multiple remote speakers live
- No post-processing step needed — the live transcript is already diarized

**Trade-offs:** More complex setup (HuggingFace model downloads vs OS-managed). Slightly wider macOS compat (14+ vs 26+). May need to compare transcription quality vs SpeechAnalyzer.

**If Path C is implemented, post-processing (Paths A/B) becomes optional** — only needed if you want even higher accuracy from a second pass.

### Path comparison

| | MVP | +Path A (11Labs post) | +Path B (Fluid post) | Path C (Fluid real-time) |
|---|---|---|---|---|
| **Real-time transcription** | SpeechAnalyzer | SpeechAnalyzer | SpeechAnalyzer | FluidAudio |
| **Live speaker ID** | Channel only (You/Remote) | Channel only | Channel only | Full diarization |
| **Post-processing** | None | ElevenLabs batch | FluidAudio batch | Optional |
| **Multi-speaker remote** | No | Yes (post) | Yes (post) | Yes (live) |
| **In-person meetings** | No speaker ID | Diarized post | Diarized post | Diarized live |
| **Cost** | Free | Per-minute API | Free | Free |
| **Privacy** | On-device | Cloud post-pass | On-device | On-device |
| **Languages** | Many (Apple) | 90+ | 25 European | 25 European |
| **macOS req** | 26+ | 26+ | 26+ (or 14+ for Fluid) | 14+ |

## Provider Reference

### ElevenLabs real-time API (alternative to SpeechAnalyzer for live pass)

If SpeechAnalyzer quality isn't sufficient, ElevenLabs real-time could replace it:
- Endpoint: `wss://api.elevenlabs.io/v1/speech-to-text/realtime`
- Model: `scribe_v2_realtime`
- Audio format: `pcm_16000`
- Commit strategy: `vad` (automatic voice activity detection)
- Events: `partial_transcript`, `committed_transcript`, `committed_transcript_with_timestamps`
- Does NOT support diarization — same dual-channel approach needed
- 150ms latency, 90+ languages
- Would require a Python/Node orchestrator or Swift WebSocket client

### FluidAudio SDK

[FluidAudio](https://github.com/FluidInference/FluidAudio) — open-source (MIT/Apache 2.0) Swift SDK, on-device via Apple Neural Engine.

**Capabilities:**
- Real-time streaming transcription (`StreamingAsrManager`)
- Real-time streaming speaker diarization (Pyannote + Sortformer models)
- Offline batch diarization (`OfflineDiarizerManager`) with advanced clustering
- Voice activity detection (Silero)
- Speaker embedding extraction (for voice fingerprinting / cross-session speaker recognition)
- ASR model: Parakeet TDT v3 (0.6B params), 25 European languages
- ~190x real-time on M4 Pro
- macOS 14+, iOS 17+

**Integration:** Swift Package Manager:
```swift
.package(url: "https://github.com/FluidInference/FluidAudio", from: "1.0.0")
```

Models are downloaded from HuggingFace on first use (not pre-installed).

### How Char (fastrepl/char) does it — reference implementation

[Char](https://github.com/fastrepl/char) is an open-source meeting transcription app that uses the same dual-channel approach:

1. Captures mic + system audio as separate streams via ScreenCaptureKit + AVAudioEngine
2. For providers without native multichannel support (ElevenLabs, Soniox, AssemblyAI, OpenAI), opens **two parallel WebSocket connections** — one per channel
3. Tags responses with channel index (0 = mic/you, 1 = system/remote)
4. Frontend renders channel 0 as "You", channel 1 as "Speaker N"
5. For post-meeting finalization, uses batch APIs with `diarize=true`
6. Stores transcripts as plain files on disk (no database) — markdown + JSON + WAV
7. Supports manual speaker-to-contact assignment with propagation

Char's data layer is filesystem-based at a configurable vault directory:
```
vault/sessions/{uuid}/
├── _meta.json
├── _memo.md
├── transcript.json    (word-level, speaker labels, timestamps)
├── _summary.md
└── recording.wav
```

Deepgram is the only provider Char treats as natively multichannel (interleaved stereo over a single connection).
