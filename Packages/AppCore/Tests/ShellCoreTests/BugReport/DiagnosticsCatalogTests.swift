// SPDX-License-Identifier: GPL-3.0-or-later
//
// The `Diagnostics` String Catalog (PRD-R62, PRD-R66, ADR 0310): every key in vi and en with matching format
// arguments, no brand literal, no dashes, no dead copy, a label and a hint for every control, PRD-R47 copy
// verbatim, and the copy helpers that compose sentences from typed values.

import AppModel
import Diagnostics
import Foundation
import InputHost
import TestSupport
import Testing

@testable import ShellCore

@Suite struct DiagnosticsCatalogTests {
    static let referenced = Set(DiagnosticsText.allCases.map(\.rawValue))

    @Test func everyKeyHasViAndEnWithMatchingArguments() throws {
        let catalog = try Catalog(table: .diagnostics)
        #expect(catalog.sourceLanguage == "vi")
        for (key, entry) in catalog.entries {
            let vi = try #require(entry.values["vi"], "\(key) has no vi value")
            let en = try #require(entry.values["en"], "\(key) has no en value")
            #expect(!vi.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty vi")
            #expect(!en.trimmingCharacters(in: .whitespaces).isEmpty, "\(key): empty en")
            #expect(FormatSpecifiers.of(vi) == FormatSpecifiers.of(en), "\(key) arguments differ")
        }
    }

    @Test func noBrandLiteralsNoDashesNoSudo() throws {
        let catalog = try Catalog(table: .diagnostics)
        let brand = try BrandFiles.values()
        for (key, entry) in catalog.entries {
            for value in entry.values.values {
                for literal in [brand.displayName, brand.siteHost, brand.bundleID] {
                    #expect(!value.contains(literal), "\(key) hard-codes \(literal)")
                }
                #expect(!value.contains("\u{2014}") && !value.contains("\u{2013}"), "\(key) contains a dash")
                #expect(!value.lowercased().contains("sudo"), "\(key) suggests sudo")
            }
        }
    }

    @Test func everyReferencedKeyExistsAndNoCopyIsDead() throws {
        let present = Set(try Catalog(table: .diagnostics).entries.keys)
        #expect(Self.referenced.subtracting(present).sorted() == [], "missing in Diagnostics")
        #expect(present.subtracting(Self.referenced).sorted() == [], "unused in Diagnostics")
    }

    @Test func everyControlHasALabelAndAHintInTheOwnedCatalog() throws {
        // PRD-R66, workstream rule 8.
        let catalog = try Catalog(table: .diagnostics)
        for control in DiagnosticsControl.allCases {
            #expect(catalog.entries[control.labelKey.rawValue] != nil, "\(control) label")
            #expect(catalog.entries[control.hintKey.rawValue] != nil, "\(control) hint")
            #expect(control.labelKey != control.hintKey)
        }
        let hints = DiagnosticsControl.allCases.map(\.hintKey)
        #expect(Set(hints).count == hints.count, "each control has its own hint")
    }

    @Test func bugReportCopyIsVerbatimFromPRDR47() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let expected: [(DiagnosticsText, String)] = [
            (.appLabel, "Lỗi xảy ra ở ứng dụng nào?"), (.symptomLabel, "Chuyện gì xảy ra?"),
            (.descriptionLabel, "Bạn gõ gì và mong ra gì?"), (.previewDisclosure, "Xem trước dữ liệu sẽ gửi"),
            (.github, "Mở GitHub"), (.email, "Gửi qua email"), (.saveFile, "Lưu file..."),
            (.practiceButton, "Thử trong ô gõ thử"),
        ]
        for (key, text) in expected { #expect(vi.string(key) == text) }
        #expect(
            vi.format(DiagnosticsText.descriptionNote, "Bộ gõ")
                == "Bạn tự gõ lại ví dụ ở đây. Bộ gõ không tự gửi những gì bạn đã gõ.")
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(en.string(DiagnosticsText.copyReport) == "Copy report")
        #expect(en.string(DiagnosticsText.misbehaves) == "This app misbehaves...")
        #expect(en.string(DiagnosticsText.recordTrace) == "Record typing trace...")
        #expect(en.string(DiagnosticsText.latencyTest) == "Run typing latency test")
        #expect(en.string(DiagnosticsText.openLogs) == "Open logs folder")
    }

    /// PLT-R397B, PLT-R1201: the Diagnostics window explains a secure-input bursts event with a label and a sentence
    /// from this catalog, the app name an argument (PRD-R62); the report text the window shows and the copied block
    /// say the same words (`DiagnosticsRenderer.healthNoticeText`).
    @Test func healthNoticesAreExplainedInBothLanguagesLikeTheReport() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(
            vi.format(DiagnosticsText.healthSecureInputBurstsExplanation, "Bộ gõ")
                == "Có ứng dụng liên tục bật rồi tắt chế độ nhập bảo mật (Secure Input) trong lúc bạn gõ, nên vài phím "
                + "có thể không tới được Bộ gõ. Hãy thử thoát các bộ gõ khác, trình quản lý mật khẩu hoặc ứng dụng chạy "
                + "nền mới cài để tìm ra ứng dụng đó.")
        for language in [InterfaceLanguage.vietnamese, .english] {
            let localizer = Localizer(language: language, appBundle: app.bundle)
            for notice in HealthNotice.allCases {
                let shown = DiagnosticsCopy.notice(notice, appName: "Bộ gõ", localizer)
                let reported = DiagnosticsRenderer.healthNoticeText(notice, language: language, appName: "Bộ gõ")
                #expect(shown == reported, "\(notice) [\(language)]")
            }
        }
    }

    /// The window lists the notices the shown report calls for, in the interface language.
    @Test func theWindowShowsTheNoticesOfItsReport() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        var report = DiagnosticsFixtures.representativeReport()
        #expect(DiagnosticsCopy.notices(for: report, appName: "Example", en).isEmpty)
        let bursts = HealthEvent(
            kind: .secureInputBursts, at: DiagnosticsFixtures.generatedAt.addingTimeInterval(-60), detail: .count(3))
        report.healthEvents.append(bursts)
        let notices = DiagnosticsCopy.notices(for: report, appName: "Example", en)
        #expect(notices.map(\.label) == ["Secure Input keeps turning on and off"])
        #expect(notices.first?.explanation.contains("may not reach Example.") == true)
    }
}

@Suite struct ClipboardNoticeTests {
    static let languages: [InterfaceLanguage] = [.vietnamese, .english]

    /// PRD-R48: each surface says, before any clipboard write, which of its buttons write to the clipboard. The
    /// notice names exactly the buttons on screen with their visible titles: a hidden button (no repository, no
    /// support address, no suggestion yet) is never named, and a renamed button cannot leave the notice behind.
    @Test(arguments: languages)
    func noticesNameExactlyTheVisibleButtonsThatWriteTheClipboard(_ language: InterfaceLanguage) throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let localizer = Localizer(language: language, appBundle: app.bundle)
        let full = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand())
        let bare = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand(repository: nil, email: nil))
        #expect(full.clipboardControls == [.copyReport, .github])
        #expect(bare.clipboardControls == [.copyReport])
        #expect(DiagnosticsCopy.windowClipboardControls == [.copyReport])
        let allOffers = MisbehavesOffer.allCases
        #expect(DiagnosticsCopy.clipboardControls(allOffers) == [.copySuggestion, .copyReport, .openGitHubIssue])
        #expect(DiagnosticsCopy.clipboardControls([.copyReport]) == [.copyReport])
        let surfaces: [[DiagnosticsControl]] = [
            full.clipboardControls, bare.clipboardControls, DiagnosticsCopy.windowClipboardControls,
            DiagnosticsCopy.clipboardControls(allOffers), DiagnosticsCopy.clipboardControls([.copyReport]),
        ]
        let writers: [DiagnosticsControl] = [.copyReport, .github, .copySuggestion, .openGitHubIssue]
        for buttons in surfaces {
            let text = DiagnosticsCopy.clipboardNotice(buttons: buttons, appName: "Example", localizer)
            #expect(text.contains("Example"), "\(buttons): the notice names the app")
            for button in writers {
                let title = localizer.string(button.labelKey)
                let named = text.contains(title)
                // "Open GitHub" is a prefix of "Open GitHub issue"; the longer title is checked on its own.
                if button == .github, buttons.contains(.openGitHubIssue) { continue }
                #expect(named == buttons.contains(button), "\(buttons): \(title) named \(named)")
            }
        }
        // The sheet's clipboard buttons are the ones whose output the copied-block preview shows.
        #expect(ReportPreviewFormat.copiedBlock.paths.map(\.control) == [.copyReport, .github])
    }

    @Test func buttonListsJoinTheVisibleTitlesInTheInterfaceLanguage() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(DiagnosticsCopy.buttonList([], joinedBy: .and, en) == "")
        #expect(DiagnosticsCopy.buttonList([.copyReport], joinedBy: .and, en) == "Copy report")
        #expect(
            DiagnosticsCopy.buttonList([.copyReport, .github], joinedBy: .and, en) == "Copy report and Open GitHub")
        #expect(
            DiagnosticsCopy.buttonList([.copySuggestion, .copyReport, .openGitHubIssue], joinedBy: .or, en)
                == "Copy rule, Copy report or Open GitHub issue")
        #expect(DiagnosticsCopy.buttonList([.email, .saveFile], joinedBy: .and, vi) == "Gửi qua email và Lưu file...")
        #expect(
            DiagnosticsCopy.buttonList([.copySuggestion, .copyReport, .openGitHubIssue], joinedBy: .or, vi)
                == "Sao chép quy tắc, Sao chép báo cáo hoặc Mở báo lỗi trên GitHub")
        #expect(
            DiagnosticsCopy.clipboardNotice(buttons: [.copyReport], appName: "Example", en)
                == "When you click Copy report, Example puts the data on the clipboard for you to paste. Example "
                + "writes to the clipboard only when you click a button like this, or in the paste compatibility "
                + "mode you turn on yourself.")
    }

    /// PRD-R47 item 4, PLT-R1204: the preview segments name the sheet buttons whose output they show, only the
    /// ones the sheet offers.
    @Test func previewTitlesNameOnlyTheOfferedButtons() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        let full = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand())
        let bare = BugReportSheet(apps: [], preselected: nil, brand: SheetFixtures.brand(repository: nil, email: nil))
        #expect(full.previewTitle(.copiedBlock, en) == "Copy report and Open GitHub")
        #expect(full.previewTitle(.attachedFile, en) == "Send by email and Save file...")
        #expect(bare.previewTitle(.copiedBlock, en) == "Copy report")
        #expect(bare.previewTitle(.attachedFile, en) == "Save file...")
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        for format in ReportPreviewFormat.allCases {
            #expect(!bare.previewTitle(format, vi).contains("GitHub"))
            #expect(!bare.previewTitle(format, vi).contains(vi.string(DiagnosticsText.email)))
        }
    }
}

@Suite struct DiagnosticsCopyTests {
    static let states: [HostStateCode] =
        [.noPermission, .starting, .readyVietnamese, .readyEnglish]
        + [PauseCode.secureInput, .nonLatinInputSource, .builtInVietnameseSource, .passThroughRule, .secureField]
        .map(HostStateCode.paused)
        + [PauseCode.sessionInactive, .userDisabled, .noTextFocus, .diagnosticsTest].map(HostStateCode.paused)
        + [FailOpenReason.permissionRevoked, .postingBroken, .tapUnavailable, .watchdog, .callbackStuck]
        .map(HostStateCode.failOpen)

    @Test func everyHostStateHasItsOwnPlainExplanation() throws {
        let keys = Self.states.map(DiagnosticsCopy.stateKey)
        #expect(Set(keys).count == Self.states.count)
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(DiagnosticsCopy.stateLine(.readyVietnamese, en) == "State: Working normally, typing Vietnamese.")
    }

    @Test func methodsDescribeStrategyHandlingAndPacing() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(
            DiagnosticsCopy.method(.backspaceReplace, inlineCompletion: .none, interEventDelayUs: 0, en)
                == "Backspace and retype")
        #expect(
            DiagnosticsCopy.method(.backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 2_000, en)
                == "Backspace and retype, remove the suggestion first, 2 ms apart")
        let names = InjectionStrategy.allCases.map {
            DiagnosticsCopy.method($0, inlineCompletion: .none, interEventDelayUs: 0, en)
        }
        #expect(Set(names).count == InjectionStrategy.allCases.count)
        let handlings = [InlineCompletionMode.placeholder, .axSelectionThenPlaceholder].map {
            DiagnosticsCopy.method(.selectReplace, inlineCompletion: $0, interEventDelayUs: 0, en)
        }
        #expect(
            handlings == [
                "Select and replace, use a placeholder character",
                "Select and replace, remove the suggestion or use a placeholder",
            ])
    }

    @Test func probeLinesShowT2AndT4() throws {
        let app = try TemporaryAppBundle(catalogs: [.diagnostics])
        let en = Localizer(language: .english, appBundle: app.bundle)
        let result = LatencyProbeResult.ProfileResult(
            profile: .burst, decideToPostedP50Microseconds: 400, decideToPostedP99Microseconds: 1_900,
            endToEndDeltaP50Microseconds: 1_200, endToEndDeltaP99Microseconds: 5_500, samples: 12)
        #expect(
            DiagnosticsCopy.probeLine(result, en)
                == "burst speed: send p50 400 µs, p99 1,900 µs; display delta p50 1,200 µs, p99 5,500 µs (12 samples)")
        // PRD-R65: numbers follow the interface language.
        let profiles = LatencyProbeResult.Profile.allCases.map(DiagnosticsCopy.profileKey)
        #expect(Set(profiles).count == 3)
    }

    @Test func symptomListsFollowTheSpec() throws {
        #expect(DiagnosticsCopy.sheetSymptoms.count == 6)  // PRD-R47 chips
        #expect(DiagnosticsCopy.misbehavesSymptoms.count == 7)  // PLT-R1205 step 2
        let app = try TemporaryAppBundle(catalogs: [.common])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        #expect(DiagnosticsCopy.symptom(.lostLetters, vi) == "Mất chữ")
    }
}
