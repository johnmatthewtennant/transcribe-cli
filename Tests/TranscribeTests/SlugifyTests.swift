import Testing
@testable import transcribe

@Suite("Slugify")
struct SlugifyTests {
    @Test func basicSlug() {
        #expect(slugify("Weekly sync") == "weekly-sync")
    }

    @Test func unicodePreserved() {
        // CharacterSet.alphanumerics includes Unicode letters
        #expect(slugify("Café meeting") == "café-meeting")
    }

    @Test func specialCharsStripped() {
        #expect(slugify("Hello, World! #1") == "hello-world-1")
    }

    @Test func emptyString() {
        #expect(slugify("") == "")
    }

    @Test func alreadySlugified() {
        #expect(slugify("my-title") == "my-title")
    }

    @Test func multipleSpaces() {
        #expect(slugify("a  b   c") == "a--b---c")
    }

    @Test func numbersPreserved() {
        #expect(slugify("Meeting 42") == "meeting-42")
    }
}
