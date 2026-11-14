// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007) readback findings on synthetic reproductions of the two incidents of the first dev-recorder
// day (2026-11-14, a native app whose editor is a WKWebView): a key the tap passed never reached the field while a
// readback ran next to it. The scanner names the dropped key (in `show` only: the summary stays free of typed
// content), says whether a readback was in flight when it went down or started right after it, re-baselines after
// a mismatch so one divergence is one finding, discounts reads a key overlapped, and flags slow readbacks.

import Foundation
import Testing
import VietnameseEngine

@testable import TraceScanCore

private let webEditor = IncidentTraces.webEditor

private func findings(_ builder: TraceBuilder) -> [Finding] {
    FindingDetector.findings(in: builder.events, replay: nil)
}

private func scan(_ builder: TraceBuilder, _ arguments: [String]) throws -> String {
    let folder = TraceBuilder.temporaryFolder()
    try builder.write(to: folder)
    defer { try? FileManager.default.removeItem(at: folder) }
    let result = TraceScanCommand.run(
        arguments + ["--dir", folder.path], now: Date(timeIntervalSince1970: Double(TraceBuilder.base) / 1e6 + 7_200),
        timeZone: TraceBuilder.utc, makeReplay: { nil })
    #expect(result.exitCode == 0)
    return result.output
}

@Suite struct ReadbackDivergenceTests {
    /// Incident 1: one keyDropped finding naming the readback that started 27 ms after the key, and no follow-on
    /// mismatches (the first recorder's trace gave one mismatch and five follow-ons).
    @Test func incidentOneIsOneDroppedKey() throws {
        let trace = IncidentTraces.one()
        let found = findings(trace)
        #expect(found.map(\.kind) == [.keyDropped])
        let dropped = try #require(found.first)
        #expect(dropped.bundle == webEditor)
        #expect(dropped.detail.contains("a readback started 27 ms after it went down"))
        #expect(dropped.detail.contains("backspaceEdit readback"))
        #expect(dropped.note?.hasPrefix("keyDropped: \"c\" passed at -") == true)
        #expect(dropped.note?.hasSuffix(" ms, absent from the field") == true)
    }

    /// Incident 10: the "i" is named, with the readback that started 71 ms after it.
    @Test func incidentTenIsOneDroppedKey() throws {
        let found = findings(IncidentTraces.ten())
        #expect(found.map(\.kind) == [.keyDropped])
        #expect(found.first?.detail.contains("a readback started 71 ms after it went down") == true)
        #expect(found.first?.note?.hasPrefix("keyDropped: \"i\" passed at -") == true)
    }

    /// PLT-R904A, PLT-R901: the summary names no typed character; `show` does, around the finding only.
    @Test func theSummaryStaysFreeOfTypedContent() throws {
        for trace in [IncidentTraces.one(), IncidentTraces.ten()] {
            let summary = try scan(trace, ["summary"])
            #expect(summary.contains("keyDropped  a passed key is absent from the field"))
            for content in ["\"c\"", "\"i\"", "Khúc", "máy", "cái", "coi", "nhé"] {
                #expect(!summary.contains(content))
            }
        }
        let shown = try scan(IncidentTraces.ten(), ["show", "1", "--before", "2s", "--after", "0s"])
        #expect(shown.contains("keyDropped: \"i\" passed at -"))
        #expect(shown.contains("readback  commit  ok  \"máy co\""))
    }

    /// A readback a key overlapped is not compared (its text may be half way through the key); the next readback
    /// names the key and says that a readback was in flight when it went down. The overlapped read also took
    /// longer than the slow-readback threshold.
    @Test func aReadAKeyOverlappedIsDiscountedAndNamed() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("xin ")
        trace.advance(1_000)
        trace.readback("xin b", durUs: 40_000, idleUs: 1_000_000, overlap: true)  // a torn read: no finding
        trace.advance(15)
        trace.press("b", event: .key(KeyInput("b")), dropped: true)
        trace.advance(120)
        trace.type("an ")
        trace.advance(1_000)
        trace.readbackField(reason: "commit", durUs: 8_000, idleUs: 1_000_000)
        let found = findings(trace)
        #expect(found.map(\.kind) == [.slowReadback, .keyDropped])
        #expect(found.last?.detail.contains("a readback was in flight when it went down") == true)
        #expect(found.last?.note?.hasPrefix("keyDropped: \"b\"") == true)
    }

    /// A dropped key with no readback near it says so (the drop is then not the observer's doing).
    @Test func aDropFarFromAnyReadbackSaysSo() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("xin ")
        trace.press("b", event: .key(KeyInput("b")), dropped: true)
        trace.advance(120)
        trace.type("an ")
        trace.advance(1_000)
        trace.readbackField(reason: "commit", durUs: 6_000, idleUs: 1_000_000)
        let found = findings(trace)
        #expect(found.map(\.kind) == [.keyDropped])
        #expect(found.first?.detail.contains("no readback within 200 ms of it") == true)
    }

    /// One character the app added that KeyVi never typed: named in `show`, counted without content.
    @Test func anExtraCharacterIsExplained() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("xin ")
        trace.appInserts("Z")
        trace.type("chao ")
        trace.advance(1_000)
        trace.readbackField(reason: "commit", durUs: 6_000)
        let found = findings(trace)
        #expect(found.map(\.kind) == [.extraCharacter])
        #expect(found.first?.detail == "the field holds one character KeyVi did not type (commit readback)")
        #expect(found.first?.note == "extraCharacter: \"Z\" in the field, not typed by KeyVi")
    }

    /// (a) After a mismatch the expected text is the field's: the same divergence is reported once, a new one
    /// again.
    @Test func aMismatchIsReportedOnceThenRebaselined() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.type("toi ")
        trace.appInserts("XY")  // two characters: no single-character explanation
        trace.advance(1_000)
        trace.readbackField()
        for word in ["dda ", "ddi ", "hocj "] {
            trace.type(word)
            trace.advance(1_000)
            trace.readbackField()
        }
        trace.press("x", event: .key(KeyInput("x")), dropped: true)
        trace.advance(120)
        trace.type("em ")
        trace.advance(1_000)
        trace.readbackField()
        #expect(findings(trace).map(\.kind) == [.readbackMismatch, .keyDropped])
    }

    /// Once a Backspace reached past what the scanner saw typed, a readback gives the baseline back, so a later
    /// drop is still found.
    @Test func anUnknownBaselineIsTakenFromTheNextReadback() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.boundary("focusChanged", job: "focusChanged")
        trace.appInserts("abc ")  // text from before the boundary
        trace.press(nil, keyCode: 0x33, outcome: "passed")  // into it: KeyVi's view is unknown
        trace.advance(1_000)
        trace.readbackField()
        trace.type("xin ")
        trace.press("b", event: .key(KeyInput("b")), dropped: true)
        trace.advance(120)
        trace.type("an ")
        trace.advance(1_000)
        trace.readbackField()
        #expect(findings(trace).map(\.kind) == [.keyDropped])
    }

    /// Slow and timed-out readbacks (more than 30 ms of AX calls), with the first recorder's lines (no duration)
    /// flagged only when they timed out.
    @Test func slowReadbacksAreFindings() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.readback("", durUs: 30_000)
        trace.advance(1_000)
        trace.readback("", durUs: 45_000)
        trace.advance(1_000)
        trace.readback("", reason: "marker", status: "timedOut", durUs: 51_000)
        trace.advance(1_000)
        trace.readback("", status: "timedOut")
        let found = findings(trace)
        #expect(found.map(\.kind) == [.slowReadback, .slowReadback, .slowReadback])
        #expect(
            found.map(\.detail) == [
                "commit readback took 45 ms (ok)", "marker readback timed out after 51 ms",
                "commit readback timed out",
            ])
    }

    /// `show` prints the readback's timing next to its text.
    @Test func showPrintsTheReadbackTiming() throws {
        var trace = TraceBuilder()
        trace.launch(bundle: webEditor, rule: nil)
        trace.readback("", durUs: 45_000)
        trace.line(
            "readback",
            [
                "reason": "commit", "status": "ok", "text": "ab", "selLoc": 2, "selLen": 0, "durUs": 12_300,
                "waitUs": 1_250_000, "idleUs": 1_000_000, "overlap": true,
            ])
        let shown = try scan(trace, ["show", "1"])
        let timing = "read 12.3 ms  waited 1.250 s  idle 1.000 s  key during read"
        #expect(shown.contains("readback  commit  ok  \"ab\"  selection 2+0  " + timing))
    }
}
