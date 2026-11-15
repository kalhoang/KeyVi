// SPDX-License-Identifier: MPL-2.0
//
// spec/01-engine.md 13.9.3 (rows C001 to C036) with the bundled data: each row is read from the spec, typed
// from an empty field and ended with Return; the field must equal the row's text, the rules L9a and L9b it
// names must have decided a token, and the revisions (RV1 to RV4, ENG-R828) must be exactly the ones it names.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("13.9.3 collision decisions with the bundled data")
struct CollisionWorkedExampleTests {
    struct Row: Sendable, CustomStringConvertible {
        let id: String
        let keys: String
        let text: String
        let decided: String
        var description: String { id }
    }

    /// The rows of 13.9.3, read from the spec in the repository.
    static let rows: [Row] = {
        let url = TestPaths.repoRoot.appendingPathComponent("spec/01-engine.md")
        guard let spec = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var inSection = false
        var rows: [Row] = []
        for line in spec.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("#") { inSection = line.hasPrefix("#### 13.9.3") }
            guard inSection, line.hasPrefix("| C") else { continue }
            let cells = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count == 4 else { continue }
            func unquote(_ cell: String) -> String { cell.trimmingCharacters(in: CharacterSet(charactersIn: "`")) }
            rows.append(Row(id: cells[0], keys: unquote(cells[1]), text: unquote(cells[2]), decided: cells[3]))
        }
        return rows
    }()

    static let revisionCodes: [(String, RevisionReason)] = [
        ("RV1", .phrase), ("RV2", .particleTail), ("RV3", .nextEnglish), ("RV4", .nextVietnamese),
        ("RV5", .lineVietnamese),
    ]

    @Test("The table has its 36 rows")
    func tableIsComplete() {
        #expect(Self.rows.map(\.id) == (1...36).map { String(format: "C%03d", $0) })
    }

    @Test("ENG-R825 to ENG-R828: every row of 13.9.3", arguments: rows)
    func row(_ row: Row) throws {
        var driver = EngineDriver(configuration: EngineConfiguration(), resources: try RealData.resources())
        try driver.type(row.keys + "\n")
        #expect(driver.field.string == row.text + "\n", "\(row.id): \(driver.field.string.debugDescription)")
        let decisions = driver.outputs.compactMap(\.decision)
        if row.decided.contains("L9a") { #expect(decisions.contains(.kept(.boundaryParticle)), "\(row.id)") }
        if row.decided.contains("L9b") { #expect(decisions.contains(.restored(.phrase)), "\(row.id)") }
        let expected = Set(Self.revisionCodes.filter { row.decided.contains($0.0) }.map(\.1))
        #expect(Set(driver.outputs.compactMap(\.revision)) == expected, "\(row.id)")
    }

    @Test("ENG-R829: with lookaheadRevision off no row is revised and L9a, L9b never decide")
    func rowsWithoutTheContextRules() throws {
        for row in Self.rows {
            var driver = EngineDriver(
                configuration: EngineConfiguration(lookaheadRevision: false), resources: try RealData.resources())
            try driver.type(row.keys + "\n")
            #expect(driver.outputs.allSatisfy { $0.revision == nil }, "\(row.id)")
            let decisions = driver.outputs.compactMap(\.decision)
            #expect(!decisions.contains(.kept(.boundaryParticle)) && !decisions.contains(.restored(.phrase)))
        }
    }
}
