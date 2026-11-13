// SPDX-License-Identifier: GPL-3.0-or-later
//
// The machine-parseable diagnostics block (QA-R44), format v1 of docs/decisions/0501-diagnostics-block-format.md:
// a fenced block (info string `text`), the header `<slug>-diagnostics v1`, then `key: value` lines, at most 200
// lines in total. Every `DiagnosticsBlockKey` is always present (empty value when unknown) so the shape is
// stable; the other ADR 0501 keys follow. `scripts/parse-diagnostics.py` reads the same format.

internal import AppModel
internal import Foundation

enum IssueBlock {
    static let maximumLines = 200
    static let fence = "```"
    private static let headerMarker = "-diagnostics v"

    static func render(_ report: DiagnosticsReport) -> String {
        let fields = self.fields(report)
        var lines = [fence + "text", header(slug: report.app.slug)]
        lines += fields.map { $0.value.isEmpty ? $0.key + ":" : $0.key + ": " + $0.value }
        lines.append(fence)
        return lines.joined(separator: "\n") + "\n"
    }

    /// `<slug>-diagnostics v1`. The slug comes from the bundle (`AppIdentity.slug`); a value outside
    /// `[a-z][a-z0-9-]*` is normalised so the header always parses.
    static func header(slug: String) -> String {
        let cleaned = String(String.UnicodeScalarView(slug.lowercased().unicodeScalars.filter(isSlugScalar)))
        let usable = cleaned.first.map { ("a"..."z").contains($0) } == true ? cleaned : "app" + cleaned
        return usable + headerMarker + String(DiagnosticsReport.formatVersion)
    }

    /// The ordered `key: value` pairs, health events last and trimmed so the block stays within 200 lines.
    static func fields(_ report: DiagnosticsReport) -> [(key: String, value: String)] {
        var list = BlockFieldList()
        BlockFields.addReportAndApp(report, to: &list)
        BlockFields.addHostAndInput(report, to: &list)
        BlockFields.addFocusAndRule(report, to: &list)
        BlockFields.addSettings(report, to: &list)
        BlockFields.addLatency(report, to: &list)
        list.add(
            "conflicts", report.conflictingInputApps.isEmpty ? "none" : BlockFields.list(report.conflictingInputApps))
        // Fences and header take three lines, `health.events` one more.
        let budget = max(0, maximumLines - 4 - list.pairs.count)
        let events = report.healthEvents.suffix(budget)
        list.add("health.events", String(events.count))
        for (offset, event) in events.enumerated() {
            let number = offset + 1
            list.add("health.event." + (number < 10 ? "0" : "") + String(number), event.summaryLine)
        }
        return list.pairs
    }

    // MARK: Parsing (ADR 0501 rules 1 and 2)

    static func parse(_ text: String) -> [String: String]? {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard let headerIndex = lines.firstIndex(where: { headerVersion($0) != nil }),
            headerVersion(lines[headerIndex]) == DiagnosticsReport.formatVersion
        else { return nil }
        var fields: [String: String] = [:]
        for raw in lines[(headerIndex + 1)...] {
            if isFence(raw) { break }
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let pair = keyValue(line), fields[pair.key] == nil else {
                continue
            }
            fields[pair.key] = pair.value
        }
        return fields
    }

    /// The format version of a header line, or nil when the line is not a header. Any slug of the shape
    /// `[a-z][a-z0-9-]*` is accepted so blocks from builds made before a rename still parse.
    static func headerVersion(_ raw: Substring) -> Int? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard let marker = line.range(of: headerMarker, options: .backwards) else { return nil }
        let slug = line[..<marker.lowerBound]
        let digits = line[marker.upperBound...]
        guard let first = slug.unicodeScalars.first, ("a"..."z").contains(first),
            slug.unicodeScalars.allSatisfy(isSlugScalar), (1...3).contains(digits.count),
            digits.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 })
        else { return nil }
        return Int(digits)
    }

    private static func isFence(_ raw: Substring) -> Bool {
        var line = raw[...]
        var spaces = 0
        while spaces < 3, line.first == " " {
            line = line.dropFirst()
            spaces += 1
        }
        return line.hasPrefix("```") || line.hasPrefix("~~~")
    }

    /// `key: value` with a key matching `[a-z][A-Za-z0-9]*(\.[A-Za-z0-9]+)*`; the value is trimmed.
    private static func keyValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespaces)
        guard isKey(key) else { return nil }
        return (key, line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
    }

    static func isKey(_ key: String) -> Bool {
        let segments = key.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = segments.first?.unicodeScalars.first, ("a"..."z").contains(first) else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty
                && segment.unicodeScalars.allSatisfy {
                    $0.isASCII && $0.properties.isAlphabetic || ("0"..."9").contains($0)
                }
        }
    }

    private static func isSlugScalar(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) || scalar == "-"
    }
}

/// Ordered pairs with value sanitising (single line, no leading fence characters, ADR 0501 rule 2).
struct BlockFieldList {
    private(set) var pairs: [(key: String, value: String)] = []

    mutating func add(_ key: DiagnosticsBlockKey, _ value: String?) { add(key.rawValue, value) }

    mutating func add(_ key: String, _ value: String?, maxLength: Int = 200) {
        pairs.append((key, MetadataText.singleLine(value ?? "", maxLength: maxLength)))
    }
}
