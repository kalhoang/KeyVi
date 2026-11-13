// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R540, PRD-R36: the per-app user override ids come from one algorithm. The Apps pane's compatibility mode and
// the guided test's "this app" result share `user.compat.<bundle>`; "type here anyway" writes
// `user.textfocus.<bundle>`. Bundle keys below are test fixtures (PLT-R501).

import AppModel
import Testing

@testable import CompatRules

@Suite struct PerAppOverrideSlotTests {
    @Test func theSlotIsThePrefixAndTheBundle() {
        let bundle = BundleKey(rawValue: "com.example.Chat")!
        #expect(PerAppOverrideSlot.compat.ruleID(for: bundle).rawValue == "user.compat.com.example.Chat")
        #expect(PerAppOverrideSlot.textFocus.ruleID(for: bundle).rawValue == "user.textfocus.com.example.Chat")
        #expect(PerAppOverrideSlot.compat.prefix == "user.compat.")
        #expect(PerAppOverrideSlot.textFocus.prefix == "user.textfocus.")
        #expect(PerAppOverrideSlot.allCases.allSatisfy { $0.ruleID(for: bundle).isUserOverride })
    }

    /// `sha256:` keys (PLT-R393) become `sha256-`: the colon is outside the rule ID alphabet.
    @Test func executableHashKeysStayInTheRuleIDAlphabet() {
        let hex = String(repeating: "ab", count: 32)
        let hashed = BundleKey.executable(sha256Hex: hex)!
        #expect(PerAppOverrideSlot.compat.ruleID(for: hashed).rawValue == "user.compat.sha256-" + hex)
        #expect(PerAppOverrideSlot.textFocus.ruleID(for: hashed).rawValue == "user.textfocus.sha256-" + hex)
    }

    /// Empty segments are dropped and a long id is cut to the 128-byte limit without a trailing dot.
    @Test(arguments: PerAppOverrideSlot.allCases)
    func theIDIsValidForAnyBundleKey(_ slot: PerAppOverrideSlot) throws {
        let doubled = try #require(BundleKey(rawValue: "com..example-1_x"))
        #expect(slot.ruleID(for: doubled).rawValue == slot.prefix + "com.example-1_x")
        let long = try #require(BundleKey(rawValue: String(repeating: "a.", count: 100) + "b"))
        let id = slot.ruleID(for: long)
        #expect(id.rawValue.utf8.count <= 128)
        #expect(!id.rawValue.hasSuffix("."))
        #expect(id.rawValue.hasPrefix(slot.prefix))
        let onlyDots = try #require(BundleKey(rawValue: "..."))
        #expect(RuleID(rawValue: slot.ruleID(for: onlyDots).rawValue) != nil)
    }
}
