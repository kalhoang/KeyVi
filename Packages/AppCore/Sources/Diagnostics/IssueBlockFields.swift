// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Field values of the issue block, section by section, in the order of the ADR 0501 example. Values are
// metadata only (PLT-R1202, PLT-R1203, PRD-R45): enumerated raw values, validated identifiers, counts,
// durations and bundle metadata strings. Booleans are `true`/`false`, lists are comma-separated.

internal import AppModel
internal import Foundation

enum BlockFields {
    static func addReportAndApp(_ report: DiagnosticsReport, to list: inout BlockFieldList) {
        let reported = report.userReport?.reportedApp
        let focus = report.focus
        list.add(.reportBundle, reported?.rawValue)
        list.add(.reportAppVersion, reported != nil && reported == focus?.bundle ? focus?.appVersion : nil)
        list.add(.reportSymptom, report.userReport.map { blockSymptom($0.symptom) })
        list.add("report.symptomDetail", report.userReport?.symptom.rawValue)
        list.add("report.practiceField", report.userReport?.reproducesInPracticeField.map(flag))
        list.add(.appVersion, report.app.version)
        list.add(.appBuild, report.app.build)
        list.add(.appChannel, report.app.channel.rawValue)
        list.add(.macOSVersion, report.system.macOSVersion)
        list.add(.macOSBuild, report.system.macOSBuild)
        list.add(.architecture, report.system.architecture)
        list.add(.model, report.system.modelIdentifier)
        list.add("ui.locale", report.system.systemLanguage)
    }

    static func addHostAndInput(_ report: DiagnosticsReport, to list: inout BlockFieldList) {
        list.add(.method, report.settings.typingMethod.rawValue)
        list.add(.layout, report.keyboard.layout?.rawValue)
        list.add("input.sourceType", report.keyboard.sourceKind.rawValue)
        list.add("input.enabledSources", Self.list(report.keyboard.enabledSources), maxLength: 2_000)
        list.add("permission.accessibility", report.permissions.accessibility.rawValue)
        list.add("permission.inputMonitoring", report.permissions.listenEvent.rawValue)
        list.add("permission.postEvent", report.permissions.postEvent.rawValue)
        list.add("permission.health", report.permissions.health.rawValue)
        list.add(.hostState, report.hostState.logCode)
        list.add("tap.state", report.tap.enabled ? "enabled" : "disabled")
        list.add("tap.location", report.tap.location)
        list.add("tap.timeouts24h", String(report.tap.timeoutsLast24Hours))
        list.add("tap.userInputDisables24h", String(report.tap.userInputDisablesLast24Hours))
        list.add("tap.lastReenableReason", report.tap.lastReenableReason?.rawValue ?? "none")
        list.add(.secureInput, flag(report.secureInput.enabled))
        list.add("secureInput.holderBundleId", report.secureInput.likelyHolder?.rawValue)
        list.add("secureInput.holderKind", report.secureInput.holderKind?.rawValue)
    }

    static func addFocusAndRule(_ report: DiagnosticsReport, to list: inout BlockFieldList) {
        let focus = report.focus
        list.add(.focusBundle, focus?.bundle.rawValue)
        list.add(.focusAppVersion, focus?.appVersion)
        list.add(.focusEngine, focus?.engine.rawValue)
        list.add("focus.ax", focus?.axAvailability.rawValue)
        list.add("focus.role", focus?.role)
        list.add("focus.subrole", focus?.subrole)
        list.add("focus.identifier", focus?.identifier)
        list.add("focus.domClasses", focus.map { $0.domClasses.joined(separator: ",") }, maxLength: 1_000)
        list.add("focus.editable", focus?.editable.map(flag))
        list.add("focus.secure", focus.map { flag($0.secure) })
        let rule = report.rule
        list.add(.rule, rule?.rule?.rawValue)
        list.add("rule.specificity", rule.map { String($0.specificity) })
        list.add(.strategy, rule?.strategy.rawValue)
        list.add("rule.params", rule.map { ReportJSON.compact($0.parameters) }, maxLength: 2_000)
        list.add("rule.source", rule?.source.rawValue)
        list.add("rule.override", rule.map { flag($0.isUserOverride) })
        let userOverride = rule?.userOverride
        list.add("rule.userOverride", userOverride.map { ReportJSON.rule($0, pretty: false) }, maxLength: 8_000)
        list.add(
            "rule.userOverrideOmitted",
            userOverride.map { $0.omittedMatchFields.map(\.rawValue).joined(separator: ",") })
    }

    static func addSettings(_ report: DiagnosticsReport, to list: inout BlockFieldList) {
        let settings = report.settings
        list.add("settings.toneStyle", settings.tonePlacement.rawValue)
        list.add("settings.autoRestore", flag(settings.englishRestore))
        list.add("settings.standaloneW", flag(settings.standaloneW))
        list.add("settings.bracketKeys", flag(settings.bracketKeys))
        list.add("settings.macros", flag(settings.macrosEnabled))
        list.add("settings.macroCount", String(settings.macroCount))  // count only (PRD-R33)
        list.add("settings.macrosInEnglish", flag(settings.macrosInEnglishMode))
        list.add("settings.rememberPerApp", flag(settings.rememberPerApp))
        list.add("settings.toggleHotkey", hotkey(settings.toggleHotkey))
        list.add("settings.restoreHotkey", flag(settings.restoreHotkeySet))
        list.add("settings.interfaceLanguage", settings.interfaceLanguage.rawValue)
        list.add("settings.updateChannel", settings.updateChannel.rawValue)
        list.add("settings.changed", settings.explicitlySetKeys.joined(separator: ","), maxLength: 2_000)
        let mode = report.reportedAppMode
        list.add("appMode.bundleId", mode?.bundle.rawValue)
        list.add("appMode.rule", mode?.rule?.rawValue)
        list.add("appMode.remembered", mode?.rememberedMode?.rawValue)
    }

    static func addLatency(_ report: DiagnosticsReport, to list: inout BlockFieldList) {
        let metrics = report.latency.metrics
        for (name, histogram) in latencyHistograms(metrics) {
            list.add("latency." + name + ".p50Us", microseconds(histogram.percentile(0.5)))
            list.add("latency." + name + ".p99Us", microseconds(histogram.percentile(0.99)))
            list.add("latency." + name + ".samples", String(histogram.count))
        }
        for (name, value) in counters(metrics) { list.add("counters." + name, String(value)) }
        guard let probe = report.latency.probe else { return }
        list.add("probe.ranAt", probe.ranAt.formatted(.iso8601))
        for result in probe.results {
            let prefix = "probe." + result.profile.rawValue
            list.add(prefix + ".t2.p50Us", String(result.decideToPostedP50Microseconds))
            list.add(prefix + ".t2.p99Us", String(result.decideToPostedP99Microseconds))
            list.add(prefix + ".t4.p50Us", String(result.endToEndDeltaP50Microseconds))
            list.add(prefix + ".t4.p99Us", String(result.endToEndDeltaP99Microseconds))
            list.add(prefix + ".samples", String(result.samples))
        }
    }

    // MARK: Value helpers

    /// ADR 0501 value set of `report.symptom` (the PRD-R47 chips). The two PLT-R1205 symptoms without a chip
    /// map to the closest chip; `report.symptomDetail` keeps the exact value.
    static func blockSymptom(_ symptom: DiagnosticsReport.Symptom) -> String {
        switch symptom {
        case .lostLetters: "missing"
        case .duplicatedLetters: "duplicated"
        case .wrongTone: "wrongTone"
        case .cannotTypeVietnamese, .nothingTyped: "cannotType"
        case .lag: "lag"
        case .lettersOutOfOrder, .other: "other"
        }
    }

    static func flag(_ value: Bool) -> String { value ? "true" : "false" }

    static func list(_ values: [some RawRepresentable<String>]) -> String {
        values.map(\.rawValue).joined(separator: ",")
    }

    /// `modifierTap:controlShift`, `keyCombo:<modifiers>:<keyCode>` or `key:<keyCode>` (no characters).
    static func hotkey(_ binding: HotkeyBinding) -> String {
        switch binding {
        case .modifierTap(let chord): "modifierTap:" + chord.rawValue
        case .keyCombo(let modifiers, let keyCode):
            "keyCombo:" + String(modifiers.rawValue) + ":" + String(keyCode.rawValue)
        case .key(let keyCode): "key:" + String(keyCode.rawValue)
        }
    }

    /// Bucket upper bound in whole microseconds, rounded up; empty when the histogram has no samples.
    static func microseconds(_ nanoseconds: UInt64?) -> String {
        guard let nanoseconds else { return "" }
        return String(nanoseconds / 1_000 + (nanoseconds % 1_000 == 0 ? 0 : 1))
    }

    /// Histograms in report order with their 8.1 metric names (02-platform.md).
    static func latencyHistograms(_ metrics: MetricsSnapshot) -> [(String, HistogramSnapshot)] {
        [
            ("t1", metrics.callbackDuration), ("t2", metrics.decideToPosted), ("t3", metrics.decideToPostedWithAX),
            ("echo", metrics.echoRoundTrip), ("t5", metrics.heldWait), ("t6", metrics.focusRefresh),
        ]
    }

    static func counters(_ metrics: MetricsSnapshot) -> [(String, UInt64)] {
        [
            ("flushes", metrics.flushes), ("tapTimeouts", metrics.tapTimeouts),
            ("fallbacks", metrics.fallbackActivations), ("echoLosses", metrics.echoLosses),
            ("watchdogTrips", metrics.watchdogTrips), ("lostWhilePostingBroken", metrics.lostWhilePostingBroken),
        ]
    }
}
