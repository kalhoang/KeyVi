// SPDX-License-Identifier: LicenseRef-App-Pending

import AppModel
import Foundation
import Testing

@testable import SettingsStore

/// Test-only migrations (no real one ships while every file is at version 1).
enum TestMigrations {
    /// v0 -> v1 of settings.json: `prefs` becomes `settings`, `method` becomes `typingMethod`; unknown keys stay.
    struct ZeroToOne: DocumentMigration {
        var file: SettingsFile { .settings }
        var fromVersion: Int { 0 }
        func migrate(_ object: [String: JSONValue]) throws -> [String: JSONValue] {
            var result = object
            guard var prefs = result.removeValue(forKey: "prefs")?.objectValue else {
                throw MigrationError.invalidDocument(file: .settings, reason: "no prefs")
            }
            if let method = prefs.removeValue(forKey: "method") { prefs["typingMethod"] = method }
            result["settings"] = .object(prefs)
            return result
        }
    }

    /// Identity steps for the other files, so v0 sections of an export can be migrated too.
    struct Identity: DocumentMigration {
        var file: SettingsFile
        var fromVersion: Int { 0 }
        func migrate(_ object: [String: JSONValue]) throws -> [String: JSONValue] { object }
    }

    static let chain = MigrationChain(
        [ZeroToOne(), Identity(file: .appModes), Identity(file: .ruleOverrides), Identity(file: .macros)])
}

@Suite struct MigrationChainTests {
    private struct Step: DocumentMigration {
        var file: SettingsFile
        var fromVersion: Int
        var tag: String
        func migrate(_ object: [String: JSONValue]) throws -> [String: JSONValue] {
            var result = object
            var steps: [JSONValue] = []
            if case .array(let items)? = object["steps"] { steps = items }
            result["steps"] = .array(steps + [.string(tag)])
            return result
        }
    }

    @Test func chainsStepsInOrderAndStampsVersionPLTR1005() throws {
        let chain = MigrationChain([
            Step(file: .macros, fromVersion: 1, tag: "b"), Step(file: .macros, fromVersion: 0, tag: "a"),
        ])
        let result = try chain.migrate(["keep": .bool(true)], file: .macros, from: 0, to: 2)
        #expect(result["steps"] == .array([.string("a"), .string("b")]))
        #expect(result["schemaVersion"] == .number(2))
        #expect(result["keep"] == .bool(true))
    }

    @Test func laterRegistrationWins() throws {
        let chain = MigrationChain([
            Step(file: .settings, fromVersion: 0, tag: "old"), Step(file: .settings, fromVersion: 0, tag: "new"),
        ])
        #expect(try chain.migrate([:], file: .settings, from: 0, to: 1)["steps"] == .array([.string("new")]))
    }

    @Test func missingStepAndDowngradeAreErrors() {
        let chain = MigrationChain([Step(file: .settings, fromVersion: 0, tag: "a")])
        #expect(throws: MigrationError.missingStep(file: .appModes, from: 0)) {
            try chain.migrate([:], file: .appModes, from: 0, to: 1)
        }
        #expect(throws: MigrationError.missingStep(file: .settings, from: 1)) {
            try chain.migrate([:], file: .settings, from: 0, to: 2)
        }
        #expect(throws: MigrationError.self) { try chain.migrate([:], file: .settings, from: 2, to: 1) }
        #expect(throws: Never.self) { try MigrationChain.shipped.migrate([:], file: .macros, from: 1, to: 1) }
    }

    @Test func shippedChainCoversEveryReleasedVersion() throws {
        for release in SchemaFixtures.released {
            for file in SettingsFile.allCases {
                _ = try MigrationChain.shipped.migrate(
                    [:], file: file, from: release.schemaVersion, to: file.currentSchemaVersion)
            }
        }
    }
}

@Suite struct JSONSupportTests {
    @Test func boundsNestingBeforeDecodingPLTR912() {
        let deep = String(repeating: "[", count: 65) + String(repeating: "]", count: 65)
        #expect(throws: JSONParseFailure.tooDeeplyNested(limit: 64)) { try JSONSupport.parseValue(Data(deep.utf8)) }
        let ok = String(repeating: "[", count: 64) + String(repeating: "]", count: 64)
        #expect(throws: Never.self) { try JSONSupport.parseValue(Data(ok.utf8)) }
        // Brackets inside strings, including after escaped quotes, do not count.
        let inString = #"{"a":"[[[[\"[[[[","b":[1]}"#
        #expect(!JSONSupport.exceedsNesting(Array(inString.utf8), limit: 2))
    }

    @Test func classifiesFailures() {
        #expect(throws: JSONParseFailure.empty) { try JSONSupport.parseValue(Data(" \n".utf8)) }
        #expect(throws: JSONParseFailure.invalidJSON) { try JSONSupport.parseValue(Data("{".utf8)) }
        #expect(throws: JSONParseFailure.notAnObject) { try JSONSupport.parseObject(Data("[1]".utf8)) }
        #expect(throws: Never.self) { try JSONSupport.parseObject(Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8))) }
    }

    @Test func serializesSortedWithIntegers() throws {
        let data = try JSONSupport.serialize(.object(["b": .number(1), "a": .string("x/y")]))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(text == "{\n  \"a\" : \"x/y\",\n  \"b\" : 1\n}")
    }

    @Test func bridgesCodableValues() {
        #expect(JSONSupport.decode(TypingMethod.self, from: .string("vni")) == .vni)
        #expect(JSONSupport.decode(TypingMethod.self, from: .string("dvorak")) == nil)
        #expect(JSONSupport.encode(TypingMethod.telex) == .string("telex"))
        #expect(JSONSupport.encode(Double.nan) == nil)
    }

    @Test func timestampsRoundTripAtSecondPrecision() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(StorageTimestamp.iso(date) == "2027-01-15T08:00:00Z")
        #expect(StorageTimestamp.date(iso: "2027-01-15T08:00:00Z") == date)
        #expect(StorageTimestamp.date(iso: "2027-01-15T08:00:00.250Z") == date.addingTimeInterval(0.25))
        #expect(StorageTimestamp.date(iso: "yesterday") == nil)
        #expect(StorageTimestamp.compact(date) == "20270115T080000Z")
        #expect(StorageTimestamp.date(compact: "20270115T080000Z") == date)
        #expect(StorageTimestamp.wholeSeconds(date.addingTimeInterval(0.9)) == date)
    }

    @Test func dispatchIntervalConversion() {
        #expect(DispatchDebounceScheduler.interval(.seconds(1)) == .nanoseconds(1_000_000_000))
        #expect(DispatchDebounceScheduler.interval(.milliseconds(5)) == .nanoseconds(5_000_000))
        #expect(DispatchDebounceScheduler.interval(.seconds(Int64.max)) == .never)
        #expect(DispatchDebounceScheduler.interval(.seconds(-1)) == .nanoseconds(0))
    }

    @Test func dispatchSchedulerFiresAndCancels() async {
        let scheduler = DispatchDebounceScheduler(queue: DispatchQueue(label: "debounce-test"))
        let cancelled = scheduler.schedule(after: .zero) { Issue.record("cancelled timer fired") }
        cancelled.cancel()
        var pending: (any DebounceTimer)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // Kept in `pending`: a timer its owner drops is cancelled.
            pending = scheduler.schedule(after: .zero) { continuation.resume() }
        }
        withExtendedLifetime(pending) {}
        withExtendedLifetime(cancelled) {}
    }
}
