// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Integration hooks (W2-E2, ADR 0502 "Integration hooks"): the wire format the INTEGRATION_HOOKS test build must
// answer, the file-drop transport over InMemoryFileSystem with ManualClock, the state probe and the `testHook`
// setup steps. Nothing here talks to a real app.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import Testing

@testable import TestSupport

private let hooksDirectory = URL(fileURLWithPath: "/support/App/IntegrationHooks")

private func channel(
    app: FakeHookApp?, clock: ManualClock, fileSystem: InMemoryFileSystem, timeout: UInt64 = 1_000_000_000
) -> FileDropHookChannel {
    FileDropHookChannel(
        directory: hooksDirectory, fileSystem: fileSystem, clock: clock,
        sleeper: RespondingSleeper(app: app, clock: clock), timeoutNanoseconds: timeout)
}

@Suite struct AppHookWireFormatTests {
    /// The request the app decodes: format version, sequence, command name, profile for the latency probe.
    @Test func requestsCarryTheCommandName() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let text = { (command: AppHookCommand) in
            String(decoding: try encoder.encode(AppHookRequest(sequence: 7, command: command)), as: UTF8.self)
        }
        #expect(try text(.state) == #"{"command":"state","formatVersion":1,"sequence":7}"#)
        #expect(try text(.trigger(.tapTimeout)) == #"{"command":"tapTimeout","formatVersion":1,"sequence":7}"#)
        #expect(
            try text(.latencyProbe(.normal)) == #"{"command":"latencyProbe","formatVersion":1,"profile":"normal","sequence":7}"#)
        #expect(AppHookCommand.resetMetrics.name == "resetMetrics" && AppHookCommand.checkForUpdates.name == "checkForUpdates")
        #expect(AppTestHook.allCases.map(\.rawValue) == ["tapTimeout", "revokePermission", "restorePermission"])
    }

    /// A response the app writes, decoded with the shared vocabulary (PauseCode, FailOpenReason, MetricsSnapshot).
    @Test func responsesDecodeTheStateSnapshot() throws {
        let metrics = String(decoding: try JSONEncoder().encode(emptyMetrics()), as: UTF8.self)
        let json = """
            {"formatVersion":1,"sequence":3,"ok":true,"state":{"processIdentifier":42,"state":"paused",
            "pauseReason":"secureInput","secureInputHolderBundleId":"com.example.Terminal",
            "firstKeyAfterSecureInputReleaseComposed":true,"tapRecoveries":2,"engineResetsAfterTapRecovery":2,
            "metrics":\(metrics)}}
            """
        let response = try JSONDecoder().decode(AppHookResponse.self, from: Data(json.utf8))
        let state = try #require(response.state)
        #expect(state.state == .paused && state.pauseReason == .secureInput && state.passesKeysThrough)
        #expect(state.secureInputHolderBundleId == bundle("com.example.Terminal"))
        #expect(state.tapRecoveries == 2 && state.engineResetsAfterTapRecovery == 2)
        #expect(!snapshot(.ready).passesKeysThrough && snapshot(.failOpen).passesKeysThrough)
    }
}

@Suite struct FileDropHookChannelTests {
    @Test func requestIsAnsweredAndBothFilesAreRemoved() async throws {
        let clock = ManualClock()
        let fileSystem = InMemoryFileSystem()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory, state: snapshot(.paused, pid: 9))
        let hooks = channel(app: app, clock: clock, fileSystem: fileSystem)
        let state = try await hooks.state()
        #expect(state.processIdentifier == 9 && state.state == .paused)
        try await hooks.trigger(.revokePermission)
        try await hooks.resetMetrics()
        #expect(app.commands.all == ["state", "revokePermission", "resetMetrics"])
        #expect(try fileSystem.contentsOfDirectory(at: hooksDirectory).isEmpty)
        #expect(try fileSystem.attributes(at: hooksDirectory).permissions == .ownerOnlyDirectory)
        #expect(hooks.requestURL(2).lastPathComponent == "request-2.json")
    }

    @Test func silenceTimesOutAndLeavesNothingBehind() async throws {
        let clock = ManualClock()
        let fileSystem = InMemoryFileSystem()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        app.setAnswers(false)
        let hooks = channel(app: app, clock: clock, fileSystem: fileSystem)
        await #expect(throws: AppHookError.timeout(command: "state")) { try await hooks.state() }
        #expect(try fileSystem.contentsOfDirectory(at: hooksDirectory).isEmpty)
        #expect(clock.now().nanoseconds >= 1_000_000_000)
        #expect(AppHookError.timeout(command: "state").description.contains("INTEGRATION_HOOKS"))
    }

    /// The latency probe types for seconds: its answer may take up to two minutes.
    @Test func latencyProbeWaitsLonger() async throws {
        let clock = ManualClock()
        let fileSystem = InMemoryFileSystem()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        app.setAnswers(false)
        let hooks = channel(app: app, clock: clock, fileSystem: fileSystem)
        await #expect(throws: AppHookError.timeout(command: "latencyProbe")) { try await hooks.latencyProbe(.normal) }
        #expect(clock.now().nanoseconds >= FileDropHookChannel.latencyProbeTimeoutNanoseconds)
    }

    @Test func rejectedAndMalformedAnswersAreErrors() async throws {
        let clock = ManualClock()
        let fileSystem = InMemoryFileSystem()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        app.reject("tapTimeout")
        let hooks = channel(app: app, clock: clock, fileSystem: fileSystem)
        await #expect(throws: AppHookError.rejected(command: "tapTimeout", code: "unsupported")) {
            try await hooks.trigger(.tapTimeout)
        }
        await #expect(throws: AppHookError.missingPayload(command: "latencyProbe")) {
            _ = try await hooks.latencyProbe(.fast)
        }
        // An answer for another sequence number, or not JSON, is malformed.
        let broken = channel(app: nil, clock: clock, fileSystem: fileSystem)
        try fileSystem.createDirectory(at: hooksDirectory, permissions: .ownerOnlyDirectory)
        try fileSystem.writeAtomically(Data("{}".utf8), to: broken.responseURL(1), permissions: .ownerOnlyFile)
        await #expect(throws: AppHookError.malformedResponse(command: "state")) { _ = try await broken.state() }
        for error in [
            AppHookError.rejected(command: "a", code: "b"), .malformedResponse(command: "a"),
            .missingPayload(command: "a"),
        ] {
            #expect(error.description.contains("'a'"))
        }
    }

    @Test func latencyProbeResultComesBack() async throws {
        let clock = ManualClock()
        let fileSystem = InMemoryFileSystem()
        let app = FakeHookApp(fileSystem: fileSystem, directory: hooksDirectory)
        let result = LatencyProbeResult(
            ranAt: Date(timeIntervalSince1970: 0),
            results: [
                .init(
                    profile: .normal, decideToPostedP50Microseconds: 300, decideToPostedP99Microseconds: 1_500,
                    endToEndDeltaP50Microseconds: 1_000, endToEndDeltaP99Microseconds: 4_000, samples: 60)
            ])
        app.setLatency(result)
        #expect(try await channel(app: app, clock: clock, fileSystem: fileSystem).latencyProbe(.normal) == result)
        #expect(FileDropHookChannel.directory(applicationSupport: URL(fileURLWithPath: "/s")).path == "/s/IntegrationHooks")
    }
}

@Suite struct HookStateProbeTests {
    @Test func mapsTheSnapshotToExpectations() async throws {
        var paused = snapshot(.paused)
        paused.pauseReason = .secureInput
        paused.secureInputHolderBundleId = bundle("com.example.Terminal")
        paused.firstKeyAfterSecureInputReleaseComposed = false
        let observation = try await HookStateProbe(hooks: FakeHookClient(state: paused)).observe(after: makeScenario())
        #expect(observation == ScenarioObservation(paused: true, holderBundleId: bundle("com.example.Terminal"), firstKeyAfterReleaseComposed: false))
        // The holder only counts while paused for secure input.
        var japanese = snapshot(.paused)
        japanese.pauseReason = .nonLatinInputSource
        japanese.secureInputHolderBundleId = bundle("com.example.Terminal")
        let other = try await HookStateProbe(hooks: FakeHookClient(state: japanese)).observe(after: makeScenario())
        #expect(other.paused == true && other.holderBundleId == nil)
        let ready = try await HookStateProbe(hooks: FakeHookClient(state: snapshot(.ready))).observe(after: makeScenario())
        #expect(ready.paused == false)
    }
}

@Suite struct ScenarioHookStepTests {
    @Test func valueGrammar() {
        #expect(ScenarioHookStep.parse("tapTimeout") == ScenarioHookStep(hook: .tapTimeout))
        #expect(ScenarioHookStep.parse("revokePermission@6") == ScenarioHookStep(hook: .revokePermission, afterKeys: 6))
        for bad in ["", "tap", "tapTimeout@", "tapTimeout@x", "tapTimeout@-1", "tapTimeout@1@2", "TAPTIMEOUT"] {
            #expect(ScenarioHookStep.parse(bad) == nil, "\(bad)")
        }
        #expect(ScenarioHookStep.of(.init(action: .wait, value: "tapTimeout")) == nil)
    }

    @Test func validatorChecksTheValueAndTheKeyIndex() {
        let scenario = { (value: String) in
            makeScenario(setup: [.init(action: .testHook, value: value)], keys: ["a", "b", "c"])
        }
        #expect(ScenarioValidator.problems(in: scenario("tapTimeout@3")).isEmpty)
        #expect(ScenarioValidator.problems(in: scenario("tapTimeout@4")) == ["setup[0] testHook @4 is past the end of keys"])
        #expect(ScenarioValidator.problems(in: scenario("nope")).first?.contains("testHook value must be one of") == true)
    }

    /// Deferred hooks cut the key script; the layout comes first; a hook without `@` stays in setup order.
    @Test func scheduleCutsTheKeyScript() {
        let scenario = Scenario(
            id: "s", targetBundleId: bundle("com.example.Editor"),
            setup: [
                .init(action: .launch), .init(action: .testHook, value: "restorePermission@3"),
                .init(action: .testHook, value: "revokePermission@1"), .init(action: .testHook, value: "tapTimeout"),
            ],
            keys: ["a", "b", "c", "d"], timing: .burst, method: .telex,
            layout: InputSourceID(rawValue: "com.apple.keylayout.ABC"), expect: .init(text: "x"), readback: .ax)
        let schedule = ScenarioSchedule(scenario)
        #expect(schedule.setup.map(\.action) == [.selectInputSource, .launch, .testHook])
        let segments = schedule.segments(of: scenario.keys)
        #expect(segments.map { Array($0.keys) } == [["a"], ["b", "c"], ["d"]])
        #expect(segments.map { $0.then?.value } == ["revokePermission@1", "restorePermission@3", nil])
        #expect(ScenarioSchedule.hooks(of: scenario) == [.restorePermission, .revokePermission, .tapTimeout])
    }

    /// The runner types up to the hook, fires it, types the rest; `finish` runs after the readback.
    @Test func runnerFiresTheHookMidScript() async throws {
        let driver = FakeDriver()
        let setup = FakeSetup()
        let scenario = makeScenario(
            setup: [.init(action: .focusField, value: "f"), .init(action: .testHook, value: "tapTimeout@2")],
            keys: ["d", "d", "i"])
        let runner = ScenarioRunner(
            driver: driver, readback: FakeReadback(result: .success("đi")), setup: setup, probe: nil,
            clock: ManualClock())
        let result = await runner.run(scenario)
        #expect(result.outcome == .pass)
        #expect(driver.typed.all == [["d", "d"], ["i"]])
        #expect(setup.steps.all.map(\.action) == [.focusField, .testHook])
    }
}
