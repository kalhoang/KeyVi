// SPDX-License-Identifier: GPL-3.0-or-later
//
// Reads the dev recorder's folder (PLT-R904A): `YYYYMMDD-HH.jsonl` files in local time, selected by `--since` or
// `--date`, decoded line by line (an unreadable line is counted and skipped, never fatal), then ordered by time. The
// scanner only reads: it never writes, moves or deletes anything.

public import Foundation

/// Which files and lines a command looks at.
public enum TraceSelection: Sendable, Hashable {
    case all
    /// Lines of the last so many seconds before `now`.
    case since(seconds: Int64)
    /// One local calendar day, `YYYY-MM-DD`.
    case date(year: Int, month: Int, day: Int)
}

public struct TraceLoad: Sendable {
    public var files: [String]
    public var events: [TraceEvent]
    public var unreadableLines: Int
}

public enum TraceScanError: Error, Sendable, Hashable, CustomStringConvertible {
    case folderMissing(String)
    case usage(String)
    case noSuchFinding(Int, count: Int)

    public var description: String {
        switch self {
        case .folderMissing(let path): "no trace folder at \(path)"
        case .usage(let message): message
        case .noSuchFinding(let number, let count): "no finding #\(number) (this selection has \(count))"
        }
    }
}

public struct TraceStore: Sendable {
    public let directory: URL
    public let timeZone: TimeZone

    public init(directory: URL, timeZone: TimeZone) {
        self.directory = directory
        self.timeZone = timeZone
    }

    /// File names of the selection, oldest first.
    public func files(_ selection: TraceSelection, now: Date) throws -> [String] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw TraceScanError.folderMissing(directory.path) }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        return names.compactMap { name -> (String, Date)? in hourStart(of: name).map { (name, $0) } }
            .filter { _, start in includes(hourStart: start, selection, now: now) }
            .sorted { $0.0 < $1.0 }
            .map(\.0)
    }

    /// Line types a selection that starts inside a file keeps from before its start, the last of each type per file:
    /// the file header (format version, launch, engine identity), the settings and the focus in effect, so findings
    /// are attributed to the right app and the replay knows the settings and the engine build. They make no findings.
    static let contextTypes: Set<String> = ["file", "settings", "focus"]

    /// Every line of the selection in time order (ties keep file order).
    public func load(_ selection: TraceSelection, now: Date) throws -> TraceLoad {
        let names = try files(selection, now: now)
        let decoder = JSONDecoder()
        var lines: [(TraceLine, String)] = []
        var unreadable = 0
        let lower = lowerBound(selection, now: now)
        let upper = lower.map { _ in Int64((now.timeIntervalSince1970 * 1_000_000).rounded()) }
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name), options: .mappedIfSafe)
            var context: [String: TraceLine] = [:]
            for slice in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
                guard let line = try? decoder.decode(TraceLine.self, from: Data(slice)) else {
                    unreadable += 1
                    continue
                }
                if let lower, line.t < lower {
                    if Self.contextTypes.contains(line.type) { context[line.type] = line }
                    continue
                }
                if let upper, line.t > upper { continue }
                lines.append((line, name))
            }
            lines += context.values.sorted { $0.t < $1.t }.map { ($0, name) }
        }
        let ordered = lines.enumerated().sorted { ($0.element.0.t, $0.offset) < ($1.element.0.t, $1.offset) }
        let events = ordered.enumerated().map { index, item in
            TraceEvent(index: index, line: item.element.0, file: item.element.1)
        }
        return TraceLoad(files: names, events: events, unreadableLines: unreadable)
    }

    /// `YYYYMMDD-HH.jsonl` -> the start of that local hour.
    func hourStart(of name: String) -> Date? {
        guard name.hasSuffix(".jsonl") else { return nil }
        let stem = Array(name.dropLast(6))
        guard stem.count == 11, stem[8] == "-" else { return nil }
        let digits = stem.filter { $0 != "-" }
        guard digits.count == 10, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
        func number(_ from: Int, _ length: Int) -> Int? { Int(String(digits[from..<(from + length)])) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(year: number(0, 4), month: number(4, 2), day: number(6, 2), hour: number(8, 2))
        guard let date = calendar.date(from: parts), calendar.component(.hour, from: date) == parts.hour else {
            return nil
        }
        return date
    }

    private func includes(hourStart start: Date, _ selection: TraceSelection, now: Date) -> Bool {
        switch selection {
        case .all: return true
        case .since(let seconds):
            return start.addingTimeInterval(3_600) > now.addingTimeInterval(-Double(seconds)) && start <= now
        case .date(let year, let month, let day):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            return parts.year == year && parts.month == month && parts.day == day
        }
    }

    private func lowerBound(_ selection: TraceSelection, now: Date) -> Int64? {
        guard case .since(let seconds) = selection else { return nil }
        return Int64((now.timeIntervalSince1970 * 1_000_000).rounded()) - seconds * 1_000_000
    }
}
