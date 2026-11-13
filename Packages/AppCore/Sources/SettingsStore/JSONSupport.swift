// SPDX-License-Identifier: LicenseRef-App-Pending
//
// JSON plumbing shared by the four documents, export/import and the macro importer. Every byte stream read from
// disk or from a user-chosen file goes through `JSONSupport.parseValue`, which bounds nesting with a byte scan
// before Foundation recurses (PLT-R912): the utility queue runs on a 512 KB GCD stack, and a recursive decode of
// a 256-deep document overflows it. Our own documents nest at most about ten levels.

internal import AppModel
internal import Foundation

/// Why a byte stream is not a usable JSON document.
enum JSONParseFailure: Error, Sendable, Hashable {
    case empty
    case tooDeeplyNested(limit: Int)
    case invalidJSON
    case notAnObject
}

enum JSONSupport {
    static let maxNestingDepth = 64
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    static func parseValue(_ data: Data) throws(JSONParseFailure) -> JSONValue {
        let body = data.starts(with: utf8BOM) ? data.dropFirst(utf8BOM.count) : data[...]
        guard body.contains(where: { !isJSONWhitespace($0) }) else { throw .empty }
        guard !exceedsNesting(body, limit: maxNestingDepth) else { throw .tooDeeplyNested(limit: maxNestingDepth) }
        do {
            return try JSONDecoder().decode(JSONValue.self, from: Data(body))
        } catch {
            throw .invalidJSON
        }
    }

    static func parseObject(_ data: Data) throws(JSONParseFailure) -> [String: JSONValue] {
        guard case .object(let object) = try parseValue(data) else { throw .notAnObject }
        return object
    }

    /// True when brackets outside string literals nest deeper than `limit`. Stops at the first excess.
    static func exceedsNesting(_ bytes: some Sequence<UInt8>, limit: Int) -> Bool {
        var depth = 0
        var inString = false
        var escaped = false
        for byte in bytes {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == UInt8(ascii: "\\") {
                    escaped = true
                } else if byte == UInt8(ascii: "\"") {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth > limit { return true }
            case UInt8(ascii: "]"), UInt8(ascii: "}"): depth -= 1
            default: break
            }
        }
        return false
    }

    /// Pretty, key-sorted UTF-8 so files diff well and writes are deterministic.
    static func serialize(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    /// Typed value from a JSON tree; nil when the tree does not decode as `T`.
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) -> T? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    /// JSON tree of a typed value; nil only for values JSON cannot represent (non-finite numbers).
    static func encode<T: Encodable>(_ value: T) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func isJSONWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }
}

/// Timestamps written into files and file names. All UTC, second precision, so a value survives a write and a
/// read unchanged.
enum StorageTimestamp {
    /// UTC. `TimeZone.gmt` needs macOS 13 (PLT-R106: the floor is macOS 12).
    private static let utc = TimeZone(secondsFromGMT: 0)!

    /// `2026-11-13T09:00:00Z` (rule override `createdAt`, export `exportedAt`).
    static func iso(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(timeZone: utc))
    }

    static func date(iso string: String) -> Date? {
        if let date = try? Date(string, strategy: Date.ISO8601FormatStyle(timeZone: utc)) { return date }
        return try? Date(string, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: utc))
    }

    /// `20261113T090000Z`: sortable and safe in file names (backups, quarantined files).
    static func compact(_ date: Date) -> String {
        date.formatted(compactStyle)
    }

    static func date(compact string: String) -> Date? {
        try? Date(string, strategy: compactStyle)
    }

    /// Drops sub-second precision so an in-memory date equals the same date after a write and a read.
    static func wholeSeconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
    }

    private static let compactStyle = Date.ISO8601FormatStyle(
        dateSeparator: .omitted, dateTimeSeparator: .standard, timeSeparator: .omitted, timeZone: utc)
}
