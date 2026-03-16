import Testing
@testable import transcribe

@Suite("Speaker Name Sanitization")
struct SpeakerNameSanitizationTests {
    @Test func normalName() {
        #expect(sanitizeSpeakerName("Jack") == "Jack")
    }

    @Test func markdownBoldStripped() {
        #expect(sanitizeSpeakerName("**bold**") == "bold")
    }

    @Test func backtickStripped() {
        #expect(sanitizeSpeakerName("`code`") == "code")
    }

    @Test func underscoreItalicStripped() {
        #expect(sanitizeSpeakerName("__italic__") == "italic")
    }

    @Test func controlCharsStripped() {
        #expect(sanitizeSpeakerName("name\u{0007}here") == "namehere")
    }

    @Test func ansiEscapeStripped() {
        let input = "name\u{001B}[31mred"
        let result = sanitizeSpeakerName(input)
        #expect(!result.contains("\u{001B}"))
    }

    @Test func newlinesStripped() {
        #expect(sanitizeSpeakerName("line1\nline2") == "line1line2")
    }

    @Test func lengthLimit() {
        let longName = String(repeating: "a", count: 51)
        let result = sanitizeSpeakerName(longName)
        #expect(result.count == 50)
    }

    @Test func emptyAfterSanitization() {
        #expect(sanitizeSpeakerName("**") == "Speaker")
        #expect(sanitizeSpeakerName("``") == "Speaker")
    }
}

@Suite("Parse Speaker Names")
struct ParseSpeakerNamesTests {
    @Test func nilInput() {
        let (mic, sys) = parseSpeakerNames(nil)
        #expect(mic == "Local")
        #expect(sys == "Remote")
    }

    @Test func emptyInput() {
        let (mic, sys) = parseSpeakerNames("")
        #expect(mic == "Local")
        #expect(sys == "Remote")
    }

    @Test func twoNames() {
        let (mic, sys) = parseSpeakerNames("Jack,Jeanne")
        #expect(mic == "Jack")
        #expect(sys == "Jeanne")
    }

    @Test func singleName() {
        let (mic, sys) = parseSpeakerNames("Jack")
        #expect(mic == "Jack")
        #expect(sys == "Remote")
    }

    @Test func extraCommas() {
        let (mic, sys) = parseSpeakerNames("Jack, Jeanne , Extra")
        #expect(mic == "Jack")
        #expect(sys == "Jeanne , Extra")
    }

    @Test func whitespaceTrimmmed() {
        let (mic, sys) = parseSpeakerNames("  Jack  ,  Jeanne  ")
        #expect(mic == "Jack")
        #expect(sys == "Jeanne")
    }
}

@Suite("Title Sanitization")
struct TitleSanitizationTests {
    @Test func nilTitle() {
        #expect(sanitizeTitle(nil) == nil)
    }

    @Test func emptyTitle() {
        #expect(sanitizeTitle("") == nil)
    }

    @Test func normalTitle() {
        #expect(sanitizeTitle("My Title") == "My Title")
    }

    @Test func controlCharsStripped() {
        let result = sanitizeTitle("Hello\u{0007}World")
        #expect(result == "HelloWorld")
    }

    @Test func lengthLimit() {
        let longTitle = String(repeating: "a", count: 201)
        let result = sanitizeTitle(longTitle)
        #expect(result?.count == 200)
    }

    @Test func onlyControlChars() {
        #expect(sanitizeTitle("\u{0007}\u{0008}") == nil)
    }

    @Test func ansiEscapeStripped() {
        let result = sanitizeTitle("\u{001B}[31mRed Title")
        #expect(result != nil)
        #expect(!result!.contains("\u{001B}"))
    }
}
