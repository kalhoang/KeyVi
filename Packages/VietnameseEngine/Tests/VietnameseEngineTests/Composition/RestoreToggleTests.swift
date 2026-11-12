// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Spec 13.10 rows that need only the active token (7.2): E01, E02, E02b, E03, E05, E06, E07, E08.
/// E04 needs the commit restore and history re-open of sections 8 and 10.
@Suite("Restore toggle (7.2, 13.10)")
struct RestoreToggleTests {
    static let activeTokenRows: Set<String> = ["E01", "E02", "E02b", "E03", "E05", "E06", "E07", "E08"]

    static let rows: [RestoreToggleExample] = {
        do {
            let all = try SpecExamples.restoreToggles(tsv: CorpusFiles.text(SpecExamples.restoreToggleFile))
            return all.filter { activeTokenRows.contains($0.id) }
        } catch {
            Issue.record("cannot load \(SpecExamples.restoreToggleFile): \(error)")
            return []
        }
    }()

    @Test func rowsArePresent() {
        #expect(Set(Self.rows.map(\.id)) == Self.activeTokenRows)
    }

    @Test(arguments: rows)
    func toggle(_ row: RestoreToggleExample) throws {
        var driver = EngineDriver(configuration: row.configuration)
        try driver.send(row.events)
        #expect(driver.state.activeDisplay == row.expectedActive, "\(row.id): \(row.eventsText)")
        let last = try #require(driver.outputs.last)
        switch row.lastAction {
        case .passThrough: #expect(last.action == .passThrough, "\(row.id)")
        case .edit:
            guard case .edit(_, let thenPassThrough) = last.action else {
                Issue.record("\(row.id): expected an edit, got \(last.action)")
                return
            }
            #expect(!thenPassThrough, "\(row.id): the toggle key is swallowed")
        }
    }

    @Test func restoredTokenIsLiteralForTheRestOfTheToken() throws {
        // ENG-R701: user-restored means literal for the rest of the token.
        var driver = EngineDriver(configuration: EngineConfiguration())
        try driver.type("vieejt")
        try driver.send(.restoreToggle)
        try driver.type("s")
        #expect(driver.state.activeDisplay == "vieejts")
        #expect(driver.state.isLiteral)
        #expect(driver.outputs.last?.action == .passThrough)
        // Not consecutive: composes again and marks the token user-kept.
        try driver.send(.restoreToggle)
        #expect(driver.state.activeDisplay == "viết")
        try driver.send(.restoreToggle)  // consecutive: passes through, nothing changes (ENG-R702)
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.state.activeDisplay == "viết")
    }

    @Test func toggleWithoutTokenPassesThrough() throws {
        var driver = EngineDriver(configuration: EngineConfiguration())
        try driver.send(.restoreToggle)
        #expect(driver.outputs.last?.action == .passThrough)
        try driver.type("ban ")
        try driver.send(.restoreToggle)
        #expect(driver.outputs.last?.action == .passThrough)
        #expect(driver.field.string == "ban ")
    }

    @Test func vniRestoreReproducesDigits() throws {
        // ENG-R705, REG-05.
        var driver = EngineDriver(configuration: EngineConfiguration(inputMethod: .vni))
        try driver.type("vie65t")
        try driver.send(.restoreToggle)
        #expect(driver.field.string == "vie65t")
        #expect(driver.state.activeRawKeys == "vie65t")
    }
}
