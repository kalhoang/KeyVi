// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

/// TRACEABILITY.md maps every identifier of spec/01-engine.md (the same check as
/// Scripts/check-traceability.py). Skipped when the package is built outside the repository.
@Suite("Traceability")
struct TraceabilityTests {
    static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static func identifiers(in text: String, rowsOnly: Bool) throws -> Set<String> {
        let pattern = rowsOnly ? #"(?m)^\| (ENG-R\d+|ENG-T\d+|REG-\d+) \|"# : #"\b(ENG-R\d+|ENG-T\d+|REG-\d+)\b"#
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(text.startIndex..., in: text)
        return Set(
            expression.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            })
    }

    @Test func everySpecIdentifierHasARow() throws {
        let specURL = Self.package.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("spec/01-engine.md")
        guard FileManager.default.fileExists(atPath: specURL.path) else { return }
        let spec = try Self.identifiers(in: String(contentsOf: specURL, encoding: .utf8), rowsOnly: false)
        let table = try Self.identifiers(
            in: String(contentsOf: Self.package.appendingPathComponent("TRACEABILITY.md"), encoding: .utf8),
            rowsOnly: true)
        #expect(spec.count >= 200)
        print("[TRACEABILITY] \(spec.count) identifiers in the spec, \(table.count) rows")
        #expect(spec.subtracting(table).isEmpty, "missing rows: \(spec.subtracting(table).sorted())")
        #expect(table.subtracting(spec).isEmpty, "unknown rows: \(table.subtracting(spec).sorted())")
    }
}
