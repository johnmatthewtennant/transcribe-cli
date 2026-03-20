#if compiler(>=6.2)
import ArgumentParser
import Foundation

@available(macOS 26.0, *)
struct MergeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "merge",
        abstract: "Merge mic and system audio CAF files into a single stereo file.",
        discussion: """
        Combines a .mic.caf and .sys.caf recording pair into a single stereo file.
        Left channel = mic (local), Right channel = system (remote).

        By default, outputs a stereo WAV file. Use --format m4a for AAC-compressed output.

        Examples:
          transcribe merge recording.mic.caf recording.sys.caf
          transcribe merge recording.mic.caf recording.sys.caf -o merged.wav
          transcribe merge recording.mic.caf recording.sys.caf --format m4a
        """
    )

    @Argument(help: "Path to the mic (local) CAF file.")
    var micFile: String

    @Argument(help: "Path to the system (remote) CAF file.")
    var sysFile: String

    @Option(name: .shortAndLong, help: "Output file path. Defaults to <base>.wav (or .m4a with --format m4a).")
    var output: String?

    @Option(name: .long, help: "Output format: wav (default) or m4a.")
    var format: String = "wav"

    @Flag(name: .long, help: "Delete the original CAF files after successful merge.")
    var deleteOriginals = false

    /// Overridable merge function for testing. Defaults to AudioMerger.mergeToStereo.
    /// Set to a custom closure in tests to simulate failures after file creation.
    nonisolated(unsafe) static var _mergeOverride: ((URL, URL, URL, AudioMerger.OutputFormat) throws -> Void)?

    func validate() throws {
        let validFormats = ["wav", "m4a"]
        guard validFormats.contains(format.lowercased()) else {
            throw ValidationError("Unsupported format '\(format)'. Use 'wav' or 'm4a'.")
        }

        // Reject output extension that doesn't match format
        if let output {
            let outputURL = URL(fileURLWithPath: output)
            let ext = outputURL.pathExtension.lowercased()
            let expectedExt = format.lowercased() == "m4a" ? "m4a" : "wav"
            if !ext.isEmpty && ext != expectedExt {
                throw ValidationError(
                    "Output extension '.\(ext)' doesn't match format '\(format)'. "
                    + "Use -o with a .\(expectedExt) extension, or change --format."
                )
            }
        }
    }

    func run() throws {
        let fm = FileManager.default
        let micURL = URL(fileURLWithPath: (micFile as NSString).expandingTildeInPath).standardizedFileURL
        let sysURL = URL(fileURLWithPath: (sysFile as NSString).expandingTildeInPath).standardizedFileURL

        guard fm.fileExists(atPath: micURL.path) else {
            throw ValidationError("Mic file not found: \(micURL.path)")
        }
        guard fm.fileExists(atPath: sysURL.path) else {
            throw ValidationError("System file not found: \(sysURL.path)")
        }
        guard micURL != sysURL else {
            throw ValidationError("Mic and system files must be different files.")
        }

        let outputFormat: AudioMerger.OutputFormat = format.lowercased() == "m4a" ? .aac : .wav
        let ext = outputFormat == .aac ? "m4a" : "wav"

        let outputURL: URL
        if let output {
            outputURL = URL(fileURLWithPath: (output as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            // Derive output path from mic file: remove .mic.caf, append .wav/.m4a
            let micPath = micURL.path
            let basePath: String
            if micPath.hasSuffix(".mic.caf") {
                basePath = String(micPath.dropLast(".mic.caf".count))
            } else {
                basePath = micURL.deletingPathExtension().path
            }
            outputURL = URL(fileURLWithPath: basePath).appendingPathExtension(ext)
        }

        if fm.fileExists(atPath: outputURL.path) {
            throw ValidationError("Output file already exists: \(outputURL.path). Use -o to specify a different path.")
        }

        fputs("Merging:\n  mic: \(micURL.lastPathComponent)\n  sys: \(sysURL.lastPathComponent)\n", stderr)
        fputs("Output: \(outputURL.path)\n", stderr)

        do {
            if let override = Self._mergeOverride {
                try override(micURL, sysURL, outputURL, outputFormat)
            } else {
                try AudioMerger.mergeToStereo(
                    micPath: micURL, sysPath: sysURL, outputPath: outputURL, format: outputFormat
                )
            }
        } catch {
            // Clean up partial output file on failure
            try? fm.removeItem(at: outputURL)
            throw error
        }

        // Report file size
        if let attrs = try? fm.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? UInt64 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
            fputs("Done. Output: \(outputURL.lastPathComponent) (\(sizeStr))\n", stderr)
        } else {
            fputs("Done. Output: \(outputURL.lastPathComponent)\n", stderr)
        }

        if deleteOriginals {
            var deleted: [String] = []
            var failed: [String] = []
            for url in [micURL, sysURL] {
                do {
                    try fm.removeItem(at: url)
                    deleted.append(url.lastPathComponent)
                } catch {
                    failed.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if !deleted.isEmpty {
                fputs("Deleted: \(deleted.joined(separator: ", "))\n", stderr)
            }
            if !failed.isEmpty {
                fputs("Error: failed to delete: \(failed.joined(separator: "; "))\n", stderr)
                throw ExitCode(1)
            }
        }
    }
}
#endif
