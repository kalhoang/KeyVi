// SPDX-License-Identifier: GPL-3.0-or-later
//
// `trace-scan`, the dev recorder's offline reader (PLT-R904A, ADR 0007). Reads a folder of dev trace files and
// prints to standard output only; it never writes, moves or deletes a file. scripts/dev/trace-scan.sh passes the dev
// build's folder as `--dir`; the brand-dependent default lives there, never in Swift.
//
//   trace-scan summary --dir PATH [--since 2h | --date YYYY-MM-DD] [--no-replay]
//   trace-scan show N --dir PATH [--since ... | --date ...] [--before 30s] [--after 10s] [--no-replay]
//
// `show N` numbers findings exactly as `summary` does for the same selection, so pass the same `--since` or
// `--date`. `--now` (ISO 8601) pins the clock `--since` counts from, for tests and reproducible reads.

public import Foundation

public enum TraceScanCommand {
    public struct Result: Sendable, Equatable {
        public var output: String
        public var error: String
        public var exitCode: Int32
    }

    public static let usage = """
        Usage:
          trace-scan summary --dir PATH [--since 2h | --date YYYY-MM-DD] [--no-replay]
          trace-scan show N --dir PATH [--since 2h | --date YYYY-MM-DD] [--before 30s] [--after 10s] [--no-replay]

        summary  metadata only (files, apps, counts, gaps) and the numbered findings
        show N   the excerpt around finding N (same selection as the summary that numbered it)
        Durations: 500ms, 30s, 5m, 2h, 7d. Reads only; never writes anywhere but standard output.

        """

    struct Options {
        var command = ""
        var number: Int?
        var directory: URL?
        var selection = TraceSelection.all
        var before: Int64 = 30_000_000
        var after: Int64 = 10_000_000
        var now: Date?
        var replay = true
    }

    /// Runs one command. `makeReplay` loads the bundled lexicons (only when replay is on).
    public static func run(
        _ arguments: [String], now: Date, timeZone: TimeZone,
        makeReplay: () throws -> ReplayEngineFactory? = { try ReplayEngineFactory.bundled() }
    ) -> Result {
        do {
            let options = try parse(arguments, timeZone: timeZone)
            if options.command == "help" { return Result(output: usage, error: "", exitCode: 0) }
            guard let directory = options.directory else { throw TraceScanError.usage("--dir PATH is required") }
            let store = TraceStore(directory: directory, timeZone: timeZone)
            let load = try store.load(options.selection, now: options.now ?? now)
            let replay = options.replay ? try makeReplay() : nil
            let findings = FindingDetector.findings(in: load.events, replay: replay)
            switch options.command {
            case "summary":
                let text = TraceRendering.summary(load, findings: findings, directory: directory, timeZone: timeZone)
                return Result(output: text, error: "", exitCode: 0)
            default:
                let number = options.number ?? 0
                guard number >= 1, number <= findings.count else {
                    throw TraceScanError.noSuchFinding(number, count: findings.count)
                }
                let text = TraceRendering.show(
                    findings[number - 1], number: number, events: load.events, before: options.before,
                    after: options.after, timeZone: timeZone)
                return Result(output: text, error: "", exitCode: 0)
            }
        } catch TraceScanError.usage(let message) {
            return Result(output: "", error: "trace-scan: " + message + "\n\n" + usage, exitCode: 2)
        } catch let error as TraceScanError {
            return Result(output: "", error: "trace-scan: " + error.description + "\n", exitCode: 1)
        } catch {
            return Result(output: "", error: "trace-scan: " + String(describing: error) + "\n", exitCode: 1)
        }
    }

    static func parse(_ arguments: [String], timeZone: TimeZone) throws -> Options {
        var options = Options()
        var remaining = arguments[...]
        guard let command = remaining.popFirst() else { throw TraceScanError.usage("missing command") }
        switch command {
        case "help", "-h", "--help":
            options.command = "help"
            return options
        case "summary": options.command = command
        case "show":
            options.command = command
            guard let text = remaining.popFirst(), let number = Int(text) else {
                throw TraceScanError.usage("show needs a finding number")
            }
            options.number = number
        default: throw TraceScanError.usage("unknown command " + command)
        }
        var sawSince = false
        var sawDate = false
        while let flag = remaining.popFirst() {
            if flag == "--no-replay" {
                options.replay = false
                continue
            }
            guard let value = remaining.popFirst() else { throw TraceScanError.usage(flag + " needs a value") }
            switch flag {
            case "--dir": options.directory = URL(fileURLWithPath: value, isDirectory: true)
            case "--since":
                options.selection = .since(seconds: try duration(value) / 1_000_000)
                sawSince = true
            case "--date":
                options.selection = try date(value)
                sawDate = true
            case "--before": options.before = try duration(value)
            case "--after": options.after = try duration(value)
            case "--now":
                guard let now = ISO8601DateFormatter().date(from: value) else {
                    throw TraceScanError.usage("--now takes an ISO 8601 time")
                }
                options.now = now
            default: throw TraceScanError.usage("unknown option " + flag)
            }
        }
        if sawSince && sawDate { throw TraceScanError.usage("use --since or --date, not both") }
        return options
    }

    /// `500ms`, `30s`, `5m`, `2h`, `7d` in microseconds.
    static func duration(_ text: String) throws -> Int64 {
        let units: [(String, Int64)] = [
            ("ms", 1_000), ("s", 1_000_000), ("m", 60_000_000), ("h", 3_600_000_000), ("d", 86_400_000_000),
        ]
        for (suffix, scale) in units where text.hasSuffix(suffix) {
            let digits = text.dropLast(suffix.count)
            if !digits.isEmpty, digits.allSatisfy(\.isASCII), let value = Int64(digits), value >= 0 {
                return value * scale
            }
        }
        throw TraceScanError.usage("not a duration: " + text)
    }

    /// `YYYY-MM-DD`.
    static func date(_ text: String) throws -> TraceSelection {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.map(\.count) == [4, 2, 2], let year = Int(parts[0]), let month = Int(parts[1]),
            let day = Int(parts[2]), (1...12).contains(month), (1...31).contains(day)
        else { throw TraceScanError.usage("--date takes YYYY-MM-DD") }
        return .date(year: year, month: month, day: day)
    }
}
