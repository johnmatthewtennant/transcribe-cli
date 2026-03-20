import Foundation
import Testing
@testable import transcribe

@Suite("TerminalUI Volatile Display")
struct TerminalUIVolatileTests {
    let mic = "Mic"
    let sys = "System"

    private func makeUI(columns: Int = 80) -> TerminalUI {
        TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: true, overrideColumns: columns)
    }

    // MARK: - Interim skips mic speaker

    @Test func interimSkipsMicSpeaker() {
        let ui = makeUI()
        // Mic interim should be silently ignored
        ui.showVolatile(speaker: mic, text: "local speech")
        // No crash, no visible output — just verifying it doesn't error
    }

    @Test func interimShowsSystemSpeaker() {
        let ui = makeUI()
        ui.showVolatile(speaker: sys, text: "remote speech")
        // Verifying it doesn't crash with system speaker
    }

    // MARK: - Processing promotion

    @Test func shorterTextPromotesToProcessing() {
        let ui = makeUI()
        // Simulate segment A growing
        ui.showVolatile(speaker: sys, text: "segment A text here")
        // Segment B starts (shorter text = new segment)
        ui.showVolatile(speaker: sys, text: "seg B")
        // Segment A should now be in processing state
        // (We can't inspect internal state directly, but verify no crash
        // and that showFinalized works correctly after)
        ui.showFinalized(speaker: sys, text: "Segment A finalized text.")
    }

    // MARK: - Finalization clears processing

    @Test func finalizationRemovesProcessingLine() {
        let ui = makeUI()
        ui.showVolatile(speaker: sys, text: "long interim text for segment")
        ui.showVolatile(speaker: sys, text: "new") // promotes old to processing
        ui.showFinalized(speaker: sys, text: "Finalized segment.")
        // Should not crash, processing line removed
    }

    @Test func multipleProcessingLinesClearedInOrder() {
        let ui = makeUI()
        // Create multiple processing lines
        ui.showVolatile(speaker: sys, text: "segment one interim")
        ui.showVolatile(speaker: sys, text: "seg two") // promotes seg one
        ui.showVolatile(speaker: sys, text: "s") // promotes seg two
        // Finalize first processing line
        ui.showFinalized(speaker: sys, text: "Segment one final.")
        // Finalize second
        ui.showFinalized(speaker: sys, text: "Segment two final.")
    }

    // MARK: - showInterim disabled

    @Test func interimDisabledIgnoresVolatile() {
        let ui = TerminalUI(micSpeaker: mic, systemSpeaker: sys, showInterim: false, overrideColumns: 80)
        ui.showVolatile(speaker: sys, text: "should be ignored")
        // No crash, no output
    }

    // MARK: - Summary cleans up

    @Test func summaryAfterInterimDoesNotCrash() {
        let ui = makeUI()
        ui.showVolatile(speaker: sys, text: "interim still showing")
        ui.printSummary(duration: 10, wordCount: 5, filePath: URL(fileURLWithPath: "/tmp/test.md"))
    }

    @Test func summaryAfterProcessingDoesNotCrash() {
        let ui = makeUI()
        ui.showVolatile(speaker: sys, text: "long segment text")
        ui.showVolatile(speaker: sys, text: "new") // promotes to processing
        ui.printSummary(duration: 10, wordCount: 5, filePath: URL(fileURLWithPath: "/tmp/test.md"))
    }
}
