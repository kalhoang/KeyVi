// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PRD-R43 rows, PRD-R41 resume, PLT-R397/R398C hints, PLT-R540 override action, ADR 0309 reopen, PLT-R1009 safe
// mode, precedence host state > safe mode > tap notice > known limitation.

import AppModel
import CompatRules
import Foundation
import Testing

@testable import ShellCore

@Suite struct StatusLineTests {
    let appName = "Example"
    let frontmost = FrontmostAppStatus(
        bundle: BundleKey(rawValue: "com.example.Editor")!, displayName: "Editor", matrixStatus: .knownLimitation,
        limitationNote: "Editor: macOS does not let input methods type here.",
        learnMore: URL(string: "https://example.invalid/apps/editor"))

    func line(
        _ state: HostState, hint: String? = nil, app: FrontmostAppStatus? = nil, reenabled: Bool = false,
        onboardingCompleted: Bool = true, safeMode: Bool = false
    ) -> StatusLine? {
        StatusLine.forState(
            state, holderHintKey: hint, appName: appName, frontmostApp: app, tapRecentlyReenabled: reenabled,
            onboardingCompleted: onboardingCompleted, safeMode: safeMode)
    }

    @Test func safeModeLineOffersResetExitOrReport_PLTR1009_PRDR43() throws {
        // What happened (safe mode, defaults in memory), which component (the app) and one action: the
        // safe-mode choices, so reset and exit are reachable from the menu without the report flow.
        let safe = try #require(line(.ready(.vietnamese), safeMode: true))
        #expect(safe.key == StatusText.safeMode.rawValue)
        #expect(safe.arguments == [appName])
        #expect(safe.action == .safeModeChoices)
        #expect(safe.actionLabelKey == StatusText.actionSafeModeChoices.rawValue)
        #expect(safe.actionLabelArguments.isEmpty)
        #expect(line(.ready(.vietnamese)) == nil)  // nothing outside safe mode
        let menu = MenuModel(
            statusLine: safe, mode: .vietnamese, toggleHotkeyDisplay: "", method: .telex, frontmostApp: nil,
            appName: appName, updateCheckEnabled: false)
        #expect(Array(menu.entries.prefix(3)) == [.status(safe), .statusAction(safe), .separator])
    }

    @Test func safeModeRanksBelowHostStateAndAboveNoticeAndLimitation() throws {
        // A host-state line explains why typing does not work right now and wins; safe mode outranks the
        // transient tap notice and the frontmost app's known limitation.
        #expect(try #require(line(.noPermission, safeMode: true)).key == StatusText.noPermission.rawValue)
        let failOpen = try #require(line(.failOpen(.watchdog), safeMode: true))
        #expect(failOpen.key == StatusText.watchdog.rawValue)
        let overNotice = try #require(line(.ready(.english), app: frontmost, reenabled: true, safeMode: true))
        #expect(overNotice.key == StatusText.safeMode.rawValue)
        let overPause = try #require(line(.paused(.secureField), app: frontmost, safeMode: true))
        #expect(overPause.key == StatusText.safeMode.rawValue)
    }

    @Test func safeModeCopyNamesTheAppAndTheAction() throws {
        let app = try TemporaryAppBundle(catalogs: [.status])
        let safe = try #require(line(.ready(.vietnamese), safeMode: true))
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let en = Localizer(language: .english, appBundle: app.bundle)
        #expect(
            safe.message(vi)
                == "Example đang chạy ở chế độ an toàn với cài đặt mặc định vì đã dừng đột ngột nhiều lần khi mở.")
        #expect(safe.actionLabel(vi) == "Đặt lại hoặc dùng lại cài đặt...")
        #expect(
            safe.message(en)
                == "Example is running in safe mode with the default settings because it stopped unexpectedly "
                + "several times while opening.")
        #expect(safe.actionLabel(en) == "Reset or use saved settings...")
    }

    @Test func permissionMissingOffersGrantAndTheBuiltInFallback() throws {
        let missing = try #require(line(.noPermission))
        #expect(missing.key == StatusText.noPermission.rawValue)
        #expect(missing.arguments == [appName])
        #expect(missing.action == .grantPermission)
        #expect(missing.actionLabelKey == StatusText.actionGrantPermission.rawValue)
        #expect(missing.hintKey == StatusText.builtInFallbackHint.rawValue)  // PLT-R206
        #expect(line(.failOpen(.permissionRevoked)) == missing)
    }

    @Test func closingOnboardingBeforeGrantResumesAtScreenTwo() throws {
        // PRD-R41
        let resume = try #require(line(.noPermission, onboardingCompleted: false))
        #expect(resume.action == .resumeOnboarding)
        #expect(resume.key == StatusText.noPermission.rawValue)
    }

    @Test func secureInputNamesTheHolderAndOffersToShowIt() throws {
        let holder = SecureInputHolder(
            pid: 77, kind: .application, bundle: BundleKey(rawValue: "com.example.Term"), displayName: "Term",
            hintKey: "terminal.secureKeyboardEntry")
        let secure = try #require(line(.paused(.secureInput(holder))))
        #expect(secure.key == StatusText.secureInputHolder.rawValue)
        #expect(secure.arguments == ["Term"])
        #expect(secure.action == .showHolderApp(pid: 77))
        #expect(secure.actionLabelKey == StatusText.actionShowHolder.rawValue)
        #expect(secure.actionLabelArguments == ["Term"])
        // PLT-R397: data-driven hint from the holder's rules entry.
        #expect(secure.hintKey == "secureInputHint.terminal.secureKeyboardEntry")
    }

    @Test func iTermHintCoversTheAutomaticSecureEntry() throws {
        // PLT-R398C (P0-1): the hint passed by the caller wins over the holder's own key.
        let holder = SecureInputHolder(pid: 5, kind: .application, bundle: nil, displayName: "iTerm2", hintKey: nil)
        let secure = try #require(line(.paused(.secureInput(holder)), hint: "iterm2.secureKeyboardEntry"))
        #expect(secure.hintKey == StatusText.hintITerm2.rawValue)
    }

    @Test func unknownHintKeysShowNoHint() throws {
        let holder = SecureInputHolder(pid: 5, kind: .application, bundle: nil, displayName: "X", hintKey: "made.up")
        #expect(try #require(line(.paused(.secureInput(holder)))).hintKey == nil)
    }

    @Test func unknownHolderOffersHelp() throws {
        let unknown = try #require(line(.paused(.secureInput(nil)), hint: "browser.passwordField"))
        #expect(unknown.key == StatusText.secureInputUnknownHolder.rawValue)
        #expect(unknown.action == .secureInputHelp)
        #expect(unknown.actionLabelKey == StatusText.actionSecureInputHelpUnknownHolder.rawValue)
        #expect(unknown.hintKey == StatusText.hintBrowser.rawValue)
        let nameless = SecureInputHolder(pid: 9, kind: .application, bundle: nil, displayName: nil, hintKey: nil)
        #expect(try #require(line(.paused(.secureInput(nameless)))).key == StatusText.secureInputUnknownHolder.rawValue)
    }

    @Test func loginWindowOrExitedHolderAdvisesLockAndUnlock() throws {
        // PLT-R396
        for kind in [SecureInputHolder.Kind.loginWindow, .exitedProcess] {
            let holder = SecureInputHolder(pid: 1, kind: kind, bundle: nil, displayName: "loginwindow", hintKey: nil)
            let stale = try #require(line(.paused(.secureInput(holder))))
            #expect(stale.key == StatusText.secureInputStaleHolder.rawValue)
            #expect(stale.action == .secureInputHelp)
        }
    }

    @Test func bundlelessProcessHolderIsNamedButNotShown() throws {
        let holder = SecureInputHolder(pid: 3, kind: .process, bundle: nil, displayName: "helper", hintKey: nil)
        let process = try #require(line(.paused(.secureInput(holder))))
        #expect(process.key == StatusText.secureInputHolder.rawValue)
        #expect(process.action == .secureInputHelp)
    }

    @Test func failOpenRowsOfferReportOrReopen() throws {
        let rows: [(FailOpenReason, StatusText)] = [
            (.postingBroken, .postingBroken), (.tapUnavailable, .tapUnavailable), (.watchdog, .watchdog),
        ]
        for (reason, key) in rows {
            let failed = try #require(line(.failOpen(reason)))
            #expect(failed.key == key.rawValue)
            #expect(failed.action == .reportProblem)
        }
        // ADR 0309: callbackStuck can only be fixed by reopening the app.
        let stuck = try #require(line(.failOpen(.callbackStuck)))
        #expect(stuck.key == StatusText.callbackStuck.rawValue)
        #expect(stuck.action == .reopenApp)
        #expect(stuck.actionLabelArguments == [appName])
    }

    @Test func nonLatinAndBuiltInSourcesHaveNoAction() throws {
        let nonLatin = try #require(line(.paused(.nonLatinInputSource(name: "Kotoeri"))))
        #expect(nonLatin.key == StatusText.nonLatinSource.rawValue)
        #expect(nonLatin.arguments == ["Kotoeri", appName])
        #expect(nonLatin.action == .none)
        #expect(nonLatin.actionLabelKey == nil)
        let builtIn = try #require(line(.paused(.builtInVietnameseSource)))
        #expect(builtIn.key == StatusText.builtInVietnamese.rawValue)
        #expect(try #require(line(.paused(.userDisabled))).key == StatusText.userDisabled.rawValue)
    }

    @Test func noTextFocusOffersTheOneClickOverride() throws {
        // 02-platform.md section 6, PLT-R540
        let paused = try #require(line(.paused(.noTextFocus), app: frontmost))
        #expect(paused.key == StatusText.noTextFocus.rawValue)
        #expect(paused.arguments == [appName, "Editor"])
        #expect(paused.action == .overrideTextFocus(bundle: frontmost.bundle))
        #expect(paused.actionLabelKey == StatusText.actionOverrideTextFocus.rawValue)
        let unknown = try #require(line(.paused(.noTextFocus)))
        #expect(unknown.key == StatusText.noTextFocusUnknownApp.rawValue)
        #expect(unknown.action == .none)
    }

    @Test func statusLineTableCoversEveryHostState() {
        // PRD-R43, PLT-R211: every state has a decided row (a key and action, or deliberately none).
        let expected: [HostState: (StatusText, StatusLine.Action)?] = [
            .noPermission: (.noPermission, .grantPermission),
            .starting: nil,
            .ready(.vietnamese): nil,
            .ready(.english): nil,
            .paused(.secureInput(AllHostStates.holder)): (.secureInputHolder, .showHolderApp(pid: 42)),
            .paused(.secureInput(nil)): (.secureInputUnknownHolder, .secureInputHelp),
            .paused(.nonLatinInputSource(name: "Kotoeri")): (.nonLatinSource, .none),
            .paused(.builtInVietnameseSource): (.builtInVietnamese, .none),
            .paused(.passThroughRule(AllHostStates.rule)): nil,
            .paused(.secureField): nil,
            .paused(.sessionInactive): nil,
            .paused(.userDisabled): (.userDisabled, .none),
            .paused(.noTextFocus): (.noTextFocus, .overrideTextFocus(bundle: frontmost.bundle)),
            .paused(.diagnosticsTest): nil,  // the guided test's own pause: its panel says what happens
            .failOpen(.permissionRevoked): (.noPermission, .grantPermission),
            .failOpen(.postingBroken): (.postingBroken, .reportProblem),
            .failOpen(.tapUnavailable): (.tapUnavailable, .reportProblem),
            .failOpen(.watchdog): (.watchdog, .reportProblem),
            .failOpen(.callbackStuck): (.callbackStuck, .reopenApp),
        ]
        #expect(Set(expected.keys) == Set(AllHostStates.all))
        var noLimitation = frontmost
        noLimitation.matrixStatus = .works
        for state in AllHostStates.all {
            let line = line(state, app: noLimitation)
            if let row = expected[state] ?? nil {
                #expect(line?.key == row.0.rawValue, "\(state)")
                #expect(line?.action == row.1, "\(state)")
            } else {
                #expect(line == nil, "\(state)")
            }
        }
    }

    @Test func expectedPausesAndHealthyStatesShowNoLine() {
        for state: HostState in [
            .starting, .ready(.vietnamese), .ready(.english), .paused(.secureField), .paused(.sessionInactive),
            .paused(.passThroughRule(AllHostStates.rule)), .paused(.diagnosticsTest),
        ] {
            #expect(line(state) == nil, "\(state)")
        }
    }

    @Test func precedenceIsHostStateThenTapNoticeThenKnownLimitation() throws {
        let host = try #require(line(.noPermission, app: frontmost, reenabled: true))
        #expect(host.key == StatusText.noPermission.rawValue)
        let notice = try #require(line(.ready(.vietnamese), app: frontmost, reenabled: true))
        #expect(notice.key == StatusText.tapReenabled.rawValue)
        #expect(notice.action == .reportProblem)
        let limitation = try #require(line(.ready(.vietnamese), app: frontmost))
        #expect(limitation.key == StatusText.knownLimitationNote.rawValue)
        #expect(limitation.arguments == ["Editor: macOS does not let input methods type here."])
        #expect(limitation.action == .learnMore(URL(string: "https://example.invalid/apps/editor")!))
        // An expected pause falls through to the lower rows too.
        #expect(
            try #require(line(.paused(.secureField), app: frontmost)).key == StatusText.knownLimitationNote.rawValue)
    }

    @Test func knownLimitationWithoutNoteOrLinkStillNamesTheApp() throws {
        var app = frontmost
        app.limitationNote = nil
        app.learnMore = nil
        let generic = try #require(line(.ready(.english), app: app))
        #expect(generic.key == StatusText.knownLimitationGeneric.rawValue)
        #expect(generic.arguments == ["Editor"])
        #expect(generic.action == .none)
        #expect(generic.actionLabelKey == nil)
        app.matrixStatus = .worksWithNotes
        #expect(line(.ready(.english), app: app) == nil)
    }

    @Test func everyLineRendersWithoutLeftoverPlaceholders() throws {
        let app = try TemporaryAppBundle(catalogs: [.status])
        let holders: [SecureInputHolder?] = [
            AllHostStates.holder, nil,
            SecureInputHolder(pid: 1, kind: .loginWindow, bundle: nil, displayName: nil, hintKey: nil),
            SecureInputHolder(pid: 1, kind: .process, bundle: nil, displayName: "p", hintKey: nil),
        ]
        var lines = AllHostStates.all.compactMap { line($0, app: frontmost) }
        lines += holders.compactMap { line(.paused(.secureInput($0)), hint: "iterm2.secureKeyboardEntry") }
        lines += [
            line(.ready(.english), reenabled: true), line(.ready(.english), app: frontmost),
            line(.ready(.english), safeMode: true),
        ].compactMap { $0 }
        for language in InterfaceLanguage.allCases {
            let localizer = Localizer(language: language, appBundle: app.bundle)
            for line in lines {
                let rendered = [line.message(localizer), line.actionLabel(localizer), line.hint(localizer)]
                for text in rendered.compactMap({ $0 }) {
                    #expect(!text.contains("%"), "\(line.key): \(text)")
                    #expect(!text.contains("status."), "\(line.key) unresolved")
                }
            }
        }
    }

    @Test func verbatimCopyOfPRDR43() throws {
        let app = try TemporaryAppBundle(catalogs: [.status])
        let vi = Localizer(language: .vietnamese, appBundle: app.bundle)
        let permission = try #require(line(.noPermission))
        #expect(
            permission.message(vi) == "Chưa có quyền nhận phím gõ. Example đang tạm dừng để không ảnh hưởng bàn phím.")
        #expect(permission.actionLabel(vi) == "Cấp quyền...")
        let source = try #require(line(.paused(.nonLatinInputSource(name: "Kotoeri"))))
        #expect(source.message(vi) == "Đang dùng bàn phím Kotoeri. Example tạm dừng.")
        let notice = try #require(line(.ready(.english), reenabled: true))
        #expect(notice.message(vi) == "Bộ gõ vừa bị macOS tạm ngắt và đã chạy lại.")
        #expect(notice.actionLabel(vi) == "Báo lỗi...")
    }

    @Test func sentencesSplitAtSentenceEnds() {
        #expect(StatusLine.sentences("A b. C d? E.") == ["A b.", "C d?", "E."])
        #expect(StatusLine.sentences("Chọn ABC hoặc U.S. ngay") == ["Chọn ABC hoặc U.S.", "ngay"])
        #expect(StatusLine.sentences("Hướng dẫn...") == ["Hướng dẫn..."])
        #expect(StatusLine.sentences("") == [])
    }
}
