// SPDX-License-Identifier: MPL-2.0
//
// Errors, repository layout and file helpers for lexicon-builder.

import Foundation

struct BuilderError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Where the pinned inputs and generated outputs live (data/README.md).
struct Layout {
    /// `<repo>/data`
    let dataRoot: URL
    /// Directory that receives the bundled resource files.
    let resources: URL

    var repoRoot: URL { dataRoot.deletingLastPathComponent() }
    var inputs: URL { dataRoot.appendingPathComponent("inputs") }
    var cache: URL { dataRoot.appendingPathComponent("cache") }
    var licenses: URL { dataRoot.appendingPathComponent("licenses") }
    var derived: URL { dataRoot.appendingPathComponent("derived") }
    var corpusFile: URL { dataRoot.appendingPathComponent("corpus/prose-vi.txt") }
    var manifestFile: URL { inputs.appendingPathComponent("MANIFEST.sha256") }
    var scowlDirectory: URL { inputs.appendingPathComponent("english/\(Scowl.release)") }
    var legalDirectory: URL { inputs.appendingPathComponent("legal") }

    static let defaultResourcesPath = "Packages/VietnameseEngine/Sources/VietnameseEngineData/Resources"

    /// Finds `data/` by walking up from `start` until `data/inputs/MANIFEST.sha256` exists.
    static func locateDataRoot(from start: URL) -> URL? {
        var directory = start.standardizedFileURL
        while true {
            let candidate = directory.appendingPathComponent("data")
            let marker = candidate.appendingPathComponent("inputs/MANIFEST.sha256")
            if FileManager.default.fileExists(atPath: marker.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { return nil }
            directory = parent
        }
    }
}

enum FileIO {
    static func read(_ url: URL) throws -> Data {
        do { return try Data(contentsOf: url) } catch {
            throw BuilderError("cannot read \(url.path): \(error.localizedDescription)")
        }
    }

    static func readUTF8(_ url: URL) throws -> String {
        let data = try read(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BuilderError("\(url.path) is not valid UTF-8")
        }
        return text
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try data.write(to: url, options: .atomic) } catch {
            throw BuilderError("cannot write \(url.path): \(error.localizedDescription)")
        }
    }

    static func write(_ text: String, to url: URL) throws {
        try write(Data(text.utf8), to: url)
    }

    /// Lines of a hand-edited input file without comments (`#` to end of line) and blank lines.
    /// Returns (1-based line number, trimmed content).
    static func contentLines(_ text: String) -> [(number: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            var line = Substring(raw)
            if let hash = line.firstIndex(of: "#") { line = line[..<hash] }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : (index + 1, trimmed)
        }
    }

    /// Non-empty lines that do not start with `#`, with their 1-based line numbers (tab-separated data).
    static func dataLines(_ text: String) -> [(number: Int, text: String)] {
        text.split(separator: "\n", omittingEmptySubsequences: false).enumerated().compactMap { index, raw in
            raw.isEmpty || raw.hasPrefix("#") ? nil : (index + 1, String(raw))
        }
    }

    static func temporaryDirectory(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("lexicon-builder-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Runs an external tool and returns its standard output.
    static func run(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(decoding: errorData, as: UTF8.self)
            throw BuilderError("\(executable) failed (\(process.terminationStatus)): \(message)")
        }
        return data
    }
}

/// Sorting by UTF-8 bytes keeps every generated file independent of locale and Unicode library version.
func utf8Sorted<S: Sequence>(_ words: S) -> [String] where S.Element == String {
    words.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

/// Joins lines with LF and a final LF (empty list -> empty file).
func joinedLines(_ lines: [String]) -> String {
    lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
}
