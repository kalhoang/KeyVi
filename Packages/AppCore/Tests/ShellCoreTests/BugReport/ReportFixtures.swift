// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Report inputs for ReportAssembler and BugReportComposer tests. Canary strings mark every piece of content
// or other apps' data that must never reach a report, a URL or a mail body (PLT-R901, PLT-R1203, PLT-R913,
// ADR 0312).

import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport

@testable import InputHost
@testable import SettingsStore
@testable import ShellCore

enum Canary {
    static let typed = "zqxkanarytyped"
    static let url = "https://zqxkanary.example/zqxkanaryurl"
    static let title = "zqxkanarytitle.*"
    static let summary = "zqxkanarysummary"
    static let macroTrigger = "zqxkanarytrigger"
    static let macroExpansion = "zqxkanaryexpansion"
    static let userList = "zqxkanarylist"
    static let sourceName = "zqxkanarysource"
    static let holderName = "zqxkanaryholder"
    static let otherBundle = "com.example.zqxkanaryother"
    static let otherOverrideBundle = "com.example.zqxkanaryoverride"

    static let all = [
        typed, url, "zqxkanaryurl", title, summary, macroTrigger, macroExpansion, userList, sourceName, holderName,
        otherBundle, otherOverrideBundle,
    ]
}

enum ReportFixtures {
    static let now = Date(timeIntervalSince1970: 1_794_528_000)
    static let reported = BundleKey(rawValue: "com.example.Chat")!
    static let focused = BundleKey(rawValue: "com.example.Chat")!
    static let conflict = BundleKey(rawValue: "com.example.OtherIME")!
    static let holderBundle = BundleKey(rawValue: "com.example.Vault")!

    static let identity = AppIdentity(
        displayName: "Example", slug: "example", bundleIdentifier: "invalid.example.app", version: "0.1.0", build: "7",
        channel: .beta)
    static let system = SystemInfo(
        macOSVersion: "27.1", macOSBuild: "27B42", architecture: "arm64", modelIdentifier: "Mac15,3",
        uiLanguage: .vietnamese, systemLanguage: "vi-VN")

    /// Override for the reported app whose content-bearing fields are canaries (ADR 0312 verification).
    static let canaryOverride = Rule(
        id: RuleID(rawValue: "user.compat.com.example.Chat")!, summary: Canary.summary,
        match: RuleMatch(
            bundleIds: [reported], engines: [.electron], appVersion: VersionRange(min: LooseVersion("1.0")),
            ax: AXMatch(
                roles: ["AXTextArea"], subroles: ["AXSearchField"], identifiers: ["composer"],
                domClasses: ["editor"], ancestorRoles: ["AXWebArea"], editable: true),
            web: WebMatch(urlPrefixes: [Canary.url]), titlePattern: Canary.title),
        action: RuleAction(
            strategy: .selectReplace, params: StrategyParams(interEventDelayUs: 2_000, inlineCompletion: .axSelection),
            fallback: [.backspaceReplace], requireTextFocus: .never, verifyReentry: .whenReadable,
            engineContext: .general),
        provenance: .userSuggestion(UserProvenance(source: "user-suggestion", date: "2026-11-13")))

    static func ruleJSON(_ rule: Rule, provenance: Bool = true) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(rule.id.rawValue), "summary": .string(rule.summary),
            "match": jsonValue(rule.match), "action": jsonValue(rule.action),
        ]
        if provenance {
            object["provenance"] = .object(["source": .string("user-suggestion"), "date": .string("2026-11-13")])
        }
        return .object(object)
    }

    static func jsonValue(_ value: some Encodable) -> JSONValue {
        let data = try! JSONEncoder().encode(value)
        return try! JSONDecoder().decode(JSONValue.self, from: data)
    }

    static func host(
        state: HostState = .ready(.vietnamese), decision: ResolvedDecision? = decision(),
        secureHolder: SecureInputHolder? = nil
    ) -> HostReportContext {
        let field = FieldContext(
            axAvailability: .available, role: "AXTextArea", subrole: nil, identifier: "composer",
            domClasses: ["editor"], editable: true, secure: false)
        let hostDecision = HostDecision(
            plan: .default, variant: .default, requireTextFocus: .never, verifyReentry: .never,
            restoreHotkeyEnabled: true, rule: decision?.rule, source: decision?.source ?? .default,
            specificity: decision?.specificity ?? 0)
        let focus = FocusSnapshot(
            generation: FocusGeneration(rawValue: 3),
            app: FocusedApp(
                pid: 501, bundle: focused, appVersion: LooseVersion("2.3.1"), engine: .electron),
            field: field, decision: hostDecision, mode: .vietnamese, modeSource: .remembered, appliedToggleSequence: 0,
            fieldHandle: nil, changedAt: MonotonicInstant(nanoseconds: 1), pause: nil)
        let source = InputSourceInfo(
            id: InputSourceID(rawValue: "com.apple.keylayout.ABC")!, kind: .asciiLayout,
            localizedName: Canary.sourceName, languages: ["en"], isBuiltInVietnamese: false)
        return HostReportContext(
            state: state, focus: focus, decision: decision,
            inputSource: InputSourceSnapshot(generation: 1, source: source, table: nil, boundMode: nil),
            enabledSources: [source],
            secureInput: SecureInputSnapshot(generation: 1, enabled: secureHolder != nil, holder: secureHolder),
            permissions: PermissionStatus(
                accessibility: .granted, postEvent: .granted, listenEvent: .unknown, listenEventRequired: false,
                health: .ready),
            tapEnabled: true,
            conflicts: [
                .runningApp(bundle: conflict, name: "Other"),
                .builtInVietnameseSource(id: InputSourceID(rawValue: "com.apple.inputmethod.VietnameseIM")!, name: "x"),
            ])
    }

    static func decision(userOverride: Rule? = nil) -> ResolvedDecision {
        ResolvedDecision(
            rule: RuleID(rawValue: "electron.default")!, source: userOverride == nil ? .shipped : .user,
            specificity: 12,
            strategy: .selectReplace, params: .defaults, fallback: [.backspaceReplace], defaultMode: .inherit,
            requireTextFocus: .never, verifyReentry: .whenReadable, axEnable: .none, overlay: false,
            requiresUserOptIn: false, engineContext: .general, features: .defaults, userOverride: userOverride)
    }

    static func settings(overrides: [StoredRuleOverride] = []) -> SettingsState {
        var user = UserSettings()
        user.typingMethod = .set(.vni)
        user.interfaceLanguage = .set(.vietnamese)
        user.keepAsTyped = [Canary.userList]
        user.keepVietnamese = [Canary.userList]
        let appModes = AppModesDocument(
            globalMode: .vietnamese,
            apps: [
                AppModeEntry(bundle: BundleKey(rawValue: Canary.otherBundle)!, rule: .alwaysEnglish, mode: .english),
                AppModeEntry(bundle: reported, rule: .alwaysVietnamese, mode: .vietnamese),
            ])
        return SettingsState(
            generation: 1, user: user, effective: user.resolved(), appModes: appModes, ruleOverrides: overrides,
            macros: [StoredMacro(trigger: Canary.macroTrigger, expansion: Canary.macroExpansion)],
            readOnlyFiles: [], safeMode: false, notices: [])
    }

    static func storedOverrides() -> [StoredRuleOverride] {
        var other = canaryOverride
        other.id = RuleID(rawValue: "user.compat.other")!
        other.match = RuleMatch(bundleIds: [BundleKey(rawValue: Canary.otherOverrideBundle)!])
        return [
            StoredRuleOverride(createdAt: now.addingTimeInterval(-60), rule: ruleJSON(other)),
            StoredRuleOverride(createdAt: now.addingTimeInterval(-120), rule: ruleJSON(canaryOverride)),
            StoredRuleOverride(createdAt: now, rule: .string("not a rule")),
        ]
    }

    static let metrics = MetricsSnapshot(
        callbackDuration: .empty, decideToPosted: .empty, decideToPostedWithAX: .empty, echoRoundTrip: .empty,
        heldWait: .empty, focusRefresh: .empty, flushes: 1, tapTimeouts: 2, fallbackActivations: 0, echoLosses: 0,
        watchdogTrips: 0, lostWhilePostingBroken: 0)

    static func health(count: Int = 60) -> [HealthEvent] {
        var events = (0..<count).map { index in
            HealthEvent(kind: .flush, at: now.addingTimeInterval(Double(-index * 60)), bundle: reported)
        }
        events.append(HealthEvent(kind: .tapTimeout, at: now.addingTimeInterval(-3_600)))
        events.append(HealthEvent(kind: .tapTimeout, at: now.addingTimeInterval(-200_000)))  // older than 24 h
        events.append(HealthEvent(kind: .tapDisabledByUserInput, at: now.addingTimeInterval(-30)))
        return events
    }

    static let draft = BugReportDraft(
        app: reported, appName: "Chat", symptom: .duplicatedLetters, userDescription: "Tôi gõ " + Canary.typed,
        reproducesInPracticeField: false)

    static func report(draft: BugReportDraft? = draft, host: HostReportContext = host()) -> DiagnosticsReport {
        ReportAssembler.report(
            identity: identity, system: system, host: host, settings: settings(overrides: storedOverrides()),
            metrics: metrics, health: health(), probe: nil, draft: draft, now: now)
    }
}
