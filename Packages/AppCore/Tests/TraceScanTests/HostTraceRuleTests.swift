// SPDX-License-Identifier: GPL-3.0-or-later
//
// The scanner rules of 2026-11-15 (W14-H, ADR 0007, PLT-R904A), one fixture each: a dropped key found behind a
// count-based edit and named by the held-keyUp pattern (ADR 0322); unseenKey (PLT-R397A) and the readback it
// explains; correction bursts that count plain Backspaces after an edit that changed letters; app substitutions;
// replay only for traces of the scanner's engine build, and never across a gap; a Backspace that re-opens a
// rule-restored token. Summary details stay free of typed content.

import Foundation
import Testing
import VietnameseEngine

@testable import TraceScanCore

private func scan(_ trace: TraceBuilder, replay: Bool = false, anyEngine: Bool = false) -> (
    findings: [Finding], replaySkips: ReplaySkips
) {
    FindingDetector.scan(
        trace.events, replay: replay ? ReplayEngineFactory(resources: TraceBuilder.resources) : nil,
        replayAnyEngine: anyEngine)
}

/// ANSI key codes of the letters these fixtures type, so key-down tracking sees real pairs.
private let codes: [Character: UInt16] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "c": 0x08, "e": 0x0E, "t": 0x11, "i": 0x22,
    "j": 0x26, "m": 0x2E, "n": 0x2D, "g": 0x05, "u": 0x20, "w": 0x0D, "o": 0x1F, " ": 0x31,
]

extension TraceBuilder {
    fileprivate mutating func key(_ character: Character, dropped: Bool = false, keyUp: String = "passed") {
        press(
            String(character), keyCode: codes[character] ?? 0, event: .key(KeyInput(character)), dropped: dropped,
            keyUpOutcome: keyUp)
        advance(120)
    }

    fileprivate mutating func keys(_ text: String) { for character in text { key(character) } }
}

@Suite struct HostTraceRuleTests {
    /// (a) Pa's #62: the "u" of "mục" never arrived (its previous keyUp was held and replayed); the "j" edit deleted
    /// two characters by count, so the field shows "ục". The texts alone fit three keys; the pattern names the "u".
    @Test func aDropBehindACountBasedEditIsNamedByTheHeldKeyUpPattern() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.key("d")
        trace.key("u", keyUp: "held")  // released while the tone key's edit was in flight
        trace.keys("f ")
        trace.key("m")
        trace.key("u", dropped: true)
        trace.keys("cj")
        trace.advance(1_000)
        trace.readbackField()
        let dropped = try #require(scan(trace).findings.first { $0.kind == .keyDropped })
        #expect(dropped.detail.contains("passed keys fit, most likely the first press of a key after its keyUp"))
        #expect(dropped.note?.hasPrefix("keyDropped: \"u\"") == true)
        #expect(!dropped.detail.contains("\"") && !dropped.detail.contains("u\""))
    }

    /// (b) A key the tap never saw: only its keyUp is in the trace. The readback mismatch after it says why.
    @Test func anOrphanKeyUpIsAnUnseenKeyAndExplainsTheNextMismatchPLTR397A() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.advance(2_000)
        trace.keys("ha")
        trace.appInserts("s")  // reached the app while secure input hid it from the tap
        trace.line("key", ["ev": "keyUp", "kc": 1, "fl": 0, "ch": "s", "out": "passed"])
        trace.advance(40)
        trace.key("a")  // the engine still holds "ha": "hâ" deletes the "s" the app got
        trace.advance(1_000)
        trace.readbackField()
        let found = scan(trace).findings
        let unseen = try #require(found.first { $0.kind == .unseenKey })
        #expect(
            unseen.detail == "a key went up that the tap never saw go down: the app received a key KeyVi did not see")
        #expect(unseen.note == "unseenKey: key 0x01 went up without a key down")
        let mismatch = try #require(
            found.first { [.readbackMismatch, .extraCharacter, .keyDropped].contains($0.kind) })
        #expect(mismatch.detail.contains("a key the tap never saw went up"))
    }

    /// The first key after a gap may have gone down unrecorded: no unseenKey within 1 s of its end. The tap's own
    /// unseenInput boundary is not a resetWithOpenToken.
    @Test func orphanKeyUpsRightAfterAGapAndTheTapsBoundaryAreQuiet() {
        var trace = TraceBuilder()
        trace.launch()
        trace.advance(2_000)
        trace.line("gap", ["reason": "secureInput", "end": trace.t + 223_000])
        trace.advance(400)
        trace.line("key", ["ev": "keyUp", "kc": 4, "fl": 0, "ch": "h", "out": "passed"])
        trace.advance(2_000)
        trace.keys("ha")
        trace.line("key", ["ev": "keyUp", "kc": 1, "fl": 0, "ch": "s", "out": "passed"])
        trace.boundary("unknown", job: "unseenInput")
        let kinds = scan(trace).findings.map(\.kind)
        #expect(kinds.filter { $0 == .unseenKey }.count == 1)
        #expect(!kinds.contains(.resetWithOpenToken))
    }

    /// (c) Option+Backspace and Command+Backspace are not single Backspaces; an edit that only added a letter (a
    /// standalone "ư") is no transform. A tone edit still starts a burst.
    @Test func burstsCountPlainBackspacesAfterAnEditThatChangedLetters() {
        let option: UInt64 = 0x0008_0000
        var modified = TraceBuilder()
        modified.launch()
        modified.keys("as")  // "á": changes a letter
        for _ in 0..<3 {
            modified.press(nil, keyCode: 0x33, flags: option, event: nil)
            modified.advance(100)
        }
        modified.keys("ab")
        #expect(!scan(modified).findings.contains { $0.kind == .correctionBurst })

        var added = TraceBuilder()
        added.launch()
        added.keys("w")  // standalone "ư": an edit that deletes nothing
        for _ in 0..<3 { added.backspace() }
        added.keys("ab")
        #expect(!scan(added).findings.contains { $0.kind == .correctionBurst })

        var tone = TraceBuilder()
        tone.launch()
        tone.keys("as")
        for _ in 0..<3 { tone.backspace() }
        tone.keys("ab")
        #expect(scan(tone).findings.contains { $0.kind == .correctionBurst })
    }

    /// (d) Smart quotes, the ellipsis and the double-space period are the app's substitutions, not mismatches.
    @Test func appSubstitutionsAreNotMismatches() {
        let cases: [(typed: String, field: String)] = [
            ("\"ab\" ", "\u{201C}ab\u{201D} "), ("it's ", "it\u{2019}s "), ("ok... ", "ok\u{2026} "),
            ("pa  ", "pa. "), ("a -- b ", "a \u{2014} b "),
        ]
        for (typed, field) in cases {
            var trace = TraceBuilder()
            trace.launch()
            trace.boundary("focusChanged", job: "focusChanged")
            trace.type(typed)
            trace.advance(1_000)
            trace.readback(field)
            let kinds = scan(trace).findings.map(\.kind)
            #expect(
                !kinds.contains { [.readbackMismatch, .keyDropped, .extraCharacter].contains($0) },
                "\(typed.debugDescription) read back as \(field.debugDescription)")
        }
        var real = TraceBuilder()  // a real difference next to a substitution is still one
        real.launch()
        real.boundary("focusChanged", job: "focusChanged")
        real.type("\"ab\" xy")
        real.advance(1_000)
        real.readback("\u{201C}ab\u{201D} x")
        #expect(scan(real).findings.contains { [.readbackMismatch, .keyDropped].contains($0.kind) })
    }

    /// (e) A trace another engine build wrote is not replayed (the summary says so); `--replay-anyway` replays it.
    @Test func replayRunsOnlyOnTracesOfTheScannersEngineBuild() {
        func tampered(engine: String?, version: Int = 3) -> TraceBuilder {
            var trace = TraceBuilder()
            trace.launch(version: version, engine: engine)
            trace.boundary("focusChanged", job: "focusChanged")
            trace.type("vie")
            let output = trace.engineOutput(.key(KeyInput("e")))
            trace.line("key", ["ev": "keyDown", "kc": 14, "fl": 0, "ch": "e", "out": "consumedForEdit"])
            trace.engineLine(output, tamperedInsert: "ế")
            return trace
        }
        let same = scan(tampered(engine: TraceBuilder.engineIdentity), replay: true)
        #expect(same.findings.contains { $0.kind == .replayDivergence } && same.replaySkips.total == 0)
        let other = scan(tampered(engine: "p1-0000000000000000"), replay: true)
        #expect(!other.findings.contains { $0.kind == .replayDivergence })
        #expect(other.replaySkips.otherEngine == 1 && other.replaySkips.unidentifiedEngine == 0)
        let old = scan(tampered(engine: nil, version: 2), replay: true)
        #expect(old.replaySkips.unidentifiedEngine == 1)
        let anyway = scan(tampered(engine: "p1-0000000000000000"), replay: true, anyEngine: true)
        #expect(anyway.findings.contains { $0.kind == .replayDivergence })
        #expect(
            TraceRendering.replayNote(other.replaySkips, replayed: true)
                == "Replay: 1 segment not replayed (1 written by another engine build); --replay-anyway replays them\n"
        )
    }

    /// Keys inside a gap are not recorded and the host reset at its end: the replay stops at the gap (Pa's #19).
    @Test func replayStopsAtAGap() {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("tri")
        trace.line("gap", ["reason": "secureInput", "end": trace.t + 223_000])
        trace.advance(300)
        _ = trace.engineOutput(.reset(.secureInputChanged))  // the host's reset the recorder did not write
        trace.type("t")
        #expect(!scan(trace, replay: true).findings.contains { $0.kind == .replayDivergence })
    }

    /// (f) Pa's #76: a Backspace that re-opens a token a rule restored at its commit.
    @Test func aBackspaceThatReopensARestoredTokenIsAFinding() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.line("key", ["ev": "keyDown", "kc": 49, "fl": 0, "ch": " ", "out": "held"])
        trace.line(
            "engine", ["act": "editThenPassThrough", "del": 5, "ins": "tiesng", "comp": "", "dec": "restored(invalid)"])
        trace.advance(300)
        trace.press(nil, keyCode: 0x33)
        trace.line("engine", ["act": "passThrough", "comp": "tiesng"])
        trace.advance(300)
        trace.press(nil, keyCode: 0x33)
        trace.line("engine", ["act": "passThrough", "comp": "tiesn"])
        let reopen = scan(trace).findings.filter { $0.kind == .restoreOrReopen }
        #expect(reopen.map(\.detail) == ["Backspace re-opened a token committed as restored(invalid)"])
    }

    /// Typing in an app AX did not name is attributed to NSWorkspace's frontmost application, in parentheses.
    @Test func anUnnamedAppIsAttributedToTheFrontmostApplication() {
        var trace = TraceBuilder()
        trace.launch()
        trace.line(
            "focus",
            [
                "gen": 2, "strat": "backspaceReplace", "rtf": "whenKnown", "ax": "available", "secure": false,
                "mode": "vietnamese", "modeSrc": "globalMode", "ctx": "general", "er": true, "mac": true,
                "front": "com.example.unnamed",
            ])
        trace.marker()
        #expect(scan(trace).findings.first?.bundle == "(com.example.unnamed)")
    }

    /// A `--since` window that starts inside a file keeps that file's header, settings and focus in effect, so the
    /// findings name the app and the replay knows the settings and the engine build.
    @Test func aSinceWindowInsideAFileKeepsItsContext() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.boundary("focusChanged", job: "focusChanged")
        trace.advance(40 * 60_000)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("vie")
        let output = trace.engineOutput(.key(KeyInput("e")))
        trace.line("key", ["ev": "keyDown", "kc": 14, "fl": 0, "ch": "e", "out": "consumedForEdit"])
        trace.engineLine(output, tamperedInsert: "ế")
        let folder = TraceBuilder.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try trace.write(to: folder)
        let result = TraceScanCommand.run(
            ["summary", "--dir", folder.path, "--since", "10m", "--now", "2026-11-14T09:45:00Z"], now: Date(),
            timeZone: TraceBuilder.utc, makeReplay: { ReplayEngineFactory(resources: TraceBuilder.resources) })
        #expect(result.output.contains("com.example.editor  rule editor.sample  replayDivergence"))
        #expect(!result.output.contains("Replay:"))
    }

    /// A key held across the start of a `--since` window went down before it: its keyUp 100 ms into the window is
    /// not an unseenKey (PLT-R397A). The context lines kept from before the window must not move the window's start
    /// back, or the 1 s grace after it is lost.
    @Test func aKeyHeldAcrossTheStartOfASinceWindowIsNotUnseen() throws {
        var trace = TraceBuilder()
        trace.launch()
        trace.advance(35 * 60_000 - 100)
        trace.line("key", ["ev": "keyDown", "kc": 0, "fl": 0, "ch": "a", "out": "passed"])
        trace.advance(200)
        trace.line("key", ["ev": "keyUp", "kc": 0, "fl": 0, "ch": "a", "out": "passed"])
        trace.advance(2_000)
        trace.keys("ha")
        let folder = TraceBuilder.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try trace.write(to: folder)
        let result = TraceScanCommand.run(
            ["summary", "--dir", folder.path, "--since", "10m", "--now", "2026-11-14T09:45:00Z", "--no-replay"],
            now: Date(), timeZone: TraceBuilder.utc,
            makeReplay: { ReplayEngineFactory(resources: TraceBuilder.resources) })
        #expect(result.output.contains("Findings: 0"))
        #expect(!result.output.contains("unseenKey"))
    }
}
