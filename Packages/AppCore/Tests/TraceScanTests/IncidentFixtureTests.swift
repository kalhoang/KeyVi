// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007): the committed incident trace (Fixtures/incidents, both incidents of 2026-11-14 reproduced
// with sample words in the first recorder's format) and its summary, line for line: two dropped keys, each with
// the readback that started right after it, no follow-on mismatches, and no typed content. The folder doubles as
// one to try `trace-scan` on by hand. To regenerate it after a change to `IncidentTraces`:
//   TRACE_SCAN_WRITE_FIXTURES=1 swift test --filter IncidentFixtureTests

import Foundation
import Testing

@testable import TraceScanCore

@Suite struct IncidentFixtureTests {
    static let folder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/incidents", isDirectory: true)

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TRACE_SCAN_WRITE_FIXTURES"] != nil))
    func writeTheIncidentFixture() throws {
        try? FileManager.default.removeItem(at: Self.folder)
        try IncidentTraces.both().write(to: Self.folder)
    }

    /// The committed files are what `IncidentTraces.both()` writes.
    @Test func theFixtureIsUpToDate() throws {
        let committed = try FileManager.default.contentsOfDirectory(atPath: Self.folder.path).sorted()
        #expect(committed == ["20261114-09.jsonl"])
        let data = try Data(contentsOf: Self.folder.appendingPathComponent("20261114-09.jsonl"))
        #expect(data == IncidentTraces.both().data)
    }

    @Test func summaryOfTheIncidentTrace() throws {
        let result = TraceScanCommand.run(
            ["summary", "--dir", Self.folder.path], now: Date(), timeZone: TraceBuilder.utc,
            makeReplay: { ReplayEngineFactory(resources: TraceBuilder.resources) })
        let expected = """
            Dev traces in \(Self.folder.path)
            Files: 1 (20261114-09 to 20261114-09)
            Launches: 1
            Apps (key downs): com.example.webeditor 37
            Key downs: 37, engine steps: 37, jobs: 0, readbacks: 7, markers: 0
            Gaps: none; pauses: 0
            Unreadable lines: 0
            Findings: 2
              1  2026-11-14 09:00:01.893  com.example.webeditor  rule -  keyDropped  \
            a passed key is absent from the field: it went down 1020 ms before this backspaceEdit readback; \
            a readback started 27 ms after it went down
              2  2026-11-14 09:02:36.233  com.example.webeditor  rule -  keyDropped  \
            a passed key is absent from the field: it went down 1411 ms before this commit readback; \
            a readback started 71 ms after it went down
            Replay: 3 segments not replayed (3 by a build that did not record its engine); --replay-anyway replays them

            """
        #expect(result.exitCode == 0)
        #expect(result.output == expected)
    }

    @Test func showNamesTheDroppedKey() throws {
        let result = TraceScanCommand.run(
            ["show", "2", "--dir", Self.folder.path, "--before", "2s", "--after", "0s"], now: Date(),
            timeZone: TraceBuilder.utc, makeReplay: { nil })
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines.contains("  keyDropped: \"i\" passed at -1411 ms, absent from the field"))
        #expect(lines.contains("  -1.411 s  key  keyDown  0x00  -  \"i\"  passed"))
        #expect(lines.contains("  -1.340 s  readback  commit  ok  \"máy co\"  selection 6+0"))
    }
}
