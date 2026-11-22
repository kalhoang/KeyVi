// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Properties of commits, history and macros over random event streams (spec 13.6, the subset this track
/// owns; the full fuzz campaign is ENG-T30 and later work): the simulated field always ends with the
/// engine's view and the engine never deletes more than it produced (ENG-T31), restore is exact (ENG-T32),
/// replay is deterministic (ENG-T33), inserts are NFC with equal counts (ENG-T34), with the 13.9 resources
/// and a table of 1,000 random triggers, punctuation-only ones included.
@Suite("Commit, history and macro properties (13.6)")
struct CommitPropertyTests {
    static let configurations: [EngineConfiguration] = [
        EngineConfiguration(typoCorrection: false), EngineConfiguration(inputMethod: .vni, typoCorrection: false),
        EngineConfiguration(historyLimit: 2, typoCorrection: false),
        EngineConfiguration(autoRestore: false, appContext: .code, typoCorrection: false),
    ]
    static let seeds: [UInt64] = Array(1...6)

    /// 1,000 random triggers over a small alphabet so that random streams hit them often. A candidate is
    /// accepted only if no accepted trigger shadows it (ENG-R1103); candidates are taken shortest first,
    /// so an accepted trigger can never shadow a later one's acceptance.
    static let macroTable: MacroTable = {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let alphabet = Array("abdnovw.@,;1-!")
        var candidates = Set<String>()
        while candidates.count < 8_000 {
            let length = Int.random(in: 1...5, using: &generator)
            candidates.insert(String((0..<length).map { _ in alphabet.randomElement(using: &generator) ?? "a" }))
        }
        var accepted = Set<String>()
        var entries: [MacroTable.Entry] = []
        for trigger in candidates.sorted(by: { ($0.count, $0) < ($1.count, $1) }) where entries.count < 1_000 {
            let characters = Array(trigger)
            // ENG-R1103: punctuation or a digit after a shorter trigger shadows the longer one.
            let shadowed = (1..<characters.count).contains { length in
                !characters[length].isLetter && accepted.contains(String(characters[..<length]))
            }
            guard !shadowed else { continue }
            accepted.insert(trigger)
            let index = entries.count
            entries.append(.init(trigger: trigger, expansion: index % 3 == 0 ? "Việt \(index)" : "x\(index)\ny"))
        }
        do {
            return try MacroTable(entries)
        } catch {
            Issue.record("random macro table: \(error)")
            return .empty
        }
    }()

    static let resources = SpecFixtures.commitResources(macros: macroTable)

    @Test(arguments: configurations, seeds)
    func randomStreams(configuration: EngineConfiguration, seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed &* 0x9E37_79B9)
        let engine = Engine(configuration: configuration, resources: Self.resources)
        var decisions: [CommitDecision: Int] = [:]
        for _ in 0..<150 {
            var driver = EngineDriver(engine: engine)
            for event in RandomEvents.events(count: 80, using: &generator) {
                let output = try driver.send(event)
                if let decision = output.decision { decisions[decision, default: 0] += 1 }
                if case .edit(let edit, _) = output.action {
                    #expect(edit.insert.precomposedStringWithCanonicalMapping == edit.insert)
                }
                try checkRestoreIsExact(driver)
            }
        }
        // The streams exercise expansions and both outcomes of the rules.
        #expect(decisions[.macro, default: 0] > 0)
        #expect(decisions.keys.contains { $0.restores } || !configuration.autoRestore)
        #expect(decisions.keys.contains { if case .kept = $0 { return true } else { return false } })
    }

    /// ENG-T32: for an ordinary token whose display differs from its raw keys, the toggle produces exactly
    /// the raw keys. A re-opened token that shows `R′` after rule L4 (ENG-R804, REG-40) shows its raw keys: its toggle
    /// composes it (ENG-R701 second branch).
    private func checkRestoreIsExact(_ driver: EngineDriver) throws {
        guard let token = driver.state.active, !token.isMacro, token.display != token.rawText,
            token.display != token.shownRawText, !driver.state.previousEventWasRestoreToggle
        else { return }
        var copy = driver
        try copy.send(.restoreToggle)
        #expect(copy.state.activeDisplay == token.rawText)
        #expect(copy.field.string.hasSuffix(token.rawText))
    }

    @Test(arguments: seeds)
    func deterministicReplay(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let events = RandomEvents.events(count: 3_000, using: &generator)
        let engine = Engine(configuration: EngineConfiguration(typoCorrection: false), resources: Self.resources)
        var session = Session(engine: engine)
        var state = EngineState.initial
        for event in events {
            let output = session.handle(event)
            let (next, pureOutput) = engine.reduce(state, event)
            #expect(pureOutput == output)
            state = next
        }
        #expect(state == session.state)
    }

    @Test func macroTableIsLarge() {
        #expect(Self.macroTable.entries.count == 1_000)
    }
}
