// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Implementation of `RulesLoader` (PLT-R503): strict decode, schema version gate, semantic validation, and the
// embedded fallback. Nothing here traps on bad input; every failure becomes a `RulesValidationError`.

import AppModel
import Foundation

enum RulesDecoding {
    /// `$schema` lets editors find the JSON Schema; it is the only extra key the files may carry.
    static let allowedRootKeys: Set<String> = ["$schema"]

    private struct VersionProbe: Decodable {
        let schemaVersion: Int
    }

    /// Strict decode without the semantic checks (the linter reports those itself).
    static func decodeStructure(_ data: Data) throws(RulesValidationError) -> RulesDocument {
        let probe = try StrictJSON.decode(JSONValue.self, from: data, allowedRootKeys: [])
        guard let version = probe["schemaVersion"]?.intValue else {
            throw .decoding(path: "$.schemaVersion", reason: "missing required key")
        }
        guard version == RulesValidator.supportedSchemaVersion else { throw .unsupportedSchemaVersion(version) }
        return try StrictJSON.decode(RulesDocument.self, from: probe, allowedRootKeys: allowedRootKeys)
    }

    static func decode(_ data: Data) throws(RulesValidationError) -> RulesDocument {
        let document = try decodeStructure(data)
        if let first = RulesValidator.issues(in: document).first { throw first }
        return document
    }

    static func load(contentsOf url: URL) -> RulesLoadResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            return fallback(.decoding(path: "$", reason: "file unreadable"))
        }
        do {
            return RulesLoadResult(document: try decode(data), usedEmbeddedDefaults: false, error: nil)
        } catch {
            return fallback(error)
        }
    }

    private static func fallback(_ error: RulesValidationError) -> RulesLoadResult {
        RulesLoadResult(document: EmbeddedRuleset.document, usedEmbeddedDefaults: true, error: error)
    }

    /// Each entry of rule-overrides.json is decoded on its own; one bad entry never hides the others.
    static func decodeOverrides(_ raw: [JSONValue]) -> (rules: [Rule], rejected: [RejectedOverride]) {
        var rules: [Rule] = []
        var rejected: [RejectedOverride] = []
        var seen = Set<RuleID>()
        for (index, value) in raw.enumerated() {
            do throws(RulesValidationError) {
                let rule = try decodeOverride(value)
                guard seen.insert(rule.id).inserted else { throw .duplicateRuleID(rule.id) }
                rules.append(rule)
            } catch {
                rejected.append(RejectedOverride(index: index, error: error))
            }
        }
        return (rules, rejected)
    }

    /// The `userOverrideRule` shape of the JSON Schema: no `test`, user-suggestion provenance, `user.` id.
    private static func decodeOverride(_ value: JSONValue) throws(RulesValidationError) -> Rule {
        let rule = try StrictJSON.decode(Rule.self, from: value, allowedRootKeys: [])
        if rule.test != nil { throw .decoding(path: "$.test", reason: "not allowed in a user override") }
        switch rule.provenance {
        case .shipped:
            throw .decoding(path: "$.provenance", reason: "user overrides carry user-suggestion provenance")
        case .userSuggestion(let provenance) where provenance.source != UserProvenance.suggestionSource:
            throw .decoding(path: "$.provenance.source", reason: "invalid value")
        case .userSuggestion(let provenance) where ISODay(provenance.date) == nil:
            throw .decoding(path: "$.provenance.date", reason: "invalid value")
        default:
            break
        }
        if let first = RulesValidator.overrideIssues(rule).first { throw first }
        return rule
    }
}
