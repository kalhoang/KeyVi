// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007) scanner findings a to i on synthetic traces with sample words: markers, Backspace edits,
// correction bursts, readback mismatches, resets with a token open, injection problems, restores and re-opens,
// replay divergences and Command+Z after an edit. Detail texts carry names and numbers, never typed content.

import Foundation
import Testing
import VietnameseEngine

@testable import TraceScanCore

private func kinds(_ builder: TraceBuilder, replay: Bool = false) throws -> [Finding.Kind] {
    try findings(builder, replay: replay).map(\.kind)
}

private func findings(_ builder: TraceBuilder, replay: Bool = false) throws -> [Finding] {
    FindingDetector.findings(
        in: builder.events, replay: replay ? ReplayEngineFactory(resources: TraceBuilder.resources) : nil)
}

private let command: UInt64 = 0x0010_0000

@Suite struct FindingDetectorTests {
    /// Clean typing gives nothing, the replay included.
    @Test func cleanTypingHasNoFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("vieejt nam ")
        trace.advance(400)
        trace.readback("việt nam ")
        #expect(try kinds(trace, replay: true).isEmpty)
    }

    /// (a) Every marker.
    @Test func markersAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.marker("chord")
        trace.advance(5_000)
        trace.marker("menu")
        let found = try findings(trace)
        #expect(found.map(\.kind) == [.marker, .marker])
        #expect(found.map(\.detail) == ["chord", "menu"])
        #expect(found.first?.bundle == TraceBuilder.editor && found.first?.rule == "editor.sample")
    }

    /// (b) A Backspace that deleted more than one character or inserted something.
    @Test func backspaceEditsAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.press(nil, keyCode: 0x33)
        trace.line("engine", ["act": "edit", "del": 2, "ins": "ê", "comp": "viê"])
        trace.advance(200)
        trace.press(nil, keyCode: 0x33)
        trace.line("engine", ["act": "edit", "del": 1, "ins": "", "comp": "vi"])
        let found = try findings(trace).filter { $0.kind == .backspaceEdit }
        #expect(found.count == 1)
        #expect(found.first?.detail == "Backspace deleted 2, inserted 1")
    }

    /// (c) Three Backspaces within 1.5 s right after a transform, then retyping.
    @Test func correctionBurstsAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.type("tieesng")  // the engine transforms on the way
        trace.advance(300)
        for _ in 0..<3 { trace.backspace() }
        trace.type("g")
        #expect(try kinds(trace).contains(.correctionBurst))
        var slow = TraceBuilder()
        slow.launch()
        slow.type("tieesng")
        slow.advance(3_000)  // too long after the transform
        for _ in 0..<3 { slow.backspace() }
        slow.type("g")
        #expect(try !kinds(slow).contains(.correctionBurst))
    }

    /// (d) The field does not end with what KeyVi typed since the last boundary.
    @Test func readbackMismatchesAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("chaof ")
        trace.advance(400)
        trace.readback("xin chào ")  // matches: earlier text is not KeyVi's
        trace.advance(400)
        trace.readback("xin chaof ")  // the app shows something else
        let found = try findings(trace).filter { $0.kind == .readbackMismatch }
        #expect(found.count == 1)
        #expect(found.first?.detail.contains("chào") == false)
    }

    /// (e) A focus change, revalidation or any unintended boundary while a token is open; not arrows or clicks.
    @Test func resetsWithAnOpenTokenAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.type("vie")
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("ab")
        trace.boundary("cursorMoved", job: "navigation")
        trace.type("cd")
        trace.boundary("lateFocusChange")  // a reason this scanner has never seen counts too
        let found = try findings(trace).filter { $0.kind == .resetWithOpenToken }
        #expect(
            found.map(\.detail) == [
                "focusChanged / focusChanged, token of 3 characters open",
                "lateFocusChange, token of 2 characters open",
            ])
    }

    /// (f) Failed, retried, timed-out or slow injection jobs.
    @Test func injectionProblemsAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.job(1)
        trace.line("fallback", ["seq": 2, "from": "axReplace", "to": "backspaceReplace", "reason": "axTimedOut"])
        trace.job(2, outcome: "executedWithFallback")
        trace.job(3, outcome: "passedThroughByFallback")
        trace.job(4, totalUs: 80_000)
        let found = try findings(trace).filter { $0.kind == .injectionProblem }
        #expect(
            found.map(\.detail) == [
                "job 2 compose backspaceReplace: outcome executedWithFallback; fallback axReplace -> backspaceReplace (axTimedOut)",
                "job 3 compose backspaceReplace: outcome passedThroughByFallback",
                "job 4 compose backspaceReplace: slow 80 ms",
            ])
    }

    /// (g) Escape restore and history re-open.
    @Test func restoresAndReopensAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.job(1, kind: "restore")
        trace.job(2, kind: "reentry")
        trace.job(3, kind: "backspaceRecompose")
        let found = try findings(trace).filter { $0.kind == .restoreOrReopen }
        #expect(
            found.map(\.detail) == [
                "restore (job 1 restore backspaceReplace)", "history re-open (job 2 reentry backspaceReplace)",
            ])
    }

    /// (h) Replaying a segment's keys with the recorded settings gives another result than recorded.
    @Test func replayDivergencesAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("vie")
        // The host recorded another insert for "e" than the engine produces from these keys.
        let output = trace.engineOutput(.key(KeyInput("e")))
        trace.line("key", ["ev": "keyDown", "kc": 14, "fl": 0, "ch": "e", "out": "consumedForEdit"])
        trace.engineLine(output, tamperedInsert: "ế")
        let found = try findings(trace, replay: true).filter { $0.kind == .replayDivergence }
        #expect(found.count == 1)
        #expect(found.first?.detail.hasPrefix("step 4 after the reset: recorded edit") == true)
        #expect(found.first?.detail.contains("ế") == false)
    }

    /// Return and Tab are fed to the engine first, then they are a hard boundary (KeyPipeline `commitLine`). The
    /// recorder writes the boundary when it happens and the key's engine step after the key line, so the boundary
    /// comes first in the file with the same time. Day finding 155 of 15/11/2026 was this: a revision committed by
    /// Return replayed into an engine already reset. The replay applies such a boundary after the key's own step.
    @Test func aReturnBoundaryIsAppliedAfterTheReturnsOwnStep() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("cais nayf tricky as hell")
        let output = trace.engineOutput(.key(KeyInput("\n")))
        guard case .edit(let edit, true) = output.action else {
            Issue.record("Return commits with an edit (the revision of the previous word)")
            return
        }
        #expect(edit.deleteCount > 0)
        trace.line("key", ["ev": "keyDown", "kc": 0x24, "fl": 0, "out": "held"])
        trace.boundary("cursorMoved", job: "returnOrTab")
        trace.engineLine(output)
        trace.advance(400)
        trace.type("nha")  // a fresh engine after the Return: replays without a divergence too
        #expect(try !kinds(trace, replay: true).contains(.replayDivergence))
    }

    /// The same boundary without an engine step of its own key (the recorder did not capture it) still resets.
    @Test func aReturnBoundaryWithoutItsStepStillResets() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("vie")
        trace.line("key", ["ev": "keyDown", "kc": 0x24, "fl": 0, "out": "passed"])
        trace.boundary("cursorMoved", job: "returnOrTab")
        trace.advance(400)
        trace.type("ej")  // a fresh token: "e" then "ej" -> "ẹ" (replayed without the old "vie")
        #expect(try !kinds(trace, replay: true).contains(.replayDivergence))
    }

    /// Word-list and macro decisions cannot be replayed without the user's lists: no false divergence.
    @Test func userListDecisionsStopTheReplayQuietly() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("ab")
        trace.line("key", ["ev": "keyDown", "kc": 49, "fl": 0, "ch": " ", "out": "held"])
        trace.line(
            "engine", ["act": "editThenPassThrough", "del": 2, "ins": "xy", "comp": "", "dec": "restored(userList)"])
        #expect(try !kinds(trace, replay: true).contains(.replayDivergence))
    }

    /// (i) Command+Z within 2 s of an engine edit.
    @Test func undoRightAfterAnEditIsAFinding() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.type("vieej")  // ends with an edit
        trace.press("z", keyCode: 0x06, flags: command, outcome: "passed")
        trace.advance(3_000)
        trace.press("z", keyCode: 0x06, flags: command, outcome: "passed")
        let found = try findings(trace).filter { $0.kind == .undoAfterEdit }
        #expect(found.count == 1)
    }

    @Test func findingsAreInTimeOrderAndDeterministic() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.job(1, kind: "restore")
        trace.advance(10)
        trace.marker()
        let first = try findings(trace)
        #expect(first.map(\.kind) == [.restoreOrReopen, .marker])
        #expect(try findings(trace) == first)
    }
}
