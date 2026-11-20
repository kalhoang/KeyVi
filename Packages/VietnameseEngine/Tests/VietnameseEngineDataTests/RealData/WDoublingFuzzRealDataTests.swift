// SPDX-License-Identifier: MPL-2.0
//
// REG-40 (ENG-R804, ENG-R1005, ENG-R701): a seeded fuzz that starts from a committed token whose text left out a `w`
// doubling (`R′`) and edits it with the keys that reach its states: Backspace into and past the doubling, `w` typed
// again, a re-commit, the toggle. The random campaign of 13.6 does not reach these states (the review of 20/11/2026
// found none of them in 60,000 random sequences), so they are drawn here on purpose.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("REG-40: fuzz from a token committed without its w doubling (ENG-R701, ENG-R1005)")
struct WDoublingFuzzRealDataTests {
    /// Words committed as `R′` by rule L4 or L3b, by the typo correction, or taken back from it by the toggle; some
    /// re-opened and deleted down to the character before the doubling the token does not show.
    static let starts = [
        "answwer ", "wwebview ", "softwware ", "WwordPress ", "wwindwos ", "wwindwos ⎋", "wwindwos ⎋⌫ ", "dwWidth ",
        "answwer ⌫⌫⌫", "softwware ⌫⌫⌫⌫", "answwer ⌫⌫ ⌫⌫",
    ]

    /// The keys of the edits: Backspace, the doubled letter in both cases, letters that compose with it, boundaries.
    static let keys: [EngineEvent] =
        [.backspace, .backspace, .backspace, .restoreToggle]
        + "wwWaesr .".map { .key(KeyInput($0)) }

    static let sequencesPerStart = 250
    static let maxEdits = 14

    @Test(
        "Random edits keep every invariant of 13.6 and never crash",
        arguments: Array(EscapeCommitRealDataTests.configurationsWithCorrection.indices))
    func randomEditsKeepTheInvariants(_ index: Int) throws {
        let configuration = EscapeCommitRealDataTests.configurationsWithCorrection[index]
        let resources = try RealData.resources()
        var generator = SeededGenerator(seed: 0x4E6_4040 &+ UInt64(index))
        var sequences = 0
        for start in Self.starts {
            let prefix = KeyNotation.events(start)
            for _ in 0..<Self.sequencesPerStart {
                let count = Int.random(in: 1...Self.maxEdits, using: &generator)
                let edits = (0..<count).map { _ in Self.keys.randomElement(using: &generator) ?? .backspace }
                var checker = InvariantChecker(engine: Engine(configuration: configuration, resources: resources))
                do {
                    try checker.send(prefix + edits)
                    try checker.finish()
                } catch let violation as FuzzViolation {
                    Issue.record("\(configuration) \(start.debugDescription): \(violation)")
                    return
                }
                sequences += 1
            }
        }
        #expect(sequences == Self.starts.count * Self.sequencesPerStart)
    }
}
