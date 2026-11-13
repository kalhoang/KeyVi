// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R395-R398B: 2 s polling through the scheduler, transition generations, episodes ended by key evidence,
// likely-holder naming and hint keys.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

private let terminalPID: Int32 = 501
private let loginPID: Int32 = 88
private let toolPID: Int32 = 777
private let terminalBundle = "com.apple.Terminal"
private let terminalHint = "terminal.secureKeyboardEntry"

private struct Harness {
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let probe = FakeSecureInputProbe()
    let processes: FakeProcessIdentityProvider
    let published = Recorder<SecureInputSnapshot>()
    let monitor: SecureInputMonitor

    init() {
        scheduler = ManualScheduler(clock: clock)
        let loginWindow = ProcessIdentity(
            pid: loginPID, bundle: bundle("com.apple.loginwindow"), bundleURL: nil, shortVersion: nil,
            buildVersion: nil, appCategory: nil, localizedName: "Login Window", processName: "loginwindow")
        let tool = ProcessIdentity(
            pid: toolPID, bundle: BundleKey.executable(sha256Hex: String(repeating: "ab", count: 32))!, bundleURL: nil,
            shortVersion: nil, buildVersion: nil, appCategory: nil, localizedName: nil, processName: "pinentry")
        processes = FakeProcessIdentityProvider(processes: [
            FakeProcessIdentityProvider.process(pid: terminalPID, bundle: terminalBundle, name: "Terminal"),
            loginWindow, tool,
        ])
        let published = self.published
        monitor = SecureInputMonitor(
            probe: probe, processes: processes,
            hintKey: { $0.rawValue == terminalBundle ? terminalHint : nil }, scheduler: scheduler,
            publish: { published.append($0) })
    }
}

@Suite("SecureInputMonitor (PLT-R395-R398B)")
struct SecureInputMonitorTests {
    @Test func pollsAtStartAndEveryTwoSecondsThroughTheScheduler() {
        let harness = Harness()
        harness.monitor.start()
        #expect(harness.probe.pollCount == 1)
        #expect(harness.scheduler.repeatingIntervals == [.seconds(2)])
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.probe.pollCount == 2)
        harness.scheduler.advance(by: .seconds(6))
        #expect(harness.probe.pollCount == 5)
        #expect(SecureInputMonitor.pollLeeway >= SecureInputMonitor.pollInterval / 10)  // PLT-R803
    }

    @Test func generationChangesOnlyOnTransitions() {
        let harness = Harness()
        harness.monitor.start()
        #expect(harness.published.count == 0)  // still the initial state
        harness.probe.set(enabled: true, holderPID: terminalPID)
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.published.last?.generation == 1)
        #expect(harness.published.last?.enabled == true)
        harness.scheduler.advance(by: .seconds(4))
        #expect(harness.published.count == 1)  // stuck flag: same generation, nothing new
        harness.probe.set(enabled: false, holderPID: nil)
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.published.last == SecureInputSnapshot(generation: 2, enabled: false, holder: nil))
    }

    @Test func applicationHolderGetsNameBundleAndHintKey() {
        let harness = Harness()
        harness.probe.set(enabled: true, holderPID: terminalPID)
        let holder = harness.monitor.pollNow().holder
        #expect(
            holder
                == SecureInputHolder(
                    pid: terminalPID, kind: .application, bundle: bundle(terminalBundle), displayName: "Terminal",
                    hintKey: terminalHint))
    }

    @Test func loginWindowIsRecognisedByProcessName() {
        let harness = Harness()
        harness.probe.set(enabled: true, holderPID: loginPID)
        let holder = harness.monitor.pollNow().holder
        #expect(holder?.kind == .loginWindow)
        #expect(holder?.hintKey == nil)
    }

    @Test func deadPIDIsAnExitedProcess() {
        let harness = Harness()
        harness.processes.terminate(pid: terminalPID)
        harness.probe.set(enabled: true, holderPID: terminalPID)
        #expect(
            harness.monitor.pollNow().holder
                == SecureInputHolder(
                    pid: terminalPID, kind: .exitedProcess, bundle: nil, displayName: nil, hintKey: nil))
    }

    @Test func unknownHolder() {
        let harness = Harness()
        harness.probe.set(enabled: true, holderPID: nil)
        #expect(harness.monitor.pollNow().holder == nil)
        harness.probe.set(enabled: true, holderPID: 0)
        #expect(harness.monitor.pollNow().holder == nil)
    }

    @Test func processWithoutBundleIdentifier() {
        let harness = Harness()
        harness.probe.set(enabled: true, holderPID: toolPID)
        let holder = harness.monitor.pollNow().holder
        #expect(holder?.kind == .process)
        #expect(holder?.displayName == "pinentry")
        #expect(holder?.bundle?.isExecutableHash == true)
    }

    @Test func applicationWithoutAHintHasNoHintKey() {
        let harness = Harness()
        let ghost = ProcessIdentity(
            pid: 999, bundle: bundle("test.ghost"), bundleURL: nil, shortVersion: nil, buildVersion: nil,
            appCategory: nil, localizedName: nil, processName: "ghost")
        harness.processes.add(ghost)
        harness.probe.set(enabled: true, holderPID: 999)
        let holder = harness.monitor.pollNow().holder
        #expect(holder?.kind == .application)
        #expect(holder?.hintKey == nil)
    }

    @Test func keyEvidenceKeepsTheResumedStateUntilTheNextPoll() {
        let harness = Harness()
        harness.probe.set(enabled: true, holderPID: terminalPID)
        harness.monitor.start()
        #expect(harness.published.last?.generation == 1)
        harness.monitor.keyEvidence(generation: 1)
        #expect(harness.published.count == 1)  // no publication: the tap already resumed for generation 1
        #expect(harness.monitor.pollNow().generation == 2)  // the OS flag is still on: a new episode
        #expect(harness.published.count == 2)
    }

    /// PLT-R398B / review finding 12: on -> off -> key evidence -> on inside one interval pauses again.
    @Test func onOffKeyOnWithinOnePollBumpsTheGeneration() {
        let harness = Harness()
        harness.monitor.start()
        harness.probe.set(enabled: true, holderPID: terminalPID)
        harness.scheduler.advance(by: .seconds(2))  // poll A: on, generation 1
        #expect(harness.published.last?.generation == 1)
        harness.probe.set(enabled: false, holderPID: nil)  // released between polls
        harness.monitor.keyEvidence(generation: 1)  // the tap saw a key and resumed
        harness.probe.set(enabled: true, holderPID: terminalPID)  // raised again before the next poll
        harness.scheduler.advance(by: .seconds(2))  // poll B never saw "off"
        #expect(harness.published.last?.generation == 2)
        #expect(harness.published.last?.enabled == true)
        harness.scheduler.advance(by: .seconds(2))
        #expect(harness.published.last?.generation == 2)  // no evidence for 2: the episode continues
    }

    @Test func staleOrDisabledEvidenceIsIgnored() {
        let harness = Harness()
        harness.monitor.keyEvidence(generation: 0)  // disabled
        harness.probe.set(enabled: true, holderPID: terminalPID)
        #expect(harness.monitor.pollNow().generation == 1)
        harness.monitor.keyEvidence(generation: 0)  // stale generation
        #expect(harness.monitor.pollNow().generation == 1)
    }

    @Test func stopCancelsTheTimerAndStartIsIdempotent() {
        let harness = Harness()
        harness.monitor.start()
        harness.monitor.start()
        #expect(harness.scheduler.pendingCount == 1)
        harness.monitor.stop()
        #expect(harness.scheduler.pendingCount == 0)
        harness.scheduler.advance(by: .seconds(10))
        #expect(harness.probe.pollCount == 1)
        harness.monitor.start()
        #expect(harness.scheduler.pendingCount == 1)
    }

    @Test func holderChangeWithoutTransitionKeepsTheGeneration() {
        let harness = Harness()
        harness.probe.set(enabled: true, holderPID: terminalPID)
        _ = harness.monitor.pollNow()
        harness.probe.set(enabled: true, holderPID: loginPID)
        let snapshot = harness.monitor.pollNow()
        #expect(snapshot.generation == 1)
        #expect(snapshot.holder?.kind == .loginWindow)
        #expect(harness.published.count == 2)
    }
}
