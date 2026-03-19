import Foundation

/// Loads a custom word-replacement dictionary from a JSON file and applies
/// corrections to transcription output.
///
/// The dictionary file is a JSON object mapping mistranscribed words/phrases
/// to their correct forms:
///
/// ```json
/// {
///   "Cashapp": "Cash App",
///   "square up": "Square Up",
///   "blockInc": "Block, Inc."
/// }
/// ```
///
/// Matching is case-insensitive and respects word boundaries so partial words
/// are never replaced (e.g. "app" won't match inside "application").
struct CustomDictionary: @unchecked Sendable {
    /// Each entry compiles to a regex for efficient repeated application.
    private let entries: [(pattern: Regex<Substring>, replacement: String)]

    /// The number of replacement rules loaded.
    var count: Int { entries.count }

    /// An empty dictionary that performs no replacements.
    static let empty = CustomDictionary(entries: [])

    private init(entries: [(pattern: Regex<Substring>, replacement: String)]) {
        self.entries = entries
    }

    /// Load a dictionary from a JSON file at the given path.
    ///
    /// - Parameter path: Absolute path to a JSON file. Tilde is expanded.
    /// - Throws: If the file cannot be read or parsed.
    static func load(from path: String) throws -> CustomDictionary {
        let expandedPath = (path as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expandedPath)
        let data = try Data(contentsOf: url)

        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw CustomDictionaryError.invalidFormat(path: expandedPath)
        }

        let entries: [(Regex<Substring>, String)] = dict.compactMap { (key, value) in
            guard !key.isEmpty else { return nil }
            // Escape regex metacharacters in the key, then wrap with word boundaries.
            let escaped = NSRegularExpression.escapedPattern(for: key)
            guard let regex = try? Regex<Substring>("(?i)\\b\(escaped)\\b") else { return nil }
            return (regex, value)
        }

        return CustomDictionary(entries: entries)
    }

    /// Load the dictionary from the default path if it exists.
    /// Returns `.empty` if the file doesn't exist.
    static func loadDefault() -> CustomDictionary {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/transcribe/dictionary.json")
            .path

        guard FileManager.default.fileExists(atPath: defaultPath) else {
            return .empty
        }

        do {
            return try load(from: defaultPath)
        } catch {
            DiagnosticLog.shared.log("[CustomDictionary] Failed to load default dictionary: \(error.localizedDescription)")
            return .empty
        }
    }

    /// Apply all dictionary replacements to the given text.
    func apply(to text: String) -> String {
        guard !entries.isEmpty else { return text }
        var result = text
        for (pattern, replacement) in entries {
            result = result.replacing(pattern, with: replacement)
        }
        return result
    }
}

enum CustomDictionaryError: LocalizedError {
    case invalidFormat(path: String)

    var errorDescription: String? {
        switch self {
        case .invalidFormat(let path):
            return "Dictionary file is not a valid JSON object (expected {\"word\": \"replacement\", ...}): \(path)"
        }
    }
}
