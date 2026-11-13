// SPDX-License-Identifier: GPL-3.0-or-later

import AppModel
import Foundation
import Testing

@testable import CompatRules

@Suite struct LoadingTests {
    private func temporaryFile(_ contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rules-" + UUID().uuidString + ".json")
        try Data(contents.utf8).write(to: url)
        return url
    }

    @Test func seededRulesFileLoadsWithoutFallback() throws {
        let result = RulesLoader.load(contentsOf: RepoFiles.rules)
        #expect(result.usedEmbeddedDefaults == false)
        #expect(result.error == nil)
        #expect(result.document.rules.count == 21)
        #expect(result.document.bundleGroups[ReservedGroup.terminals]?.count == 7)
    }

    /// PLT-R503: an invalid shipped file never crashes and falls back to the embedded ruleset.
    @Test(arguments: [
        "{ not json",
        "[]",
        #"{"schemaVersion": 2}"#,
        #"{"schemaVersion": 1, "rulesetVersion": "2026.11.0"}"#,
    ])
    func invalidShippedFileUsesEmbeddedDefaults(contents: String) throws {
        let result = RulesLoader.load(contentsOf: try temporaryFile(contents))
        #expect(result.usedEmbeddedDefaults)
        #expect(result.error != nil)
        #expect(result.document == EmbeddedRules.minimal)
    }

    @Test func missingFileUsesEmbeddedDefaults() {
        let result = RulesLoader.load(contentsOf: URL(fileURLWithPath: "/nonexistent/compat-rules.json"))
        #expect(result.usedEmbeddedDefaults)
        #expect(result.error == .decoding(path: "$", reason: "file unreadable"))
    }

    @Test func semanticallyInvalidShippedFileUsesEmbeddedDefaults() throws {
        var document = try Build.seededDocument()
        document.rules[0].match = RuleMatch()  // global rule with a placeholder (PLT-R422)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rules-" + UUID().uuidString + ".json")
        try JSONEncoder().encode(document).write(to: url)
        let result = RulesLoader.load(contentsOf: url)
        #expect(result.usedEmbeddedDefaults)
        #expect(result.error == .placeholderInBroadRule(ruleID("browser.chromium.addressBar")))
    }

    @Test func unsupportedSchemaVersionIsReportedAsSuch() {
        #expect(throws: RulesValidationError.unsupportedSchemaVersion(2)) {
            try RulesLoader.decode(Data(#"{"schemaVersion": 2, "anything": true}"#.utf8))
        }
    }

    @Test func unknownKeysAreRejectedWithTheirPath() throws {
        var raw = try String(contentsOf: RepoFiles.rules, encoding: .utf8)
        raw = raw.replacingOccurrences(of: #""engines": ["chromium"], "ax""#, with: #""engine": ["chromium"], "ax""#)
        #expect(
            throws: RulesValidationError.decoding(path: "$.rules[0].match.engine", reason: "unknown key or null value")
        ) {
            try RulesLoader.decode(Data(raw.utf8))
        }
    }

    @Test func decodingErrorsNameThePathAndReason() {
        let wrongType = #"{"schemaVersion": 1, "rulesetVersion": 5}"#
        #expect(throws: RulesValidationError.decoding(path: "$.rulesetVersion", reason: "wrong type")) {
            try RulesLoader.decode(Data(wrongType.utf8))
        }
        let missing = #"{"schemaVersion": 1}"#
        #expect(throws: RulesValidationError.decoding(path: "$.rulesetVersion", reason: "missing required key")) {
            try RulesLoader.decode(Data(missing.utf8))
        }
        #expect(throws: RulesValidationError.decoding(path: "$.schemaVersion", reason: "missing required key")) {
            try RulesLoader.decode(Data(#"{"rules": []}"#.utf8))
        }
        let badBundle =
            #"{"schemaVersion":1,"rulesetVersion":"1","defaults":{},"bundleGroups":{},"conflictingInputApps":["bad id"]}"#
        #expect(throws: RulesValidationError.self) { try RulesLoader.decode(Data(badBundle.utf8)) }
    }

    @Test func dollarSchemaIsAllowedOnlyAtTheRoot() throws {
        let seeded = try String(contentsOf: RepoFiles.rules, encoding: .utf8)
        #expect(seeded.contains("\"$schema\""))
        #expect(throws: Never.self) { try RulesLoader.decode(Data(seeded.utf8)) }
        let nested = seeded.replacingOccurrences(
            of: #""strategy": "selectReplace" }"#, with: #""strategy": "selectReplace", "$schema": "x" }"#)
        #expect(throws: RulesValidationError.self) { try RulesLoader.decode(Data(nested.utf8)) }
    }

    // MARK: Validation table (one case per RulesValidationError)

    @Test func duplicateIDsUnknownGroupsAndRangesAreRejected() {
        let a = Build.rule("app.a", match: RuleMatch(engines: [.qt]))
        #expect(RulesValidator.issues(in: Build.document([a, a])) == [.duplicateRuleID(ruleID("app.a"))])
        let grouped = Build.rule("grouped", match: RuleMatch(bundleGroup: "missing"))
        #expect(
            RulesValidator.issues(in: Build.document([grouped])) == [
                .unknownBundleGroup(rule: ruleID("grouped"), group: "missing")
            ])
        let fast = Build.rule(
            "fast", match: RuleMatch(engines: [.qt]),
            action: RuleAction(
                strategy: .backspaceReplace, params: StrategyParams(unicodeChunk: 21, interEventDelayUs: 50_001)))
        #expect(
            RulesValidator.issues(in: Build.document([fast])) == [
                .parameterOutOfRange(rule: ruleID("fast"), key: "unicodeChunk"),
                .parameterOutOfRange(rule: ruleID("fast"), key: "interEventDelayUs"),
            ])
        var defaults = Build.defaults
        defaults.params.restoreDelayMs = 5_001
        defaults.params.longTextThreshold = 0
        #expect(
            RulesValidator.issues(in: Build.document([], defaults: defaults)) == [
                .parameterOutOfRange(rule: nil, key: "longTextThreshold"),
                .parameterOutOfRange(rule: nil, key: "restoreDelayMs"),
            ])
    }

    /// PLT-R502: title patterns only in shipped rules, only with bundleIds, at most 200 characters, compiled.
    @Test func titlePatternRules() throws {
        let noBundle = Build.rule("t.a", match: RuleMatch(engines: [.native], titlePattern: "Inbox"))
        let tooLong = Build.rule(
            "t.b", match: RuleMatch(bundleIds: [bundleKey("com.a.b")], titlePattern: String(repeating: "x", count: 201))
        )
        let invalid = Build.rule("t.c", match: RuleMatch(bundleIds: [bundleKey("com.a.b")], titlePattern: "(unclosed"))
        #expect(RulesValidator.issues(in: Build.document([noBundle])) == [.titlePatternWithoutBundleIDs(ruleID("t.a"))])
        #expect(RulesValidator.issues(in: Build.document([tooLong])) == [.titlePatternTooLong(ruleID("t.b"))])
        #expect(RulesValidator.issues(in: Build.document([invalid])) == [.invalidTitlePattern(ruleID("t.c"))])
        // NSRegularExpression rejects "" while Python's re accepts it: the schema has minLength 1 and the
        // validator names the cause itself, so CI and load agree (PLT-R502, PLT-R503).
        let empty = Build.rule("t.d", match: RuleMatch(bundleIds: [bundleKey("com.a.b")], titlePattern: ""))
        #expect(RulesValidator.issues(in: Build.document([empty])) == [.invalidTitlePattern(ruleID("t.d"))])
        let userTitle = Build.userRule(
            "user.t", match: RuleMatch(bundleIds: [bundleKey("com.a.b")], titlePattern: "Inbox"))
        #expect(throws: RulesValidationError.titlePatternInUserOverride(ruleID("user.t"))) {
            try Build.ruleSet([], overrides: [userTitle])
        }
    }

    /// PLT-R422: never in defaults, a global rule or a title-only rule.
    @Test func placeholderScope() {
        let placeholder = RuleAction(
            strategy: .backspaceReplace, params: StrategyParams(inlineCompletion: .placeholder))
        let global = Build.rule("p.global", match: RuleMatch(), action: placeholder)
        let titleOnly = Build.rule(
            "p.title", match: RuleMatch(bundleIds: [bundleKey("com.a.b")], titlePattern: "Sheet"), action: placeholder)
        let categoryOnly = Build.rule("p.category", match: RuleMatch(appCategories: ["x"]), action: placeholder)
        let scoped = Build.rule(
            "p.scoped", match: RuleMatch(engines: [.chromium], ax: AXMatch(editable: true)), action: placeholder)
        let bundleScoped = Build.rule(
            "p.bundle", match: RuleMatch(bundleIds: [bundleKey("com.a.b")]), action: placeholder)
        #expect(
            RulesValidator.issues(in: Build.document([global, titleOnly, categoryOnly, scoped, bundleScoped])) == [
                .placeholderInBroadRule(ruleID("p.global")), .placeholderInBroadRule(ruleID("p.title")),
                .placeholderInBroadRule(ruleID("p.category")),
            ])
        var defaults = Build.defaults
        defaults.params.inlineCompletion = .axSelectionThenPlaceholder
        #expect(
            RulesValidator.issues(in: Build.document([], defaults: defaults)) == [
                .parameterOutOfRange(rule: nil, key: "inlineCompletion")
            ])
    }

    @Test func emptyMatchListsAreRejected() {
        let empty = Build.rule("e.a", match: RuleMatch(ax: AXMatch(roles: [])))
        #expect(
            RulesValidator.issues(in: Build.document([empty])) == [
                .decoding(path: "rule e.a match.ax.roles", reason: "empty list")
            ])
    }

    @Test func ruleSetRejectsBadOverrides() {
        let shipped = Build.rule("shared.id", match: RuleMatch(engines: [.qt]))
        let unprefixed = Build.userRule("terminal.mine", match: RuleMatch(engines: [.qt]))
        #expect(throws: RulesValidationError.userOverrideIDNotPrefixed(ruleID("terminal.mine"))) {
            try Build.ruleSet([shipped], overrides: [unprefixed])
        }
        let clash = Build.userRule("user.x", match: RuleMatch(engines: [.qt]))
        #expect(throws: RulesValidationError.duplicateRuleID(ruleID("user.x"))) {
            try Build.ruleSet([shipped], overrides: [clash, clash])
        }
        let grouped = Build.userRule("user.g", match: RuleMatch(bundleGroup: "nope"))
        #expect(throws: groupInOverride("user.g")) {
            try Build.ruleSet([shipped], overrides: [grouped])
        }
        #expect(throws: RulesValidationError.unsupportedSchemaVersion(3)) {
            var document = Build.document([shipped])
            document.schemaVersion = 3
            _ = try RuleSet(document: document, overrides: [], optedIn: [])
        }
    }

    // MARK: rule-overrides.json

    @Test func overridesAreDecodedAndRejectedIndividually() throws {
        let valid = try JSONDecoder().decode(
            JSONValue.self,
            from: JSONEncoder().encode(
                Build.userRule("user.ok", match: RuleMatch(bundleIds: [bundleKey("com.a.b")]))))
        func with(_ edit: (inout [String: JSONValue]) -> Void) -> JSONValue {
            guard case .object(var object) = valid else { return valid }
            edit(&object)
            return .object(object)
        }
        let entries: [JSONValue] = [
            valid,
            with { $0["id"] = .string("not.user") },
            with { $0["match"] = .object(["bundleIds": .array([.string("com.a.b")]), "titlePattern": .string("x")]) },
            .string("not an object"),
            with { $0["test"] = .object(["scenario": .string("x"), "automation": .string("manual")]) },
            with {
                $0["provenance"] = try! JSONDecoder().decode(
                    JSONValue.self, from: JSONEncoder().encode(Build.provenance()))
            },
            with { $0["provenance"] = .object(["source": .string("someone"), "date": .string("2026-11-13")]) },
            with { $0["provenance"] = .object(["source": .string("user-suggestion"), "date": .string("VERIFY")]) },
            valid,
            with {
                $0["action"] = .object([
                    "strategy": .string("backspaceReplace"), "params": .object(["interEventDelayUs": .number(60_000)]),
                ])
            },
        ]
        let (rules, rejected) = RulesLoader.decodeOverrides(entries)
        #expect(rules.map(\.id) == [ruleID("user.ok")])
        #expect(rejected.map(\.index) == [1, 2, 3, 4, 5, 6, 7, 8, 9])
        #expect(rejected[0].error == .userOverrideIDNotPrefixed(ruleID("not.user")))
        #expect(rejected[1].error == .titlePatternInUserOverride(ruleID("user.ok")))
        #expect(rejected[3].error == .decoding(path: "$.test", reason: "not allowed in a user override"))
        #expect(rejected[7].error == .duplicateRuleID(ruleID("user.ok")))
        #expect(rejected[8].error == .parameterOutOfRange(rule: ruleID("user.ok"), key: "interEventDelayUs"))
    }

    /// PLT-R540, PLT-R522: an override is scoped to one app or one kind of field, so a `bundleGroup` (known or
    /// not) is rejected for that entry alone, and the surviving overrides still compile into a rule set.
    @Test func overrideWithBundleGroupIsRejectedIndividuallyPLTR540() throws {
        func encoded(_ rule: Rule) throws -> JSONValue {
            try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rule))
        }
        let entries = [
            try encoded(Build.userRule("user.unknown", match: RuleMatch(bundleGroup: "nope"))),
            try encoded(Build.userRule("user.known", match: RuleMatch(bundleGroup: "terminals"))),
            try encoded(Build.userRule("user.ok", match: RuleMatch(bundleIds: [bundleKey("com.a.b")]))),
        ]
        let (rules, rejected) = RulesLoader.decodeOverrides(entries)
        #expect(rules.map(\.id) == [ruleID("user.ok")])
        #expect(
            rejected == [
                RejectedOverride(index: 0, error: groupInOverride("user.unknown")),
                RejectedOverride(index: 1, error: groupInOverride("user.known")),
            ])
        let shipped = Build.rule("terminal.default", match: RuleMatch(bundleGroup: "terminals"))
        let ruleSet = try Build.ruleSet(
            [shipped], overrides: rules, groups: ["terminals": [bundleKey("com.a.b")]])
        let resolved = ruleSet.resolve(Build.context(bundle: "com.a.b"))
        #expect(resolved.rule == ruleID("user.ok"))
        #expect(resolved.source == .user)
    }

    // MARK: Embedded ruleset (PLT-R503, PLT-R501)

    /// Acceptance: `EmbeddedRules.minimal` contains no bundle-ID-shaped string.
    @Test func embeddedRulesContainNoBundleIdentifiers() throws {
        let strings = Self.strings(
            in: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(EmbeddedRules.minimal)))
        let lintShape = try NSRegularExpression(pattern: BundleIDShape.lintPattern)
        let shipped = try Self.seededBundleIDs()
        for value in strings {
            let range = NSRange(value.startIndex..<value.endIndex, in: value)
            #expect(lintShape.firstMatch(in: value, range: range) == nil, "bundle-ID-shaped: \(value)")
            #expect(!shipped.contains(value), "shipped bundle ID in embedded rules: \(value)")
            #expect(!value.contains("://"), "URL in embedded rules: \(value)")
        }
    }

    @Test func embeddedRulesMirrorTheEngineOnlyRulesOfTheShippedFile() throws {
        let shipped = try Build.seededDocument()
        let engineOnly = shipped.rules.filter { rule in
            let match = rule.match
            return match.engines != nil && match.bundleIds == nil && match.bundleGroup == nil
                && match.titlePattern == nil
                && match.web == nil && match.appCategories == nil
        }
        let embedded = EmbeddedRules.minimal
        #expect(embedded.defaults == shipped.defaults)
        #expect(embedded.rules.map(\.id) == engineOnly.map(\.id))
        for (mine, theirs) in zip(embedded.rules, engineOnly) {
            #expect(mine.match == theirs.match, "match differs: \(mine.id)")
            #expect(mine.action == theirs.action, "action differs: \(mine.id)")
            #expect(mine.summary == theirs.summary)
        }
        #expect(throws: Never.self) { try RuleSet(document: embedded, overrides: [], optedIn: []) }
    }

    static func strings(in value: JSONValue) -> [String] {
        switch value {
        case .string(let text): [text]
        case .array(let items): items.flatMap(strings(in:))
        case .object(let object): object.keys.map { $0 } + object.values.flatMap(strings(in:))
        default: []
        }
    }

    static func seededBundleIDs() throws -> Set<String> {
        let rules = try Build.seededDocument()
        var ids = Set(rules.conflictingInputApps.map(\.rawValue))
        ids.formUnion(rules.bundleGroups.values.flatMap { $0 }.map(\.rawValue))
        ids.formUnion(rules.secureInputHints.map(\.bundleId.rawValue))
        ids.formUnion(rules.rules.flatMap { $0.match.bundleIds ?? [] }.map(\.rawValue))
        ids.formUnion(try Build.seededMatrix().entries.map(\.bundleId.rawValue))
        return ids
    }
}

/// The literal shape scripts/lint-bundle-ids.sh rejects (PLT-R501), anchored for whole strings.
enum BundleIDShape {
    static let lintPattern =
        "^(?:com|org|net|io|dev|app|vn|me|co|ai|so|sh|tv|us|uk|de|fr|jp|cn|ru|ca|au|eu|nl|se|ch|info|biz|xyz|tech|"
        + "cloud|edu|gov)\\.[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)*$"
}

/// The per-entry rejection of a `bundleGroup` in a user override (PLT-R540).
private func groupInOverride(_ id: String) -> RulesValidationError {
    .decoding(path: "rule " + id + " match.bundleGroup", reason: "not allowed in a user override")
}
