// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R1202 (only listed fields), PLT-R1203 and PLT-R901 (no content: canaries), PLT-R913 (reported app only),
// PLT-R541 and ADR 0312 (typed override projection), PLT-R362 (layout ID), PRD-R33 (macro count only).

import AppModel
import CompatRules
import Diagnostics
import Foundation
import SettingsStore
import Testing

@testable import InputHost
@testable import ShellCore

@Suite struct ReportAssemblerTests {
    func json(_ report: DiagnosticsReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    @Test func reportHoldsOnlyPLTR1202Sections() throws {
        let data = try JSONEncoder().encode(ReportFixtures.report())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let allowed: Set<String> = [
            "formatVersion", "generatedAt", "app", "system", "hostState", "keyboard", "permissions", "tap",
            "secureInput", "focus", "rule", "settings", "reportedAppMode", "latency", "healthEvents",
            "conflictingInputApps", "userReport",
        ]
        #expect(Set(object.keys).isSubset(of: allowed))
        #expect(
            Set(object.keys).isSuperset(of: allowed.subtracting(["reportedAppMode", "focus", "rule", "userReport"])))
    }

    @Test func reportContainsNoContentAndNoOtherAppsData() throws {
        // Canary test (PLT-R901, PLT-R1203, PLT-R913, ADR 0312).
        let text = try json(ReportFixtures.report(host: ReportFixtures.host(secureHolder: holder())))
        for canary in Canary.all { #expect(!text.contains(canary), "report leaks \(canary)") }
    }

    func holder() -> SecureInputHolder {
        SecureInputHolder(
            pid: 9, kind: .application, bundle: ReportFixtures.holderBundle, displayName: Canary.holderName,
            hintKey: "terminal.secureKeyboardEntry")
    }

    @Test func metadataSectionsAreFilledFromTheHost() throws {
        let report = ReportFixtures.report(host: ReportFixtures.host(secureHolder: holder()))
        #expect(report.formatVersion == DiagnosticsReport.formatVersion)
        #expect(report.generatedAt == ReportFixtures.now)
        #expect(report.app == ReportFixtures.identity)
        #expect(report.system == ReportFixtures.system)
        #expect(report.hostState == .readyVietnamese)
        #expect(report.keyboard.layout?.rawValue == "com.apple.keylayout.ABC")  // PLT-R362
        #expect(report.keyboard.sourceKind == .asciiLayout)
        #expect(report.permissions.health == .ready)
        #expect(report.secureInput.enabled)
        #expect(report.secureInput.likelyHolder == ReportFixtures.holderBundle)
        #expect(report.secureInput.holderKind == .application)
        #expect(report.conflictingInputApps == [ReportFixtures.conflict])
        let focus = try #require(report.focus)
        #expect(focus.bundle == ReportFixtures.focused)
        #expect(focus.appVersion == "2.3.1")
        #expect(focus.identifier == "composer")
        #expect(focus.engine == .electron)
    }

    @Test func tapCountersCoverTheLast24Hours() {
        let tap = ReportFixtures.report().tap
        #expect(tap.enabled)
        #expect(tap.location == "session")
        #expect(tap.timeoutsLast24Hours == 1)
        #expect(tap.userInputDisablesLast24Hours == 1)
        #expect(tap.lastReenableReason == .tapDisabledByUserInput)
    }

    /// PLT-R1202: the 24-hour tap counters count every event the app still holds (the in-memory ring and the
    /// earlier sessions' log), not only the 50 the report lists. Many later events must not hide a timeout.
    @Test func tapCountersSeeTimeoutsBehindMoreThan50LaterEvents() {
        let now = ReportFixtures.now
        let log = HealthEventLog()
        log.record(HealthEvent(kind: .tapTimeout, at: now.addingTimeInterval(-7_200)))
        for index in 0..<60 {
            log.record(HealthEvent(kind: .echoLoss, at: now.addingTimeInterval(Double(index - 3_600))))
        }
        let earlier =
            [HealthEvent(kind: .tapTimeout, at: now.addingTimeInterval(-36_000))]
            + (0..<60).map { HealthEvent(kind: .flush, at: now.addingTimeInterval(Double($0 - 30_000))) }
        let health = log.reportSource { limit in Array(earlier.suffix(limit)) }
        let report = ReportAssembler.report(
            identity: ReportFixtures.identity, system: ReportFixtures.system, host: ReportFixtures.host(),
            settings: ReportFixtures.settings(overrides: []), metrics: ReportFixtures.metrics, health: health,
            probe: nil, draft: nil, now: now)
        #expect(report.tap.timeoutsLast24Hours == 2)
        #expect(report.tap.lastReenableReason == .tapTimeout)
        #expect(report.healthEvents.count == 50)
        #expect(report.healthEvents.allSatisfy { $0.kind == .echoLoss })
    }

    @Test func healthEventsAreTheLast50() {
        let events = ReportFixtures.report().healthEvents
        #expect(events.count == 50)
        #expect(events == events.sorted { $0.at < $1.at })
        #expect(events.last?.at == ReportFixtures.now)
    }

    @Test func settingsAreValuesWithMacroCountOnly() {
        // PRD-R33, PRD-R6
        let settings = ReportFixtures.report().settings
        #expect(settings.typingMethod == .vni)
        #expect(settings.macroCount == 1)
        #expect(settings.restoreHotkeySet == false)
        #expect(settings.toggleHotkey == .defaultToggle)
        // Names from SettingsStore (`UserSettings.explicitlySetKeys`), list names without their entries.
        #expect(settings.explicitlySetKeys == ["typingMethod", "interfaceLanguage", "keepAsTyped", "keepVietnamese"])
    }

    /// PRD-R6, PLT-R901: the report's changed-settings list is SettingsStore's `explicitlySetKeys`, nothing kept by
    /// hand in ShellCore. The 19 setting names come first in declaration order; the user lists (`keepAsTyped`,
    /// `keepVietnamese`, `optedInRules`) are reported by name only when non-empty, never with their entries
    /// (decision recorded in docs/decisions/0314-report-lists-user-word-lists-by-name.md).
    @Test func explicitlySetKeysAreTheStoresNamesAndNeverListEntries_PRDR6_PLTR901() throws {
        var user = UserSettings()
        user.typingMethod = .set(.vni)
        user.tonePlacement = .set(.modern)
        user.englishRestore = .set(true)
        user.telexStandaloneW = .set(true)
        user.telexBracketKeys = .set(false)
        user.restoreHotkey = .set(nil)
        user.macrosEnabled = .set(false)
        user.macrosInEnglishMode = .set(true)
        user.toggleHotkey = .set(.modifierTap(.rightCommand))
        user.rememberPerApp = .set(false)
        user.firstSeenAppMode = .set(.en)
        user.showSwitchIndicator = .set(false)
        user.soundOnSwitch = .set(true)
        user.clickIconToToggle = .set(true)
        user.interfaceLanguage = .set(.english)
        user.automaticallyCheckForUpdates = .set(false)
        user.automaticallyInstallUpdates = .set(false)
        user.updateChannel = .set(.beta)
        user.layoutBinding = .set(LayoutModeBinding(enabled: true))
        user.keepAsTyped = [Canary.userList]
        user.keepVietnamese = [Canary.userList + "vi"]
        user.optedInRules = [try #require(RuleID(rawValue: "user.zqxkanaryrule"))]
        let reported = ReportSections.settings(SettingsState(user: user)).explicitlySetKeys
        #expect(reported == user.explicitlySetKeys)
        #expect(
            Array(reported.prefix(19)) == [
                "typingMethod", "tonePlacement", "englishRestore", "telexStandaloneW", "telexBracketKeys",
                "restoreHotkey", "macrosEnabled", "macrosInEnglishMode", "toggleHotkey", "rememberPerApp",
                "firstSeenAppMode", "showSwitchIndicator", "soundOnSwitch", "clickIconToToggle", "interfaceLanguage",
                "automaticallyCheckForUpdates", "automaticallyInstallUpdates", "updateChannel", "layoutBinding",
            ])
        #expect(Array(reported.dropFirst(19)) == ["keepAsTyped", "keepVietnamese", "optedInRules"])
        var report = ReportFixtures.report()
        report.settings = ReportSections.settings(SettingsState(user: user))
        let outputs = [
            try json(report), DiagnosticsRenderer.issueBlock(report),
            DiagnosticsRenderer.plainText(report, language: .vietnamese),
            DiagnosticsRenderer.plainText(report, language: .english),
        ]
        for output in outputs {
            #expect(!output.contains("zqxkanary"), "a list entry leaked into the report")
            #expect(output.contains("keepAsTyped"), "the list name is reported")
        }
    }

    @Test func onlyTheReportedAppsMemoryEntryIsIncluded() throws {
        // PLT-R913
        let mode = try #require(ReportFixtures.report().reportedAppMode)
        #expect(mode.bundle == ReportFixtures.reported)
        #expect(mode.rule == .alwaysVietnamese)
        #expect(mode.rememberedMode == .vietnamese)
        // Without a draft the focused app is the reported app.
        #expect(ReportFixtures.report(draft: nil).reportedAppMode?.bundle == ReportFixtures.focused)
        let unknown = BugReportDraft(
            app: BundleKey(rawValue: "com.example.Unseen"), appName: nil, symptom: .other, userDescription: "",
            reproducesInPracticeField: nil)
        #expect(ReportFixtures.report(draft: unknown).reportedAppMode == nil)
    }

    @Test func reportedAppsOverrideIsAttachedAsTypedProjection() throws {
        // PLT-R541, ADR 0312
        let rule = try #require(ReportFixtures.report().rule)
        #expect(rule.rule?.rawValue == "electron.default")
        #expect(rule.isUserOverride == false)
        #expect(rule.parameters.unicodeChunk == ResolvedParams.defaults.unicodeChunk)
        #expect(rule.parameters.verifyAfterEdit == ResolvedParams.defaults.verifyAfterEdit)
        let override = try #require(rule.userOverride)
        #expect(override.id.rawValue == "user.compat.com.example.Chat")
        #expect(override.omittedMatchFields == [.webURLPrefixes, .titlePattern])
        #expect(override.strategy == .selectReplace)
    }

    @Test func focusedOverrideIsUsedWhenNothingIsStored() throws {
        var rule = ReportFixtures.canaryOverride
        rule.id = RuleID(rawValue: "user.focus.1")!
        let host = ReportFixtures.host(decision: ReportFixtures.decision(userOverride: rule))
        let report = ReportAssembler.report(
            identity: ReportFixtures.identity, system: ReportFixtures.system, host: host,
            settings: ReportFixtures.settings(), metrics: ReportFixtures.metrics, health: [], probe: nil,
            draft: ReportFixtures.draft, now: ReportFixtures.now)
        let section = try #require(report.rule)
        #expect(section.isUserOverride)
        #expect(section.userOverride?.id.rawValue == "user.focus.1")
        #expect(report.healthEvents.isEmpty)
        #expect(report.tap.lastReenableReason == nil)
    }

    /// PLT-R541, ADR 0312: with several overrides for the focused app, the block names the one that decided, not
    /// the newest stored one, so `rule.id` and `rule.userOverride` agree.
    @Test func decidingOverrideWinsOverANewerStoredOneForTheFocusedApp() throws {
        var guided = ReportFixtures.canaryOverride
        guided.id = RuleID(rawValue: "user.guided.com.example.Chat")!
        var compat = ReportFixtures.canaryOverride
        compat.match = RuleMatch(bundleIds: [ReportFixtures.reported])
        let newer = StoredRuleOverride(
            createdAt: ReportFixtures.now, rule: ReportFixtures.ruleJSON(compat, provenance: false))
        let older = StoredRuleOverride(
            createdAt: ReportFixtures.now.addingTimeInterval(-86_400),
            rule: ReportFixtures.ruleJSON(guided, provenance: false))
        var decision = ReportFixtures.decision(userOverride: guided)
        decision.rule = guided.id
        let report = ReportAssembler.report(
            identity: ReportFixtures.identity, system: ReportFixtures.system,
            host: ReportFixtures.host(decision: decision),
            settings: ReportFixtures.settings(overrides: [newer, older]), metrics: ReportFixtures.metrics,
            health: [], probe: nil, draft: ReportFixtures.draft, now: ReportFixtures.now)
        let section = try #require(report.rule)
        #expect(section.rule == guided.id)
        #expect(section.userOverride?.id == guided.id)
    }

    @Test func noDecisionMeansNoRuleSection() {
        let report = ReportFixtures.report(host: ReportFixtures.host(decision: nil))
        #expect(report.rule == nil)
    }

    @Test func userReportCarriesNoFreeText() throws {
        let user = try #require(ReportFixtures.report().userReport)
        #expect(user.symptom == .duplicatedLetters)
        #expect(user.reportedApp == ReportFixtures.reported)
        #expect(user.reproducesInPracticeField == false)
        #expect(ReportFixtures.report(draft: nil).userReport == nil)
    }

    @Test(arguments: [
        (HostState.paused(.secureInput(nil)), DiagnosticsReport.PermissionHealthCode.secureInput),
        (.paused(.noTextFocus), .paused), (.ready(.english), .ready),
    ])
    func permissionHealthReflectsPauses(state: HostState, expected: DiagnosticsReport.PermissionHealthCode) {
        #expect(ReportFixtures.report(host: ReportFixtures.host(state: state)).permissions.health == expected)
    }

    @Test func permissionHealthFromProbeWins() {
        var host = ReportFixtures.host(state: .noPermission)
        host.permissions.health = .stale
        #expect(ReportFixtures.report(host: host).permissions.health == .stale)
        host.permissions.health = .noPermission
        #expect(ReportFixtures.report(host: host).permissions.health == .noPermission)
    }

    @Test func inputSourceKindsMapToReportCodes() {
        func kind(_ kind: InputSourceKind, builtIn: Bool = false) -> DiagnosticsReport.InputSourceKindCode {
            var host = ReportFixtures.host()
            host.inputSource.source.kind = kind
            host.inputSource.source.isBuiltInVietnamese = builtIn
            return ReportFixtures.report(host: host).keyboard.sourceKind
        }
        #expect(kind(.nonASCIILayout) == .nonLatinLayout)
        #expect(kind(.inputMethod) == .inputMethod)
        #expect(kind(.inputMode) == .inputMethod)
        #expect(kind(.inputMethod, builtIn: true) == .builtInVietnamese)
    }
}

@Suite struct ReportedOverrideTests {
    @Test func canaryOverrideProjectionContainsNoCanary() throws {
        // ADR 0312 verification
        let projection = ReportAssembler.reportedOverride(from: ReportFixtures.canaryOverride)
        let text = String(decoding: try JSONEncoder().encode(projection), as: UTF8.self)
        for canary in Canary.all { #expect(!text.contains(canary)) }
        #expect(projection.omittedMatchFields == [.webURLPrefixes, .titlePattern])
    }

    @Test func metadataFieldsAreCopied() throws {
        let projection = ReportAssembler.reportedOverride(from: ReportFixtures.canaryOverride)
        #expect(projection.match.bundleIds == [ReportFixtures.reported])
        #expect(projection.match.engines == [.electron])
        #expect(projection.match.appVersion == VersionRange(min: LooseVersion("1.0")))
        #expect(projection.match.axRoles == ["AXTextArea"])
        #expect(projection.match.axSubroles == ["AXSearchField"])
        #expect(projection.match.axIdentifiers == ["composer"])
        #expect(projection.match.axDomClasses == ["editor"])
        #expect(projection.match.axAncestorRoles == ["AXWebArea"])
        #expect(projection.match.axEditable == true)
        #expect(projection.parameters?.interEventDelayUs == 2_000)
        #expect(projection.parameters?.inlineCompletion == .axSelection)
        #expect(projection.parameters?.unicodeChunk == nil)
        #expect(projection.fallback == [.backspaceReplace])
        #expect(projection.requireTextFocus == .never)
        #expect(projection.verifyReentry == .whenReadable)
        #expect(projection.engineContext == .general)
    }

    @Test func overrideWithoutContentFieldsOmitsNothing() {
        let rule = Rule(
            id: RuleID(rawValue: "user.ignore.1")!, summary: "s",
            match: RuleMatch(bundleIds: [ReportFixtures.reported]),
            action: RuleAction(strategy: .passThrough))
        let projection = ReportAssembler.reportedOverride(from: rule)
        #expect(projection.omittedMatchFields.isEmpty)
        #expect(projection.parameters == nil)
        #expect(projection.match.axRoles == nil)
    }

    @Test func storedOverridesAreDecodedWithoutProvenance() {
        let rule = ReportedOverrideSource.decode(ReportFixtures.ruleJSON(ReportFixtures.canaryOverride))
        #expect(rule?.id == ReportFixtures.canaryOverride.id)
        #expect(rule?.provenance == nil)
        #expect(ReportedOverrideSource.decode(.array([])) == nil)
        #expect(ReportedOverrideSource.decode(.object(["id": .string("bad id!")])) == nil)
        #expect(ReportedOverrideSource.override(for: nil, in: ReportFixtures.storedOverrides()) == nil)
    }
}
