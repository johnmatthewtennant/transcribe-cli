import Foundation

/// A reorder buffer that collects events and flushes them in chronological order
/// once they're older than the watermark duration.
struct ReorderBuffer {
    typealias Event = TranscriptEvent

    private var buffer: [Event] = []
    private let watermarkNanos: UInt64
    private let onFlush: (Event) -> Void

    /// - Parameters:
    ///   - watermarkNanos: Events older than `currentTime - watermarkNanos` are flushed.
    ///   - onFlush: Called for each event when flushed, in chronological order.
    init(watermarkNanos: UInt64 = 500_000_000, onFlush: @escaping (Event) -> Void) {
        self.watermarkNanos = watermarkNanos
        self.onFlush = onFlush
    }

    /// Add an event and flush any events past the watermark.
    mutating func add(_ event: Event) {
        buffer.append(event)
        flush(currentTime: event.wallClockTime)
    }

    /// Flush events older than `currentTime - watermark`.
    private mutating func flush(currentTime: UInt64) {
        let cutoff = currentTime > watermarkNanos ? currentTime - watermarkNanos : 0
        let ready = buffer.filter { $0.wallClockTime < cutoff }
            .sorted { $0.wallClockTime < $1.wallClockTime }

        for event in ready {
            onFlush(event)
        }

        buffer.removeAll { $0.wallClockTime < cutoff }
    }

    /// Flush events older than watermark based on current time (called periodically).
    mutating func flushStale() {
        guard !buffer.isEmpty else { return }
        let now = mach_continuous_time()
        flush(currentTime: now)
    }

    /// Flush all remaining events in chronological order (called on stop).
    mutating func flushAll() {
        if !buffer.isEmpty {
            DiagnosticLog.shared.log("[ReorderBuffer] flushAll: flushing \(buffer.count) remaining events")
        }
        let remaining = buffer.sorted { $0.wallClockTime < $1.wallClockTime }
        for event in remaining {
            onFlush(event)
        }
        buffer.removeAll()
    }

    /// Number of buffered (unflushed) events.
    var count: Int { buffer.count }
}
