// SPDX-License-Identifier: MPL-2.0

/// An error in a corpus file.
public struct FixtureError: Error, Sendable, Hashable, CustomStringConvertible {
    public let file: String
    public let line: Int
    public let reason: String

    public init(file: String, line: Int, reason: String) {
        self.file = file
        self.line = line
        self.reason = reason
    }

    public var description: String { "\(file):\(line): \(reason)" }
}

/// A parsed tab-separated corpus file as written by `Scripts/extract-spec-examples.py`: lines
/// starting with `#` are comments, the first other line is the header, fields use the escapes
/// `\t`, `\n`, `\r`, `\\` and `\s` (a space).
public struct TSVTable: Sendable {
    public struct Row: Sendable {
        /// 1-based line number in the file.
        public let line: Int
        let fields: [String: String]

        /// The value of `column`; a column missing at the end of the line is empty.
        public subscript(_ column: String) -> String { fields[column] ?? "" }
    }

    public let name: String
    public let header: [String]
    public let rows: [Row]

    public init(name: String, text: String) throws {
        self.name = name
        var header: [String]?
        var rows: [Row] = []
        var lineNumber = 0
        // "\r\n" is one Character in Swift, so both line endings are separators.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            lineNumber += 1
            if line.isEmpty || line.hasPrefix("#") { continue }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let columns = header else {
                header = fields
                continue
            }
            guard fields.count <= columns.count else {
                throw FixtureError(
                    file: name, line: lineNumber, reason: "\(fields.count) fields, header has \(columns.count)")
            }
            var values: [String: String] = [:]
            for (index, field) in fields.enumerated() {
                values[columns[index]] = try Self.unescape(field, file: name, line: lineNumber)
            }
            rows.append(Row(line: lineNumber, fields: values))
        }
        guard let header else { throw FixtureError(file: name, line: lineNumber, reason: "no header line") }
        self.header = header
        self.rows = rows
    }

    static func unescape(_ field: String, file: String, line: Int) throws -> String {
        guard field.contains("\\") else { return field }
        var result = ""
        var iterator = field.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            switch iterator.next() {
            case "t": result.append("\t")
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "s": result.append(" ")
            case "\\": result.append("\\")
            default: throw FixtureError(file: file, line: line, reason: "bad escape in \(field)")
            }
        }
        return result
    }
}
