// SPDX-License-Identifier: GPL-3.0-or-later
//
// Property test of the lifecycle state machine against a simulated controller (W1-F2). Random input sequences
// check the invariants that must hold after every step, whatever the order of events.
import AppModel
import Testing

@testable import InputHost

/// Deterministic generator so failures reproduce from the seed.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

/// What `InputHostController` would do with the effects: one tap at a time; a creation may stay in flight while
/// other inputs arrive (the factory runs on the tap thread, so permissions can change before it answers).
private struct ControllerModel {
    var tapAlive = false
    var creationInFlight = false
    /// A watchdog trip was accepted and the callback has not been seen returning (ADR 0309).
    var callbackMayBeStuck = false
    var retryScheduled = false
    var permissionsGranted = false

    mutating func apply(_ effects: [LifecycleEffect]) {
        for effect in effects {
            switch effect {
            case .createTap:
                #expect(!creationInFlight, "PLT-R302: one creation at a time")
                creationInFlight = true
            case .removeTap: tapAlive = false
            case .scheduleRetry: retryScheduled = true
            case .cancelRetry: retryScheduled = false
            default: break
            }
        }
    }
}

private let randomInputs: [LifecycleInput] = [
    .permissionsChanged(.granted), .permissionsChanged(.denied), .permissionsChanged(.grantedListenRequired),
    .retryTimerFired, .watchdogTripped(.callbackOverLimit(microseconds: 300_000)),
    .watchdogTripped(.callbackStuck(microseconds: 2_300_000)), .watchdogTripped(.unexpectedlyDisabled),
    .callbackExited, .postingBroken, .tapDisabledBySystem(byTimeout: true),
    .tapDisabledBySystem(byTimeout: false), .sessionActive(true), .sessionActive(false), .userDisabled(true),
    .userDisabled(false), .diagnosticsPassThrough(true), .diagnosticsPassThrough(false),
    .livePermissions(.granted), .livePermissions(.denied),
]

@Suite struct HostLifecycleInvariantTests {
    @Test(arguments: 0..<64)
    func invariantsHoldForRandomSequences(seed: Int) {
        var random = SplitMix64(state: UInt64(seed) &* 7_919)
        var script = LifecycleScript()
        var model = ControllerModel()
        script.send(.launched)
        for _ in 0..<1_500 {
            let input = nextInput(&random, model: &model)
            let before = script.phase
            let wasStuck = model.callbackMayBeStuck
            let effects = script.send(input)
            check(effects, from: before, to: script.phase, input: input, model: model, wasStuck: wasStuck)
            model.apply(effects)
            update(&model, after: input, effects: effects, phase: script.phase)
            checkTapBacksThePhase(script.phase, model: model)
            checkTruthfulAndLive(script.phase, model: model)
            script.advance(by: .milliseconds(Int64(random.next() % 90_000)))
        }
    }

    private func nextInput(_ random: inout SplitMix64, model: inout ControllerModel) -> LifecycleInput {
        // Half of the time the creation stays in flight for another input (review finding: permission flicker).
        if model.creationInFlight && random.next() % 2 == 0 {
            model.creationInFlight = false
            return random.next() % 3 == 0 ? .tapCreationFailed : .tapCreated
        }
        let input = randomInputs[Int(random.next() % UInt64(randomInputs.count))]
        if case .retryTimerFired = input { model.retryScheduled = false }
        return input
    }

    private func update(
        _ model: inout ControllerModel, after input: LifecycleInput, effects: [LifecycleEffect],
        phase: LifecycleSnapshot.Phase
    ) {
        switch input {
        case .tapCreated: model.tapAlive = !effects.contains(.removeTap)
        case .permissionsChanged(let status), .livePermissions(let status):
            model.permissionsGranted = status.health == .ready
        case .watchdogTripped(.callbackOverLimit): if phase == .failOpen(.watchdog) { model.callbackMayBeStuck = true }
        case .callbackExited: model.callbackMayBeStuck = false
        default: break
        }
    }

    private func check(
        _ effects: [LifecycleEffect], from before: LifecycleSnapshot.Phase, to after: LifecycleSnapshot.Phase,
        input: LifecycleInput, model: ControllerModel, wasStuck: Bool
    ) {
        let publishes = effects.filter { if case .publish = $0 { true } else { false } }
        if before != after {
            #expect(publishes == [.publish(after)], "\(input): one publish per transition")
            if before.holdsComposition || after.holdsComposition {
                #expect(effects.contains(.resetComposition), "PLT-R210: \(before) -> \(after) resets")
            }
        } else {
            #expect(publishes.isEmpty, "\(input): no publish without a transition")
        }
        if effects.contains(.createTap) {
            #expect(!model.tapAlive, "PLT-R302, PLT-R208: never a second tap")
            #expect(!wasStuck, "ADR 0309: no new tap while the old callback may be stuck")
        }
        // `callbackExited` means the callback returned, so recovery may touch the tap again.
        if wasStuck && input != .callbackExited {
            #expect(!effects.contains(.removeTap) && !effects.contains(.reenableTap), "stuck thread untouched")
        }
        if effects.contains(where: { if case .scheduleRetry = $0 { true } else { false } }) {
            let retryPhase = after == .failOpen(.tapUnavailable) || after == .failOpen(.postingBroken)
            #expect(retryPhase && model.permissionsGranted, "PLT-R332, PLT-R323: retry only while granted")
        }
    }

    /// PLT-R211: `noPermission` is published only while permissions do not look granted. PLT-R731, PLT-R332:
    /// with permissions granted and nothing pending (no creation, no retry timer, no possibly stuck callback) the
    /// host holds a tap, so no input sequence strands it fail-open until relaunch.
    private func checkTruthfulAndLive(_ phase: LifecycleSnapshot.Phase, model: ControllerModel) {
        if phase == .noPermission {
            #expect(!model.permissionsGranted, "noPermission published while permission is granted")
        }
        guard model.permissionsGranted, !model.creationInFlight, !model.retryScheduled, !model.callbackMayBeStuck
        else { return }
        #expect(phase == .running || phase == .sessionInactive, "stranded in \(phase) with nothing pending")
    }

    /// PRD-R44: the host only transforms (or pauses with a tap installed) while a tap exists, permissions look
    /// granted and no callback may be stuck.
    private func checkTapBacksThePhase(_ phase: LifecycleSnapshot.Phase, model: ControllerModel) {
        if phase == .running || phase == .sessionInactive {
            #expect(model.tapAlive, "\(phase) without a tap")
            #expect(model.permissionsGranted, "\(phase) without permission")
            #expect(!model.callbackMayBeStuck, "\(phase) while the callback may be stuck")
        }
    }
}
