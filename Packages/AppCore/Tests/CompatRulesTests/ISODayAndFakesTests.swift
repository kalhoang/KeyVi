// SPDX-License-Identifier: GPL-3.0-or-later

import AppModel
import Foundation
import TestSupport
import Testing

@testable import CompatRules

@Suite struct ISODayTests {
    @Test(arguments: ["2024-02-29", "2000-02-29", "2026-04-30", "2026-12-31", "0000-01-01", "1969-12-31"])
    func acceptsValidDates(_ text: String) {
        #expect(ISODay(text) != nil)
    }

    @Test(arguments: [
        "2026-02-29", "1900-02-29", "2026-04-31", "2026-13-01", "2026-00-10", "2026-1-01", "2026-01-1", "VERIFY",
        "2026-11-13T00:00", "２０２６-11-13", "",
    ])
    func rejectsInvalidDates(_ text: String) {
        #expect(ISODay(text) == nil)
    }

    @Test func ordinalsMatchFoundation() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        for text in ["1970-01-01", "1969-12-31", "2000-03-01", "2026-11-13", "2027-11-14", "1900-03-01"] {
            let parts = text.split(separator: "-").compactMap { Int($0) }
            let date = try #require(calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])))
            #expect(ISODay(text) == ISODay(date), "\(text)")
        }
        #expect(ISODay("2027-11-14")!.days(since: ISODay("2026-11-13")!) == 366)
        #expect(ISODay("2026-11-12")! < ISODay("2026-11-13")!)
        #expect(ISODay(Date(timeIntervalSince1970: -1)) == ISODay("1969-12-31"))
    }
}

/// The skeleton's `FakeDecisionResolver` (W1-E focus tests) must agree with the real resolver's defaults.
@Suite struct FakeDecisionResolverTests {
    @Test(arguments: EngineFingerprint.allCases)
    func defaultDecisionMatchesRuleSetDefaults(_ engine: EngineFingerprint) throws {
        let rules = try RuleSet(document: Build.document([]), overrides: [], optedIn: [])
        #expect(FakeDecisionResolver.defaultDecision(engine: engine) == rules.resolve(Build.context(engine: engine)))
    }

    @Test func scriptedDecisionsAndRecordedContexts() {
        let editor = bundleKey("com.example.editor")
        let scripted = FakeDecisionResolver.defaultDecision(engine: .jvm)
        let fake = FakeDecisionResolver(
            decisions: [editor: scripted], fallback: FakeDecisionResolver.defaultDecision(engine: .native),
            overlayBundles: [editor], titlePatternBundles: [editor], fingerprints: [editor: .jvm])
        #expect(fake.resolve(Build.context()) == scripted)
        #expect(fake.resolve(Build.context(bundle: nil)).requireTextFocus == .whenKnown)
        #expect(fake.resolvedContexts.count == 2)
        #expect(fake.fingerprint(bundleURL: URL(fileURLWithPath: "/A.app"), bundle: editor) == .jvm)
        #expect(
            fake.fingerprint(bundleURL: URL(fileURLWithPath: "/B.app"), bundle: bundleKey("com.example.b")) == .native)
        #expect(fake.overlayBundles == [editor] && fake.titlePatternBundles == [editor])
    }
}
