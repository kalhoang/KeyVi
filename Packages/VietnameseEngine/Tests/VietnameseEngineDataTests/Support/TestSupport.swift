// SPDX-License-Identifier: MPL-2.0
//
// Helpers shared by the data tests: repository paths, the lexicon-builder executable (driven as a
// subprocess because the test target cannot import an executable target without a manifest change),
// temporary directories and hand-made resource directories.

import CryptoKit
import Foundation
import Testing

enum TestPaths {
    /// `<repo>/Packages/VietnameseEngine`
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // VietnameseEngineDataTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // VietnameseEngine

    static var repoRoot: URL { packageRoot.deletingLastPathComponent().deletingLastPathComponent() }
    static var dataRoot: URL { repoRoot.appendingPathComponent("data") }
    static var committedResources: URL {
        packageRoot.appendingPathComponent("Sources/VietnameseEngineData/Resources")
    }

    /// The lexicon-builder executable built next to the test bundle.
    static func lexiconBuilder() throws -> URL {
        let fileManager = FileManager.default
        var candidates: [URL] = []
        if let explicit = ProcessInfo.processInfo.environment["LEXICON_BUILDER"] {
            candidates.append(URL(fileURLWithPath: explicit))
        }
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            candidates.append(bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("lexicon-builder"))
        }
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("lexicon-builder"))
        for relative in [".build/debug/lexicon-builder", ".build/out/Products/Debug/lexicon-builder"] {
            candidates.append(packageRoot.appendingPathComponent(relative))
        }
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) { return found }
        throw TestFailure("lexicon-builder not found; build it first (swift build) or set LEXICON_BUILDER")
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ProcessResult {
    let status: Int32
    let output: Data
    let errors: String
    var text: String { String(decoding: output, as: UTF8.self) }
}

enum Builder {
    /// Runs lexicon-builder with `arguments`, optional standard input, in `directory`.
    static func run(_ arguments: [String], input: String? = nil, in directory: URL? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = try TestPaths.lexiconBuilder()
        process.arguments = arguments
        process.currentDirectoryURL = directory ?? TestPaths.repoRoot
        let output = Pipe()
        let errors = Pipe()
        let inputPipe = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = inputPipe
        try process.run()
        if let input { inputPipe.fileHandleForWriting.write(Data(input.utf8)) }
        try inputPipe.fileHandleForWriting.close()
        // Read both pipes concurrently-safe: stderr is small, stdout may be large.
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessResult(
            status: process.terminationStatus, output: outputData, errors: String(decoding: errorData, as: UTF8.self))
    }
}

enum TempDirectory {
    static func make(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-data-tests-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }
}

func write(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Writes a resource directory in the bundled format: the given files plus a manifest.json that
/// matches them (unless `manifestOverride` is given), so tests can target one validation at a time.
enum ResourceFixture {
    static let valid: [String: String] = [
        "english.txt": "as\nis\ntest\nthis\n",
        "tech-always.txt": "usb\nwifi\nwww\n",
        "tech-code-only.txt": "tar\n",
        "attested.txt": "hòa\nhoà\ná\nđi\n",
        "ambiguity.tsv": "raw\tdecision\tstatus\tdisplay\tnote\nas\tvi\tproposed\tá\tx\nis\ten\tunreviewed\tí\tx\ntest\ten\tproposed\ttét\tx\n",
        "NOTICES.txt": "notices\n",
    ]

    static func make(
        replacing overrides: [String: String] = [:], removing removed: Set<String> = [],
        entryOverrides: [String: Int] = [:], manifestOverride: String? = nil
    ) throws -> URL {
        let directory = try TempDirectory.make("resources")
        var files = valid.merging(overrides) { _, new in new }
        for name in removed { files[name] = nil }
        var manifestFiles: [String] = []
        for (name, text) in files.sorted(by: { $0.key < $1.key }) {
            let data = Data(text.utf8)
            try data.write(to: directory.appendingPathComponent(name))
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
            let entries = entryOverrides[name] ?? (name == "ambiguity.tsv" ? lines - 1 : lines)
            let entryField = name == "NOTICES.txt" ? "" : ", \"entries\": \(entries)"
            manifestFiles.append(
                "{\"name\": \"\(name)\", \"bytes\": \(data.count)\(entryField), \"sha256\": \"\(sha256Hex(data))\"}")
        }
        let manifest = manifestOverride ?? "{\"format\": 1, \"files\": [\(manifestFiles.joined(separator: ", "))]}"
        try write(manifest, to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}
