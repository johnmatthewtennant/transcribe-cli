import Testing
@testable import transcribe

@Suite("ReorderBuffer")
struct ReorderBufferTests {
    func makeEvent(speaker: String = "You", text: String = "test", time: UInt64, isFinal: Bool = true) -> TranscriptEvent {
        TranscriptEvent(speaker: speaker, text: text, wallClockTime: time, isFinal: isFinal)
    }

    @Test func eventsWithinWatermarkNotFlushed() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 2_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(time: 1_000_000_000))
        #expect(flushed.isEmpty)
        #expect(buffer.count == 1)
    }

    @Test func eventsFlushedPastWatermark() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 2_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(speaker: "You", text: "first", time: 1_000_000_000))
        buffer.add(makeEvent(speaker: "Remote", text: "second", time: 4_000_000_000))

        #expect(flushed.count == 1)
        #expect(flushed[0].text == "first")
    }

    @Test func crossChannelChronologicalOrder() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 1_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(speaker: "Remote", text: "B", time: 2_000_000_000))
        buffer.add(makeEvent(speaker: "You", text: "A", time: 1_000_000_000))
        buffer.add(makeEvent(speaker: "You", text: "C", time: 5_000_000_000))

        #expect(flushed.count == 2)
        #expect(flushed[0].text == "A")
        #expect(flushed[0].speaker == "You")
        #expect(flushed[1].text == "B")
        #expect(flushed[1].speaker == "Remote")
    }

    @Test func equalTimestamps() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 1_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(speaker: "You", text: "A", time: 1_000_000_000))
        buffer.add(makeEvent(speaker: "Remote", text: "B", time: 1_000_000_000))
        buffer.add(makeEvent(speaker: "You", text: "C", time: 3_000_000_000))

        #expect(flushed.count == 2)
    }

    @Test func boundaryExactCutoffNotFlushed() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 2_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(text: "boundary", time: 1_000_000_000))
        buffer.add(makeEvent(text: "trigger", time: 3_000_000_000))

        #expect(flushed.isEmpty)
        #expect(buffer.count == 2)
    }

    @Test func lateOutOfOrderArrival() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 1_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(speaker: "You", text: "newer", time: 3_000_000_000))
        buffer.add(makeEvent(speaker: "Remote", text: "older", time: 1_000_000_000))
        buffer.add(makeEvent(speaker: "You", text: "latest", time: 5_000_000_000))

        #expect(flushed.count == 2)
        #expect(flushed[0].text == "older")
        #expect(flushed[1].text == "newer")
    }

    @Test func flushAllOnStop() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 100_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(speaker: "You", text: "B", time: 2_000_000_000))
        buffer.add(makeEvent(speaker: "Remote", text: "A", time: 1_000_000_000))
        #expect(flushed.isEmpty)

        buffer.flushAll()
        #expect(flushed.count == 2)
        #expect(flushed[0].text == "A")
        #expect(flushed[1].text == "B")
        #expect(buffer.count == 0)
    }

    @Test func emptyFlushAll() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 1_000_000_000) { flushed.append($0) }

        buffer.flushAll()
        #expect(flushed.isEmpty)
    }

    @Test func singleChannelOrdering() {
        var flushed: [TranscriptEvent] = []
        var buffer = ReorderBuffer(watermarkNanos: 1_000_000_000) { flushed.append($0) }

        buffer.add(makeEvent(speaker: "You", text: "A", time: 1_000_000_000))
        buffer.add(makeEvent(speaker: "You", text: "B", time: 2_000_000_000))
        buffer.add(makeEvent(speaker: "You", text: "C", time: 4_000_000_000))

        #expect(flushed.count == 2)
        #expect(flushed[0].text == "A")
        #expect(flushed[1].text == "B")
    }
}
