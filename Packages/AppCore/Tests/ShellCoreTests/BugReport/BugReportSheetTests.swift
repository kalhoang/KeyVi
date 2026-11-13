// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R47-R49 sheet logic, PLT-R1204 (the preview is the exact text), the 3-click path from the menu to
// "Copy report" (section 12 acceptance), and the canary checks of PLT-R1203 and ADR 0312: a report generated
// during a canary session, and after a guided-test suggestion with a page address, contains neither.

import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import Testing

@testable import InputHost
@testable import ShellCore
@testable import TestSupport

enum SheetFixtures {
    static let chat = BugReportAppChoice(bundle: ReportFixtures.reported, name: "Chat")
    static let mail = BugReportAppChoice(bundle: BundleKey(rawValue: "com.example.Mail")!, name: "Mail")

    static func brand(repository: URL? = URL(string: "https://github.com/example/repo"), email: String? = "s@x.invalid")
        -> Brand
    {
        Brand(
            displayName: "Example", slug: "example", siteHost: "example.invalid",
            bundleIdentifier: "invalid.example.app",
            version: "0.1.0", build: "7", supportEmail: email, repositoryURL: repository)
    }

    static func menu() -> MenuModel {
        MenuModel(
            statusLine: nil, mode: .vietnamese, toggleHotkeyDisplay: "⌃⇧", method: .telex,
            frontmostApp: MenuModel.FrontmostAppMenu(bundle: chat.bundle, displayName: "Chat", rule: .remember),
            appName: "Example", updateCheckEnabled: true)
    }
}

@Suite struct BugReportSheetTests {
    @Test func preselectsTheLastFrontmostApp() {
        let sheet = BugReportSheet(
            apps: [SheetFixtures.mail], preselected: SheetFixtures.chat, brand: SheetFixtures.brand())
        #expect(sheet.apps == [SheetFixtures.chat, SheetFixtures.mail])
        #expect(sheet.draft.app == SheetFixtures.chat.bundle && sheet.draft.appName == "Chat")
        #expect(sheet.draft.userDescription.isEmpty && sheet.draft.reproducesInPracticeField == nil)
        #expect(!sheet.previewExpanded)
        let none = BugReportSheet(apps: [SheetFixtures.chat], preselected: nil, brand: SheetFixtures.brand())
        #expect(none.apps == [SheetFixtures.chat] && none.draft.app == nil)
    }

    @Test func actionsFollowTheBrandAndAlwaysWorkWithoutGitHub() {
        // PRD-R49: the flow works without a GitHub account; the practice field is always offered.
        let full = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand())
        #expect(full.actions == BugReportAction.allCases)
        let bare = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand(repository: nil, email: nil))
        #expect(bare.actions == [.copyReport, .saveFile, .practiceField, .openDiagnostics])
    }

    @Test func editingTheDraft() {
        var sheet = BugReportSheet(
            apps: [SheetFixtures.chat, SheetFixtures.mail], preselected: nil, brand: SheetFixtures.brand())
        sheet.selectApp(SheetFixtures.mail.bundle)
        #expect(sheet.draft.app == SheetFixtures.mail.bundle && sheet.draft.appName == "Mail")
        sheet.selectApp(BundleKey(rawValue: "com.example.Unknown"))
        #expect(sheet.draft.app == nil && sheet.draft.appName == nil)
        sheet.select(.wrongTone)
        sheet.setDescription(Canary.typed)
        sheet.setReproducesInPracticeField(true)
        #expect(sheet.draft.symptom == .wrongTone && sheet.draft.reproducesInPracticeField == true)
    }

    @Test func reportCarriesChoicesButNotTheFreeText() throws {
        var sheet = BugReportSheet(apps: [], preselected: SheetFixtures.chat, brand: SheetFixtures.brand())
        sheet.select(.lag)
        sheet.setDescription(Canary.typed)
        let report = sheet.report(from: ReportFixtures.report(draft: nil))
        #expect(
            report.userReport
                == DiagnosticsReport.UserReportSection(
                    symptom: .lag, reportedApp: SheetFixtures.chat.bundle, reproducesInPracticeField: nil))
        #expect(report.reportedAppMode?.bundle == SheetFixtures.chat.bundle)
        #expect(report.rule?.userOverride != nil)
        for text in ReportPreviewFormat.allCases.map({ sheet.preview(report, format: $0) }) + [
            sheet.clipboardText(report)
        ] {
            #expect(!text.contains(Canary.typed))
        }
        let json = String(decoding: try sheet.attachment(report), as: UTF8.self)
        #expect(!json.contains(Canary.typed))
    }

    @Test func choosingAnotherAppDropsTheFirstAppsData() {
        // PLT-R913, PLT-R541: only the reported app's memory entry and override.
        var sheet = BugReportSheet(
            apps: [SheetFixtures.chat, SheetFixtures.mail], preselected: SheetFixtures.chat,
            brand: SheetFixtures.brand())
        sheet.selectApp(SheetFixtures.mail.bundle)
        let report = sheet.report(from: ReportFixtures.report())
        #expect(report.reportedAppMode == nil)
        #expect(report.rule?.userOverride == nil)
        #expect(report.rule != nil)  // the focused field's decision stays
        sheet.selectApp(nil)
        #expect(sheet.report(from: ReportFixtures.report()).rule?.userOverride == nil)
    }

    @Test func previewIsTheExactCopiedAndSavedText() throws {
        // PLT-R1204, PRD-R47 item 4: each format shows byte for byte what its paths write.
        var sheet = BugReportSheet(apps: [], preselected: SheetFixtures.chat, brand: SheetFixtures.brand())
        #expect(sheet.previewFormat == .copiedBlock)
        #expect(ReportPreviewFormat.allCases == [.copiedBlock, .attachedFile])
        let report = sheet.report(from: ReportFixtures.report())
        let json = String(decoding: try sheet.attachment(report), as: UTF8.self)
        #expect(sheet.preview(report, format: .copiedBlock) == sheet.clipboardText(report))
        #expect(sheet.preview(report, format: .attachedFile) == json)
        #expect(sheet.preview(report) == sheet.clipboardText(report))
        sheet.previewFormat = .attachedFile
        #expect(sheet.preview(report) == json)
        #expect(ReportPreviewFormat.copiedBlock.text(report) == sheet.clipboardText(report))
        #expect(ReportPreviewFormat.copiedBlock.paths == [.copyReport, .github])
        #expect(ReportPreviewFormat.attachedFile.paths == [.email, .saveFile])
        #expect(ReportPreviewFormat.allCases.map(\.title) == [.previewCopied, .previewFile])
        #expect(sheet.clipboardText(report) == DiagnosticsRenderer.issueBlock(report))
        let decoded = try JSONDecoder.reportDecoder.decode(DiagnosticsReport.self, from: sheet.attachment(report))
        #expect(decoded == report)
        #expect(sheet.attachmentFileName(slug: "example", report: report).hasPrefix("example-report-"))
    }

    @Test func githubAndMailUseTheDraft() throws {
        var sheet = BugReportSheet(apps: [], preselected: SheetFixtures.chat, brand: SheetFixtures.brand())
        sheet.select(.duplicatedLetters)
        let report = sheet.report(from: ReportFixtures.report())
        let url = sheet.githubURL(repository: URL(string: "https://github.com/example/repo")!, report: report)
        #expect(url.absoluteString.contains("symptom=Duplicated"))
        let app = try TemporaryAppBundle(catalogs: [.common, .menu])
        let localizer = Localizer(language: .english, appBundle: app.bundle)
        let mail = try #require(sheet.mail(report: report, brand: SheetFixtures.brand(), localizer: localizer))
        #expect(mail.recipients == ["s@x.invalid"])
        #expect(mail.attachmentFileName.hasSuffix(".json"))
    }
}

@Suite struct DiagnosticsNavigationTests {
    @Test func firstTimeUserReachesCopyReportInThreeClicks() throws {
        // 02-platform.md section 12 acceptance: at most 3 clicks from the menu.
        let sheet = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand(repository: nil, email: nil))
        let path = try #require(DiagnosticsNavigation.pathToCopyReport(menu: SheetFixtures.menu(), sheet: sheet))
        #expect(path.count <= 3)
        #expect(path == [.statusItem, .menu(.reportProblem), .sheet(.copyReport)])
        #expect(!sheet.previewExpanded)  // no extra click to open the preview first
    }

    @Test(arguments: [true, false], [true, false])
    func copyReportLeadsTheSheetButtonsForEveryBrand(repository: Bool, email: Bool) {
        // Section 12: the sheet's first button is "Copy report" whatever paths the brand enables, and the
        // view's button for it carries the "Copy report" label and hint. Its on-screen placement outside the
        // preview disclosure is checked by hand (no App test target).
        let brand = SheetFixtures.brand(
            repository: repository ? URL(string: "https://github.com/example/repo") : nil,
            email: email ? "s@x.invalid" : nil)
        let sheet = BugReportSheet(apps: [], preselected: nil, brand: brand)
        #expect(sheet.actions.first == .copyReport)
        #expect(sheet.actions.contains(.github) == repository && sheet.actions.contains(.email) == email)
        #expect(BugReportAction.copyReport.control == .copyReport)
        #expect(BugReportAction.copyReport.control.labelKey == .copyReport)
        #expect(BugReportAction.copyReport.control.hintKey == .copyReportHint)
    }

    @Test func everySheetButtonHasItsOwnControl() {
        let controls = BugReportAction.allCases.map(\.control)
        #expect(Set(controls.map(\.rawValue)).count == controls.count)
        #expect(BugReportAction.practiceField.control == .practiceButton)
    }

    @Test func reportItemsOpenTheRightFlow() {
        let chat = SheetFixtures.chat.bundle
        #expect(
            DiagnosticsNavigation.destination(reportProblemFor: nil, lastFrontmost: chat)
                == .bugReport(preselected: chat))
        #expect(DiagnosticsNavigation.destination(reportProblemFor: chat, lastFrontmost: nil) == .misbehaves(chat))
    }

    /// PLT-R1009: in safe mode both report items lead to the safe-mode choices first (reset, use saved settings,
    /// report, later), so reset and exit never depend on which status line is showing.
    @Test func safeModeReportItemsOpenTheSafeModeChoices_PLTR1009() {
        let chat = SheetFixtures.chat.bundle
        #expect(
            DiagnosticsNavigation.destination(reportProblemFor: nil, lastFrontmost: chat, safeMode: true)
                == .safeModeChoices)
        #expect(
            DiagnosticsNavigation.destination(reportProblemFor: chat, lastFrontmost: nil, safeMode: true)
                == .safeModeChoices)
        #expect(
            DiagnosticsNavigation.destination(reportProblemFor: chat, lastFrontmost: nil, safeMode: false)
                == .misbehaves(chat))
    }

    /// PLT-R1009, PRD-R43: whatever host state wins the status line (no text focus when the menu is opened from
    /// the desktop, secure input, missing permission, fail-open), the safe-mode choices are at most two clicks
    /// away from the closed menu.
    @Test(arguments: [
        HostState.ready(.vietnamese), .paused(.noTextFocus), .paused(.secureInput(nil)), .paused(.userDisabled),
        .paused(.builtInVietnameseSource), .paused(.nonLatinInputSource(name: "Kotoeri")), .noPermission,
        .failOpen(.watchdog),
    ])
    func safeModeChoicesStayReachableUnderEveryHostState_PLTR1009(state: HostState) throws {
        let status = StatusLine.forState(
            state, holderHintKey: nil, appName: "Example", frontmostApp: nil, tapRecentlyReenabled: false,
            safeMode: true)
        let menu = MenuModel(
            statusLine: status, mode: .vietnamese, toggleHotkeyDisplay: "", method: .telex, frontmostApp: nil,
            appName: "Example", updateCheckEnabled: false)
        let path = try #require(DiagnosticsNavigation.pathToSafeModeChoices(menu: menu, safeMode: true))
        #expect(path.count <= 2)
        #expect(path.first == .statusItem)
        #expect(DiagnosticsNavigation.pathToSafeModeChoices(menu: menu, safeMode: false) == nil)
    }

    @Test func diagnosticsWindowOffersThePLTR1201Buttons() {
        #expect(DiagnosticsWindowAction.allCases == [.copyReport, .misbehaves, .recordTrace, .latencyTest, .openLogs])
    }
}

@Suite struct CanarySessionReportTests {
    static let pageCanary = "https://zqxkanary.example/zqxkanaryurl?q=zqxkanary"

    @Test func reportAfterAGuidedTestSessionHoldsNoCanary() async throws {
        // Canary session: the guided test types "đá â" into a simulated inline-completion field.
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["dao.vn", "đang"]))
        let layout = InjectionTestLayouts.qwerty()
        let clock = ManualClock()
        let runner = GuidedTestRunner(
            poster: InjectionFieldWiring.poster(for: field, layout: layout),
            fieldAccess: FakeFocusedFieldAccess(field: field), marker: EventMarker(tag: 0x5EED), clock: clock,
            layout: layout)
        let target = MisbehavesTarget(
            app: FocusedApp(
                pid: 501, bundle: ReportFixtures.focused, appVersion: LooseVersion("2.3.1"), engine: .electron),
            field: ReportFixtures.host().focus.field, fieldHandle: FieldHandle(pid: 501, token: 1, element: nil),
            focusGeneration: FocusGeneration(rawValue: 3), rule: nil, source: .default, plan: .default)
        var flow = MisbehavesFlow(target: target)
        flow.requestGuidedTest()
        flow.confirmFieldIsEmptyAndSafe()
        while let pending = flow.pendingCandidate {
            flow.record(await runner.run(pending.candidate, field: target.fieldHandle))
        }
        flow.includePageAddress = true
        flow.pageAddress = Self.pageCanary
        let suggestion = try #require(flow.suggestion(macOS: "27.1", date: "2026-11-13"))
        #expect(suggestion.match.web?.urlPrefixes == ["https://zqxkanary.example/"])

        // "Use this for me now": the suggestion is stored as a user override; the report follows.
        let stored = StoredRuleOverride(createdAt: ReportFixtures.now, rule: ReportFixtures.jsonValue(suggestion))
        var draft = ReportFixtures.draft
        draft.userDescription = Canary.typed
        let report = ReportAssembler.report(
            identity: ReportFixtures.identity, system: ReportFixtures.system, host: ReportFixtures.host(),
            settings: ReportFixtures.settings(overrides: [stored]), metrics: ReportFixtures.metrics, health: [],
            probe: nil, draft: draft, now: ReportFixtures.now)
        let override = try #require(report.rule?.userOverride)
        #expect(override.id == suggestion.id && override.omittedMatchFields == [.webURLPrefixes])
        let outputs = [
            DiagnosticsRenderer.plainText(report, language: .vietnamese),
            DiagnosticsRenderer.plainText(report, language: .english), DiagnosticsRenderer.issueBlock(report),
            String(decoding: try DiagnosticsRenderer.json(report), as: UTF8.self),
            DiagnosticsRenderer.ruleJSON(override, pretty: true),
        ]
        for text in outputs {
            for canary in [GuidedTestCanary.text, "zqxkanary", Canary.typed] {
                #expect(!text.contains(canary), "report leaks \(canary)")
            }
        }
    }
}

extension JSONDecoder {
    static var reportDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
