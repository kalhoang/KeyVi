// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Test-only JSON Schema validator for the keyword subset that scripts/lib/jsonschema_lite.py supports (and that
// compat/schema/*.json are restricted to): type, enum, const, required, properties, additionalProperties,
// patternProperties, items, minItems, maxItems, uniqueItems, minLength, maxLength, pattern, minimum, maximum,
// allOf, anyOf, oneOf, not, if/then/else and local $ref. Same semantics, so Swift and CI agree.

import AppModel
import Foundation

struct JSONSchemaSubset {
    let root: JSONValue

    init(_ root: JSONValue) {
        self.root = root
    }

    func errors(_ value: JSONValue, at pointer: String = "#") -> [String] {
        errors(value, schema: resolve(pointer), path: "$")
    }

    private func resolve(_ pointer: String) -> JSONValue {
        pointer.dropFirst().split(separator: "/").reduce(root) { node, part in node[String(part)] ?? .null }
    }

    private func errors(_ value: JSONValue, schema: JSONValue, path: String) -> [String] {
        guard case .object(let keywords) = schema else {
            return schema == .bool(false) ? [path + ": not allowed"] : []
        }
        var out: [String] = []
        if let ref = keywords["$ref"]?.stringValue { out += errors(value, schema: resolve(ref), path: path) }
        out += typeErrors(value, keywords, path) + combinatorErrors(value, keywords, path)
        switch value {
        case .object(let object): out += objectErrors(object, keywords, path)
        case .array(let items): out += arrayErrors(items, keywords, path)
        case .string(let text): out += stringErrors(text, keywords, path)
        case .number(let number): out += numberErrors(number, keywords, path)
        default: break
        }
        return out
    }

    private func typeErrors(_ value: JSONValue, _ keywords: [String: JSONValue], _ path: String) -> [String] {
        var out: [String] = []
        if let type = keywords["type"] {
            let names: [String] =
                if case .array(let list) = type { list.compactMap(\.stringValue) } else { [type.stringValue ?? ""] }
            if !names.contains(where: { Self.has(type: $0, value) }) { out.append(path + ": wrong type") }
        }
        if case .array(let allowed) = keywords["enum"], !allowed.contains(value) { out.append(path + ": not in enum") }
        if let constant = keywords["const"], constant != value { out.append(path + ": not the constant") }
        return out
    }

    private static func has(type: String, _ value: JSONValue) -> Bool {
        switch (type, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null),
            ("number", .number):
            true
        case ("integer", .number(let number)): number == number.rounded()
        default: false
        }
    }

    private func combinatorErrors(_ value: JSONValue, _ keywords: [String: JSONValue], _ path: String) -> [String] {
        var out: [String] = []
        if case .array(let all) = keywords["allOf"] { out += all.flatMap { errors(value, schema: $0, path: path) } }
        if case .array(let any) = keywords["anyOf"],
            !any.contains(where: { errors(value, schema: $0, path: path).isEmpty })
        {
            out.append(path + ": anyOf")
        }
        if case .array(let one) = keywords["oneOf"],
            one.filter({ errors(value, schema: $0, path: path).isEmpty }).count != 1
        {
            out.append(path + ": oneOf")
        }
        if let not = keywords["not"], errors(value, schema: not, path: path).isEmpty { out.append(path + ": not") }
        if let condition = keywords["if"] {
            let branch = errors(value, schema: condition, path: path).isEmpty ? "then" : "else"
            if let schema = keywords[branch] { out += errors(value, schema: schema, path: path) }
        }
        return out
    }

    private func objectErrors(_ object: [String: JSONValue], _ keywords: [String: JSONValue], _ path: String)
        -> [String]
    {
        var out: [String] = []
        if case .array(let required) = keywords["required"] {
            out += required.compactMap(\.stringValue).filter { object[$0] == nil }.map { path + ": missing " + $0 }
        }
        let properties = keywords["properties"]?.objectValue ?? [:]
        let patterns = keywords["patternProperties"]?.objectValue ?? [:]
        for (key, item) in object.sorted(by: { $0.key < $1.key }) {
            let child = path + "." + key
            var matched = false
            if let schema = properties[key] {
                matched = true
                out += errors(item, schema: schema, path: child)
            }
            for (pattern, schema) in patterns where key.range(of: pattern, options: .regularExpression) != nil {
                matched = true
                out += errors(item, schema: schema, path: child)
            }
            if !matched, let extra = keywords["additionalProperties"] {
                out += extra == .bool(false) ? [path + ": unexpected " + key] : errors(item, schema: extra, path: child)
            }
        }
        return out
    }

    private func arrayErrors(_ items: [JSONValue], _ keywords: [String: JSONValue], _ path: String) -> [String] {
        var out: [String] = []
        if let schema = keywords["items"] {
            for (index, item) in items.enumerated() {
                out += errors(item, schema: schema, path: path + "[" + String(index) + "]")
            }
        }
        if let minimum = keywords["minItems"]?.intValue, items.count < minimum { out.append(path + ": minItems") }
        if let maximum = keywords["maxItems"]?.intValue, items.count > maximum { out.append(path + ": maxItems") }
        if keywords["uniqueItems"] == .bool(true), Set(items).count != items.count {
            out.append(path + ": uniqueItems")
        }
        return out
    }

    private func stringErrors(_ text: String, _ keywords: [String: JSONValue], _ path: String) -> [String] {
        var out: [String] = []
        let length = text.unicodeScalars.count
        if let minimum = keywords["minLength"]?.intValue, length < minimum { out.append(path + ": minLength") }
        if let maximum = keywords["maxLength"]?.intValue, length > maximum { out.append(path + ": maxLength") }
        if let pattern = keywords["pattern"]?.stringValue, text.range(of: pattern, options: .regularExpression) == nil {
            out.append(path + ": pattern")
        }
        return out
    }

    private func numberErrors(_ number: Double, _ keywords: [String: JSONValue], _ path: String) -> [String] {
        var out: [String] = []
        if case .number(let minimum) = keywords["minimum"], number < minimum { out.append(path + ": minimum") }
        if case .number(let maximum) = keywords["maximum"], number > maximum { out.append(path + ": maximum") }
        return out
    }
}
