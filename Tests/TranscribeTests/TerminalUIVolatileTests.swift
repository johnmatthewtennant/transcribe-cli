import Testing
@testable import transcribe

@Suite("TerminalUI Volatile Display")
struct TerminalUIVolatileTests {
    let mic = "Mic"
    let sys = "System"

    private func makeUI(columns: Int = 80) -> TerminalUI {
        TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: true, overrideColumns: columns)
    }

    // MARK: - Single speaker

    @Test func singleSpeakerVolatile() {
        let ui = makeUI()
        ui.showVolatile(speaker: mic, text: "hello world")
        let segs = ui.volatileSegments()
        #expect(segs.count == 1)
        #expect(segs[0].speaker == mic)
        #expect(segs[0].text == "hello world")
    }

    @Test func volatileNeverRetracts() {
        let ui = makeUI()
        ui.showVolatile(speaker: mic, text: "longer text here")
        ui.showVolatile(speaker: mic, text: "short")
        let segs = ui.volatileSegments()
        #expect(segs.count == 1)
        #expect(segs[0].text == "longer text here")
    }

    @Test func finalizedKeepsVolatileUntilCleared() {
        let ui = makeUI()
        ui.showVolatile(speaker: mic, text: "interim")
        ui.showFinalized(speaker: mic, text: "final text")
        // showFinalized does NOT clear volatile — last interim persists to avoid blank gap
        let segs = ui.volatileSegments()
        #expect(segs.count == 1)
        #expect(segs[0].text == "interim")
    }

    @Test func clearVolatileRemovesState() {
        let ui = makeUI()
        ui.showVolatile(speaker: mic, text: "interim")
        ui.clearVolatile(speaker: mic)
        let segs = ui.volatileSegments()
        #expect(segs.isEmpty)
    }

    // MARK: - Dual channel

    @Test func dualChannelBothVisible() {
        let ui = makeUI(columns: 80)
        ui.showVolatile(speaker: mic, text: "mic text")
        ui.showVolatile(speaker: sys, text: "sys text")
        let segs = ui.volatileSegments()
        #expect(segs.count == 2)
        #expect(segs[0].speaker == mic)
        #expect(segs[1].speaker == sys)
    }

    @Test func finalizeOneSpeakerKeepsOther() {
        let ui = makeUI(columns: 80)
        ui.showVolatile(speaker: mic, text: "mic interim")
        ui.showVolatile(speaker: sys, text: "sys interim")
        ui.showFinalized(speaker: mic, text: "mic final")
        // showFinalized doesn't clear volatile; use clearVolatile for that
        ui.clearVolatile(speaker: mic)
        let segs = ui.volatileSegments()
        #expect(segs.count == 1)
        #expect(segs[0].speaker == sys)
        #expect(segs[0].text == "sys interim")
    }

    @Test func interleavedUpdates() {
        let ui = makeUI(columns: 80)
        ui.showVolatile(speaker: mic, text: "a")
        ui.showVolatile(speaker: sys, text: "b")
        ui.showVolatile(speaker: mic, text: "aa")
        ui.showVolatile(speaker: sys, text: "bb")
        let segs = ui.volatileSegments()
        #expect(segs.count == 2)
        #expect(segs[0].text == "aa")
        #expect(segs[1].text == "bb")
    }

    // MARK: - Narrow terminal

    @Test func narrowTerminalFallsBackToOneSpeaker() {
        // With columns=30 and speakers "Mic" (3) + "System" (6):
        // Label overhead for both = (3+3) + (6+3) + 1 separator = 16
        // Available text = 30 - 16 = 14, need 2*10=20 → too narrow → fallback to one
        let ui = makeUI(columns: 30)
        ui.showVolatile(speaker: mic, text: "mic text")
        ui.showVolatile(speaker: sys, text: "sys text")
        let segs = ui.volatileSegments()
        #expect(segs.count == 1)
        // Falls back to last speaker in [mic, system] order = system
        #expect(segs[0].speaker == sys)
    }

    @Test func veryNarrowTerminalTruncatesAggressively() {
        // columns=15, speaker "Mic" (3): label overhead = 3+3 = 6, available = 9
        let ui = makeUI(columns: 15)
        ui.showVolatile(speaker: mic, text: "abcdefghijklmnop")
        let segs = ui.volatileSegments()
        #expect(segs.count == 1)
        // maxTextWidth = 15 - 6 = 9, text.count(16) > 9 → truncate to 6 + "..."
        #expect(segs[0].text == "abcdef...")
    }

    @Test func wideTerminalFitsBoth() {
        let ui = makeUI(columns: 120)
        ui.showVolatile(speaker: mic, text: "hello from mic channel")
        ui.showVolatile(speaker: sys, text: "hello from system channel")
        let segs = ui.volatileSegments()
        #expect(segs.count == 2)
        // Both should fit without truncation at 120 columns
        #expect(segs[0].text == "hello from mic channel")
        #expect(segs[1].text == "hello from system channel")
    }

    // MARK: - showInterim disabled

    @Test func interimDisabledIgnoresVolatile() {
        let ui = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false, overrideColumns: 80)
        ui.showVolatile(speaker: mic, text: "should be ignored")
        let segs = ui.volatileSegments()
        #expect(segs.isEmpty)
    }
}
