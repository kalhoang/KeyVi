// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): the committed sample trace (Fixtures/sample, sample words typed through the real engine)
// and its summary, line for line. The fixture doubles as a folder to try `trace-scan` on by hand.

import Foundation
import Testing

@testable import TraceScanCore

@Suite struct SampleFixtureTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/sample", isDirectory: true)

    @Test func summaryOfTheSampleTrace() throws {
        let result = TraceScanCommand.run(
            ["summary", "--dir", Self.folder.path], now: Date(), timeZone: TraceBuilder.utc,
            makeReplay: { ReplayEngineFactory(resources: TraceBuilder.resources) })
        let expected = """
            Dev traces in \(Self.folder.path)
            Files: 1 (20261114-09 to 20261114-09)
            Launches: 1
            Apps (key downs): com.example.editor 14, com.example.chat 12
            Key downs: 26, engine steps: 26, jobs: 2, readbacks: 2, markers: 1
            Gaps: none; pauses: 0
            Unreadable lines: 0
            Findings: 6
              1  2026-11-14 09:00:02.080  com.example.editor  rule editor.sample  resetWithOpenToken  \
            focusChanged / focusChanged, token of 3 characters open
              2  2026-11-14 09:00:03.220  com.example.chat  rule chat.sample  correctionBurst  \
            3 Backspaces after a transform, then retyping
              3  2026-11-14 09:00:04.220  com.example.chat  rule chat.sample  readbackMismatch  \
            field does not end with KeyVi's last 4 characters (commit)
              4  2026-11-14 09:00:04.220  com.example.chat  rule chat.sample  marker  chord
              5  2026-11-14 09:00:04.220  com.example.chat  rule chat.sample  injectionProblem  \
            job 3 compose backspaceReplace: outcome executedWithFallback; fallback axReplace -> backspaceReplace \
            (axTimedOut)
              6  2026-11-14 09:00:04.220  com.example.chat  rule chat.sample  restoreOrReopen  \
            restore (job 4 restore backspaceReplace)

            """
        #expect(result.exitCode == 0)
        #expect(result.output == expected)
    }

    @Test func theSampleShowsTheCorrectionInContext() throws {
        let result = TraceScanCommand.run(
            ["show", "2", "--dir", Self.folder.path, "--before", "500ms", "--after", "600ms"], now: Date(),
            timeZone: TraceBuilder.utc, makeReplay: { nil })
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.contains("> +0.000 s  key  keyDown  0x33  -  -  passed"))
        #expect(lines.contains("  +0.240 s  engine  passThrough  token \"ti\""))
        #expect(lines.contains("  +0.480 s  engine  passThrough  token \"\"  commit kept(unchanged)"))
        #expect(lines.contains("  -0.420 s  engine  passThrough  token \"tiếng\""))
    }
}
