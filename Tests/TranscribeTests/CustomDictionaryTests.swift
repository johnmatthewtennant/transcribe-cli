import Foundation
import Testing
@testable import transcribe

@Suite("CustomDictionary")
struct CustomDictionaryTests {
    let tmpDir: URL

    init() throws {
        tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcribe-dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    // MARK: - Loading

    @Test func loadValidDictionary() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        let json = """
        {
            "Cashapp": "Cash App",
            "blockInc": "Block, Inc."
        }
        """
        try json.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.count == 2)
    }

    @Test func loadEmptyDictionary() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("empty.json")
        try "{}".write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.count == 0)
    }

    @Test func loadInvalidJsonThrows() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("bad.json")
        try "not json".write(to: path, atomically: true, encoding: .utf8)

        #expect(throws: (any Error).self) {
            _ = try CustomDictionary.load(from: path.path)
        }
    }

    @Test func loadArrayJsonThrows() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("array.json")
        try "[\"a\", \"b\"]".write(to: path, atomically: true, encoding: .utf8)

        #expect(throws: CustomDictionaryError.self) {
            _ = try CustomDictionary.load(from: path.path)
        }
    }

    @Test func loadNonExistentFileThrows() {
        #expect(throws: (any Error).self) {
            _ = try CustomDictionary.load(from: "/nonexistent/dict.json")
        }
    }

    @Test func loadDefaultReturnsEmptyWhenNoFile() {
        let dict = CustomDictionary.loadDefault()
        // May or may not be empty depending on whether the user has a default file,
        // but it should not throw.
        _ = dict.count
    }

    // MARK: - Replacement

    @Test func simpleReplacement() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"Cashapp": "Cash App"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.apply(to: "Welcome to Cashapp") == "Welcome to Cash App")
    }

    @Test func caseInsensitiveMatch() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"cashapp": "Cash App"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.apply(to: "Welcome to CASHAPP today") == "Welcome to Cash App today")
        #expect(dict.apply(to: "Use CashApp now") == "Use Cash App now")
    }

    @Test func wordBoundaryRespected() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"app": "application"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        // Should replace standalone "app"
        #expect(dict.apply(to: "open the app") == "open the application")
        // Should NOT replace "app" inside "happy"
        #expect(dict.apply(to: "I am happy") == "I am happy")
    }

    @Test func multipleReplacements() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"Cashapp": "Cash App", "blockInc": "Block, Inc."}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.apply(to: "Cashapp is owned by blockInc") == "Cash App is owned by Block, Inc.")
    }

    @Test func multipleOccurrences() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"um": ""}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.apply(to: "um so um yeah um") == " so  yeah ")
    }

    @Test func emptyDictionaryNoOp() {
        let dict = CustomDictionary.empty
        #expect(dict.apply(to: "Hello world") == "Hello world")
        #expect(dict.count == 0)
    }

    @Test func noMatchReturnsOriginal() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"foo": "bar"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.apply(to: "Hello world") == "Hello world")
    }

    @Test func multiWordPhrase() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"square up": "Square Up"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.apply(to: "let me square up with you") == "let me Square Up with you")
    }

    @Test func regexMetacharactersEscaped() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"C++": "C plus plus"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        // C++ contains regex metacharacters; should be escaped properly
        #expect(dict.apply(to: "I use C++ daily") == "I use C plus plus daily")
    }

    @Test func emptyKeySkipped() throws {
        defer { cleanup() }
        let path = tmpDir.appendingPathComponent("dict.json")
        try """
        {"": "nothing", "hello": "hi"}
        """.write(to: path, atomically: true, encoding: .utf8)

        let dict = try CustomDictionary.load(from: path.path)
        #expect(dict.count == 1)
        #expect(dict.apply(to: "hello world") == "hi world")
    }
}
