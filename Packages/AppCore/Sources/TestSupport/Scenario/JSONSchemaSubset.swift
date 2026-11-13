// SPDX-License-Identifier: GPL-3.0-or-later
//
// Validator for the JSON Schema keywords the compat schemas use (draft 2020-12 subset): type, enum, const,
// required, properties, additionalProperties, items, minItems, maxItems, uniqueItems, minLength, maxLength,
// pattern, minimum, maximum, minProperties, maxProperties, allOf, anyOf, oneOf, not and local `$ref`.
// Unknown keywords are ignored, as the specification allows. Lets the Swift tests check every scenario file
// against compat/schema/scenario.schema.json itself, so the schema and the Swift types cannot drift apart.

public import AppModel
public import Foundation

public struct JSONSchemaSubset: Sendable {
    public struct Violation: Sendable, Hashable, CustomStringConvertible {
        /// JSON pointer of the offending value (`/setup/0/action`).
        public var path: String
        public var message: String
        public var description: String { (path.isEmpty ? "/" : path) + ": " + message }
    }

    private let root: JSONValue

    public init(schema: JSONValue) { root = schema }

    public init(schemaData: Data) throws {
        root = try JSONDecoder().decode(JSONValue.self, from: schemaData)
    }

    public func validate(_ instance: JSONValue) -> [Violation] {
        var violations: [Violation] = []
        check(instance, against: root, path: "", into: &violations)
        return violations
    }

    private func check(_ value: JSONValue, against schema: JSONValue, path: String, into out: inout [Violation]) {
        guard let keywords = schema.objectValue else { return }  // `true` / `{}`: anything goes
        if let reference = keywords["$ref"]?.stringValue {
            guard let target = resolve(reference) else {
                out.append(Violation(path: path, message: "unresolvable $ref " + reference))
                return
            }
            check(value, against: target, path: path, into: &out)
        }
        checkGeneric(value, keywords, path, &out)
        checkCombinators(value, keywords, path, &out)
        switch value {
        case .object(let object): checkObject(object, keywords, path, &out)
        case .array(let array): checkArray(array, keywords, path, &out)
        case .string(let string): checkString(string, keywords, path, &out)
        case .number(let number): checkNumber(number, keywords, path, &out)
        case .bool, .null: break
        }
    }

    private func checkGeneric(
        _ value: JSONValue, _ keywords: [String: JSONValue], _ path: String, _ out: inout [Violation]
    ) {
        if let type = keywords["type"] {
            let allowed = type.stringValue.map { [$0] } ?? Self.strings(type)
            if !allowed.contains(where: { Self.matches(value, type: $0) }) {
                out.append(Violation(path: path, message: "expected type " + allowed.joined(separator: " or ")))
            }
        }
        if case .array(let options)? = keywords["enum"], !options.contains(value) {
            out.append(Violation(path: path, message: "value not in enum"))
        }
        if let constant = keywords["const"], constant != value {
            out.append(Violation(path: path, message: "value differs from const"))
        }
    }

    private func checkCombinators(
        _ value: JSONValue, _ keywords: [String: JSONValue], _ path: String, _ out: inout [Violation]
    ) {
        let passes: (JSONValue) -> Bool = { schema in
            var nested: [Violation] = []
            check(value, against: schema, path: path, into: &nested)
            return nested.isEmpty
        }
        if case .array(let all)? = keywords["allOf"] {
            for schema in all { check(value, against: schema, path: path, into: &out) }
        }
        if case .array(let any)? = keywords["anyOf"], !any.contains(where: passes) {
            out.append(Violation(path: path, message: "matches none of anyOf"))
        }
        if case .array(let one)? = keywords["oneOf"], one.filter(passes).count != 1 {
            out.append(Violation(path: path, message: "must match exactly one of oneOf"))
        }
        if let negated = keywords["not"], passes(negated) {
            out.append(Violation(path: path, message: "matches a schema under not"))
        }
    }

    private func checkObject(
        _ object: [String: JSONValue], _ keywords: [String: JSONValue], _ path: String, _ out: inout [Violation]
    ) {
        for name in Self.strings(keywords["required"]) where object[name] == nil {
            out.append(Violation(path: path, message: "missing required property " + name))
        }
        if let minimum = keywords["minProperties"]?.intValue, object.count < minimum {
            out.append(Violation(path: path, message: "fewer than \(minimum) properties"))
        }
        if let maximum = keywords["maxProperties"]?.intValue, object.count > maximum {
            out.append(Violation(path: path, message: "more than \(maximum) properties"))
        }
        let properties = keywords["properties"]?.objectValue ?? [:]
        for (name, child) in object.sorted(by: { $0.key < $1.key }) {
            let childPath = path + "/" + name
            if let schema = properties[name] {
                check(child, against: schema, path: childPath, into: &out)
            } else if let additional = keywords["additionalProperties"] {
                if case .bool(false) = additional {
                    out.append(Violation(path: childPath, message: "property not allowed"))
                } else {
                    check(child, against: additional, path: childPath, into: &out)
                }
            }
        }
    }

    private func checkArray(
        _ array: [JSONValue], _ keywords: [String: JSONValue], _ path: String, _ out: inout [Violation]
    ) {
        if let minimum = keywords["minItems"]?.intValue, array.count < minimum {
            out.append(Violation(path: path, message: "fewer than \(minimum) items"))
        }
        if let maximum = keywords["maxItems"]?.intValue, array.count > maximum {
            out.append(Violation(path: path, message: "more than \(maximum) items"))
        }
        if case .bool(true)? = keywords["uniqueItems"], Set(array).count != array.count {
            out.append(Violation(path: path, message: "items are not unique"))
        }
        if let items = keywords["items"] {
            for (index, item) in array.enumerated() {
                check(item, against: items, path: path + "/" + String(index), into: &out)
            }
        }
    }

    private func checkString(
        _ string: String, _ keywords: [String: JSONValue], _ path: String, _ out: inout [Violation]
    ) {
        let length = string.unicodeScalars.count
        if let minimum = keywords["minLength"]?.intValue, length < minimum {
            out.append(Violation(path: path, message: "shorter than \(minimum)"))
        }
        if let maximum = keywords["maxLength"]?.intValue, length > maximum {
            out.append(Violation(path: path, message: "longer than \(maximum)"))
        }
        if let pattern = keywords["pattern"]?.stringValue {
            // JSON Schema patterns are unanchored searches (ECMA-262); the compat schemas anchor with ^ and $.
            guard let expression = try? NSRegularExpression(pattern: pattern) else {
                out.append(Violation(path: path, message: "invalid pattern " + pattern))
                return
            }
            let range = NSRange(string.startIndex..<string.endIndex, in: string)
            if expression.firstMatch(in: string, range: range) == nil {
                out.append(Violation(path: path, message: "does not match " + pattern))
            }
        }
    }

    private func checkNumber(
        _ number: Double, _ keywords: [String: JSONValue], _ path: String, _ out: inout [Violation]
    ) {
        if case .number(let minimum)? = keywords["minimum"], number < minimum {
            out.append(Violation(path: path, message: "below minimum"))
        }
        if case .number(let maximum)? = keywords["maximum"], number > maximum {
            out.append(Violation(path: path, message: "above maximum"))
        }
    }

    /// Local references only: `#`, `#/$defs/name`, `#/definitions/name`, any JSON pointer into the root.
    private func resolve(_ reference: String) -> JSONValue? {
        guard reference.hasPrefix("#") else { return nil }
        var node = root
        for token in reference.dropFirst().split(separator: "/") {
            let key = token.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = node[key] else { return nil }
            node = next
        }
        return node
    }

    private static func matches(_ value: JSONValue, type: String) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null),
            ("number", .number):
            return true
        case ("integer", .number(let number)): return number == number.rounded()
        default: return false
        }
    }

    private static func strings(_ value: JSONValue?) -> [String] {
        guard case .array(let items)? = value else { return [] }
        return items.compactMap(\.stringValue)
    }
}
