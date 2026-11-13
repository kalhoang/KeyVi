// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Ready-made `DiagnosticsReport` values for tests of every consumer (renderers, bug report composer, the
// diagnostics window). The brand values are neutral placeholders, never the real slug or bundle ID; the
// bundle IDs are fixtures (PLT-R501 allows them in TestSupport).

public import AppModel
public import Diagnostics
public import Foundation

public enum DiagnosticsFixtures {
    public static let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)
    public static let reportedBundle = BundleKey(rawValue: "com.example.Browser")!

    public static let identity = AppIdentity(
        displayName: "Sample App", slug: "sample-app", bundleIdentifier: "org.example.SampleApp", version: "0.1.0",
        build: "10001", channel: .beta)

    public static let system = SystemInfo(
        macOSVersion: "27.1", macOSBuild: "26B12", architecture: "arm64", modelIdentifier: "Mac15,3",
        uiLanguage: .vietnamese, systemLanguage: "vi-VN")

    /// Every section filled: focus, rule with a user override, per-app mode, latency probe, health events and a
    /// user report. Used for the golden issue block (Tests/DiagnosticsTests/Fixtures/issue-block-v1.txt).
    public static func representativeReport() -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: generatedAt, app: identity, system: system, hostState: .readyVietnamese,
            keyboard: .init(
                layout: InputSourceID(rawValue: "com.apple.keylayout.ABC"), sourceKind: .asciiLayout,
                enabledSources: [
                    InputSourceID(rawValue: "com.apple.keylayout.ABC")!,
                    InputSourceID(rawValue: "com.apple.keylayout.US")!,
                ]),
            permissions: .init(accessibility: .granted, postEvent: .granted, listenEvent: .unknown, health: .ready),
            tap: .init(
                enabled: true, timeoutsLast24Hours: 1, userInputDisablesLast24Hours: 0, lastReenableReason: .tapTimeout),
            secureInput: .init(enabled: false, likelyHolder: nil, holderKind: nil),
            focus: .init(
                bundle: reportedBundle, appVersion: "156.0.8078.80", engine: .chromium, axAvailability: .available,
                role: "AXTextField", subrole: nil, identifier: nil, domClasses: [], editable: true, secure: false),
            rule: representativeRule(), settings: settings(),
            reportedAppMode: .init(
                bundle: reportedBundle, rule: .remember, rememberedMode: .vietnamese),
            latency: .init(metrics: representativeMetrics(), probe: representativeProbe()),
            healthEvents: representativeHealthEvents(), conflictingInputApps: [],
            userReport: .init(
                symptom: .duplicatedLetters, reportedApp: reportedBundle, reproducesInPracticeField: false))
    }

    /// Optional sections empty: no focus, rule, per-app mode, probe, health events or user report.
    public static func minimalReport() -> DiagnosticsReport {
        DiagnosticsReport(
            generatedAt: generatedAt, app: identity, system: system, hostState: .noPermission,
            keyboard: .init(layout: nil, sourceKind: .unknown, enabledSources: []),
            permissions: .init(
                accessibility: .denied, postEvent: .denied, listenEvent: .unknown, health: .noPermission),
            tap: .init(
                enabled: false, timeoutsLast24Hours: 0, userInputDisablesLast24Hours: 0, lastReenableReason: nil),
            secureInput: .init(enabled: false, likelyHolder: nil, holderKind: nil), focus: nil, rule: nil,
            settings: settings(), reportedAppMode: nil,
            latency: .init(metrics: PlatformMetrics().snapshot(), probe: nil),
            healthEvents: [], conflictingInputApps: [], userReport: nil)
    }

    public static func settings() -> DiagnosticsReport.SettingsSection {
        DiagnosticsReport.SettingsSection(
            typingMethod: .telex, tonePlacement: .traditional, englishRestore: true, standaloneW: true,
            bracketKeys: false, macrosEnabled: true, macroCount: 12, macrosInEnglishMode: false, rememberPerApp: true,
            toggleHotkey: .defaultToggle, restoreHotkeySet: false, interfaceLanguage: .vietnamese,
            updateChannel: .beta, explicitlySetKeys: ["typingMethod", "macrosEnabled"])
    }

    public static func representativeRule() -> DiagnosticsReport.RuleSection {
        let ruleID = RuleID(rawValue: "user.browser.1")!
        let userOverride = DiagnosticsReport.ReportedOverride(
            id: ruleID, match: .init(bundleIds: [reportedBundle], axRoles: ["AXTextField"]),
            strategy: .backspaceReplace,
            parameters: .init(inlineCompletion: .axSelectionThenPlaceholder), fallback: [.selectReplace],
            requireTextFocus: .whenKnown, verifyReentry: nil, engineContext: nil, omittedMatchFields: [.webURLPrefixes])
        return DiagnosticsReport.RuleSection(
            rule: ruleID, source: .user, specificity: 10, strategy: .backspaceReplace,
            parameters: .init(
                unicodeChunk: 20, interEventDelayUs: 0, postDeleteSettleUs: 0, firstEditDelayUs: 0,
                inlineCompletion: .axSelectionThenPlaceholder, allowMultiCharEvents: true, allowSplit: true,
                longTextThreshold: 64, restoreDelayMs: 400, verifyAfterEdit: false),
            isUserOverride: true, userOverride: userOverride)
    }

    /// Histograms with a few known samples (T1 around 41 µs, T2 around 1.3 ms) and some counters.
    public static func representativeMetrics() -> MetricsSnapshot {
        let metrics = PlatformMetrics()
        for _ in 0..<99 { metrics.callbackDuration.record(nanoseconds: 20_000) }
        metrics.callbackDuration.record(nanoseconds: 41_000)
        for _ in 0..<50 { metrics.decideToPosted.record(nanoseconds: 900_000) }
        metrics.decideToPosted.record(nanoseconds: 1_300_000)
        metrics.echoRoundTrip.record(nanoseconds: 2_000_000)
        metrics.focusRefresh.record(nanoseconds: 12_000_000)
        metrics.tapTimeouts.increment()
        metrics.flushes.increment(by: 2)
        return metrics.snapshot()
    }

    public static func representativeProbe() -> LatencyProbeResult {
        LatencyProbeResult(
            ranAt: generatedAt.addingTimeInterval(-60),
            results: [
                .init(
                    profile: .normal, decideToPostedP50Microseconds: 900, decideToPostedP99Microseconds: 1_300,
                    endToEndDeltaP50Microseconds: 4_000, endToEndDeltaP99Microseconds: 7_500, samples: 200),
                .init(
                    profile: .burst, decideToPostedP50Microseconds: 1_100, decideToPostedP99Microseconds: 2_400,
                    endToEndDeltaP50Microseconds: 6_000, endToEndDeltaP99Microseconds: 12_000, samples: 200),
            ])
    }

    public static func representativeHealthEvents() -> [HealthEvent] {
        [
            HealthEvent(kind: .tapTimeout, at: generatedAt.addingTimeInterval(-3_600)),
            HealthEvent(
                kind: .fallbackActivated, at: generatedAt.addingTimeInterval(-600), bundle: reportedBundle,
                rule: RuleID(rawValue: "user.browser.1"), detail: .fallback(from: .axReplace, to: .backspaceReplace)),
            HealthEvent(
                kind: .secureInputEpisode, at: generatedAt.addingTimeInterval(-60),
                detail: .secureInput(holder: nil, holderKind: .loginWindow, durationMilliseconds: 4_000)),
        ]
    }
}
