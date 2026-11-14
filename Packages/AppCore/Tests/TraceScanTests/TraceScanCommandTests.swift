// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R904A (ADR 0007) `trace-scan summary` and `show N` over synthetic trace folders: metadata-only summaries
// (no typed content), excerpts with relative times, file selection by `--since` and `--date`, unreadable lines,
// usage errors, and the guarantee that the scanner writes nothing but its output.

import Foundation
import Testing

@testable import TraceScanCore

private func run(_ arguments: [String], replay: Bool = true) -> TraceScanCommand.Result {
    TraceScanCommand.run(
        arguments, now: Date(timeIntervalSince1970: Double(TraceBuilder.base) / 1_000_000 + 7_200),
        timeZone: TraceBuilder.utc,
        makeReplay: { replay ? ReplayEngineFactory(resources: TraceBuilder.resources) : nil })
}

/// A morning of typing: a clean word, a reset with an open token, a marker and a slow job, across two hours.
private func sampleFolder() throws -> URL {
    var trace = TraceBuilder()
    trace.launch()
    trace.boundary("focusChanged", job: "focusChanged")
    trace.type("xin chaof ")
    trace.advance(400)
    trace.readback("xin chào ")
    trace.type("bajn")
    trace.boundary("focusChanged", job: "focusChanged")
    trace.focus(bundle: "com.example.chat", rule: nil)
    trace.advance(3_600_000)  // the next hour
    trace.type("toi")
    trace.marker()
    trace.job(7, totalUs: 75_000)
    let folder = TraceBuilder.temporaryFolder()
    try trace.write(to: folder)
    return folder
}

@Suite struct TraceScanCommandTests {
    @Test func summaryListsMetadataAndNumberedFindingsWithoutContent() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = run(["summary", "--dir", folder.path])
        #expect(result.exitCode == 0 && result.error.isEmpty)
        let text = result.output
        #expect(text.contains("Files: 2 (20261114-09 to 20261114-10)"))
        #expect(text.contains("Launches: 1"))
        #expect(text.contains("Apps (key downs): com.example.editor 14, com.example.chat 3"))
        #expect(text.contains("Findings: 3"))
        #expect(
            text.contains("  1  2026-11-14 09:00:02.080  com.example.editor  rule editor.sample  resetWithOpenToken"))
        #expect(text.contains("resetWithOpenToken  focusChanged / focusChanged, token of 3 characters open"))
        #expect(text.contains("  2  2026-11-14 10:00:02.440  com.example.chat  rule -  marker  chord"))
        #expect(text.contains("injectionProblem  job 7 compose backspaceReplace: slow 75 ms"))
        for content in ["chào", "chaof", "bạn", "bajn", "toi", "xin"] { #expect(!text.contains(content)) }
    }

    @Test func showRendersTheWindowInOrderWithRelativeTimes() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let result = run(["show", "1", "--dir", folder.path, "--before", "1s", "--after", "200ms"])
        #expect(result.exitCode == 0)
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(
            lines.first
                == "Finding #1: resetWithOpenToken at 2026-11-14 09:00:02.080, app com.example.editor, rule editor.sample"
        )
        #expect(lines.contains { $0.hasPrefix(">") && $0.contains("boundary  focusChanged / focusChanged") })
        #expect(lines.contains { $0.contains("-0.120 s  key  keyDown  0x00  -  \"n\"  passed") })
        #expect(lines.contains { $0.contains("engine  edit  delete 1  insert \"ạ\"  token \"bạ\"") })
        #expect(lines.contains { $0.contains("+0.000 s  focus  com.example.chat") })
    }

    @Test func showNumbersFindingsLikeTheSummary() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(run(["show", "3", "--dir", folder.path]).output.hasPrefix("Finding #3: injectionProblem"))
        let missing = run(["show", "4", "--dir", folder.path])
        #expect(missing.exitCode == 1 && missing.error.contains("no finding #4 (this selection has 3)"))
    }

    @Test func sinceAndDateSelectFilesAndLines() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // `now` is 11:00 UTC: the last hour holds only the second file's lines.
        let recent = run(["summary", "--dir", folder.path, "--since", "1h"])
        #expect(recent.output.contains("Files: 1 (20261114-10 to 20261114-10)"))
        #expect(recent.output.contains("Findings: 2"))
        let pinned = run(["summary", "--dir", folder.path, "--since", "30m", "--now", "2026-11-14T09:30:00Z"])
        #expect(pinned.output.contains("Files: 1 (20261114-09 to 20261114-09)"))
        #expect(run(["summary", "--dir", folder.path, "--date", "2026-11-14"]).output.contains("Files: 2"))
        #expect(run(["summary", "--dir", folder.path, "--date", "2026-11-13"]).output.contains("Files: 0"))
    }

    @Test func unreadableLinesAreCountedAndSkipped() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("20261114-09.jsonl")
        let handle = try FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(Data("{not json\n{\"type\":\"key\"}\n".utf8))
        try handle.close()
        let result = run(["summary", "--dir", folder.path])
        #expect(result.exitCode == 0 && result.output.contains("Unreadable lines: 2"))
    }

    @Test func foreignFilesAreIgnoredAndNothingIsWritten() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("x".utf8).write(to: folder.appendingPathComponent("notes.txt"))
        let before = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let sizes = try before.map {
            try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.size] as? Int
        }
        _ = run(["summary", "--dir", folder.path])
        _ = run(["show", "1", "--dir", folder.path])
        let after = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        #expect(before == after)
        #expect(
            try after.map {
                try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent($0).path)[.size] as? Int
            } == sizes)
    }

    @Test func outputIsDeterministic() throws {
        let folder = try sampleFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(run(["summary", "--dir", folder.path]) == run(["summary", "--dir", folder.path]))
        #expect(run(["show", "2", "--dir", folder.path]) == run(["show", "2", "--dir", folder.path]))
    }

    @Test func usageErrorsExitTwo() {
        #expect(run([]).exitCode == 2)
        #expect(run(["summary"]).error.contains("--dir PATH is required"))
        #expect(run(["show", "x", "--dir", "/tmp"]).exitCode == 2)
        #expect(run(["summary", "--dir", "/tmp", "--since", "2 hours"]).error.contains("not a duration: 2 hours"))
        #expect(run(["summary", "--dir", "/tmp", "--date", "2026-13-01"]).exitCode == 2)
        #expect(run(["summary", "--dir", "/tmp", "--since", "1h", "--date", "2026-11-14"]).exitCode == 2)
        #expect(run(["summary", "--dir", "/tmp", "--frobnicate", "1"]).error.contains("unknown option --frobnicate"))
        #expect(run(["help"]).output == TraceScanCommand.usage)
    }

    @Test func aMissingFolderIsAnError() {
        let result = run(["summary", "--dir", "/nonexistent/dev-traces"])
        #expect(result.exitCode == 1 && result.error.contains("no trace folder at /nonexistent/dev-traces"))
    }

    @Test func durationsParse() throws {
        #expect(try TraceScanCommand.duration("500ms") == 500_000)
        #expect(try TraceScanCommand.duration("30s") == 30_000_000)
        #expect(try TraceScanCommand.duration("5m") == 300_000_000)
        #expect(try TraceScanCommand.duration("2h") == 7_200_000_000)
        #expect(try TraceScanCommand.duration("7d") == 604_800_000_000)
        #expect(throws: TraceScanError.self) { try TraceScanCommand.duration("-1s") }
        #expect(throws: TraceScanError.self) { try TraceScanCommand.duration("s") }
    }

    /// Fast on a week of data: about 200,000 lines scanned with replay well within the test budget.
    @Test func aWeekOfLinesScansQuickly() throws {
        var trace = TraceBuilder()
        trace.launch()
        var words = 0
        while trace.lines.count < 200_000 {
            if words % 50 == 0 { trace.boundary("focusChanged", job: "focusChanged") }
            trace.type("vieejt nam ")
            trace.job(words)
            words += 1
        }
        let folder = TraceBuilder.temporaryFolder()
        try trace.write(to: folder)
        defer { try? FileManager.default.removeItem(at: folder) }
        let start = Date()
        let result = run(["summary", "--dir", folder.path])
        let seconds = Date().timeIntervalSince(start)
        #expect(result.exitCode == 0 && result.output.contains("Findings: 0"))
        #expect(seconds < 60, "scan took \(seconds) s")
    }
}
