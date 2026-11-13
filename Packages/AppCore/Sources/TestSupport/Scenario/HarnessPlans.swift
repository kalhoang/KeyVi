// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Human-readable plans printed by `compat-harness <command> --dry-run`. Pure functions over loaded data: the
// dry run never creates a keyboard driver, never launches an app and never posts an event. The plan shows
// scenario fixture text (test data written in the repository), never anything a person typed (PLT-R901).

internal import AppModel
internal import Foundation

enum HarnessPlans {
    static func scenarioPlan(_ scenarios: [Scenario], targets: HarnessTargets, options: HarnessOptions) -> [String] {
        var lines = [
            "compat-harness run --dry-run: \(scenarios.count) scenario(s) from " + options.scenarios
                + " (plan only, no events are posted)",
            "TestHost bundle id: " + (targets.testHostBundleID?.rawValue ?? "unresolved (scripts/brand.env missing)"),
        ]
        var totalKeys = 0
        var totalRange: ClosedRange<UInt64> = 0...0
        for original in scenarios {
            var scenario = original
            if let profile = options.profile { scenario.timing = profile }
            let keys = scenario.keys.count
            let range = KeyEventPlan.estimatedDuration(keystrokes: keys, profile: scenario.timing)
            totalKeys += keys
            totalRange = (totalRange.lowerBound + range.lowerBound)...(totalRange.upperBound + range.upperBound)
            lines += describe(scenario, targets: targets, duration: range)
        }
        lines.append(
            "Total: \(scenarios.count) scenario(s), \(totalKeys) keystroke(s), typing time " + seconds(totalRange))
        return lines
    }

    static func describe(_ scenario: Scenario, targets: HarnessTargets, duration: ClosedRange<UInt64>) -> [String] {
        let target =
            targets.resolve(scenario.targetBundleId)?.rawValue ?? "UNRESOLVED " + scenario.targetBundleId.rawValue
        let events = (try? KeyEventPlan.make(keys: scenario.keys, profile: scenario.timing, seed: 0).events.count) ?? 0
        let setup = scenario.setup.map { step in
            step.action.rawValue + (step.value.map { " " + targets.expand($0) } ?? "")
        }
        return [
            "- " + scenario.id,
            "    target " + target + ", method " + scenario.method.rawValue + ", layout "
                + (scenario.layout?.rawValue ?? "current") + ", timing " + scenario.timing.rawValue + ", readback "
                + scenario.readback.rawValue,
            "    setup: " + (setup.isEmpty ? "none" : setup.joined(separator: "; ")),
            "    keys: \(scenario.keys.count) keystroke(s), \(events) event(s), " + seconds(duration),
            "    expect: " + expectation(scenario.expect),
        ]
    }

    static func expectation(_ expect: Scenario.Expectation) -> String {
        var parts: [String] = []
        if let text = expect.text { parts.append("text \u{201C}" + text + "\u{201D}") }
        if let paused = expect.paused { parts.append("paused \(paused)") }
        if let holder = expect.holderBundleId { parts.append("holder " + holder.rawValue) }
        if let composed = expect.firstKeyAfterReleaseComposed {
            parts.append("first key after release composed \(composed)")
        }
        return parts.joined(separator: ", ")
    }

    static func coverage(_ gaps: [RuleScenarioGap], rules: Int, file: String) -> [String] {
        guard !gaps.isEmpty else { return ["Rule coverage (" + file + "): all \(rules) rule(s) have a scenario"] }
        return ["Rule coverage (" + file + "): \(gaps.count) of \(rules) rule(s) have no scenario file"]
            + gaps.map { "  missing: " + $0.description }
    }

    static func soakPlan(
        _ plan: SoakPlan, targets: [Scenario], resolved: HarnessTargets, profile: Scenario.TimingProfile
    )
        -> [String]
    {
        let duration = KeyEventPlan.estimatedDuration(keystrokes: plan.keystrokes, profile: profile)
        var lines = [
            "compat-harness soak --dry-run: \(plan.keystrokes) keystroke(s) in \(plan.chunks.count) chunk(s), "
                + "profile " + profile.rawValue + ", typing time " + seconds(duration) + " (plan only, no events)",
            "Targets (round robin):",
        ]
        for (index, target) in targets.enumerated() {
            let chunks = plan.chunks.filter { $0.target == index }
            lines.append(
                "  " + target.id + ": " + (resolved.resolve(target.targetBundleId)?.rawValue ?? "UNRESOLVED")
                    + ", readback " + target.readback.rawValue + ", \(chunks.count) chunk(s), "
                    + "\(chunks.reduce(0) { $0 + $1.keys.count }) keystroke(s)")
        }
        lines.append("App under test: " + (resolved.appUnderTestBundleID?.rawValue ?? "unresolved"))
        lines.append(
            "Checks: text of every chunk; footprint growth at most \(SoakSummary.growthGateMegabytesPerHour) MB/h (M2); "
                + "no modifier held at the end (QA-R16)")
        return lines
    }

    static func benchPlan(_ metrics: [PlatformMetric], options: HarnessOptions, targets: HarnessTargets) -> [String] {
        var lines = [
            "compat-harness bench --dry-run: \(metrics.count) metric(s), median of \(options.runs) run(s), output "
                + (options.output ?? "stdout") + " (ADR 0502 formatVersion 1, calibrated false; plan only)",
            "App under test: " + (targets.appUnderTestBundleID?.rawValue ?? "unresolved"),
        ]
        for metric in metrics {
            lines.append(
                "  " + metric.name + ": gate \(metric.gate) " + metric.unit + ", source " + metric.source.rawValue
                    + ", " + metric.definition)
        }
        lines.append(
            "Durations per run: idle \(options.idleSeconds) s (C1), typing \(options.typingSeconds) s at 10 keys/s (C2)"
        )
        return lines
    }

    static func seconds(_ range: ClosedRange<UInt64>) -> String {
        let low = Double(range.lowerBound) / 1_000_000_000
        let high = Double(range.upperBound) / 1_000_000_000
        return String(format: "%.1f-%.1f s", low, high)
    }
}
