// SPDX-License-Identifier: GPL-3.0-or-later
//
// 13.2 keyboard driver: physical key names, timing profiles (normal 80-150 ms, fast 30 ms, burst 5 ms),
// modifiers as flagsChanged, deterministic plans, no stuck keys after a failure. Virtual time only.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

@Suite struct ScenarioKeysTests {
    /// Every literal alternative of the schema's `keys` pattern maps to a key.
    @Test func everySchemaKeyNameIsKnown() throws {
        let names =
            "abcdefghijklmnopqrstuvwxyz0123456789".map(String.init) + [
                "space", "return", "tab", "backspace", "escape", "left", "right", "up", "down", "shift", "control",
                "option",
                "command", "comma", "period", "semicolon", "slash", "minus", "equal", "quote", "leftBracket",
                "rightBracket",
            ]
        for name in names { #expect(ScenarioKeys.stroke(name) != nil, "\(name)") }
        #expect(ScenarioKeys.keyCodes.count == names.count - 4)  // modifiers are not base keys
    }

    @Test func positionsFollowTheANSIKeyboard() {
        #expect(ScenarioKeys.stroke("a")?.keyCode == KeyCode(rawValue: 0x00))
        #expect(ScenarioKeys.stroke("z")?.keyCode == KeyCode(rawValue: 0x06))  // types "y" on QWERTZ
        #expect(ScenarioKeys.stroke("6")?.keyCode == KeyCode(rawValue: 0x16))
        #expect(ScenarioKeys.stroke("backspace")?.keyCode == .delete)  // PLT-R407: never forward delete
        #expect(ScenarioKeys.stroke("return")?.keyCode == .returnKey)
    }

    @Test func modifierCombinations() {
        #expect(
            ScenarioKeys.stroke("shift+a")
                == KeyStroke(modifier: .shift, keyCode: KeyCode(rawValue: 0), keyIsModifier: false))
        #expect(ScenarioKeys.stroke("command+v")?.modifier == .command)
        #expect(
            ScenarioKeys.stroke("control+shift") == KeyStroke(modifier: .control, keyCode: .shift, keyIsModifier: true))
        #expect(ScenarioKeys.stroke("shift") == KeyStroke(modifier: nil, keyCode: .shift, keyIsModifier: true))
    }

    @Test(arguments: ["", "A", "đ", "a+b", "shift+shift", "shift+leftBracket", "shift+a+b", "hyper+a", "f1", "+a"])
    func invalidNames(name: String) {
        #expect(ScenarioKeys.stroke(name) == nil)
    }

    @Test func scriptErrorsNameTheEntry() {
        #expect(throws: KeyScriptError.emptyScript) { try ScenarioKeys.strokes([]) }
        #expect(throws: KeyScriptError.unknownKey(index: 2, name: "X")) { try ScenarioKeys.strokes(["a", "b", "X"]) }
    }

    @Test func modifierFlagsCarryTheLeftDeviceBit() {
        #expect(ScenarioModifier.shift.flags == 0x0002_0002)
        #expect(ScenarioModifier.control.flags == 0x0004_0001)
        #expect(ScenarioModifier.option.flags == 0x0008_0020)
        #expect(ScenarioModifier.command.flags == 0x0010_0008)
        #expect(ScenarioModifier.allCases.map(\.keyCode) == [.shift, .control, .option, .command])
    }
}

@Suite struct KeyEventPlanTests {
    @Test func profilesMatchSection13_2() {
        #expect(Scenario.TimingProfile.normal.intervalRange == 80_000_000...150_000_000)
        #expect(Scenario.TimingProfile.fast.intervalRange == 30_000_000...30_000_000)
        #expect(Scenario.TimingProfile.burst.intervalRange == 5_000_000...5_000_000)
    }

    @Test func burstPlanIsEvenlySpaced() throws {
        let plan = try KeyEventPlan.make(keys: ["d", "d", "i"], profile: .burst, seed: 1)
        #expect(plan.keystrokes == 3)
        #expect(plan.events.map(\.offset) == [0, 2_500_000, 5_000_000, 7_500_000, 10_000_000, 12_500_000])
        #expect(plan.events.map(\.phase) == [.down, .up, .down, .up, .down, .up])
        #expect(plan.events.allSatisfy { !$0.isFlagsChanged && $0.flags == 0 })
        #expect(plan.durationNanoseconds == 12_500_000)
    }

    @Test func normalIntervalsStayInRangeAndAreSeeded() throws {
        let keys = Array(repeating: "a", count: 200)
        let plan = try KeyEventPlan.make(keys: keys, profile: .normal, seed: 42)
        let downs = plan.events.filter { $0.phase == .down }.map(\.offset)
        let intervals = zip(downs.dropFirst(), downs).map { $0 - $1 }
        #expect(intervals.allSatisfy { (80_000_000...150_000_000).contains($0) })
        #expect(Set(intervals).count > 50)  // actually random, not a constant
        #expect(try KeyEventPlan.make(keys: keys, profile: .normal, seed: 42) == plan)
        #expect(try KeyEventPlan.make(keys: keys, profile: .normal, seed: 43) != plan)
        // Holds never reach the next keystroke.
        let ups = plan.events.filter { $0.phase == .up }.map(\.offset)
        #expect(zip(ups, downs.dropFirst()).allSatisfy { $0 < $1 })
    }

    @Test func chordUsesFlagsChangedAroundTheKey() throws {
        let plan = try KeyEventPlan.make(keys: ["shift+a"], profile: .fast, seed: 0)
        #expect(plan.events.map(\.keyCode) == [.shift, KeyCode(rawValue: 0), KeyCode(rawValue: 0), .shift])
        #expect(plan.events.map(\.isFlagsChanged) == [true, false, false, true])
        #expect(plan.events.map(\.flags) == [0x0002_0002, 0x0002_0002, 0x0002_0002, 0])
        #expect(plan.events.map(\.offset) == [0, 5_000_000, 10_000_000, 15_000_000])
    }

    @Test func modifierOnlyChordForTheToggleHotkey() throws {
        // PRD-R14 default toggle: Control+Shift pressed together and released.
        let plan = try KeyEventPlan.make(keys: ["control+shift"], profile: .burst, seed: 0)
        #expect(plan.events.allSatisfy { $0.isFlagsChanged })
        #expect(plan.events.map(\.flags) == [0x0004_0001, 0x0006_0003, 0x0004_0001, 0])
        let single = try KeyEventPlan.make(keys: ["option"], profile: .burst, seed: 0)
        #expect(single.events.map(\.flags) == [0x0008_0020, 0])
    }

    @Test func estimatedDurationBoundsThePlan() throws {
        let keys = Array(repeating: "a", count: 50)
        for profile in [Scenario.TimingProfile.normal, .fast, .burst] {
            let range = KeyEventPlan.estimatedDuration(keystrokes: keys.count, profile: profile)
            let plan = try KeyEventPlan.make(keys: keys, profile: profile, seed: 7)
            #expect(range.contains(plan.durationNanoseconds), "\(profile)")
        }
        #expect(KeyEventPlan.estimatedDuration(keystrokes: 0, profile: .burst) == 2_500_000...2_500_000)
    }

    @Test func seedMixesTheScenarioID() {
        #expect(SeededGenerator.seed(1, scenario: "a") != SeededGenerator.seed(1, scenario: "b"))
        #expect(SeededGenerator.seed(1, scenario: "a") == SeededGenerator.seed(1, scenario: "a"))
    }
}

@Suite struct PhysicalKeyboardDriverTests {
    @Test func postsEveryEventAtItsDeadline() async throws {
        let clock = ManualClock()
        let sink = RecordingKeyEventSink(clock: clock)
        let start = clock.now().nanoseconds
        try await PhysicalKeyboardDriver(sink: sink, clock: clock, seed: 3).type(["d", "d", "i"], profile: .burst)
        let plan = try KeyEventPlan.make(keys: ["d", "d", "i"], profile: .burst, seed: 3)
        #expect(sink.records.map(\.event) == plan.events)
        #expect(sink.records.map { $0.postedAt.nanoseconds - start } == plan.events.map(\.offset))
    }

    @Test func fixedTenKeysPerSecond() async throws {
        let clock = ManualClock()
        let sink = RecordingKeyEventSink(clock: clock)
        let driver = PhysicalKeyboardDriver(sink: sink, clock: clock, seed: 0)
        try await driver.type(Array(repeating: "a", count: 11), intervalRange: 100_000_000...100_000_000)
        let downs = sink.records.filter { $0.event.phase == .down }.map(\.postedAt.nanoseconds)
        #expect(downs.last! - downs.first! == 1_000_000_000)
    }

    @Test func unknownKeyPostsNothing() async {
        let clock = ManualClock()
        let sink = RecordingKeyEventSink(clock: clock)
        await #expect(throws: KeyScriptError.self) {
            try await PhysicalKeyboardDriver(sink: sink, clock: clock, seed: 0).type(["a", "?"], profile: .fast)
        }
        #expect(sink.records.isEmpty)
    }

    /// QA-R16: a failure in the middle of a chord releases the held modifier, so nothing stays stuck.
    @Test func failureReleasesHeldKeys() async {
        let clock = ManualClock()
        let sink = RecordingKeyEventSink(clock: clock)
        sink.failAfter(2)  // shift down, a down, then the a-up post fails
        await #expect(throws: RecordingSinkError.injected) {
            try await PhysicalKeyboardDriver(sink: sink, clock: clock, seed: 0).type(["shift+a"], profile: .fast)
        }
        let events = sink.records.map(\.event)
        #expect(events.count == 4)
        #expect(events[2].keyCode == KeyCode(rawValue: 0) && events[2].phase == .up)
        #expect(events[3].keyCode == .shift && events[3].phase == .up && events[3].isFlagsChanged)
    }

    @Test func cancellationStopsAndReleases() async {
        let clock = ManualClock()
        let sink = RecordingKeyEventSink(clock: clock)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await PhysicalKeyboardDriver(sink: sink, clock: clock, seed: 0).type(["a", "b"], profile: .fast)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sink.records.isEmpty)
    }
}
