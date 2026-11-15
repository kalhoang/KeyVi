// SPDX-License-Identifier: GPL-3.0-or-later
//
// The ENG-R1005 regression guard of the scanner (PLT-R904A, ADR 0007 decision 12): `reopenedLiteral` fires when a
// token a rule restored at its commit is re-opened by Backspace, at least one more Backspace goes into it, and keys
// typed into it then pass through as typed although its remaining raw keys no longer transform anything and a fresh
// token with them and the typed keys would have composed. The engine lines of the broken cases are written by hand,
// as the engine before the ENG-R1005 fix recorded them (`tiesng`, space, five Backspaces, `eesn` showed `tieesn`).
// Details carry counts and the commit decision only, never a typed character.

import Foundation
import Testing
import VietnameseEngine

@testable import TraceScanCore

private func scan(_ trace: TraceBuilder, replay: Bool = true) -> [Finding] {
    FindingDetector.scan(trace.events, replay: replay ? ReplayEngineFactory(resources: TraceBuilder.resources) : nil)
        .findings
}

private func reopenedLiterals(_ trace: TraceBuilder, replay: Bool = true) -> [Finding] {
    scan(trace, replay: replay).filter { $0.kind == .reopenedLiteral }
}

/// ANSI key codes of the letters these fixtures type.
private let codes: [Character: UInt16] = [
    "e": 0x0E, "s": 0x01, "n": 0x2D, "g": 0x05, "t": 0x11, "i": 0x22, "a": 0x00, "m": 0x2E, " ": 0x31,
]

extension TraceBuilder {
    /// `word`, space: the commit restored the keys as typed by `decision` (written by hand).
    fileprivate mutating func restoredCommit(_ word: String, decision: String = "restored(invalid)") {
        boundary("focusChanged", job: "focusChanged")
        line("key", ["ev": "keyDown", "kc": 0x31, "fl": 0, "ch": " ", "out": "held"])
        line(
            "engine",
            ["act": "editThenPassThrough", "del": word.count - 1, "ins": word, "comp": "", "dec": decision])
        advance(300)
    }

    /// A Backspace the engine passed through, leaving `comp` as the token shown.
    fileprivate mutating func passedBackspace(leaving comp: String) {
        press(nil, keyCode: 0x33)
        line("engine", ["act": "passThrough", "comp": comp])
        advance(120)
    }

    /// A key the engine passed through as typed, leaving `comp`.
    fileprivate mutating func passedKey(_ character: Character, leaving comp: String) {
        press(String(character), keyCode: codes[character] ?? 0)
        line("engine", ["act": "passThrough", "comp": comp])
        advance(120)
    }

    /// The broken re-open of 15/11/2026 up to the typed keys: `tiesng`, space (L5), the re-opening Backspace and
    /// four Backspaces into the token, which leave `ti`, then `eesn` passed through as typed.
    fileprivate mutating func brokenReopen() {
        launch()
        restoredCommit("tiesng")
        passedBackspace(leaving: "tiesng")
        for comp in ["tiesn", "ties", "tie", "ti"] { passedBackspace(leaving: comp) }
        for (character, comp) in zip("eesn", ["tie", "tiee", "tiees", "tieesn"]) { passedKey(character, leaving: comp) }
    }
}

@Suite struct ReopenedLiteralTests {
    /// The proposal's first fixture: restored(invalid) commit, Backspace (re-open), Backspace x4, four letters
    /// passed through, reset: one finding, anchored at the first letter that passed through.
    @Test func lettersPassedThroughARestoredTokenTheyShouldComposeAreAFinding() throws {
        var trace = TraceBuilder()
        trace.brokenReopen()
        trace.advance(300)
        trace.boundary("pointerClicked", job: "mouseDown")
        let found = reopenedLiterals(trace)
        #expect(found.count == 1)
        let finding = try #require(found.first)
        #expect(
            finding.detail
                == "Backspace re-opened a token committed as restored(invalid); after 4 Backspaces into it, 4 keys "
                + "passed through as typed that a fresh token composes (ENG-R1005)")
        #expect(finding.bundle == TraceBuilder.editor && finding.rule == "editor.sample")
        #expect(finding.note == nil, "nothing typed is shown, not even by show")
        let anchor = try #require(trace.events.first { $0.index == finding.eventIndex })
        #expect(anchor.line.type == "engine" && anchor.line.comp == "tie", "the first key that passed through")
    }

    /// The token can also end at a commit: the boundary key's own commit decides by 8.1, but the keys before it
    /// already passed through as typed.
    @Test func aCommitEndsTheTokenToo() {
        var trace = TraceBuilder()
        trace.brokenReopen()
        trace.line("key", ["ev": "keyDown", "kc": 0x31, "fl": 0, "ch": " ", "out": "held"])
        trace.line(
            "engine", ["act": "editThenPassThrough", "del": 6, "ins": "tiến", "comp": "", "dec": "kept(notEnglish)"])
        #expect(reopenedLiterals(trace).count == 1)
    }

    /// The proposal's second fixture: the same keys, but the letters compose (ENG-R1005 after the fix).
    @Test func lettersThatComposeAreNoFinding() {
        var trace = TraceBuilder()
        trace.launch()
        trace.restoredCommit("tiesng")
        trace.passedBackspace(leaving: "tiesng")
        for comp in ["tiesn", "ties", "tie", "ti"] { trace.passedBackspace(leaving: comp) }
        trace.passedKey("e", leaving: "tie")
        trace.press("e", keyCode: 0x0E, outcome: "consumedForEdit")
        trace.line("engine", ["act": "edit", "del": 1, "ins": "ê", "comp": "tiê"])
        trace.advance(120)
        trace.press("s", keyCode: 0x01, outcome: "consumedForEdit")
        trace.line("engine", ["act": "edit", "del": 1, "ins": "ế", "comp": "tiế"])
        trace.advance(120)
        trace.passedKey("n", leaving: "tiến")
        trace.boundary("pointerClicked", job: "mouseDown")
        #expect(reopenedLiterals(trace).isEmpty)
    }

    /// The same with the real engine: the token typed afresh composes, so a correct trace never fires.
    @Test func theRealEngineNeverFires() {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("tiesng ")
        for _ in 0..<5 { trace.backspace() }
        trace.type("eesn")
        trace.boundary("pointerClicked", job: "mouseDown")
        #expect(trace.events.contains { $0.line.dec?.hasPrefix("restored") == true }, "the fixture restores")
        #expect(reopenedLiterals(trace).isEmpty)
    }

    /// The real engine with letters that pass through after the re-open (`ti` + `ng` shows `ting`): the check runs
    /// on real engine output and still finds nothing, since a fresh token would not compose those keys either.
    @Test func theRealEngineNeverFiresOnLettersThatStayAsTyped() {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("tiesng ")
        for _ in 0..<5 { trace.backspace() }
        trace.type("ng")
        trace.boundary("pointerClicked", job: "mouseDown")
        #expect(trace.events.contains { $0.line.dec?.hasPrefix("restored") == true }, "the fixture restores")
        #expect(reopenedLiterals(trace).isEmpty)
    }

    /// ENG-R1005: the restore lasts while a remaining raw key still transforms something (`tieesngg`, space, two
    /// Backspaces leave `tieesn`), so keys typed then stay as typed on purpose.
    @Test func keysTypedWhileTheRestoreRightlyLastsAreNoFinding() {
        var trace = TraceBuilder()
        trace.launch()
        trace.restoredCommit("tieesngg")
        trace.passedBackspace(leaving: "tieesngg")
        trace.passedBackspace(leaving: "tieesng")
        trace.passedBackspace(leaving: "tieesn")
        trace.passedKey("g", leaving: "tieesng")
        trace.boundary("pointerClicked", job: "mouseDown")
        #expect(reopenedLiterals(trace).isEmpty)
    }

    /// The user's own restore (L1) stays literal for the rest of the token whatever is deleted (E02b); keys typed
    /// before any Backspace into the token stay as typed (`Safar`, space, Backspace, `i`).
    @Test func theUsersOwnRestoreAndKeysBeforeAnyBackspaceAreNoFinding() {
        var own = TraceBuilder()
        own.launch()
        own.restoredCommit("tiesng", decision: "restored(userChoice)")
        own.passedBackspace(leaving: "tiesng")
        for comp in ["tiesn", "ties", "tie", "ti"] { own.passedBackspace(leaving: comp) }
        for (character, comp) in zip("eesn", ["tie", "tiee", "tiees", "tieesn"]) {
            own.passedKey(character, leaving: comp)
        }
        own.boundary("pointerClicked", job: "mouseDown")
        #expect(reopenedLiterals(own).isEmpty)
        #expect(scan(own).contains { $0.kind == .restoreOrReopen }, "the re-open itself is still listed")

        var before = TraceBuilder()
        before.launch()
        before.restoredCommit("baas")
        before.passedBackspace(leaving: "baas")
        before.passedKey("m", leaving: "baasm")
        before.boundary("pointerClicked", job: "mouseDown")
        #expect(reopenedLiterals(before).isEmpty)
    }

    /// The check needs an engine: without replay (`--no-replay`) nothing is reported, and a token still open when
    /// the trace ends, or one cut by a gap, is not judged.
    @Test func withoutAnEngineOrAnEndNothingIsReported() {
        var trace = TraceBuilder()
        trace.brokenReopen()
        trace.boundary("pointerClicked", job: "mouseDown")
        #expect(reopenedLiterals(trace, replay: false).isEmpty)

        var open = TraceBuilder()
        open.brokenReopen()
        #expect(reopenedLiterals(open).isEmpty)

        var gap = TraceBuilder()
        gap.brokenReopen()
        gap.line("gap", ["reason": "secureInput", "end": gap.t + 200_000])
        gap.advance(300)
        gap.boundary("secureInputChanged")
        #expect(reopenedLiterals(gap).isEmpty)
    }

    /// One finding per token: a run judged at a later Backspace is not reported again at the end.
    @Test func aTokenGivesAtMostOneFinding() {
        var trace = TraceBuilder()
        trace.brokenReopen()
        trace.passedBackspace(leaving: "tiees")
        trace.passedKey("n", leaving: "tieesn")
        trace.boundary("pointerClicked", job: "mouseDown")
        #expect(reopenedLiterals(trace).count == 1)
    }
}
