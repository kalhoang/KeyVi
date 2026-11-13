// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The JSON Schema subset used to validate compat/scenarios against compat/schema/scenario.schema.json.

import AppModel
import Foundation
import Testing
@testable import TestSupport

@Suite struct JSONSchemaSubsetTests {
    private func json(_ text: String) -> JSONValue { try! JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) }

    private func violations(_ schema: String, _ instance: String) -> [String] {
        JSONSchemaSubset(schema: json(schema)).validate(json(instance)).map(\.description)
    }

    @Test func typeKeyword() {
        #expect(violations(#"{"type":"string"}"#, #""a""#) == [])
        #expect(violations(#"{"type":"string"}"#, "1") == ["/: expected type string"])
        #expect(violations(#"{"type":["string","null"]}"#, "null") == [])
        #expect(violations(#"{"type":"integer"}"#, "2") == [])
        #expect(violations(#"{"type":"integer"}"#, "2.5") == ["/: expected type integer"])
        #expect(violations(#"{"type":"boolean"}"#, "true") == [])
        #expect(violations(#"{"type":"boolean"}"#, "1") == ["/: expected type boolean"])
        #expect(violations(#"{"type":"array"}"#, "{}") == ["/: expected type array"])
        #expect(violations(#"{"type":"number"}"#, "1.5") == [])
    }

    @Test func enumAndConst() {
        #expect(violations(#"{"enum":["a","b"]}"#, #""b""#) == [])
        #expect(violations(#"{"enum":["a","b"]}"#, #""c""#) == ["/: value not in enum"])
        #expect(violations(#"{"const":1}"#, "1") == [])
        #expect(violations(#"{"const":1}"#, "true") == ["/: value differs from const"])
    }

    @Test func objectKeywords() {
        let schema = #"""
            {"type":"object","required":["id"],"additionalProperties":false,"minProperties":1,"maxProperties":2,
             "properties":{"id":{"type":"string"},"n":{"type":"number"}}}
            """#
        #expect(violations(schema, #"{"id":"x"}"#) == [])
        #expect(violations(schema, #"{"n":1}"#) == ["/: missing required property id"])
        #expect(violations(schema, #"{"id":"x","z":1}"#) == ["/z: property not allowed"])
        #expect(violations(schema, "{}").contains("/: fewer than 1 properties"))
        #expect(violations(schema, #"{"id":"x","n":1,"z":2}"#).contains("/: more than 2 properties"))
        #expect(violations(#"{"additionalProperties":{"type":"number"}}"#, #"{"a":"x"}"#) == ["/a: expected type number"])
    }

    @Test func arrayKeywords() {
        let schema = #"{"type":"array","minItems":1,"maxItems":2,"uniqueItems":true,"items":{"type":"string"}}"#
        #expect(violations(schema, #"["a"]"#) == [])
        #expect(violations(schema, "[]") == ["/: fewer than 1 items"])
        #expect(violations(schema, #"["a","b","c"]"#) == ["/: more than 2 items"])
        #expect(violations(schema, #"["a","a"]"#) == ["/: items are not unique"])
        #expect(violations(schema, #"["a",1]"#) == ["/1: expected type string"])
    }

    @Test func stringKeywords() {
        #expect(violations(#"{"minLength":2,"maxLength":3}"#, #""ab""#) == [])
        #expect(violations(#"{"minLength":2}"#, #""a""#) == ["/: shorter than 2"])
        #expect(violations(#"{"maxLength":1}"#, #""ab""#) == ["/: longer than 1"])
        #expect(violations(#"{"pattern":"^[a-z]+$"}"#, #""abc""#) == [])
        #expect(violations(#"{"pattern":"^[a-z]+$"}"#, #""aBc""#) == ["/: does not match ^[a-z]+$"])
        #expect(violations(#"{"pattern":"b"}"#, #""abc""#) == [])  // unanchored search, as ECMA-262
        #expect(violations(#"{"pattern":"("}"#, #""a""#) == ["/: invalid pattern ("])
    }

    @Test func numberKeywords() {
        #expect(violations(#"{"minimum":1,"maximum":3}"#, "2") == [])
        #expect(violations(#"{"minimum":1}"#, "0") == ["/: below minimum"])
        #expect(violations(#"{"maximum":1}"#, "2") == ["/: above maximum"])
    }

    @Test func combinators() {
        let anyOf = #"{"anyOf":[{"required":["a"]},{"required":["b"]}]}"#
        #expect(violations(anyOf, #"{"b":1}"#) == [])
        #expect(violations(anyOf, "{}") == ["/: matches none of anyOf"])
        let oneOf = #"{"oneOf":[{"type":"string"},{"maxLength":1}]}"#
        #expect(violations(oneOf, #""ab""#) == [])
        #expect(violations(oneOf, #""a""#) == ["/: must match exactly one of oneOf"])
        #expect(violations(#"{"allOf":[{"type":"string"},{"minLength":2}]}"#, #""a""#) == ["/: shorter than 2"])
        #expect(violations(#"{"not":{"type":"null"}}"#, "null") == ["/: matches a schema under not"])
    }

    @Test func localReferences() {
        let schema = #"""
            {"$defs":{"id":{"type":"string","pattern":"^x"},"a/b":{"type":"number"}},
             "properties":{"id":{"$ref":"#/$defs/id"},"n":{"$ref":"#/$defs/a~1b"},"bad":{"$ref":"other.json"}}}
            """#
        #expect(violations(schema, #"{"id":"xy","n":1}"#) == [])
        #expect(violations(schema, #"{"id":"y"}"#) == ["/id: does not match ^x"])
        #expect(violations(schema, #"{"n":"s"}"#) == ["/n: expected type number"])
        #expect(violations(schema, #"{"bad":1}"#) == ["/bad: unresolvable $ref other.json"])
        #expect(violations(##"{"properties":{"a":{"$ref":"#/missing"}}}"##, #"{"a":1}"#) == ["/a: unresolvable $ref #/missing"])
    }

    @Test func booleanSchemasAndDataInit() throws {
        #expect(violations("true", "1") == [])
        let validator = try JSONSchemaSubset(schemaData: Data(#"{"type":"string"}"#.utf8))
        #expect(validator.validate(.number(1)).count == 1)
    }

    /// The repository schema validates both the current `minProperties` form and the `anyOf` form W1-C uses.
    @Test func repositoryScenarioSchemaRejectsEmptyExpectations() throws {
        let schemaURL = repositoryRoot.appendingPathComponent("compat/schema/scenario.schema.json")
        let validator = try JSONSchemaSubset(schemaData: Data(contentsOf: schemaURL))
        let valid = json(scenarioJSON(id: "s"))
        #expect(validator.validate(valid) == [])
        let empty = json(scenarioJSON(id: "s").replacingOccurrences(of: #"{"text":"đi"}"#, with: "{}"))
        #expect(!validator.validate(empty).isEmpty)
        let badKey = json(scenarioJSON(id: "s", keys: #"["đ"]"#))
        #expect(validator.validate(badKey).map(\.path) == ["/keys/0"])
    }
}
