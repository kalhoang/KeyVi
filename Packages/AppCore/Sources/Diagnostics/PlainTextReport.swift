// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Human-readable report in the interface language, shown verbatim before copying or exporting (PLT-R1204).
// Same content as the JSON and the issue block; metadata only (PLT-R1202, PLT-R1203).

internal import AppModel
internal import Foundation

struct PlainTextReport {
    let report: DiagnosticsReport
    let labels: ReportLabels
    private var lines: [String] = []

    init(report: DiagnosticsReport, labels: ReportLabels) {
        self.report = report
        self.labels = labels
    }

    func render() -> String {
        var copy = self
        copy.renderAll()
        return copy.lines.joined(separator: "\n") + "\n"
    }

    private mutating func renderAll() {
        lines = [labels.title, labels.generatedAt + ": " + report.generatedAt.formatted(.iso8601)]
        renderAppAndSystem()
        renderInputAndPermissions()
        renderFocusAndRule()
        renderSettings()
        renderLatency()
        renderEventsAndReport()
    }

    // MARK: Sections

    private mutating func renderAppAndSystem() {
        section(labels.app)
        field(labels.version, report.app.version)
        field(labels.build, report.app.build)
        field(labels.channel, report.app.channel.rawValue)
        section(labels.system)
        field("macOS", report.system.macOSVersion + " (" + report.system.macOSBuild + ")")
        field(labels.architecture, report.system.architecture)
        field(labels.model, report.system.modelIdentifier)
        field(labels.systemLanguage, report.system.systemLanguage)
        field(labels.state, report.hostState.logCode)
    }

    private mutating func renderInputAndPermissions() {
        section(labels.keyboard)
        field(labels.layout, report.keyboard.layout?.rawValue)
        field(labels.sourceKind, report.keyboard.sourceKind.rawValue)
        field(labels.enabledSources, joined(report.keyboard.enabledSources.map(\.rawValue)))
        section(labels.permissions)
        field(labels.accessibility, report.permissions.accessibility.rawValue)
        field(labels.postEvent, report.permissions.postEvent.rawValue)
        field(labels.inputMonitoring, report.permissions.listenEvent.rawValue)
        field(labels.health, report.permissions.health.rawValue)
        section(labels.tap)
        field(labels.enabled, flag(report.tap.enabled))
        field(labels.location, report.tap.location)
        field(labels.timeouts, String(report.tap.timeoutsLast24Hours))
        field(labels.userInputDisables, String(report.tap.userInputDisablesLast24Hours))
        field(labels.lastReenable, report.tap.lastReenableReason?.rawValue ?? labels.none)
        section(labels.secureInput)
        field(labels.enabled, flag(report.secureInput.enabled))
        field(labels.likelyHolder, report.secureInput.likelyHolder?.rawValue ?? labels.none)
        field(labels.holderKind, report.secureInput.holderKind?.rawValue)
    }

    private mutating func renderFocusAndRule() {
        if let focus = report.focus {
            section(labels.focus)
            field(labels.app, focus.bundle.rawValue)
            field(labels.version, focus.appVersion)
            field(labels.engine, focus.engine.rawValue)
            field(labels.axData, focus.axAvailability.rawValue)
            field(labels.role, focus.role)
            field(labels.subrole, focus.subrole)
            field(labels.identifier, focus.identifier)
            field(labels.domClasses, joined(focus.domClasses))
            field(labels.editable, focus.editable.map(flag))
            field(labels.secureField, flag(focus.secure))
        }
        guard let rule = report.rule else { return }
        section(labels.rule)
        field(labels.ruleID, rule.rule?.rawValue ?? labels.none)
        field(labels.source, rule.source.rawValue)
        field(labels.specificity, String(rule.specificity))
        field(labels.strategy, rule.strategy.rawValue)
        field(labels.parameters, ReportJSON.compact(rule.parameters))
        field(labels.isUserOverride, flag(rule.isUserOverride))
        guard let userOverride = rule.userOverride else { return }
        lines.append(labels.userOverride + ":")
        // Rule JSON for maintainers (PLT-R541, ADR 0312); pretty-printed, so it spans several lines.
        lines += ReportJSON.rule(userOverride, pretty: true).split(separator: "\n").map { "  " + $0 }
        field(labels.omittedFields, joined(userOverride.omittedMatchFields.map(\.rawValue)))
    }

    private mutating func renderSettings() {
        let settings = report.settings
        section(labels.settings)
        field(labels.typingMethod, settings.typingMethod.rawValue)
        field(labels.tonePlacement, settings.tonePlacement.rawValue)
        field(labels.englishRestore, flag(settings.englishRestore))
        field(labels.standaloneW, flag(settings.standaloneW))
        field(labels.bracketKeys, flag(settings.bracketKeys))
        field(labels.macros, flag(settings.macrosEnabled))
        field(labels.macroCount, String(settings.macroCount))  // count only (PRD-R33)
        field(labels.macrosInEnglish, flag(settings.macrosInEnglishMode))
        field(labels.rememberPerApp, flag(settings.rememberPerApp))
        field(labels.toggleHotkey, BlockFields.hotkey(settings.toggleHotkey))
        field(labels.restoreHotkey, flag(settings.restoreHotkeySet))
        field(labels.interfaceLanguage, settings.interfaceLanguage.rawValue)
        field(labels.channel, settings.updateChannel.rawValue)
        field(labels.changedSettings, joined(settings.explicitlySetKeys))
        guard let mode = report.reportedAppMode else { return }
        section(labels.appMode)
        field(labels.app, mode.bundle.rawValue)
        field(labels.perAppRule, mode.rule?.rawValue ?? labels.none)
        field(labels.rememberedMode, mode.rememberedMode?.rawValue ?? labels.none)
    }

    private mutating func renderLatency() {
        let metrics = report.latency.metrics
        section(labels.latency)
        for (name, histogram) in BlockFields.latencyHistograms(metrics) {
            let p50 = BlockFields.microseconds(histogram.percentile(0.5))
            let p99 = BlockFields.microseconds(histogram.percentile(0.99))
            let values = histogram.count == 0 ? labels.none : "p50 " + p50 + " µs, p99 " + p99 + " µs"
            field(name.uppercased(), values + " (" + String(histogram.count) + " " + labels.samples + ")")
        }
        section(labels.counters)
        for (name, value) in BlockFields.counters(metrics) { field(name, String(value)) }
        guard let probe = report.latency.probe else { return }
        section(labels.latencyTest)
        field(labels.generatedAt, probe.ranAt.formatted(.iso8601))
        for result in probe.results {
            let t2 =
                "T2 p50 " + String(result.decideToPostedP50Microseconds) + " µs, p99 "
                + String(result.decideToPostedP99Microseconds) + " µs"
            let t4 =
                "T4 p50 " + String(result.endToEndDeltaP50Microseconds) + " µs, p99 "
                + String(result.endToEndDeltaP99Microseconds) + " µs"
            field(result.profile.rawValue, t2 + "; " + t4 + " (" + String(result.samples) + " " + labels.samples + ")")
        }
    }

    private mutating func renderEventsAndReport() {
        section(labels.events)
        if report.healthEvents.isEmpty { lines.append("  " + labels.none) }
        lines += report.healthEvents.map { "  " + $0.summaryLine }
        section(labels.conflicts)
        lines.append(
            "  "
                + (report.conflictingInputApps.isEmpty
                    ? labels.none : joined(report.conflictingInputApps.map(\.rawValue))))
        guard let userReport = report.userReport else { return }
        section(labels.userReport)
        field(labels.symptom, labels.symptoms[userReport.symptom] ?? userReport.symptom.rawValue)
        field(labels.reportedApp, userReport.reportedApp?.rawValue)
        field(labels.practiceField, userReport.reproducesInPracticeField.map(flag))
    }

    // MARK: Helpers

    private mutating func section(_ title: String) {
        lines.append("")
        lines.append("[" + title + "]")
    }

    private mutating func field(_ label: String, _ value: String?) {
        let text = value.map { MetadataText.singleLine($0, maxLength: 2_000) }
        lines.append("  " + label + ": " + (text.flatMap { $0.isEmpty ? nil : $0 } ?? labels.unknown))
    }

    private func flag(_ value: Bool) -> String { value ? labels.yes : labels.no }

    private func joined(_ values: [String]) -> String { values.isEmpty ? labels.none : values.joined(separator: ", ") }
}
