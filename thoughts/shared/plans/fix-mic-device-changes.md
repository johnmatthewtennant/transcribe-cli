# Plan: Fix mic capture — auto-detect device changes and add diagnostics

Session: `c15d1124-70ee-4610-966c-00e94fd82278`

## Problem

`AudioCapture.swift` uses `AVAudioEngine` to capture mic audio via `engine.inputNode`. It uses whatever the system default input device is at launch. If the audio device changes mid-session (e.g., user joins a Google Meet call and macOS switches to AirPods), the tap silently stops delivering buffers. There is no logging of which device is in use, no detection of device changes, and no recovery. Confirmed: local/mic capture has been broken in most recordings since March 12.

## Root cause

- `AVAudioEngine.inputNode` binds to the system default input device at engine start time
- When the system default input device changes (e.g., a Bluetooth headset connects), macOS posts `AVAudioEngineConfigurationChange` notification
- The engine's internal graph is reconfigured, which disconnects the tap — buffers silently stop flowing
- The `AsyncStream` just receives no more data; nothing errors, nothing logs

## Architecture overview

Key files:
- `Sources/Transcribe/AudioCapture.swift` — `AudioCapture` class, `startMicCapture()`, `SystemAudioDelegate`
- `Sources/Transcribe/Transcribe.swift` — CLI entry point, creates `AudioCapture`, starts capture
- `Sources/Transcribe/TranscriptionEngine.swift` — consumes `micStream`/`systemStream` via `AsyncStream<TimestampedBuffer>`

The mic capture flow:
1. `AudioCapture.init()` creates `AsyncStream<TimestampedBuffer>` with continuation
2. `startMicCapture()` creates `AVAudioEngine`, installs tap on `inputNode` bus 0, tap callback yields buffers to the continuation
3. `TranscriptionEngine` consumes `micStream`, converts buffers, feeds to `SpeechTranscriber`

## Implementation plan

### Phase 1: Add CoreAudio device query helpers

Create a new file `Sources/Transcribe/AudioDeviceUtils.swift` with utilities for querying audio devices via CoreAudio. These are needed because AVAudioEngine does not expose device metadata.

**Functions to implement:**

```swift
import CoreAudio
import AVFoundation

/// Get the current default system input device ID.
func getDefaultInputDeviceID() -> AudioDeviceID?
// Uses AudioObjectGetPropertyData with kAudioHardwarePropertyDefaultInputDevice
// on kAudioObjectSystemObject

/// Get the human-readable name of an audio device.
func getDeviceName(deviceID: AudioDeviceID) -> String?
// Uses AudioObjectGetPropertyData with kAudioDevicePropertyDeviceNameCFString

/// Get the UID string of an audio device (stable identifier).
func getDeviceUID(deviceID: AudioDeviceID) -> String?
// Uses AudioObjectGetPropertyData with kAudioDevicePropertyDeviceUID

/// Resolve a device UID to its current AudioDeviceID (returns nil if device is disconnected).
func resolveDeviceID(forUID uid: String) -> AudioDeviceID?
// Iterates listInputDevices(), returns first match by UID

/// List all audio input devices (ID, name, UID).
struct AudioInputDevice {
    let id: AudioDeviceID
    let name: String
    let uid: String
}
func listInputDevices() -> [AudioInputDevice]
// Uses kAudioHardwarePropertyDevices to get all devices,
// then filters to those with input channels (kAudioDevicePropertyStreamConfiguration
// with kAudioDevicePropertyScopeInput)

/// Set the input device for an AVAudioEngine's inputNode.
func setInputDevice(engine: AVAudioEngine, deviceID: AudioDeviceID) throws
// Gets engine.inputNode.audioUnit, calls AudioUnitSetProperty with
// kAudioOutputUnitProperty_CurrentDevice

/// Find a matching device by exact name, exact UID, or partial case-insensitive name.
/// Pure function — no hardware access. Used by --device resolution and unit-testable.
func findMatchingDevice(query: String, in devices: [AudioInputDevice]) -> AudioInputDevice?
```

**CoreAudio API pattern** (for reference during implementation):

```swift
// Getting default input device:
var address = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultInputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var deviceID: AudioDeviceID = 0
var size = UInt32(MemoryLayout<AudioDeviceID>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)

// Getting device name:
var nameAddress = AudioObjectPropertyAddress(
    mSelector: kAudioDevicePropertyDeviceNameCFString,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain
)
var name: CFString = "" as CFString
var nameSize = UInt32(MemoryLayout<CFString>.size)
AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, &name)

// Setting input device on AVAudioEngine:
guard let audioUnit = engine.inputNode.audioUnit else { throw ... }
var devID = deviceID
AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
    kAudioUnitScope_Global, 0, &devID, UInt32(MemoryLayout<AudioDeviceID>.size))
```

**Imports needed:** `CoreAudio`, `AudioToolbox` (for `kAudioOutputUnitProperty_CurrentDevice`)

### Phase 2: Log device info at startup

In `AudioCapture.startMicCapture()`, after creating the engine but before starting it, log the current input device.

**Changes to `AudioCapture.swift`:**

After `let engine = AVAudioEngine()` and before `engine.prepare()`:

```swift
if let deviceID = getDefaultInputDeviceID(),
   let name = getDeviceName(deviceID: deviceID),
   let uid = getDeviceUID(deviceID: deviceID) {
    let truncatedUID = String(uid.prefix(8))
    DiagnosticLog.shared.log("[Mic] Using input device: \(name) (UID: \(truncatedUID)..., ID: \(deviceID))")
} else {
    DiagnosticLog.shared.log("[Mic] WARNING: Could not determine input device")
}
```

Note: Device UIDs are truncated to the first 8 characters by default to avoid leaking stable hardware identifiers to logs. Full UIDs are only shown in `--list-devices` output where the user explicitly requests device info.

This gives immediate visibility into which device is being used, making it easy to correlate with "mic went silent" issues.

### Phase 3: Listen for device change notifications and auto-restart

This is the core fix. When `AVAudioEngineConfigurationChange` fires, tear down the old engine/tap and create a new one.

**Changes to `AudioCapture.swift`:**

1. Add lifecycle management properties:

```swift
private let micLock = NSLock()
nonisolated(unsafe) private var isStopped = false
nonisolated(unsafe) private var watchdogTask: Task<Void, Never>?
nonisolated(unsafe) private var retryTask: Task<Void, Never>?
```

2. Split mic capture into two methods to avoid NSLock deadlock (NSLock is not re-entrant):

- **`startMicCapture()`** — public entry point, acquires `micLock`, calls `startMicCaptureLocked()`
- **`startMicCaptureLocked()`** — private, assumes caller holds `micLock`. Contains all engine setup logic.

The handler and retry path call `startMicCaptureLocked()` directly since they already hold the lock.

```swift
func startMicCapture() throws {
    micLock.lock()
    defer { micLock.unlock() }
    try startMicCaptureLocked()
}

private func startMicCaptureLocked() throws {
    // All existing startMicCapture() logic moves here
    let engine = AVAudioEngine()
    // ... device setup, tap installation, etc. ...

    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleConfigurationChange(_:)),
        name: .AVAudioEngineConfigurationChange,
        object: engine  // use local variable, not self.audioEngine
    )

    self.audioEngine = engine
}
```

3. Add the handler method to `AudioCapture`. It acquires `micLock` and calls `startMicCaptureLocked()`:

```swift
@objc private func handleConfigurationChange(_ notification: Notification) {
    micLock.lock()
    defer { micLock.unlock() }

    guard !isStopped else { return }

    DiagnosticLog.shared.log("[Mic] AVAudioEngine configuration change detected — restarting mic capture")

    // Log new default device info
    if let newID = getDefaultInputDeviceID(), let newName = getDeviceName(deviceID: newID) {
        let uid = getDeviceUID(deviceID: newID).map { String($0.prefix(8)) } ?? "?"
        DiagnosticLog.shared.log("[Mic] New default input device: \(newName) (UID: \(uid)...)")
    }

    // Debounce rapid device switching (see Phase 6)

    // Tear down old tap
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()

    // Remove observer for old engine before creating new one
    if let oldEngine = audioEngine {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: oldEngine)
    }

    // Restart — call locked variant since we already hold micLock
    do {
        try startMicCaptureLocked()
        DiagnosticLog.shared.log("[Mic] Successfully restarted mic capture after device change")
    } catch {
        DiagnosticLog.shared.log("[Mic] ERROR: Failed to restart mic capture: \(error.localizedDescription)")
        // Don't finish the continuation — the device might come back
        // Retry logic is in Phase 6
    }
}
```

4. Update `stop()` to set `isStopped` flag and cancel background tasks:

```swift
func stop() {
    micLock.lock()
    isStopped = true
    watchdogTask?.cancel()
    watchdogTask = nil
    retryTask?.cancel()
    retryTask = nil
    if let engine = audioEngine {
        NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
    }
    audioEngine?.inputNode.removeTap(onBus: 0)
    audioEngine?.stop()
    audioEngine = nil
    micLock.unlock()
    // ... rest of existing stop() code
}
```

**Important considerations:**

- `startMicCapture()` currently sets `self.audioEngine = engine` and uses `var isFirst = true` for origin host time. On restart, the origin host time should NOT be reset — keep the original origin so timestamps remain consistent within the session. Change `isFirst` logic: only set `micOriginHostTime` if it is still 0.
- The notification may fire on a background thread. The handler must be safe to call from any thread. Since `audioEngine` is `nonisolated(unsafe)`, access is serialized via `micLock`.
- The `_micContinuation` must NOT be replaced — it was created once in `init()` and the `TranscriptionEngine` is already consuming the corresponding stream. The restart just needs to install a new tap that yields to the same continuation.

**Concurrency safety for restart:**

The `micLock` (NSLock) serializes all mic engine operations. The public `startMicCapture()` acquires the lock, while internal callers (`handleConfigurationChange`, retry loop) call `startMicCaptureLocked()` directly since they already hold the lock. This avoids deadlock — `NSLock` is not re-entrant. The `isStopped` flag ensures no restart attempts happen after `stop()` is called.

### Phase 4: Buffer delivery rate logging (silence detection)

Add periodic logging of buffer delivery rate to detect silent failures even if the notification mechanism doesn't fire.

**Changes to `AudioCapture.swift`:**

1. Add buffer counting properties:

```swift
// Add to AudioCapture as nonisolated(unsafe) properties:
nonisolated(unsafe) private var micBufferCount: Int = 0
nonisolated(unsafe) private var micLastLogTime: ContinuousClock.Instant? = nil
```

2. In the tap callback, increment counter and periodically log using `ContinuousClock` for correct time comparisons (not raw mach time ticks, which are not nanoseconds on all hardware):

```swift
inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
    guard let self else { return }
    let hostTime = mach_continuous_time()
    self.micBufferCount += 1

    // Log buffer rate every ~30 seconds using ContinuousClock
    let now = ContinuousClock.now
    if self.micLastLogTime == nil || now - (self.micLastLogTime ?? now) > .seconds(30) {
        DiagnosticLog.shared.log("[Mic] Buffer count: \(self.micBufferCount), format: \(inputFormat.sampleRate)Hz/\(inputFormat.channelCount)ch")
        self.micLastLogTime = now
    }

    if self.micOriginHostTime == 0 {
        self.micOriginHostTime = hostTime
    }
    let timestamped = TimestampedBuffer(buffer: buffer, hostTime: hostTime)
    self._micContinuation.yield(timestamped)
}
```

3. Add a watchdog timer that checks if `micBufferCount` has increased. Stored as a cancellable `Task` so `stop()` can cancel it:

```swift
// In start(), after startMicCapture():
watchdogTask = Task.detached { [weak self] in
    var lastCount = 0
    while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(15))
        guard let self = self, !self.isStopped else { return }
        let current = self.micBufferCount
        if current == lastCount {
            DiagnosticLog.shared.log("[Mic] WARNING: No new buffers in last 15 seconds — mic may be stalled")
        }
        lastCount = current
    }
}
```

### Phase 5: Add `--device` flag for explicit device selection

Allow the user to specify an input device by name or UID.

**Changes to `Transcribe.swift`:**

1. Add option to the command:

```swift
@Option(name: .long, help: "Input device name or UID. Use --list-devices to see available devices.")
var device: String?

@Flag(name: .long, help: "List available audio input devices and exit.")
var listDevices = false
```

2. Handle `--list-devices` in `run()`:

```swift
if listDevices {
    let devices = listInputDevices()
    if devices.isEmpty {
        print("No audio input devices found.")
    } else {
        print("Available input devices:")
        let defaultID = getDefaultInputDeviceID()
        for d in devices {
            let marker = d.id == defaultID ? " (default)" : ""
            print("  \(d.name)\(marker)")
            print("    UID: \(d.uid)")
        }
    }
    return
}
```

3. Pass `device` to `AudioCapture` and `runLiveRecording()`.

**Changes to `AudioCapture`:**

1. Store the requested device UID (not AudioDeviceID, since IDs are not stable across disconnect/reconnect):

```swift
private let requestedDeviceUID: String?
```

2. Accept UID in init:

```swift
init(requestedDeviceUID: String? = nil) {
    // ... existing stream setup ...
    self.requestedDeviceUID = requestedDeviceUID
}
```

3. In `startMicCapture()`, if `requestedDeviceUID` is set, resolve it to a current `AudioDeviceID` and set it on the engine before `engine.prepare()`:

```swift
if let uid = requestedDeviceUID, let deviceID = resolveDeviceID(forUID: uid) {
    try setInputDevice(engine: engine, deviceID: deviceID)
    DiagnosticLog.shared.log("[Mic] Set input device to requested UID: \(String(uid.prefix(8)))...")
} else if let uid = requestedDeviceUID {
    DiagnosticLog.shared.log("[Mic] WARNING: Requested device (UID: \(String(uid.prefix(8)))...) not available — falling back to system default. Mic output may be from a different source.")
}
```

4. On device change restart (Phase 3), if a specific device UID was requested, attempt to re-resolve and re-select it. If the device is no longer available (e.g., AirPods disconnected), fall back to the system default with a prominent warning.

**Resolution logic** in `Transcribe.swift`:

```swift
// Resolve --device to a stable UID
var requestedDeviceUID: String? = nil
if let device {
    let devices = listInputDevices()
    if let match = devices.first(where: { $0.name == device || $0.uid == device }) {
        requestedDeviceUID = match.uid
    } else {
        // Partial match
        if let match = devices.first(where: { $0.name.localizedCaseInsensitiveContains(device) }) {
            requestedDeviceUID = match.uid
        } else {
            throw ValidationError("Device not found: '\(device)'. Use --list-devices to see available devices.")
        }
    }
}
let capture = AudioCapture(requestedDeviceUID: requestedDeviceUID)
```

### Phase 6: Edge case handling

**No device available after switch:**

In `handleConfigurationChange`, if `startMicCapture()` throws `.noMicrophoneAvailable`:
- Log a clear error: `"[Mic] No input device available after device change — waiting for device"`
- Cancel any existing retry task first, then start a new one (stored so `stop()` can cancel it)
- If a device becomes available within the retry window, restart capture
- If not, log a final warning but do NOT crash or finish the continuation (system audio transcription should continue)

```swift
// Retry logic in handleConfigurationChange:
if let error = error as? TranscribeError, case .noMicrophoneAvailable = error {
    DiagnosticLog.shared.log("[Mic] No input device available — will retry every 5s")
    retryTask?.cancel()
    retryTask = Task.detached { [weak self] in
        for attempt in 1...12 {  // up to 60 seconds
            try? await Task.sleep(for: .seconds(5))
            guard let self = self, !self.isStopped, !Task.isCancelled else { return }
            self.micLock.lock()
            defer { self.micLock.unlock() }
            guard !self.isStopped else { return }
            do {
                try self.startMicCaptureLocked()
                DiagnosticLog.shared.log("[Mic] Recovered on retry #\(attempt)")
                return
            } catch {
                DiagnosticLog.shared.log("[Mic] Retry #\(attempt) failed: \(error.localizedDescription)")
            }
        }
        DiagnosticLog.shared.log("[Mic] ERROR: Could not recover mic capture after 60 seconds")
    }
}
```

**Rapid device switching:**

If the user rapidly switches devices, multiple `configurationChange` notifications may fire in quick succession. The `micLock` from Phase 3 prevents concurrent restarts. Additionally, debounce using `ContinuousClock` (not raw mach time ticks, which are not nanoseconds on all hardware):

```swift
nonisolated(unsafe) private var lastRestartTime: ContinuousClock.Instant? = nil

// In handleConfigurationChange, after acquiring lock and checking isStopped:
let now = ContinuousClock.now
if let last = lastRestartTime, now - last < .seconds(1) {
    DiagnosticLog.shared.log("[Mic] Debouncing rapid device change notification")
    return
}
lastRestartTime = now
```

**Requested device disappears:**

If `--device` was specified and that device disconnects:
1. Fall back to system default
2. Log prominently: `"[Mic] WARNING: Requested device (UID: <truncated>) no longer available — falling back to system default. Mic output may be from a different source."`
3. On next configuration change, attempt to re-resolve the requested UID — if the device is back, re-select it

## Testing

### Manual test steps

1. **Basic device logging:** Run `transcribe`, verify stderr shows `[Mic] Using input device: <name>` at startup.

2. **Device change recovery:** Start transcribe with built-in mic, then connect AirPods (or change default input in System Settings > Sound). Verify:
   - `[Mic] AVAudioEngine configuration change detected` appears in stderr
   - `[Mic] Successfully restarted mic capture` appears
   - Transcription continues with the new device

3. **Buffer rate monitoring:** Let transcribe run for 60+ seconds, verify periodic `[Mic] Buffer count:` log lines appear in stderr.

4. **Device listing:** Run `transcribe --list-devices`, verify all input devices are listed with names and UIDs, and the default is marked.

5. **Explicit device selection:** Run `transcribe --device "MacBook Pro Microphone"` (or whatever the built-in mic is named), verify it uses that device.

6. **No device edge case:** Start transcribe, then in System Settings, disable all input devices (if possible) or disconnect all external devices when no built-in mic. Verify graceful retry logging.

7. **Stop during retry:** Start transcribe, trigger a device change that causes retry, then Ctrl-C during retry. Verify clean shutdown without crashes or hangs.

### Build verification

```bash
cd ~/Development/jtennant-transcriber && swift build
```

Ensure no warnings related to Sendable, concurrency, or CoreAudio deprecations.

### Unit tests

Extract the device matching logic from `Transcribe.swift` into a pure helper function in `AudioDeviceUtils.swift`:

```swift
/// Find a matching device by exact name, exact UID, or partial case-insensitive name.
/// Returns nil if no match found. Pure function — no hardware access.
func findMatchingDevice(query: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
    // Exact name or UID match
    if let match = devices.first(where: { $0.name == query || $0.uid == query }) {
        return match
    }
    // Partial case-insensitive name match
    return devices.first(where: { $0.name.localizedCaseInsensitiveContains(query) })
}
```

Add tests to `Tests/TranscribeTests/AudioDeviceMatchingTests.swift`:

- **Exact name match:** `findMatchingDevice(query: "MacBook Pro Microphone", in: [...])` returns correct device
- **Exact UID match:** `findMatchingDevice(query: "BuiltInMicrophoneDevice", in: [...])` returns correct device
- **Partial case-insensitive match:** `findMatchingDevice(query: "macbook", in: [...])` returns the MacBook device
- **No match:** `findMatchingDevice(query: "NonexistentDevice", in: [...])` returns nil
- **Empty list:** `findMatchingDevice(query: "anything", in: [])` returns nil

These tests use synthetic `AudioInputDevice` values — no hardware dependency.

Note: `resolveDeviceID(forUID:)` and actual device switching are hardware-dependent and covered by manual test steps above.

## Implementation order

Phases should be implemented in order (1-6) since each builds on the previous. However, Phases 1-4 are the critical fix, and Phase 5-6 are enhancements. A minimal viable fix is Phases 1-3.

## Files changed

- `Sources/Transcribe/AudioDeviceUtils.swift` (new) — Phase 1
- `Sources/Transcribe/AudioCapture.swift` — Phases 2, 3, 4, 5 (init change)
- `Sources/Transcribe/Transcribe.swift` — Phase 5 (--device, --list-devices flags)
- `Tests/TranscribeTests/AudioDeviceMatchingTests.swift` (new) — Unit tests for pure device matching logic
