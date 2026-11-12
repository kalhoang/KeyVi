// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Properties of composition over random event streams (spec 13.6, the composition subset; E4 owns the
/// full fuzz campaign): replay equivalence (ENG-R601, ENG-T33), the simulated field (ENG-T31), encoding
/// (ENG-T34), method isolation (ENG-T35) and viability while composing (ENG-T37).
@Suite("Composition properties (ENG-R601, 13.6)")
struct CompositionPropertyTests {
    static let configurations: [EngineConfiguration] = [
        EngineConfiguration(),
        EngineConfiguration(toneStyle: .modern),
        EngineConfiguration(inputMethod: .vni),
        EngineConfiguration(inputMethod: .telex(TelexOptions(standaloneW: false, bracketKeys: true))),
    ]
    static let seeds: [UInt64] = Array(1...8)

    @Test(arguments: configurations, seeds)
    func randomStreams(configuration: EngineConfiguration, seed: UInt64) throws {
        var generator = SeededGenerator(seed: seed &* 0x5851_F42D_4C95_7F2D)
        let engine = Engine(configuration: configuration, resources: .empty)
        let rules = ComposerRules(configuration)
        for _ in 0..<300 {
            var driver = EngineDriver(engine: engine)
            for event in RandomEvents.events(count: 60, using: &generator) {
                let output = try driver.send(event)
                check(output, driver.state, rules: rules)
            }
        }
    }

    /// Replay from `.initial` gives identical outputs (ENG-T33, ENG-R1210).
    @Test(arguments: seeds)
    func determinism(seed: UInt64) {
        var generator = SeededGenerator(seed: seed)
        let events = RandomEvents.events(count: 2_000, using: &generator)
        let engine = Engine(configuration: EngineConfiguration(), resources: .empty)
        var first = Session(engine: engine)
        var second = Session(engine: engine)
        var state = EngineState.initial
        for event in events {
            let output = first.handle(event)
            #expect(second.handle(event) == output)
            let (next, pureOutput) = engine.reduce(state, event)
            #expect(pureOutput == output)
            state = next
        }
        #expect(first.state == second.state && state == first.state)
    }

    private func check(_ output: EngineOutput, _ state: EngineState, rules: ComposerRules) {
        if case .edit(let edit, _) = output.action {
            // ENG-T34: NFC, no combining marks, counts agree.
            #expect(edit.insert.precomposedStringWithCanonicalMapping == edit.insert)
            #expect(!edit.insert.unicodeScalars.contains { $0.properties.canonicalCombiningClass.rawValue != 0 })
            #expect(edit.deleteCount == edit.deleteUTF16Count)
        }
        guard let token = state.active else { return }
        // ENG-R601, ENG-T33: the cached state equals a replay of the raw keys.
        let replayed = Composition(replaying: token.composition.raw, rules: rules)
        #expect(replayed == token.composition, "replay differs for \(token.rawText)")
        let expectedDisplay = token.showsRawKeys ? token.rawText : replayed.display(style: rules.toneStyle)
        #expect(token.display == expectedDisplay, "display of \(token.rawText)")
        // ENG-T37: no display in composing mode is non-viable.
        if !token.composition.isLiteral {
            let letters = token.composition.letters.map(\.letter)
            #expect(ViabilityAutomaton.shared.isViable(letters), "non-viable composing letters for \(token.rawText)")
        }
        // ENG-T35: in VNI every letter shown comes from a letter typed in the token.
        if !rules.isTelex {
            let typed = Set(token.composition.raw.map(ASCII.lowercased))
            for scalar in token.display.unicodeScalars {
                guard let glyph = LetterTable.glyph(for: scalar) else { continue }
                #expect(typed.contains(glyph.letter.baseASCII), "VNI shows \(scalar) that was not typed")
            }
        }
    }
}
