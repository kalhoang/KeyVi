// SPDX-License-Identifier: MPL-2.0
//
// Helpers shared by the data tests: repository paths, the lexicon-builder executable (driven as a
// subprocess because the test target cannot import an executable target without a manifest change),
// temporary directories and hand-made resource directories.

import CryptoKit
import Foundation
import Testing
import VietnameseEngine

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
        // The test bundle's directory holds the products of the same build. `Bundle.allBundles` does not
        // list the bundle when swiftpm-testing-helper loads it, so the bundle is found through a class.
        let testBundle = Bundle(for: BundleToken.self).bundleURL
        candidates.append(testBundle.deletingLastPathComponent().appendingPathComponent("lexicon-builder"))
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

/// Any class of the test target: `Bundle(for:)` resolves the test bundle from it.
private final class BundleToken {}

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

enum BuilderProcess {
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
    CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

/// Writes a resource directory in the bundled format: the given files plus a manifest.json that
/// matches them (unless `manifestOverride` is given), so tests can target one validation at a time.
enum ResourceFixture {
    static let ambiguityHeader = "raw\tdecision\tstatus\tdisplay\trun\tviKind\tnote\n"

    static let valid: [String: String] = [
        "english.txt": "as\nis\ntest\nthis\n",
        "tech-always.txt": "usb\nwifi\nwww\n",
        "tech-code-only.txt": "tar\n",
        "tech-code-capitalized.txt": "tar\n",
        "attested.txt": "hòa\nhoà\ná\nđi\n",
        "ambiguity.tsv":
            ambiguityHeader
            + "as\tvi\tproposed\tá\ten\tparticle\tx\nis\ten\tunreviewed\tí\ten\tcontent\tx\n"
            + "test\ten\tproposed\ttét\tvi\tfunction\tx\n",
        "NOTICES.txt": "notices\n",
        // The collision lists (format 2).
        "phrases.txt": "as well\nsuch as\n",
        "collision-supplement.txt": "cos\ngif\n",
        "boundary-particles.txt": "as\n",
        "english-function-words.txt": "as\nis\nthe\n",
        "english-lean-neutral.txt": "the\n",
        "vi-tail-words.txt": "nha\nrồi\n",
        "vi-tail-particles.txt": "nha\n",
        "english-pre-guard.txt": "the\n",
        // The typo correction data (format 3; spec/01-engine.md 11A, ENG-R1120). The guard list is binary:
        // `validBinary`.
        "keyboard-neighbours.txt": GuardListFixture.neighboursText,
        "unmarked-shapes.txt": "thach\ntruong\n",
        "vietnamese-keyings.txt": "phair\nphis\n",
    ]

    /// The binary files of a valid resource directory and their manifest entry counts.
    static let validBinary: [String: (data: Data, entries: Int)] = [
        "guard-list.bloom": (GuardListFixture.encode(GuardListFixture.filter), GuardListFixture.filter.wordCount)
    ]

    static func make(
        replacing overrides: [String: String] = [:], removing removed: Set<String> = [],
        entryOverrides: [String: Int] = [:], manifestOverride: String? = nil,
        replacingBinary binaryOverrides: [String: Data] = [:]
    ) throws -> URL {
        let directory = try TempDirectory.make("resources")
        var files: [String: (data: Data, entries: Int?)] = [:]
        for (name, text) in valid.merging(overrides, uniquingKeysWith: { _, new in new }) {
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true).count
            files[name] = (Data(text.utf8), name == "NOTICES.txt" ? nil : (name == "ambiguity.tsv" ? lines - 1 : lines))
        }
        for (name, file) in validBinary { files[name] = (binaryOverrides[name] ?? file.data, file.entries) }
        for name in removed { files[name] = nil }
        var manifestFiles: [String] = []
        for (name, file) in files.sorted(by: { $0.key < $1.key }) {
            try file.data.write(to: directory.appendingPathComponent(name))
            let entryField = (entryOverrides[name] ?? file.entries).map { ", \"entries\": \($0)" } ?? ""
            manifestFiles.append(
                "{\"name\": \"\(name)\", \"bytes\": \(file.data.count)\(entryField), \"sha256\": \"\(sha256Hex(file.data))\"}"
            )
        }
        let manifest = manifestOverride ?? "{\"format\": 3, \"files\": [\(manifestFiles.joined(separator: ", "))]}"
        try write(manifest, to: directory.appendingPathComponent("manifest.json"))
        return directory
    }
}

/// The guard list file of resource format 3, written here from its documented layout (data/README.md) rather than
/// by lexicon-builder, so that the loader is tested against the format: a 32-byte header (`KVGL`, `UInt32` version
/// 1, `UInt32` hashCount, `UInt64` bitCount, `UInt64` wordCount, 4 zero bytes), then the bits as little-endian
/// `UInt64`.
enum GuardListFixture {
    static let filter = ApproximateWordSet(exactly: ["biden", "kbang"], bitCount: 256, hashCount: 8)

    static func encode(
        _ filter: ApproximateWordSet, magic: String = "KVGL", version: UInt32 = 1, bitCount: UInt64? = nil
    ) -> Data {
        var data = Data(magic.utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        append(version)
        append(UInt32(filter.hashCount))
        append(bitCount ?? UInt64(filter.bits.count * 64))
        append(UInt64(filter.wordCount))
        append(UInt32(0))
        for word in filter.bits { append(word) }
        return data
    }

    /// The QWERTY table of ENG-R1113 as resource lines.
    static let neighboursText = """
        a\tqwsz
        b\tghvn
        c\tdfxv
        d\tersfxc
        e\twrsd
        f\trtdgcv
        g\ttyfhvb
        h\tyugjbn
        i\tuojk
        j\tuihknm
        k\tiojlm
        l\topk
        m\tjkn
        n\thjbm
        o\tipkl
        p\tol
        q\twa
        r\tetdf
        s\tweadzx
        t\tryfg
        u\tyihj
        v\tfgcb
        w\tqeas
        x\tsdzc
        y\ttugh
        z\tasx

        """
}
