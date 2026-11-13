// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `testHook` setup steps (QA-R11 tap disable and recovery, permission revoked mid-session; 13.2 "tap timeout
// injection (test hook)"). Value grammar: `<hook>` fires in setup order before typing; `<hook>@<n>` fires after the
// first n entries of `keys`, so a hook can land in the middle of a word. Execution splits the key script at those
// points (ScenarioExecution.swift).

public import Diagnostics

public struct ScenarioHookStep: Sendable, Hashable {
    public var hook: AppTestHook
    /// Key-script entries typed before the hook fires; nil fires in setup order.
    public var afterKeys: Int?

    public init(hook: AppTestHook, afterKeys: Int? = nil) {
        self.hook = hook
        self.afterKeys = afterKeys
    }

    /// Parses `tapTimeout`, `revokePermission@6`. Nil for anything else.
    public static func parse(_ value: String) -> ScenarioHookStep? {
        let parts = value.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard let hook = AppTestHook(rawValue: parts[0]) else { return nil }
        guard parts.count == 2 else { return ScenarioHookStep(hook: hook) }
        guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let count = Int(parts[1])
        else { return nil }
        return ScenarioHookStep(hook: hook, afterKeys: count)
    }

    /// The hook of a setup step, nil when the step is not a valid `testHook`.
    public static func of(_ step: Scenario.SetupStep) -> ScenarioHookStep? {
        guard step.action == .testHook, let value = step.value else { return nil }
        return parse(value)
    }
}

/// A scenario's steps in execution order: setup steps (layout first) and the hooks deferred into the key script.
struct ScenarioSchedule: Sendable, Hashable {
    struct Deferred: Sendable, Hashable {
        var afterKeys: Int
        var step: Scenario.SetupStep
    }

    var setup: [Scenario.SetupStep]
    /// Sorted by `afterKeys`, stable for equal positions.
    var deferred: [Deferred]

    /// The `layout` is selected first, so no scenario inherits the keyboard layout or input source a previous one
    /// switched to (13.2 layout scenarios).
    init(_ scenario: Scenario) {
        let layout = scenario.layout.map { [Scenario.SetupStep(action: .selectInputSource, value: $0.rawValue)] } ?? []
        var setup = layout
        var deferred: [Deferred] = []
        for step in scenario.setup {
            if let after = ScenarioHookStep.of(step)?.afterKeys {
                deferred.append(Deferred(afterKeys: min(after, scenario.keys.count), step: step))
            } else {
                setup.append(step)
            }
        }
        self.setup = setup
        self.deferred = deferred.enumerated().sorted {
            ($0.element.afterKeys, $0.offset) < ($1.element.afterKeys, $1.offset)
        }
        .map(\.element)
    }

    /// The key script cut at the deferred hooks: (keys to type, step to perform after them, nil for the tail).
    func segments(of keys: [String]) -> [(keys: ArraySlice<String>, then: Scenario.SetupStep?)] {
        var segments: [(keys: ArraySlice<String>, then: Scenario.SetupStep?)] = []
        var typed = 0
        for item in deferred {
            segments.append((keys[typed..<item.afterKeys], item.step))
            typed = item.afterKeys
        }
        segments.append((keys[typed...], nil))
        return segments
    }

    /// Hooks the scenario triggers, in order (setup and deferred).
    static func hooks(of scenario: Scenario) -> [AppTestHook] {
        scenario.setup.compactMap { ScenarioHookStep.of($0)?.hook }
    }
}
