// SPDX-License-Identifier: GPL-3.0-or-later

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct SchemaCodingTests {
    /// Acceptance: compat/rules.json and compat/matrix.json validate against the JSON Schemas and decode with the
    /// Swift types, both directions (QA-R17, PLT-R503).
    @Test func seededFilesValidateAgainstSchemasAndRoundTripThroughSwiftTypes() throws {
        let rulesSchema = JSONSchemaSubset(try RepoFiles.json(RepoFiles.schema("rules.schema.json")))
        let matrixSchema = JSONSchemaSubset(try RepoFiles.json(RepoFiles.schema("matrix.schema.json")))
        #expect(rulesSchema.errors(try RepoFiles.json(RepoFiles.rules)).isEmpty)
        #expect(matrixSchema.errors(try RepoFiles.json(RepoFiles.matrix)).isEmpty)

        let rules = try Build.seededDocument()
        let matrix = try Build.seededMatrix()
        let rulesEcho = try JSONEncoder().encode(rules)
        let matrixEcho = try JSONEncoder().encode(matrix)
        #expect(rulesSchema.errors(try JSONDecoder().decode(JSONValue.self, from: rulesEcho)).isEmpty)
        #expect(matrixSchema.errors(try JSONDecoder().decode(JSONValue.self, from: matrixEcho)).isEmpty)
        #expect(try RulesLoader.decode(rulesEcho) == rules)
        #expect(try MatrixLoader.decode(matrixEcho) == matrix)
    }

    @Test func schemaRejectsTheCasesTheCIValidatorMustCatch() throws {
        let schema = JSONSchemaSubset(try RepoFiles.json(RepoFiles.schema("rules.schema.json")))
        let base = try RepoFiles.json(RepoFiles.rules)
        let mutations: [(String, (inout [String: JSONValue]) -> Void)] = [
            ("titlePattern without bundleIds", { rule in Self.setMatch(&rule, "titlePattern", .string("x")) }),
            ("no passing tested entry", { rule in Self.setTestedResult(&rule, "fail") }),
            ("delay over the cap", { rule in Self.setParam(&rule, "interEventDelayUs", .number(50_001)) }),
            ("unknown key", { rule in rule["extra"] = .bool(true) }),
            (
                "empty title pattern",
                { rule in
                    Self.setMatch(&rule, "bundleIds", .array([.string("com.a.b")]))
                    Self.setMatch(&rule, "titlePattern", .string(""))
                }
            ),
        ]
        for (label, mutate) in mutations {
            let errors = schema.errors(Self.mutatingFirstRule(base, mutate))
            #expect(!errors.isEmpty, "schema accepted: \(label)")
        }
    }

    @Test func userOverrideProducedBySwiftMatchesTheOverrideSchema() throws {
        let schema = JSONSchemaSubset(try RepoFiles.json(RepoFiles.schema("rules.schema.json")))
        let override = Build.userRule(
            "user.terminal.1",
            match: RuleMatch(bundleIds: [bundleKey("com.apple.Terminal")], ax: AXMatch(roles: ["AXTextArea"])),
            action: RuleAction(strategy: .backspaceReplace, params: StrategyParams(interEventDelayUs: 5_000)))
        let json = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(override))
        #expect(schema.errors(json, at: "#/$defs/userOverrideRule").isEmpty)
        var withTitle = override
        withTitle.match.titlePattern = "Inbox"
        let titled = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(withTitle))
        #expect(!schema.errors(titled, at: "#/$defs/userOverrideRule").isEmpty)  // PLT-R502
        var grouped = override
        grouped.match.bundleIds = nil
        grouped.match.bundleGroup = "terminals"
        let groupedJSON = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(grouped))
        #expect(!schema.errors(groupedJSON, at: "#/$defs/userOverrideRule").isEmpty)  // PLT-R540
    }

    @Test func provenanceIsDecodedByThePresenceOfSource() throws {
        let shipped =
            #"{"reason":"Symptom and cause.","evidence":[{"type":"issue","ref":"issue-1"}],"tested":[{"app":"A","appVersion":"1","macOS":"27.1","date":"2026-11-01","result":"pass"}],"addedIn":"1.0.0","reviewBy":"2027-01-01"}"#
        let user = #"{"source":"user-suggestion","appVersion":"2.0","macOS":"27.1","date":"2026-11-13"}"#
        let decodedShipped = try JSONDecoder().decode(RuleProvenance.self, from: Data(shipped.utf8))
        let decodedUser = try JSONDecoder().decode(RuleProvenance.self, from: Data(user.utf8))
        guard case .shipped(let provenance) = decodedShipped else {
            Issue.record("expected shipped")
            return
        }
        guard case .userSuggestion(let suggestion) = decodedUser else {
            Issue.record("expected user")
            return
        }
        #expect(provenance.reviewBy == "2027-01-01")
        #expect(suggestion.appVersion == "2.0")
        for value in [decodedShipped, decodedUser] {
            let echoed = try JSONDecoder().decode(RuleProvenance.self, from: JSONEncoder().encode(value))
            #expect(echoed == value)
        }
        let flat = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(decodedUser))
        #expect(flat["source"] == .string("user-suggestion"))
    }

    @Test func malformedProvenanceFailsToDecode() {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuleProvenance.self, from: Data(#"{"source":"user-suggestion"}"#.utf8))
        }
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(RuleProvenance.self, from: Data(#"[1]"#.utf8))
        }
    }

    private static func mutatingFirstRule(
        _ document: JSONValue, _ mutate: (inout [String: JSONValue]) -> Void
    ) -> JSONValue {
        guard case .object(var root) = document, case .array(var rules) = root["rules"],
            case .object(var first) = rules.first
        else { return document }
        mutate(&first)
        rules[0] = .object(first)
        root["rules"] = .array(rules)
        return .object(root)
    }

    private static func setMatch(_ rule: inout [String: JSONValue], _ key: String, _ value: JSONValue) {
        guard case .object(var match) = rule["match"] else { return }
        match[key] = value
        rule["match"] = .object(match)
    }

    private static func setParam(_ rule: inout [String: JSONValue], _ key: String, _ value: JSONValue) {
        guard case .object(var action) = rule["action"] else { return }
        var params = action["params"]?.objectValue ?? [:]
        params[key] = value
        action["params"] = .object(params)
        rule["action"] = .object(action)
    }

    private static func setTestedResult(_ rule: inout [String: JSONValue], _ result: String) {
        guard case .object(var provenance) = rule["provenance"] else { return }
        provenance["tested"] = .array([
            .object([
                "app": .string("A"), "appVersion": .string("1"), "macOS": .string("27"), "date": .string("2026-11-01"),
                "result": .string(result),
            ])
        ])
        rule["provenance"] = .object(provenance)
    }
}
