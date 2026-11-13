// SPDX-License-Identifier: GPL-3.0-or-later
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

    /// CLR-R5: every app of the conflict screen has bundle IDs with a recorded public source and check date. The
    /// IDs come from public Homebrew cask metadata (the product owner's follow-up answer of 2026-11-13); the
    /// installed apps are never inspected.
    @Test func everyConflictScreenAppHasBundleIDsWithARecordedSource() throws {
        let apps = try registry().apps.filter { Self.conflictScreenApps.contains($0.name) }
        #expect(apps.count == Self.conflictScreenApps.count)
        for app in apps {
            #expect(!app.bundleIds.isEmpty, "\(app.name): no bundle ID")
            #expect((app.source?.count ?? 0) >= Self.minimumSourceLength, "\(app.name): no recorded source")
            #expect(app.checked.flatMap(ISODay.init) != nil, "\(app.name): no check date")
        }
    }

    /// The follow-up answers name the cask's own app ID plus the older or helper IDs its uninstall and zap
    /// entries list; each must reach the conflict detector.
    @Test func publicCaskIDsOfTheFollowUpAnswersAreListed() throws {
        let expected: [String: Set<String>] = [
            "XKey": ["com.codetay.XKey", "com.codetay.inputmethod.XKey"],
            "PHTV": ["com.phamhungtien.phtv"],
            "Gõ Nhanh": ["org.gonhanh.GoNhanh", "space.khaphan.gonhanh"],
            "EVKey": ["com.lamquangminh.evkey", "com.lamquangminh.evkeyhelper"],
            "GoTiengViet": ["com.trankynam.GoTiengViet"],
            "OpenKey": ["com.tuyenmai.openkey"],
        ]
        let byName = Dictionary(try registry().apps.map { ($0.name, Set($0.bundleIds)) }) { first, _ in first }
        for (name, ids) in expected { #expect(byName[name] == ids, "\(name)") }
        let shipped = Set(try Build.seededRuleSet().conflictingInputApps.map(\.rawValue))
        #expect(shipped == expected.values.reduce(into: Set<String>()) { $0.formUnion($1) })
    }
}
