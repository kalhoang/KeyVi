// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Lists shipped rules whose `test.scenario` has no compat/scenarios/<id>.json (PLT-R505, PLT-R530, QA-R21).
// Reads only `rules[].id` and `rules[].test.scenario`, so it keeps working while the rules schema evolves.
// Used by `compat-harness coverage`, by the dry-run plan and by ScenarioFilesTests.

public import Foundation
internal import AppModel

public struct RuleScenarioGap: Sendable, Hashable, CustomStringConvertible {
    public var ruleID: String
    /// `nil` when the rule has no `test.scenario` at all.
    public var scenario: String?

    public init(ruleID: String, scenario: String?) {
        self.ruleID = ruleID
        self.scenario = scenario
    }

    public var description: String {
        scenario.map { ruleID + " -> missing compat/scenarios/" + $0 + ".json" } ?? ruleID + " -> no test.scenario"
    }
}

public enum RuleScenarioCoverage {
    public enum Failure: Error, Sendable, Hashable { case notARulesDocument }

    /// Rule ids, in file order, with the scenario each one references.
    public static func ruleScenarios(rulesData: Data) throws(Failure) -> [(rule: String, scenario: String?)] {
        guard let document = try? JSONDecoder().decode(JSONValue.self, from: rulesData),
            case .array(let rules)? = document["rules"]
        else { throw .notARulesDocument }
        return rules.compactMap { rule in
            guard let id = rule["id"]?.stringValue else { return nil }
            let scenario = rule["test"]?["scenario"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
            return (id, scenario)
        }
    }

    public static func gaps(rulesData: Data, scenarioIDs: Set<String>) throws(Failure) -> [RuleScenarioGap] {
        try ruleScenarios(rulesData: rulesData).compactMap { entry in
            guard let scenario = entry.scenario else { return RuleScenarioGap(ruleID: entry.rule, scenario: nil) }
            return scenarioIDs.contains(scenario) ? nil : RuleScenarioGap(ruleID: entry.rule, scenario: scenario)
        }
    }
}
