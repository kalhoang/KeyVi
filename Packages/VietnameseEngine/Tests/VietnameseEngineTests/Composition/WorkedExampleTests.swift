// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Spec 13.8: every worked composition example W001-W253, display before any boundary. Rows whose note
/// mentions a boundary restore (W147, W148, W211-W222 ...) only check the display before the boundary;
/// the restore itself is section 8. Every event also goes through the simulated text field, so the
/// edits must rebuild exactly the display in an empty field (ENG-T31, ENG-R611, ENG-R631).
@Suite("Worked examples W001-W253 (13.8)")
struct WorkedExampleTests {
    static let rows: [WorkedExample] = {
        do {
            return try SpecExamples.workedExamples(tsv: CorpusFiles.text(SpecExamples.workedExamplesFile))
        } catch {
            Issue.record("cannot load \(SpecExamples.workedExamplesFile): \(error)")
            return []
        }
    }()

    @Test func allRowsArePresent() {
        #expect(Self.rows.count == 253)
    }

    @Test(arguments: rows)
    func displayBeforeBoundary(_ row: WorkedExample) throws {
        var driver = EngineDriver(configuration: row.configuration)
        try driver.send(row.events)
        #expect(driver.state.activeDisplay == row.expected, "\(row.id) \(row.keys) (\(row.note))")
        #expect(driver.field.string == row.expected, "\(row.id): text field")
        #expect(driver.state.activeRawKeys == row.keys.filter { $0 != "⌫" } || row.keys.contains("⌫"), "\(row.id)")
    }
}
