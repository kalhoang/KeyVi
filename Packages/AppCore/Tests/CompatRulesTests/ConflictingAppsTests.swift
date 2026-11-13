// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R399, PRD-R40 screen 5, CLR-R5: every other Vietnamese input method the conflict screen names has its bundle
// IDs in compat/rules.json, and compat/conflicting-apps.json records where each ID was read (the running app or
// public vendor documentation, never another input method's source or bundle internals).

import AppModel
import Foundation
import Testing

@testable import CompatRules

private struct ConflictingAppsFile: Decodable {
    struct App: Decodable {
        let name: String
        let bundleIds: [String]
        let source: String?
        let checked: String?
    }

    let apps: [App]
}

@Suite struct ConflictingAppsTests {
    /// The input methods spec/03-product.md screen 5 names; the conflict detector matches by bundle ID only.
    static let conflictScreenApps: Set<String> = ["XKey", "OpenKey", "EVKey", "Gõ Nhanh", "PHTV", "GoTiengViet"]
    static let minimumSourceLength = 10  // schema: source minLength

    private static var registryURL: URL { RepoFiles.root.appendingPathComponent("compat/conflicting-apps.json") }

    private func registry() throws -> ConflictingAppsFile {
        try JSONDecoder().decode(ConflictingAppsFile.self, from: RepoFiles.data(Self.registryURL))
    }

    @Test func registryMatchesItsSchema() throws {
        let schema = JSONSchemaSubset(try RepoFiles.json(RepoFiles.schema("conflicting-apps.schema.json")))
        #expect(schema.errors(try RepoFiles.json(Self.registryURL)).isEmpty)
    }

    /// No bundle ID ships in conflictingInputApps without a registry entry, and the registry lists nothing else.
    @Test func registryAndRulesListTheSameBundleIDs() throws {
        let registered = try registry().apps.flatMap(\.bundleIds)
        #expect(registered.count == Set(registered).count)
        let shipped = try Build.seededDocument().conflictingInputApps.map(\.rawValue)
        #expect(Set(shipped) == Set(registered))
    }

    @Test func registryNamesEveryAppOfTheConflictScreen() throws {
        let names = Set(try registry().apps.map(\.name))
        #expect(names.isSuperset(of: Self.conflictScreenApps), "missing: \(Self.conflictScreenApps.subtracting(names))")
    }

    /// Ratchet: the product owner supplies the XKey, PHTV and Gõ Nhanh IDs and the sources of all six (the project may
    /// not inspect those apps). Once every entry is complete the known issue stops occurring and this test fails
    /// until `withKnownIssue` is removed.
    @Test func everyConflictScreenAppHasBundleIDsWithARecordedSource() throws {
        let apps = try registry().apps.filter { Self.conflictScreenApps.contains($0.name) }
        withKnownIssue("bundle IDs and sources pending from the product owner (review finding, CLR-R5)") {
            for app in apps {
                #expect(!app.bundleIds.isEmpty, "\(app.name): no bundle ID")
                #expect((app.source?.count ?? 0) >= Self.minimumSourceLength, "\(app.name): no recorded source")
                #expect(app.checked.flatMap(ISODay.init) != nil, "\(app.name): no check date")
            }
        }
    }
}
