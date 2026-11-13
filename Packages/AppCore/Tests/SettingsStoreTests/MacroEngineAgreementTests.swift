// SPDX-License-Identifier: GPL-3.0-or-later
//
// The engine is the contract (ENG-R1101, ENG-R1103, PRD-R29): every macro table the editor's `MacroValidator`
// accepts, typed by hand or imported, must build a `MacroTable` without throwing. Property-style: seeded random
// tables over an alphabet chosen to hit the edge cases (case, digits, punctuation boundaries, length limits,
// emoji and combining marks in expansions). The only allowed difference is the editor's stricter rule against
// empty expansions.

import AppModel
import Foundation
import Testing
import VietnameseEngine

@testable import SettingsStore

/// Trigger characters: letters in both cases, a digit (a tone key in VNI, not a boundary), punctuation of
/// several kinds (all boundaries for the engine), plus characters both sides reject.
private let triggerAlphabet: [Character] = ["a", "b", "A", "v", "n", "1", ".", ";", "@", "-", "[", "~", "!"]
private let rejectedCharacters: [Character] = [" ", "đ", "\t", "é"]
private let expansions = [
    "Việt Nam", "x", "dòng 1\ndòng 2", "thân 👋🏽", "e\u{301}", String(repeating: "ệ", count: 4_000),
    String(repeating: "a", count: 4_001), "",
]

private struct Candidate {
    var trigger: String
    var expansion: String
}

private func randomTrigger(using generator: inout SeededGenerator) -> String {
    switch UInt64.random(in: 0..<20, using: &generator) {
    case 0: return String(repeating: "a", count: 32)
    case 1: return String(repeating: "b", count: 33)
    case 2: return ""
    case 3: return "v" + String(rejectedCharacters.randomElement(using: &generator)!)
    default:
        let length = Int.random(in: 1...4, using: &generator)
        return String((0..<length).map { _ in triggerAlphabet.randomElement(using: &generator)! })
    }
}

private func randomCandidates(seed: UInt64, count: Int) -> [Candidate] {
    var generator = SeededGenerator(seed: seed)
    return (0..<count).map { _ in
        Candidate(
            trigger: randomTrigger(using: &generator),
            expansion: expansions.randomElement(using: &generator)!)
    }
}

/// What the editor ends up with when the user types the candidates one by one: each is kept only when the
/// validator accepts it against the macros already kept (disabled ones count too).
private func editorTable(_ candidates: [Candidate]) -> [StoredMacro] {
    var accepted: [StoredMacro] = []
    for candidate in candidates
    where MacroValidator.issue(shortcut: candidate.trigger, expansion: candidate.expansion, others: accepted) == nil {
        accepted.append(StoredMacro(trigger: candidate.trigger, expansion: candidate.expansion))
    }
    return accepted
}

private func engineTable(_ macros: [StoredMacro]) throws -> MacroTable {
    try MacroTable(
        macros.map { MacroTable.Entry(trigger: $0.trigger, expansion: $0.expansion, adaptCase: $0.adaptCase) })
}

@Suite struct MacroEngineAgreementTests {
    /// Hand-typed tables: whatever the validator lets through, the engine builds.
    @Test func everyValidatorAcceptedTableBuildsAnEngineTableENGR1103() throws {
        var sizes: [Int] = []
        for seed: UInt64 in 1...400 {
            let table = editorTable(randomCandidates(seed: seed, count: 40))
            sizes.append(table.count)
            #expect(throws: Never.self, "seed \(seed)") { _ = try engineTable(table) }
        }
        #expect((sizes.max() ?? 0) >= 8)  // the tables are not trivially small
    }

    /// Imported tables (PRD-R32): the preview against the user's macros, merged with either duplicate choice.
    @Test func everyImportedAndMergedTableBuildsAnEngineTable() throws {
        for seed: UInt64 in 1...200 {
            let existing = editorTable(randomCandidates(seed: seed &* 7_919, count: 15))
            let rows = randomCandidates(seed: seed, count: 30).enumerated().map { index, candidate in
                MacroImportRow(line: index + 1, shortcut: candidate.trigger, expansion: candidate.expansion)
            }
            let preview = MacroImporter.preview(rows, existing: existing)
            for resolution in [MacroDuplicateResolution.keepMine, .useImported] {
                let merged = MacroImporter.merge(preview, into: existing, resolution: resolution)
                #expect(throws: Never.self, "seed \(seed) \(resolution)") { _ = try engineTable(merged) }
            }
        }
    }

    /// Pairwise agreement in both directions: the validator accepts a pair exactly when the engine does, except
    /// that the editor also rejects an empty expansion (documented on `MacroValidator`).
    @Test func validatorAndEngineAgreeOnEveryPair() {
        var generator = SeededGenerator(seed: 2_026)
        var engineOnly = 0
        for _ in 0..<4_000 {
            let first = Candidate(trigger: randomTrigger(using: &generator), expansion: "x")
            let second = Candidate(
                trigger: randomTrigger(using: &generator), expansion: expansions.randomElement(using: &generator)!)
            let mine = StoredMacro(trigger: first.trigger, expansion: first.expansion)
            let validator =
                MacroValidator.issue(shortcut: first.trigger, expansion: first.expansion, others: []) == nil
                && MacroValidator.issue(shortcut: second.trigger, expansion: second.expansion, others: [mine]) == nil
            let engine = (try? engineTable([mine, StoredMacro(trigger: second.trigger, expansion: second.expansion)]))
            if validator { #expect(engine != nil, "\(first.trigger) / \(second.trigger)") }
            if engine != nil, !validator {
                engineOnly += 1
                #expect(second.expansion.isEmpty, "\(first.trigger) / \(second.trigger)")
            }
        }
        #expect(engineOnly > 0)  // the empty-expansion case was exercised
    }

    /// The documented shadowing cases, checked on both sides (ENG-R1103, 01-engine.md 9.2).
    @Test(arguments: [
        ("vn", "vn.", false), ("vn", "vn.x", false), ("vn", "VN!?", false), ("@@", "@@x", true), ("vn", "vn1", true),
        ("vn.", "vn.x", true), ("vn", "vnx", true), ("vn", "Vn", false), ("a", "a;b", false), ("1", "1.", false),
    ])
    func documentedPairs(shorter: String, longer: String, accepted: Bool) {
        let mine = StoredMacro(trigger: shorter, expansion: "x")
        let validator = MacroValidator.issue(shortcut: longer, expansion: "y", others: [mine]) == nil
        let engine = (try? engineTable([mine, StoredMacro(trigger: longer, expansion: "y")])) != nil
        #expect(validator == accepted)
        #expect(engine == accepted)
    }
}
