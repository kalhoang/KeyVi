// SPDX-License-Identifier: GPL-3.0-or-later
//
// Text output of the scanner (PLT-R904A). `summary` prints metadata only: files, hours, launches, apps, counts, gaps
// and the numbered findings, never typed content. `show` prints one finding's excerpt in order with times relative
// to the finding: keys as typed, engine edits, jobs, boundaries, focus changes and readbacks. Keys, modifiers and
// characters are written exactly as the PLT-R905 review window writes them (Diagnostics `TraceText`).

internal import Diagnostics
public import Foundation

public enum TraceRendering {
    public static func summary(
        _ load: TraceLoad, findings: [Finding], directory: URL, timeZone: TimeZone
    ) -> String {
        let events = load.events.map(\.line)
        var output = ["Dev traces in " + directory.path]
        let hours = load.files.map { String($0.dropLast(6)) }
        output.append(
            "Files: " + String(load.files.count)
                + (hours.isEmpty ? "" : " (" + (hours.first ?? "") + " to " + (hours.last ?? "") + ")"))
        output.append("Launches: " + String(Set(events.compactMap { $0.type == "start" ? $0.launch : nil }).count))
        output.append("Apps (key downs): " + apps(load.events))
        let count = { (type: String) in events.filter { $0.type == type }.count }
        output.append(
            "Key downs: " + String(events.filter(\.isKeyDown).count) + ", engine steps: " + String(count("engine"))
                + ", jobs: " + String(count("job")) + ", readbacks: " + String(count("readback")) + ", markers: "
                + String(count("marker")))
        output.append("Gaps: " + gaps(events) + "; pauses: " + String(count("pause")))
        output.append("Unreadable lines: " + String(load.unreadableLines))
        output.append("Findings: " + String(findings.count))
        for (number, finding) in findings.enumerated() {
            output.append(
                "  " + String(number + 1) + "  " + localTime(finding.t, timeZone: timeZone) + "  "
                    + (finding.bundle ?? "-") + "  rule " + (finding.rule ?? "-") + "  " + finding.kind.rawValue
                    + "  " + finding.detail)
        }
        return output.joined(separator: "\n") + "\n"
    }

    /// The finding's window, `before` and `after` in microseconds around it.
    public static func show(
        _ finding: Finding, number: Int, events: [TraceEvent], before: Int64, after: Int64, timeZone: TimeZone
    ) -> String {
        var output = [
            "Finding #" + String(number) + ": " + finding.kind.rawValue + " at "
                + localTime(finding.t, timeZone: timeZone)
                + ", app " + (finding.bundle ?? "-") + ", rule " + (finding.rule ?? "-"),
            "  " + finding.detail,
        ]
        let window = events.filter { $0.t >= finding.t - before && $0.t <= finding.t + after }
        for event in window {
            let marker = event.index == finding.eventIndex ? ">" : " "
            output.append(marker + " " + relative(event.t - finding.t) + "  " + describe(event.line))
        }
        return output.joined(separator: "\n") + "\n"
    }

    // MARK: Lines

    static func describe(_ line: TraceLine) -> String {
        switch line.type {
        case "key":
            let character = line.ch.map { "\"" + TraceText.visible($0) + "\"" } ?? "-"
            return [
                "key", line.ev ?? "?", TraceText.hex(line.kc ?? 0), TraceText.modifiers(line.flags), character,
                line.out ?? "",
            ].joined(separator: "  ")
        case "engine":
            var parts = ["engine", line.act ?? "?"]
            if line.isEdit {
                parts += ["delete " + String(line.del ?? 0), "insert \"" + TraceText.visible(line.ins ?? "") + "\""]
            }
            parts.append("token \"" + TraceText.visible(line.comp ?? "") + "\"")
            if let decision = line.dec { parts.append("commit " + decision) }
            return parts.joined(separator: "  ")
        case "boundary": return "boundary  " + (line.reason ?? "?") + (line.job.map { " / " + $0 } ?? "")
        case "job":
            return [
                "job " + String(line.seq ?? 0), line.kind ?? "?", line.strat ?? "?", line.out ?? "?",
                "delete " + String(line.delN ?? 0) + " insert " + String(line.insN ?? 0),
                String(line.posted ?? 0) + " events", microseconds(line.totalUs) + " total",
                microseconds(line.runUs) + " run",
            ].joined(separator: "  ")
        case "fallback":
            return "fallback job " + String(line.seq ?? 0) + "  " + (line.from ?? "?") + " -> " + (line.to ?? "?")
                + "  (" + (line.reason ?? "?") + ")"
        case "focus": return focus(line)
        case "readback":
            var parts = ["readback", line.reason ?? "?", line.status ?? "?"]
            if let text = line.text { parts.append("\"" + TraceText.visible(text) + "\"") }
            if let location = line.selLoc {
                parts.append("selection " + String(location) + "+" + String(line.selLen ?? 0))
            }
            return parts.joined(separator: "  ")
        case "marker": return "MARKER  " + (line.src ?? "")
        case "mode":
            return "mode  " + (line.mode ?? "?") + ((line.manual ?? false) ? " (manual)" : "") + "  "
                + (line.bundle ?? "-")
        case "settings":
            return "settings  "
                + (line.s ?? [:]).sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(
                    separator: " ")
        case "gap":
            let span = line.end.map { " " + microseconds(UInt64(max(0, $0 - line.t))) } ?? ""
            return "gap  " + (line.reason ?? "?") + span
                + (line.dropped.map { "  " + String($0) + " records lost" } ?? "")
        case "pause": return "pause  until " + (line.until.map { String($0) } ?? "?")
        case "file", "start":
            return line.type + "  launch " + (line.launch ?? "?") + (line.app.map { "  app " + $0 } ?? "")
        default: return line.type
        }
    }

    private static func focus(_ line: TraceLine) -> String {
        [
            "focus", line.bundle ?? "-", line.role ?? "-", line.subrole ?? "-", "rule " + (line.rule ?? "-"),
            "strategy " + (line.strat ?? "-"), "requireTextFocus " + (line.rtf ?? "-"), "ax " + (line.ax ?? "-"),
            "mode " + (line.mode ?? "-") + " (" + (line.modeSrc ?? "-") + ")", "context " + (line.ctx ?? "-"),
            (line.secure ?? false) ? "secure" : "", line.pause.map { "paused " + $0 } ?? "",
        ].filter { !$0.isEmpty }.joined(separator: "  ")
    }

    // MARK: Formatting

    /// `2026-11-14 09:41:03.120` in `timeZone`.
    static func localTime(_ microseconds: Int64, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let date = Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let millis = Int((microseconds / 1_000) % 1_000)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return pad(parts.year, 4) + "-" + pad(parts.month, 2) + "-" + pad(parts.day, 2) + " " + pad(parts.hour, 2) + ":"
            + pad(parts.minute, 2) + ":" + pad(parts.second, 2) + "." + pad(millis, 3)
    }

    /// `-1.234 s`, `+0.250 s`.
    static func relative(_ microseconds: Int64) -> String {
        let sign = microseconds < 0 ? "-" : "+"
        return sign + String(TraceText.seconds(UInt64(abs(microseconds))).dropFirst())
    }

    private static func microseconds(_ value: UInt64?) -> String {
        guard let value else { return "?" }
        return value >= 1_000
            ? String(value / 1_000) + "." + String((value % 1_000) / 100) + " ms" : String(value) + " us"
    }

    private static func apps(_ events: [TraceEvent]) -> String {
        var context = TraceContext()
        var counts: [String: Int] = [:]
        for event in events {
            context.apply(event.line)
            if event.line.isKeyDown { counts[context.bundle ?? "-", default: 0] += 1 }
        }
        let sorted = counts.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
        return sorted.isEmpty ? "none" : sorted.map { $0.key + " " + String($0.value) }.joined(separator: ", ")
    }

    private static func gaps(_ events: [TraceLine]) -> String {
        var counts: [String: Int] = [:]
        for line in events where line.type == "gap" {
            let key = line.reason ?? "?"
            counts[key, default: 0] += line.reason == "overflow" ? (line.dropped ?? 1) : 1
        }
        guard !counts.isEmpty else { return "none" }
        return counts.sorted { $0.key < $1.key }.map { $0.key + " " + String($0.value) }.joined(separator: ", ")
    }
}
