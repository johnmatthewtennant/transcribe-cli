import AVFoundation
import CoreMedia
import Foundation
import os
import ScreenCaptureKit

/// Diagnostic logger for tracking dropped audio buffers and conversion failures.
final class DiagnosticLog: Sendable {
    static let shared = DiagnosticLog()
    private let logger = Logger(subsystem: "com.transcriber", category: "diagnostics")

    func log(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        fputs("[DIAG] \(message)\n", stderr)
    }
}

/// Timestamped audio buffer from either mic or system audio capture.
struct TimestampedBuffer: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    let hostTime: UInt64  // mach_continuous_time() at capture
}

/// Captures mic audio via AVAudioEngine and system audio via ScreenCaptureKit.
/// Each stream provides timestamped buffers via AsyncStream.
@available(macOS 15.0, *)
final class AudioCapture: NSObject, Sendable {
    private let _micContinuation: AsyncStream<TimestampedBuffer>.Continuation
    private let _systemContinuation: AsyncStream<TimestampedBuffer>.Continuation

    let micStream: AsyncStream<TimestampedBuffer>
    let systemStream: AsyncStream<TimestampedBuffer>

    // Stored as nonisolated(unsafe) since they're only mutated before concurrent access
    nonisolated(unsafe) private var audioEngine: AVAudioEngine?
    nonisolated(unsafe) private var scStream: SCStream?
    nonisolated(unsafe) private var streamDelegate: SystemAudioDelegate?

    /// Origin host time for mic stream (set when first buffer arrives)
    nonisolated(unsafe) var micOriginHostTime: UInt64 = 0
    /// Origin host time for system stream (set when first buffer arrives)
    nonisolated(unsafe) var systemOriginHostTime: UInt64 = 0

    override init() {
        var micCont: AsyncStream<TimestampedBuffer>.Continuation!
        var sysCont: AsyncStream<TimestampedBuffer>.Continuation!

        // Use bounded buffering strategy for backpressure
        micStream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { micCont = $0 }
        systemStream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { sysCont = $0 }

        _micContinuation = micCont
        _systemContinuation = sysCont

        super.init()
    }

    // MARK: - Permissions

    func checkPermissions() async throws {
        var denied: [TranscribeError] = []

        // Check microphone permission
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            if !granted {
                denied.append(.micPermissionDenied)
            }
        case .denied, .restricted:
            denied.append(.micPermissionDenied)
        @unknown default:
            denied.append(.micPermissionDenied)
        }

        // Check screen recording permission (for system audio)
        if !CGPreflightScreenCaptureAccess() {
            let granted = CGRequestScreenCaptureAccess()
            if !granted {
                denied.append(.screenRecordingPermissionDenied)
            }
        }

        if !denied.isEmpty {
            throw TranscribeError.permissionsDenied(denied)
        }
    }

    // MARK: - Start Capture

    func start() async throws {
        try startMicCapture()
        try await startSystemAudioCapture()
    }

    func stop() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        scStream?.stopCapture { _ in }
        _micContinuation.finish()
        _systemContinuation.finish()
    }

    // MARK: - Mic Capture (AVAudioEngine)

    private func startMicCapture() throws {
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)

        guard inputFormat.sampleRate > 0 else {
            throw TranscribeError.noMicrophoneAvailable
        }

        var isFirst = true
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            let hostTime = mach_continuous_time()
            if isFirst {
                self.micOriginHostTime = hostTime
                isFirst = false
            }
            let timestamped = TimestampedBuffer(buffer: buffer, hostTime: hostTime)
            self._micContinuation.yield(timestamped)
        }

        engine.prepare()
        try engine.start()
        self.audioEngine = engine
    }

    // MARK: - System Audio Capture (ScreenCaptureKit)

    private func startSystemAudioCapture() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)

        // We need at least one display to create a content filter
        guard let display = content.displays.first else {
            throw TranscribeError.noDisplayAvailable
        }

        // Create a filter that captures system audio (exclude all apps from video, just get audio)
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        // Minimize video overhead since we only want audio
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 1 fps minimum
        config.showsCursor = false

        let delegate = SystemAudioDelegate(
            continuation: _systemContinuation,
            onFirstBuffer: { [weak self] hostTime in
                self?.systemOriginHostTime = hostTime
            }
        )
        self.streamDelegate = delegate

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(delegate, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        try await stream.startCapture()
        self.scStream = stream
    }
}

// MARK: - System Audio Delegate

private final class SystemAudioDelegate: NSObject, SCStreamOutput, @unchecked Sendable {
    private let continuation: AsyncStream<TimestampedBuffer>.Continuation
    private let onFirstBuffer: (UInt64) -> Void
    private var isFirst = true

    init(continuation: AsyncStream<TimestampedBuffer>.Continuation, onFirstBuffer: @escaping (UInt64) -> Void) {
        self.continuation = continuation
        self.onFirstBuffer = onFirstBuffer
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        guard sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }

        let hostTime = mach_continuous_time()
        if isFirst {
            onFirstBuffer(hostTime)
            isFirst = false
        }

        // Convert CMSampleBuffer to AVAudioPCMBuffer
        guard let formatDesc = sampleBuffer.formatDescription,
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc),
              let format = AVAudioFormat(streamDescription: asbdPtr),
              let pcmBuffer = sampleBuffer.toPCMBuffer(format: format) else {
            return
        }

        let timestamped = TimestampedBuffer(buffer: pcmBuffer, hostTime: hostTime)
        continuation.yield(timestamped)
    }
}

// MARK: - CMSampleBuffer → AVAudioPCMBuffer

extension CMSampleBuffer {
    func toPCMBuffer(format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameCount = CMSampleBufferGetNumSamples(self)
        guard frameCount > 0,
              let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        guard let blockBuffer = CMSampleBufferGetDataBuffer(self) else { return nil }
        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let data = dataPointer else { return nil }

        if let dest = pcmBuffer.floatChannelData {
            // Float format
            let byteCount = min(length, Int(pcmBuffer.frameCapacity) * MemoryLayout<Float>.size * Int(format.channelCount))
            memcpy(dest[0], data, byteCount)
        } else if let dest = pcmBuffer.int16ChannelData {
            // Int16 format
            let byteCount = min(length, Int(pcmBuffer.frameCapacity) * MemoryLayout<Int16>.size * Int(format.channelCount))
            memcpy(dest[0], data, byteCount)
        }

        return pcmBuffer
    }
}

// MARK: - Errors

enum TranscribeError: LocalizedError {
    case micPermissionDenied
    case screenRecordingPermissionDenied
    case permissionsDenied([TranscribeError])
    case noMicrophoneAvailable
    case noDisplayAvailable
    case modelUnavailable(String)
    case captureError(String)

    var errorDescription: String? {
        switch self {
        case .micPermissionDenied:
            return """
            Microphone access denied.
            Open System Settings > Privacy & Security > Microphone and grant access to this app.
            """
        case .screenRecordingPermissionDenied:
            return """
            Screen Recording access denied (needed for system audio capture).
            Open System Settings > Privacy & Security > Screen Recording and grant access to this app.
            Then restart the app.
            """
        case .permissionsDenied(let errors):
            return errors.map { $0.localizedDescription }.joined(separator: "\n")
        case .noMicrophoneAvailable:
            return "No microphone available. Check that a microphone is connected."
        case .noDisplayAvailable:
            return "No display available for screen capture."
        case .modelUnavailable(let detail):
            return "Speech model unavailable: \(detail)"
        case .captureError(let detail):
            return "Capture error: \(detail)"
        }
    }
}
