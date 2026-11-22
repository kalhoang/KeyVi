// SPDX-License-Identifier: GPL-3.0-or-later
//
// 03-product.md D30 and PRD-R80 (decision of the product owner, 18/11/2026, docs/decisions/0009-pa-decisions-2026-11-18.md
// item 10): the typo correction of 1.1.0 is on by default, stored under the settings key `typoCorrection` in the Typing
// group. PRD-R81 and ENG-R1118: the never-correct list holds lowercase letters only, and the content-free diagnostics
// report names the list, never its words (PLT-R901, PRD-R45).

import AppModel
import Foundation
import Testing

@testable import SettingsStore

@Suite struct TypoCorrectionDefaultTests {
    @Test func theShippedDefaultIsOn_D30() {
        #expect(DefaultSettings.v1.typoCorrection == true)
        #expect(UserSettings().resolved().typoCorrection == true)
        #expect(UserSettings().resolved().neverCorrect.isEmpty)
        var off = UserSettings()
        off.typoCorrection = .set(false)
        #expect(off.resolved().typoCorrection == false)
        #expect(off.explicitlySetKeys == ["typoCorrection"])
    }

    @Test func theKeyIsTypoCorrectionInTheTypingGroup() {
        let field = SettingFields.all.first { $0.key == "typoCorrection" }
        #expect(field?.group == .typing)
        var user = UserSettings()
        #expect(field?.decode(.bool(false), &user) == true)
        #expect(user.typoCorrection == .set(false))
        #expect(field?.encode(user) == .bool(false))
    }

    @Test func aSettingsFileWithoutTheKeyResolvesOn() throws {
        // Review Focus 3 of the plan: a settings.json of 1.0.x has no `typoCorrection` and gets D30 on.
        let user = SettingsCodec.decode(try JSONSupport.parseObject(Data(#"{"settings":{"typingMethod":"vni"}}"#.utf8)))
        #expect(user.typoCorrection == .unset)
        #expect(user.resolved().typoCorrection)
    }

    @Test func entriesAreLowercaseLettersOnly_PRDR81() {
        #expect(NeverCorrectEntry.normalized(" Androdi ") == "androdi")
        #expect(NeverCorrectEntry.normalized("GRAMAR") == "gramar")
        #expect(NeverCorrectEntry.normalized("android1") == nil)
        #expect(NeverCorrectEntry.normalized("well-known") == nil)
        #expect(NeverCorrectEntry.normalized("việt") == nil)
        #expect(NeverCorrectEntry.normalized("") == nil)
        #expect(NeverCorrectEntry.normalized("   ") == nil)
        #expect(NeverCorrectEntry.normalized("two words") == nil)
        #expect(NeverCorrectEntry.maximumLength == 64)
        #expect(NeverCorrectEntry.normalized(String(repeating: "a", count: 64)) == String(repeating: "a", count: 64))
        #expect(NeverCorrectEntry.normalized(String(repeating: "a", count: 65)) == nil)
    }

    @Test func explicitlySetKeysNameTheListNeverItsContent() throws {
        var user = UserSettings()
        user.neverCorrect = ["androdi"]
        #expect(user.explicitlySetKeys.contains("neverCorrect"))
        #expect(!user.explicitlySetKeys.contains { $0.contains("androdi") })
        #expect(user.resolved().neverCorrect == ["androdi"])
        let editor = try #require(BundleKey(rawValue: "com.example.editor"))
        user.learnedWords = [LearnedWord(list: .keepAsTyped, raw: "tar", app: editor)]
        // The list comes right after the learned words.
        #expect(user.explicitlySetKeys == ["learnedWords", "neverCorrect"])
    }
}
