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

    /// PLT-R423: a `forwardDelete` job posts a Forward Delete pair before each Backspace pair (6 events for a delete-1
    /// edit, 12 for delete 2 insert 2) and names its decision on the job line; none of that is a finding.
    @Test func forwardDeleteJobsAreNotFindingsPLTR423() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("tiee")
        trace.line("job", Self.forwardDeleteJob(1, delete: 1, posted: 6, completion: "forwardDelete", readUs: 21_000))
        trace.type("ns")
        trace.line("job", Self.forwardDeleteJob(2, delete: 2, posted: 12, completion: "forwardDelete", readUs: 480))
        trace.type("g ")
        trace.line(
            "job",
            Self.forwardDeleteJob(3, delete: 1, posted: 4, completion: "forwardDelete skipped notAtEnd", readUs: 900))
        trace.advance(400)
        trace.readback("tiếng ")
        #expect(try kinds(trace, replay: true).isEmpty)
    }

    /// Retest of 16/11/2026, items 34 and 40: a completion read that timed out is the cause of the lost deletion
    /// (Spotlight right after it opened), so it is an injection problem that names the read's duration; a slow job
    /// says how much of it the read took. Only the reads with no fallback count: `forwardDelete skipped unreadable`
    /// (PLT-R423) and a plain `axSelection` read (PLT-R420). With `axSelectionThenPlaceholder` the placeholder handles
    /// the suggestion (PLT-R421), so `unreadable then placeholder` stays in `show` only (review of 16/11/2026).
    @Test func anUnreadableCompletionIsAnInjectionProblemPLTR423() throws {
        var trace = TraceBuilder()
        trace.launch()
        var unreadable = Self.forwardDeleteJob(
            1, delete: 1, posted: 4, completion: "forwardDelete skipped unreadable", readUs: 50_000)
        unreadable["totalUs"] = 52_100
        trace.line("job", unreadable)
        trace.line("job", Self.forwardDeleteJob(2, delete: 1, posted: 4, completion: "unreadable", readUs: 15_000))
        var slow = Self.forwardDeleteJob(3, delete: 1, posted: 6, completion: "forwardDelete", readUs: 48_700)
        slow["totalUs"] = 50_900
        trace.line("job", slow)
        let placeholder = "unreadable then placeholder"
        trace.line("job", Self.forwardDeleteJob(4, delete: 1, posted: 8, completion: placeholder, readUs: 15_000))
        var slowPlaceholder = Self.forwardDeleteJob(5, delete: 1, posted: 8, completion: placeholder, readUs: 15_000)
        slowPlaceholder["totalUs"] = 61_200
        trace.line("job", slowPlaceholder)
        let found = try findings(trace).filter { $0.kind == .injectionProblem }
        #expect(
            found.map(\.detail) == [
                "job 1 compose backspaceReplace: completion forwardDelete skipped unreadable (read 50.0 ms); slow 52 ms",
                "job 2 compose backspaceReplace: completion unreadable (read 15.0 ms)",
                "job 3 compose backspaceReplace: slow 50 ms (completion read 48.7 ms)",
                "job 5 compose backspaceReplace: slow 61 ms (completion read 15.0 ms)",
            ])
    }

    /// PLT-R423 caret continuity (amendment of 16/11/2026, second retest: Spotlight's reads took 3.2, 14.6, 27.2 and
    /// then more than 50 ms in one session): a job whose read did not answer but kept an earlier answer sent its
    /// Forward Deletes, so it is no lossy read. A kept job always waits the whole read bound, so it is slow only when
    /// its time without the read passes the limit; then the finding still says how much of it the read took. Lines
    /// written before the amendment (no `complKeptJobs`) still parse.
    @Test func aKeptAnswerIsNoLossyReadPLTR423() throws {
        var trace = TraceBuilder()
        trace.launch()
        var kept = Self.forwardDeleteJob(1, delete: 2, posted: 12, completion: "forwardDelete kept", readUs: 50_000)
        kept["complKeptJobs"] = 1
        kept["complKeptUs"] = 120_400
        kept["totalUs"] = 53_100
        trace.line("job", kept)
        var quick = Self.forwardDeleteJob(2, delete: 1, posted: 6, completion: "forwardDelete kept", readUs: 48_000)
        quick["complKeptJobs"] = 2
        quick["complKeptUs"] = 240_000
        trace.line("job", quick)
        let old = Self.forwardDeleteJob(
            3, delete: 2, posted: 8, completion: "forwardDelete skipped unreadable", readUs: 51_000)
        trace.line("job", old)
        var slowEvents = Self.forwardDeleteJob(
            4, delete: 1, posted: 6, completion: "forwardDelete kept", readUs: 50_000)
        slowEvents["complKeptJobs"] = 1
        slowEvents["complKeptUs"] = 60_000
        slowEvents["totalUs"] = 110_000
        trace.line("job", slowEvents)
        let found = try findings(trace).filter { $0.kind == .injectionProblem }
        #expect(
            found.map(\.detail) == [
                "job 3 compose backspaceReplace: completion forwardDelete skipped unreadable (read 51.0 ms)",
                "job 4 compose backspaceReplace: slow 110 ms (completion read 50.0 ms)",
            ])
    }

    private static func forwardDeleteJob(
        _ sequence: Int, delete: Int, posted: Int, completion: String, readUs: Int? = nil
    ) -> [String: Any] {
        var line: [String: Any] = [
            "seq": sequence, "gen": 1, "kind": "compose", "strat": "backspaceReplace", "out": "executed",
            "delN": delete,
            "insN": delete, "posted": posted, "totalUs": 1_600, "runUs": 1_400, "compl": completion,
        ]
        if let readUs { line["complUs"] = readUs }
        return line
    }

    /// PLT-R357, retest of 16/11/2026: a revision whose previous word was not rewritten (only the current token's part
    /// applied, the key passed, the job discarded) is its own finding, with its events and the read-back that decided
    /// it; its slowness stays an injection problem. Traces written before the read-back field still parse and get
    /// the finding without it.
    @Test func aRevisionThatFellBackIsAFinding() throws {
        var trace = TraceBuilder()
        trace.launch()
        let fellBack = Self.revisionJob(
            1, outcome: "executedWithFallback", posted: 0, readback: "mismatch differs afterSettle", totalUs: 52_100)
        trace.line("job", fellBack)
        trace.line("job", Self.revisionJob(2, outcome: "executed", posted: 22, readback: "skipped rule"))
        trace.line("job", Self.revisionJob(3, outcome: "passedThroughByFallback", posted: 2, readback: nil))
        let found = try findings(trace)
        #expect(
            found.filter { $0.kind == .revisionFellBack }.map(\.detail) == [
                "job 1 revision backspaceReplace: outcome executedWithFallback, 0 events, "
                    + "readback mismatch differs afterSettle",
                "job 3 revision backspaceReplace: outcome passedThroughByFallback, 2 events",
            ])
        #expect(
            found.filter { $0.kind == .injectionProblem }.map(\.detail) == [
                "job 1 revision backspaceReplace: slow 52 ms"
            ])
    }

    /// PLT-R357, review of 16/11/2026: `executedWithFallback` also means the full revision ran with a fallback
    /// strategy (`runChain`), so the word before was rewritten. Only a read-back that decided against the previous
    /// word (`mismatch ...`, `skipped unknownPrevious`, `skipped wideDeletion`) or an outcome that applied nothing
    /// proves the word kept its text; a full attempt that fell back to another strategy stays an injection problem
    /// with its fallback steps, and so does a line written before the read-back field, whose cause is unknown.
    @Test func aRevisionRewrittenByAFallbackStrategyIsAnInjectionProblem() throws {
        var trace = TraceBuilder()
        trace.launch()
        let fullAttempts = [
            "matches", "unreadable afterSettle", "unreadable selection", "skipped rule", "skipped noField", nil,
        ]
        for (index, readback) in fullAttempts.enumerated() {
            let posted = readback == nil ? 0 : 22
            let job = Self.revisionJob(index + 1, outcome: "executedWithFallback", posted: posted, readback: readback)
            trace.line("job", job)
        }
        let refused = ["mismatch shortRead", "skipped unknownPrevious", "skipped wideDeletion"]
        for (index, readback) in refused.enumerated() {
            let job = Self.revisionJob(index + 7, outcome: "executedWithFallback", posted: 8, readback: readback)
            trace.line("job", job)
        }
        trace.line("job", Self.revisionJob(10, outcome: "abandoned", posted: 0, readback: "matches"))
        trace.line("job", Self.revisionJob(11, outcome: "discardedForGeneration", posted: 0, readback: nil))
        let found = try findings(trace)
        #expect(
            found.filter { $0.kind == .revisionFellBack }.map(\.detail) == [
                "job 7 revision backspaceReplace: outcome executedWithFallback, 8 events, readback mismatch shortRead",
                "job 8 revision backspaceReplace: outcome executedWithFallback, 8 events, "
                    + "readback skipped unknownPrevious",
                "job 9 revision backspaceReplace: outcome executedWithFallback, 8 events, "
                    + "readback skipped wideDeletion",
                "job 10 revision backspaceReplace: outcome abandoned, 0 events, readback matches",
                "job 11 revision backspaceReplace: outcome discardedForGeneration, 0 events",
            ])
        let expectedProblems = (1...6).map { "job \($0) revision backspaceReplace: outcome executedWithFallback" }
        #expect(found.filter { $0.kind == .injectionProblem }.map(\.detail) == expectedProblems)
    }

    private static func revisionJob(
        _ sequence: Int, outcome: String, posted: Int, readback: String?, totalUs: Int = 1_600
    ) -> [String: Any] {
        var line: [String: Any] = [
            "seq": sequence, "gen": 1, "kind": "revision", "strat": "backspaceReplace", "out": outcome, "delN": 6,
            "insN": 5, "posted": posted, "totalUs": totalUs, "runUs": totalUs - 200,
        ]
        if let readback { line["rb"] = readback }
        return line
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
