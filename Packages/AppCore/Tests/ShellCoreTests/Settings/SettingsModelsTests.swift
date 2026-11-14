// SPDX-License-Identifier: GPL-3.0-or-later
//
// Smaller Settings models: login item (D17, PLT-R205), word lists (ENG-R860), layout binding (PLT-R373), reset
// requests (PRD-R26), store notices (PLT-R1006, PLT-R1007, PLT-R1009), the About, Support and Licences panes (PRD-R53, PRD-R59,
// ENG-R811) and the updater bridge (D19 to D21).

import AppModel
import Foundation
import InputHost
import SettingsStore
import Testing
import VietnameseEngine
import VietnameseEngineData

@testable import ShellCore

@Suite struct LoginItemControlTests {
    @Test func presentationFollowsTheServiceStatus() {
        #expect(LoginItemPresentation(status: .enabled) == LoginItemPresentation(status: .enabled, failed: false))
        #expect(LoginItemPresentation(status: .enabled).isOn && LoginItemPresentation(status: .enabled).note == nil)
        let approval = LoginItemPresentation(status: .requiresApproval)
        #expect(approval.isOn && approval.note == .openAtLoginApproval && approval.offersSystemSettings)
        let missing = LoginItemPresentation(status: .notFound)
        #expect(!missing.isOn && missing.note == .openAtLoginNotFound && !missing.offersSystemSettings)
        #expect(!LoginItemPresentation(status: .notRegistered).isOn)
    }

    @Test func togglingRegistersAndExplainsFailures() {
        let service = FakeLoginItem()
        #expect(LoginItemControl.set(true, service: service).isOn)
        service.setStatusAfterRegister(.requiresApproval)
        #expect(LoginItemControl.set(true, service: service).note == .openAtLoginApproval)
        #expect(!LoginItemControl.set(false, service: service).isOn)
        service.failNextCall()
        let failed = LoginItemControl.set(true, service: service)
        #expect(!failed.isOn && failed.note == .openAtLoginFailed && failed.offersSystemSettings)
        #expect(service.calls == ["register", "register", "unregister", "register"])
    }

    /// ADR 0315: on macOS 12 the toggle is disabled and the note gives the manual steps, with a System
    /// Preferences button; a refused register keeps that explanation rather than the generic failure.
    @Test func macOS12ExplainsTheManualLoginItem() {
        let legacy = LoginItemPresentation(status: .unavailable)
        #expect(!legacy.isOn && !legacy.isAvailable)
        #expect(legacy.note == .openAtLoginManual && legacy.offersSystemSettings)
        #expect(LoginItemPresentation(status: .unavailable, failed: true) == legacy)
        #expect(LoginItemPresentation(status: .enabled).isAvailable)
        let service = FakeLoginItem()
        service.setStatus(.unavailable)
        service.failNextCall()
        #expect(LoginItemControl.set(true, service: service) == legacy)
    }

    /// PRD-R64, ADR 0315: on macOS 12 the note and the button name System Preferences with the same words, both
    /// taken from SystemPanes.json in the macOS language; the catalog never spells a pane name itself.
    @Test func macOS12RowNamesThePaneOnlyFromTheTable_PRDR64() throws {
        let l = try Localizers()
        let table = try SystemPaneTableTests.shipped()
        let viPanes = table.names(macOS: LooseVersion("12.7")!, systemLanguage: "vi-VN")
        let legacy = LoginItemPresentation(status: .unavailable)
        let row = LoginItemRowText(localizer: l.vi, appName: "Example", panes: viPanes, presentation: legacy)
        #expect(
            row.note
                == "Trên macOS 12, Example không tự bật được tùy chọn này. Hãy mở Tùy chọn Hệ thống > Người dùng & Nhóm > "
                + "Mục Đăng nhập, bấm nút cộng (+) rồi chọn Example trong thư mục Ứng dụng.")
        #expect(row.button == "Mở Tùy chọn Hệ thống")
        // Pane names come only from the table: a renamed pane shows up in both the note and the button.
        var renamed = viPanes
        renamed.systemSettings = "Pane"
        let renamedRow = LoginItemRowText(localizer: l.en, appName: "Example", panes: renamed, presentation: legacy)
        #expect(renamedRow.button == "Open Pane")
        #expect(renamedRow.note?.contains("Open Pane > Người dùng & Nhóm > Mục Đăng nhập,") == true)
        // The VoiceOver hint names no pane (the label is the button title, which names it from the table).
        for localizer in [l.vi, l.en] {
            let hint = localizer.accessibilityHint(SettingsControl.openSystemPreferences)
            #expect(!hint.isEmpty && !hint.contains("%"))
            for name in ["Tùy chọn", "System Preferences", "Mục Đăng nhập", "Mục đăng nhập", "Login Items"] {
                #expect(!hint.contains(name), "hint names a pane: \(hint)")
            }
        }
    }

    @Test func macOS13RowKeepsTheSystemSettingsButton() throws {
        let l = try Localizers()
        let panes = try SystemPaneTableTests.shipped().names(macOS: LooseVersion("14.0")!, systemLanguage: "en")
        let approval = LoginItemRowText(
            localizer: l.en, appName: "Example", panes: panes,
            presentation: LoginItemPresentation(status: .requiresApproval))
        #expect(approval.note == "macOS is waiting for you to allow Example to open at login.")
        #expect(approval.button == "Open System Settings")
        let plain = LoginItemRowText(
            localizer: l.en, appName: "Example", panes: panes, presentation: LoginItemPresentation(status: .enabled))
        #expect(plain.note == nil && plain.button == nil)
    }
}

@Suite struct WordListAndLayoutTests {
    @Test func entriesAreLowercasedRawKeys_ENGR860() {
        #expect(UserWordList.normalized("  Text ") == "text")
        #expect(UserWordList.normalized("a b") == nil)
        #expect(UserWordList.normalized("đc") == nil)
        #expect(UserWordList.normalized("") == nil)
        #expect(UserWordList.normalized(String(repeating: "a", count: 33)) == nil)
        #expect(UserWordList.adding("Wifi", to: ["text"]) == .added(["text", "wifi"]))
        #expect(UserWordList.adding("TEXT", to: ["text"]) == .duplicate)
        #expect(UserWordList.adding("x y", to: []) == .invalid)
        var settings = UserSettings()
        settings.keepAsTyped = ["user", "text"]
        settings.keepVietnamese = ["hoaf"]
        #expect(UserWordList.keepAsTyped.entries(in: settings.resolved()) == ["text", "user"])
        #expect(UserWordList.keepVietnamese.entries(in: settings.resolved()) == ["hoaf"])
        #expect(UserWordList.keepAsTyped.edit(["a"]) == .keepAsTyped(["a"]))
        #expect(UserWordList.keepVietnamese.edit(["a"]) == .keepVietnamese(["a"]))
    }

    @Test func onlyLatinLayoutsCanBeBoundAndEachToOneMode_PLTR373() {
        let abc = InputSourceID(rawValue: "com.example.keylayout.ABC")!
        let us = InputSourceID(rawValue: "com.example.keylayout.US")!
        let kotoeri = InputSourceID(rawValue: "com.example.inputmethod.Japanese")!
        let sources = [
            InputSourceInfo(
                id: abc, kind: .asciiLayout, localizedName: "ABC", languages: ["en"], isBuiltInVietnamese: false),
            InputSourceInfo(
                id: us, kind: .asciiLayout, localizedName: "U.S.", languages: ["en"], isBuiltInVietnamese: false),
            InputSourceInfo(
                id: abc, kind: .asciiLayout, localizedName: "ABC", languages: ["en"], isBuiltInVietnamese: false),
            InputSourceInfo(
                id: kotoeri, kind: .inputMethod, localizedName: "Japanese", languages: ["ja"],
                isBuiltInVietnamese: false),
        ]
        var model = LayoutBindingModel(
            binding: LayoutModeBinding(enabled: false, vietnamese: [abc]), enabledSources: sources)
        #expect(model.rows.map(\.name) == ["ABC", "U.S."])
        #expect(model.rows.map(\.assignment) == [.vietnamese, .none])
        #expect(!model.isComplete)
        let enabled = model.settingEnabled(true)
        #expect(enabled.enabled && enabled.vietnamese == [abc])
        let both = model.assigning(.english, to: us)
        #expect(both.english == [us])
        model = LayoutBindingModel(binding: both, enabledSources: sources)
        #expect(model.isComplete)
        let moved = model.assigning(.english, to: abc)
        #expect(moved.vietnamese.isEmpty && moved.english == [us, abc])
        let cleared = model.assigning(.none, to: us)
        #expect(cleared.english.isEmpty)
        #expect(
            LayoutBindingModel.Assignment.allCases.map(\.title) == [
                .layoutBindingNone, .layoutBindingVietnamese, .layoutBindingEnglish,
            ])
        #expect(
            LayoutBindingModel(binding: both, enabledSources: sources).rows.map(\.assignment) == [
                .vietnamese, .english,
            ])
    }
}

@Suite struct ResetRequestTests {
    @Test func everyResetOffersExportAndOnlyMacroResetsOfferDeletion_PRDR26() throws {
        let l = try Localizers()
        for target in [ResetTarget.all] + PaneReset.allCases.map(ResetTarget.pane) {
            let request = ResetRequest(target: target)
            #expect(request.offersExportFirst)
            #expect(!request.deleteMacros)  // unticked by default
            #expect(!request.title(l.vi).isEmpty && l.vi.string(request.body) != request.body.rawValue)
        }
        #expect(
            ResetRequest(target: .all).offersMacroDeletion && ResetRequest(target: .pane(.macros)).offersMacroDeletion)
        #expect(!ResetRequest(target: .pane(.typing)).offersMacroDeletion)
        #expect(ResetRequest(target: .pane(.typing)).title(l.vi) == "Khôi phục mặc định cho mục Kiểu gõ?")
        #expect(ResetRequest(target: .all).title(l.en) == "Restore all settings to their defaults?")
        var typing = ResetRequest(target: .pane(.typing))
        typing.deleteMacros = true  // ignored where the checkbox is not offered
        #expect(typing.plan == ResetPlan(storeScope: .typing))
        #expect(ResetRequest(target: .all).plan.storeScope == .all(includeMacros: false))
        // The Macros pane goes through the store's own scope, so the backup happens before the rewrite.
        var macros = ResetRequest(target: .pane(.macros))
        #expect(macros.plan == ResetPlan(storeScope: .macros(includeList: false)))
        macros.deleteMacros = true
        #expect(macros.plan.storeScope == .macros(includeList: true))
        #expect(PaneReset.allCases.map(\.pane) == [.general, .typing, .apps, .macros])
        #expect(SettingsPaneKind.allCases.map(\.paneReset) == [.general, .typing, .apps, .macros, nil, nil, nil])
    }
}

@Suite struct StoreNoticePresentationTests {
    @Test func recoveryIsInformationalAndCorruptionNeedsConfirmation() throws {
        let l = try Localizers()
        let date = Date(timeIntervalSince1970: 1_794_528_000)
        let notices: [StoreNotice] = [
            .recoveredFromBackup(.settings, backupDate: date), .corruptFileUsingDefaults(.macros),
            .newerSchemaReadOnly(.appModes, schemaVersion: 3), .safeMode(recentCrashes: 3),
            .writeFailed(.ruleOverrides, errno: 28),
        ]
        let shown = StoreNoticePresentation.all(notices, appName: "App", localizer: l.vi)
        #expect(
            shown.map(\.actions) == [
                [.dismiss(.settings)], [.useDefaults(.macros)], [], [.leaveSafeMode, .resetAll, .report], [],
            ])
        #expect(shown.map(\.isWarning) == [false, true, false, true, true])
        #expect(shown[0].message.contains("settings.json") && shown[0].message.contains(l.vi.formatDate(date)))
        #expect(shown[2].message.contains("3") && shown[3].message.hasPrefix("App gặp sự cố 3 lần"))
        let actions: [StoreNoticePresentation.Action] = [
            .dismiss(.settings), .useDefaults(.settings), .leaveSafeMode, .report, .resetAll,
        ]
        #expect(
            actions.map(\.title) == [
                .noticeDismiss, .noticeUseDefaults, .noticeLeaveSafeMode, .noticeReport, .noticeReset,
            ])
        #expect(
            actions.map(\.control) == [
                .noticeDismiss, .noticeUseDefaults, .noticeLeaveSafeMode, .noticeReport, .noticeReset,
            ])
    }
}

@Suite struct AboutSupportTests {
    let brand = Brand(
        displayName: "App", slug: "app", siteHost: "example.invalid", bundleIdentifier: "com.example.app",
        version: "0.1.0", build: "12", supportEmail: nil)

    @Test func versionLine_PRDR24() throws {
        let l = try Localizers()
        #expect(AboutSupportContent.versionLine(brand: brand, localizer: l.vi) == "Phiên bản 0.1.0 (12)")
    }

    @Test func acknowledgementsShowTheEngineLicenceTheBundledNoticesAndSparkle_ENGR811() throws {
        let l = try Localizers()
        let notices = try Resources.bundledNotices()
        let shown = Acknowledgements(dataNotices: Resources.bundledNotices, appName: "Example", localizer: l.vi)
        #expect(shown.sections.map(\.title) == [.licencesEngine, .licencesData, .licencesSparkle])
        #expect(shown.sections[0].text == EngineLicence.text(appName: "Example"))
        #expect(shown.sections[1].text == notices)
        #expect(notices.contains("SCOWL"))
        #expect(shown.sections[2].text.contains("Andy Matuschak"))
        #expect(shown.sections.map(\.id) == [.licencesEngine, .licencesData, .licencesSparkle])
        struct Missing: Error {}
        let fallback = Acknowledgements(dataNotices: { throw Missing() }, appName: "Example", localizer: l.vi)
        #expect(fallback.sections[1].text == l.vi.string(SupportText.licencesUnavailable))
    }

    /// The Licences pane shows the engine's MPL-2.0 licence (the app binary contains the engine): its NOTICE, which
    /// names the authors by the brand's display name, then the verbatim MPL text of Packages/VietnameseEngine/LICENSE.
    @Test func engineLicenceMatchesThePackageLicenceFile() throws {
        func file(_ name: String) throws -> String {
            try String(contentsOf: RepoPaths.url("Packages/VietnameseEngine/\(name)"), encoding: .utf8)
                .trimmingCharacters(in: .newlines)
        }
        let name = try BrandFiles.values().displayName
        let expected = try file("NOTICE") + "\n\n" + file("LICENSE")
        #expect(EngineLicence.text(appName: name) == expected)
        #expect(EngineLicence.text(appName: name).contains("Mozilla Public License Version 2.0"))
        #expect(!EngineLicence.text(appName: name).contains("{{"))
    }

    @Test func sparkleNoticeMatchesThirdPartyNotices() throws {
        let text = try String(contentsOf: RepoPaths.url("THIRD_PARTY_NOTICES.md"), encoding: .utf8)
        let section = try #require(text.range(of: "### Sparkle \(SparkleNotice.version)"))
        let fence = try #require(text.range(of: "```text\n", range: section.upperBound..<text.endIndex))
        let end = try #require(text.range(of: "\n```", range: fence.upperBound..<text.endIndex))
        func lines(_ value: some StringProtocol) -> [String] {
            value.components(separatedBy: "\n").map { String($0.reversed().drop { $0 == " " }.reversed()) }
        }
        #expect(lines(text[fence.upperBound..<end.lowerBound]) == lines(SparkleNotice.text))
    }

    @Test func donationBlockShowsTheBankAndTheAccountNumberOnly_PRDR59() throws {
        let l = try Localizers()
        let info = DonationInfo.standard
        #expect(info.details.map(\.value) == ["LioBank", "688688678"])
        #expect(info.details.map { l.vi.string($0.label) } == ["Ngân hàng", "Số tài khoản"])
        #expect(info.details.map { l.en.string($0.label) } == ["Bank", "Account number"])
        #expect(info.details.map(\.copyControl) == [.copyBank, .copyAccount])
        #expect(!info.showsSponsors)
        var sponsored = info
        sponsored.githubSponsorsURL = URL(string: "https://github.com/sponsors/example")
        #expect(sponsored.showsSponsors)
        // S8: the VietQR code is the only bundled donation image (no MoMo), never fetched.
        let catalog = RepoPaths.url("App/Resources/Donation.xcassets")
        let sets = try FileManager.default.contentsOfDirectory(atPath: catalog.path)
            .filter { $0.hasSuffix(".imageset") }
        #expect(sets == ["\(info.vietQRImageName).imageset"])
    }

    @Test func donationCopyNeverNamesTheAccountHolderOrMoMo_PRDR59() throws {
        // S8: the holder's name is not shown anywhere; the payer's bank app shows it after the scan.
        let catalog = try Catalog(table: .support)
        for (key, entry) in catalog.entries where key.hasPrefix("support.donate") {
            for value in entry.values.values {
                for forbidden in ["MoMo", "Chủ tài khoản", "Tên tài khoản", "holder", "Account name"] {
                    #expect(!value.contains(forbidden), "\(key) mentions \(forbidden)")
                }
            }
        }
    }

    /// Pa, 15/11/2026: the share text is Pa's, with the marked name and the website's address, nothing else.
    @Test func shareTextNamesTheMarkedNameAndTheWebsite_PRDR59() throws {
        let l = try Localizers()
        let brand = Brand(
            displayName: "Example", slug: "example", siteHost: "example.invalid", bundleIdentifier: "invalid.example",
            version: "1.0", build: "1", supportEmail: nil, trademarkSign: "™")
        #expect(
            AboutSupportContent.shareText(brand: brand, localizer: l.vi)
                == "Giới thiệu với mọi người Example™, một bộ gõ tiếng Việt miễn phí nhưng rất ngon nè! "
                + "Tải ở đây: https://example.invalid")
        #expect(
            AboutSupportContent.shareText(brand: brand, localizer: l.en)
                == "Check out Example™, a free Vietnamese keyboard for Mac that is really good! "
                + "Get it here: https://example.invalid")
        #expect(
            AboutSupportContent.copyrightLine(brand: brand, localizer: l.vi) == "Bản quyền © 2026 các tác giả Example")
        #expect(
            AboutSupportContent.copyrightLine(brand: brand, localizer: l.en) == "Copyright © 2026 the Example authors")
        #expect(AboutSupportContent.mailURL(brand: brand) == nil)
        var mailed = brand
        mailed.supportEmail = "help@example.invalid"
        #expect(AboutSupportContent.mailURL(brand: mailed)?.absoluteString == "mailto:help@example.invalid")
    }
}
