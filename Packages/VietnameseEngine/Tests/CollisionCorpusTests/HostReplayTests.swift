// SPDX-License-Identifier: MPL-2.0
//
// The host-mode replay of the QA-R68 gate drives the engine as the host does (PLT-R340, PLT-R353): Return and Tab
// commit and then reset, Escape is the restore toggle and a hard boundary when it passes through, and the scripted
// user's corrections give the engine's own strong signals (ENG-R701, ENG-R704, ENG-R829, ENG-R864).

import Testing
import VietnameseEngine

@Suite("QA-R68 harness: the host-mode replay")
struct HostReplayTests {
    static func replay(
        _ keys: String, corrections: Set<Correction> = [], lookaheadRevision: Bool = true
    ) throws -> ReplayResult {
        let engine = try GateResources.engine(lookaheadRevision: lookaheadRevision)
        return try HostReplay(engine: engine).run(try HostInput.parse(keys), corrections: corrections)
    }

    @Test("Key notation: characters, {RET}, {TAB}, {ESC}, {BS}; an unknown name is an error")
    func notation() throws {
        #expect(
            try HostInput.parse("ab{RET}c{TAB}{ESC}{BS}")
                == [.character("a"), .character("b"), .returnKey, .character("c"), .tab, .escape, .backspace])
        #expect(try HostInput.parse("{") == [.character("{")])
        #expect(throws: FixtureFormatError.self) { try HostInput.parse("a{F1}") }
    }

    @Test("PLT-R340: Return and Tab commit, then the host resets, so Backspace re-opens nothing")
    func lineKeysReset() throws {
        let afterReturn = try Self.replay("test{RET}{BS}s ")
        #expect(afterReturn.field == "tests ")
        #expect(afterReturn.tokens.map(\.raw) == ["test", "s"])
        #expect(afterReturn.tokens.allSatisfy { !$0.corrected })
        let afterTab = try Self.replay("vieejt{TAB}nam ")
        #expect(afterTab.field == "việt\tnam ")
        #expect(afterTab.notation == "việt{TAB}nam ")
        #expect(afterTab.tokens.map(\.boundary) == ["\t", " "])
    }

    @Test("PLT-R353: Escape consumed as restore keeps the token; passed through, it is a hard boundary")
    func escape() throws {
        let restored = try Self.replay("dduwowcj{ESC} ")
        #expect(restored.field == "dduwowcj ")
        #expect(restored.tokens.first?.decision == .restored(.userChoice))
        let passed = try Self.replay("abc {ESC}{BS}d ")
        #expect(passed.field == "abcd ")
        #expect(passed.tokens.map(\.raw) == ["abc", "d"])
        #expect(passed.tokens.allSatisfy { !$0.corrected })
    }

    @Test("Without corrections the replay of a corpus line gives its frozen output and only weak signals")
    func frozenLine() throws {
        let result = try Self.replay("Cais nayf nos tricky as hell{RET}")
        #expect(result.notation == "Cái này nó tricky as hell{RET}")
        #expect(result.tokens[4].revision == .phrase)
        #expect(result.words == ["Cái", "này", "nó", "tricky", "as", "hell"])
        #expect(result.signals.allSatisfy { $0.strength == .weak })
    }

    @Test("ENG-R704, ENG-R864: Backspace, Escape and the boundary again right after the commit give a strong signal")
    func correctionAfterCommit() throws {
        let keys = "Dduwngf trust duwx lieeuj tuwf client{RET}"
        #expect(try Self.replay(keys).words[1] == "trút")
        let corrected = try Self.replay(keys, corrections: [.afterCommit(1)])
        #expect(corrected.words[1] == "trust")
        #expect(corrected.tokens[1].decision == .restored(.userChoice) && corrected.tokens[1].corrected)
        #expect(corrected.tokens.count == 6)
        #expect(
            corrected.signals.contains(
                CollisionSignal(word: "trust", context: .afterVietnamese, side: .english, strength: .strong)))
    }

    @Test("ENG-R701, ENG-R864: Escape on the active word before Return gives its raw keys and a strong signal")
    func correctionBeforeReturn() throws {
        let keys = "Choox nayf neen return sowms, khoir loongf if{RET}"
        #expect(try Self.replay(keys).words[7] == "ì")
        let corrected = try Self.replay(keys, corrections: [.beforeBoundary(7)])
        #expect(corrected.words[7] == "if")
        #expect(corrected.tokens[7].decision == .restored(.userChoice))
        #expect(corrected.signals.contains { $0.word == "if" && $0.side == .english && $0.strength == .strong })
    }

    @Test("ENG-R829, ENG-R864: Escape right after the revising commit undoes the revision with a strong signal")
    func undoRevision() throws {
        let keys = "Anh guwir giups em file ddos as soon as possible nhes{RET}"
        let plain = try Self.replay(keys)
        #expect(plain.words[6] == "as" && plain.tokens[6].revision == .phrase)
        let undone = try Self.replay(keys, corrections: [.undoRevision(6)])
        #expect(undone.words[6] == "á")
        #expect(undone.tokens[6].revision == nil && undone.tokens[6].corrected)
        #expect(undone.signals.contains { $0.word == "as" && $0.side == .vietnamese && $0.strength == .strong })
    }
}
