// SPDX-License-Identifier: MPL-2.0
//
// Every broken resource file is rejected with a typed error naming the file (and line), never loaded
// silently (task: "Validate files and throw typed errors on malformed input").

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineData

private typealias LoadError = Resources.LoadError

private func load(_ directory: URL) throws -> Resources {
    try Resources.load(from: directory, userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
}

private func expectLoadError(
    _ expected: LoadError, replacing overrides: [String: String] = [:], removing removed: Set<String> = [],
    entryOverrides: [String: Int] = [:], manifest: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let directory = try ResourceFixture.make(
        replacing: overrides, removing: removed, entryOverrides: entryOverrides, manifestOverride: manifest)
    defer { TempDirectory.remove(directory) }
    #expect(throws: expected, sourceLocation: sourceLocation) { try load(directory) }
}

struct MalformedResourceTests {
    @Test func validFixtureLoads() throws {
        let directory = try ResourceFixture.make()
        defer { TempDirectory.remove(directory) }
        let resources = try load(directory)
        #expect(resources.english.contains("test"))
        #expect(resources.techCodeOnly.contains("tar"))
        #expect(resources.attestedSyllables.contains("hoà"))
        #expect(resources.ambiguity == ["as": .vietnamese, "is": .vietnamese, "test": .english])
    }

    @Test func emptyListsAreAllowed() throws {
        let directory = try ResourceFixture.make(replacing: ["tech-code-only.txt": "", "attested.txt": ""])
        defer { TempDirectory.remove(directory) }
        let resources = try load(directory)
        #expect(!resources.techCodeOnly.contains("tar"))
    }

    @Test func missingDirectoryOrFiles() throws {
        let nowhere = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        #expect(throws: LoadError.missingResource("manifest.json")) { try load(nowhere) }
        let directory = try ResourceFixture.make()
        defer { TempDirectory.remove(directory) }
        try FileManager.default.removeItem(at: directory.appendingPathComponent("english.txt"))
        #expect(throws: LoadError.missingResource("english.txt")) { try load(directory) }
        try expectLoadError(
            .malformedResource("manifest.json has no entry for english.txt"), removing: ["english.txt"])
    }

    @Test func manifestProblems() throws {
        try expectLoadError(
            .malformedResource("manifest.json: unsupported format 2"), manifest: "{\"format\": 2, \"files\": []}")
        try expectLoadError(
            .malformedResource("manifest.json has no entry for english.txt"), manifest: "{\"format\": 1, \"files\": []}")
        let directory = try ResourceFixture.make(manifestOverride: "not json")
        defer { TempDirectory.remove(directory) }
        #expect {
            try load(directory)
        } throws: { error in
            guard case LoadError.malformedResource(let detail) = error else { return false }
            return detail.hasPrefix("manifest.json:")
        }
    }

    @Test func integrityMismatches() throws {
        let directory = try ResourceFixture.make()
        defer { TempDirectory.remove(directory) }
        // Same length, different content: only the SHA-256 catches it.
        try Data("as\nis\ntest\nthat\n".utf8).write(to: directory.appendingPathComponent("english.txt"))
        #expect {
            try load(directory)
        } throws: { error in
            guard case LoadError.integrityMismatch(let resource, let detail) = error else { return false }
            return resource == "english.txt" && detail.hasPrefix("SHA-256")
        }
        try Data("as\n".utf8).write(to: directory.appendingPathComponent("english.txt"))
        #expect(throws: LoadError.integrityMismatch(resource: "english.txt", detail: "3 bytes, expected 16")) {
            try load(directory)
        }
        try expectLoadError(
            .integrityMismatch(resource: "english.txt", detail: "4 entries, expected 5"), entryOverrides: ["english.txt": 5])
    }

    @Test func englishEntryProblems() throws {
        try expectLoadError(
            .malformedEntry(resource: "english.txt", line: 2, reason: .invalidCharacter), replacing: ["english.txt": "as\nIs\n"])
        try expectLoadError(
            .malformedEntry(resource: "english.txt", line: 1, reason: .invalidCharacter), replacing: ["english.txt": "mp3\n"])
        try expectLoadError(
            .malformedEntry(resource: "english.txt", line: 2, reason: .emptyLine), replacing: ["english.txt": "as\n\nis\n"])
        try expectLoadError(
            .malformedEntry(resource: "english.txt", line: 2, reason: .missingFinalNewline), replacing: ["english.txt": "as\nis"])
        try expectLoadError(
            .malformedEntry(resource: "english.txt", line: 3, reason: .duplicate), replacing: ["english.txt": "as\nis\nas\n"])
        try expectLoadError(
            .malformedEntry(resource: "english.txt", line: 1, reason: .invalidCharacter), replacing: ["english.txt": "as \n"])
    }

    @Test func techEntryProblems() throws {
        try expectLoadError(
            .malformedEntry(resource: "tech-always.txt", line: 1, reason: .invalidCharacter), replacing: ["tech-always.txt": "123\n"])
        try expectLoadError(
            .malformedEntry(resource: "tech-code-only.txt", line: 1, reason: .invalidCharacter),
            replacing: ["tech-code-only.txt": "ssh-add\n"])
    }

    @Test func attestedEntryProblems() throws {
        // Decomposed (NFD) "hoà" is canonically equal to the NFC string but must be rejected (ENG-R102).
        try expectLoadError(
            .malformedEntry(resource: "attested.txt", line: 1, reason: .notNormalized),
            replacing: ["attested.txt": "hoa\u{0300}\n"])
        try expectLoadError(
            .malformedEntry(resource: "attested.txt", line: 1, reason: .invalidCharacter), replacing: ["attested.txt": "Hòa\n"])
        try expectLoadError(
            .malformedEntry(resource: "attested.txt", line: 1, reason: .invalidCharacter), replacing: ["attested.txt": "fax\n"])
        try expectLoadError(
            .malformedEntry(resource: "attested.txt", line: 2, reason: .emptyLine), replacing: ["attested.txt": "á\n\n"])
        try expectLoadError(
            .malformedEntry(resource: "attested.txt", line: 2, reason: .duplicate), replacing: ["attested.txt": "á\ná\n"])
        try expectLoadError(
            .malformedEntry(resource: "attested.txt", line: 1, reason: .missingFinalNewline), replacing: ["attested.txt": "á"])
        let directory = try ResourceFixture.make()
        defer { TempDirectory.remove(directory) }
        try Data([0x61, 0xFF, 0x0A]).write(to: directory.appendingPathComponent("attested.txt"))
        let manifest = try String(contentsOf: directory.appendingPathComponent("manifest.json"), encoding: .utf8)
        let fixed = manifest.replacingOccurrences(
            of: "\"name\": \"attested.txt\", \"bytes\": \(Data(ResourceFixture.valid["attested.txt"]!.utf8).count), \"entries\": 4, \"sha256\": \"\(sha256Hex(Data(ResourceFixture.valid["attested.txt"]!.utf8)))\"",
            with: "\"name\": \"attested.txt\", \"bytes\": 3, \"entries\": 1, \"sha256\": \"\(sha256Hex(Data([0x61, 0xFF, 0x0A])))\"")
        try Data(fixed.utf8).write(to: directory.appendingPathComponent("manifest.json"))
        #expect(throws: LoadError.malformedResource("attested.txt: not UTF-8")) { try load(directory) }
    }

    @Test func ambiguityProblems() throws {
        let header = "raw\tdecision\tstatus\tdisplay\tnote\n"
        try expectLoadError(
            .malformedEntry(resource: "ambiguity.tsv", line: 1, reason: .invalidHeader),
            replacing: ["ambiguity.tsv": "raw\tdecision\n"], entryOverrides: ["ambiguity.tsv": -1])
        try expectLoadError(
            .malformedEntry(resource: "ambiguity.tsv", line: 2, reason: .wrongFieldCount),
            replacing: ["ambiguity.tsv": header + "as\tvi\tproposed\tá\n"])
        try expectLoadError(
            .malformedEntry(resource: "ambiguity.tsv", line: 2, reason: .invalidDecision),
            replacing: ["ambiguity.tsv": header + "as\tVI\tproposed\tá\tx\n"])
        try expectLoadError(
            .malformedEntry(resource: "ambiguity.tsv", line: 2, reason: .invalidStatus),
            replacing: ["ambiguity.tsv": header + "as\tvi\tdone\tá\tx\n"])
        try expectLoadError(
            .malformedEntry(resource: "ambiguity.tsv", line: 2, reason: .invalidCharacter),
            replacing: ["ambiguity.tsv": header + "As\tvi\tproposed\tá\tx\n"])
        try expectLoadError(
            .malformedEntry(resource: "ambiguity.tsv", line: 3, reason: .duplicate),
            replacing: ["ambiguity.tsv": header + "as\tvi\tproposed\tá\tx\nas\ten\treviewed\tá\tx\n"])
    }

    @Test func errorsDescribeTheProblem() {
        let error = LoadError.malformedEntry(resource: "english.txt", line: 7, reason: .duplicate)
        #expect(error.description == "english.txt line 7: duplicate")
        #expect(LoadError.missingResource("x").description == "missing resource x")
        #expect(LoadError.malformedResource("y").description == "malformed resource: y")
        #expect(LoadError.integrityMismatch(resource: "a", detail: "b").description == "a does not match manifest.json: b")
    }
}
