// SPDX-License-Identifier: GPL-3.0-or-later
//
// Echo liveness and fail-open (PLT-R323, PLT-R730, ADR 0311), tap-disabled events (PLT-R330), probe events
// (PLT-R810), queue overflow (PLT-R314), keyboard-type notices and engine outputs the scripted engine never
// produces (empty edits, learning signals, macros; ADR 0306 decision 4).

import AppModel
import Diagnostics
import Injection
import RealtimeSupport
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

private struct StubEngine: CompositionEngine {
    var outputs: [EngineOutput]
    var activeDisplay: String { "ab" }

    mutating func handle(_ event: EngineEvent) -> EngineOutput {
        if case .reset = event { return EngineOutput(action: .passThrough, composingText: "") }
        return outputs.isEmpty ? EngineOutput(action: .passThrough, composingText: "") : outputs.removeFirst()
    }
}

private struct StubFactory: CompositionEngineFactory {
    typealias Hotkeys = ReferenceHotkeyRecognizer
    let outputs: [EngineOutput]
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot) -> StubEngine {
        StubEngine(outputs: outputs)
    }
    func makeEngine(for variant: EngineVariant, settings: TapSettingsSnapshot, continuing engine: StubEngine)
        -> StubEngine
    { engine }
}

private func taplogCodes(_ fixture: PipelineFixture) -> [TapLogRecord] {
    var records: [TapLogRecord] = []
    fixture.tapLog.drain { records.append($0) }
    return records
}

@Suite struct EchoAndFailOpenTests {
    private func expectation(_ job: JobSequence, _ sequence: UInt32, _ fixture: PipelineFixture) -> EchoExpectation {
        EchoExpectation(job: job, finalEventSequence: sequence, postedAt: fixture.clock.now())
    }

    /// ADR 0311: a job stays in flight until the tap sees the echo of its final event.
    @Test func inFlightEndsAtTheEcho() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        let edit = try #require(fixture.popJobs().first?.edit)
        fixture.queue.finished(edit.sequence, expectation: expectation(edit.sequence, 7, fixture))
        #expect(fixture.keyDown(Key.d) == .swallow)  // posted is not done: held until the echo
        let echo = PipelineFixtures.keyEvent(
            .keyUp, Key.a, userData: fixture.marker.userData(sequence: 7, probe: false))
        #expect(fixture.send(echo) == .pass)
        #expect(fixture.lastOutcome == nil)  // an echo is not a physical event (PLT-R321)
        fixture.completeJobs()  // the replay of "d"
        #expect(fixture.keyUp(Key.d) == .pass)
        #expect(fixture.queue.inFlight == 0)
    }

    /// PLT-R801: every job settled by its echo records the echo round trip; a timeout records nothing.
    @Test func echoedJobsRecordTheRoundTrip() throws {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)
        let edit = try #require(fixture.popJobs().first?.edit)
        fixture.queue.finished(edit.sequence, expectation: expectation(edit.sequence, 7, fixture))
        fixture.clock.advance(byMicroseconds: 3_000)
        fixture.send(
            PipelineFixtures.keyEvent(.keyUp, Key.a, userData: fixture.marker.userData(sequence: 7, probe: false)))
        let snapshot = fixture.metrics.echoRoundTrip.snapshot()
        #expect(snapshot.count == 1)
        #expect(fixture.queue.inFlight == 0)
        fixture.keyDown(Key.s)
        let next = try #require(fixture.popJobs().first?.edit)
        fixture.queue.finished(next.sequence, expectation: expectation(next.sequence, 8, fixture))
        fixture.clock.advance(byMicroseconds: 201_000)
        fixture.keyDown(Key.d)  // the second job timed out: a miss, not a round trip
        #expect(fixture.metrics.echoRoundTrip.snapshot().count == 1)
    }

    private func threeUnechoedEdits(_ fixture: PipelineFixture) {
        fixture.press(Key.a)
        fixture.press(Key.a)  // edit "â"
        fixture.press(Key.s)  // edit "ấ"
        fixture.press(Key.w)  // edit "ư"
        var sequence: UInt32 = 0
        for job in fixture.popJobs() {
            if let edit = job.edit {
                sequence += 1
                fixture.queue.finished(edit.sequence, expectation: expectation(edit.sequence, sequence, fixture))
            } else {
                fixture.queue.finished(PipelineFixture.sequence(of: job), expectation: nil)
            }
        }
    }

    /// PLT-R323, PLT-R730: three consecutive misses mark posting broken and the tap stops swallowing in the
    /// same callback, even with a held job still in flight.
    @Test func threeMissesFailOpenWithinTheSameCallback() {
        let fixture = PipelineFixture()
        threeUnechoedEdits(fixture)
        #expect(fixture.keyDown(Key.d) == .swallow)  // held behind the unechoed edits
        fixture.clock.advance(byMicroseconds: 201_000)
        #expect(fixture.keyDown(Key.e) == .pass)
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.feedback.isPostingBroken)
        #expect(fixture.metrics.echoLosses.value == 3)
        let notices = fixture.mainNotices()
        #expect(notices.filter { if case .echoMissed = $0 { true } else { false } }.count == 1)
        #expect(notices.contains { if case .postingBroken = $0 { true } else { false } })
        #expect(fixture.keyDown(Key.a) == .pass)
        #expect(fixture.keyUp(Key.a) == .pass)
        #expect(taplogCodes(fixture).contains { $0.code == .echoMissing })
    }

    /// PLT-R330, ADR 0311: jobs posted before a tap-disabled event bypassed the disabled tap; their missing
    /// echoes are not posting failures, so the first key after the re-enable does not fail open.
    @Test func echoesLostWhileTheTapWasDisabledDoNotBreakPosting() {
        let fixture = PipelineFixture()
        threeUnechoedEdits(fixture)
        fixture.send(PipelineFixtures.keyEvent(.tapDisabledByTimeout, 0))
        fixture.clock.advance(byMicroseconds: 300_000)
        fixture.keyDown(Key.d)
        #expect(!fixture.feedback.isPostingBroken)
        #expect(fixture.metrics.echoLosses.value == 0)
        #expect(fixture.echo.consecutiveMisses == 0)
        #expect(!fixture.mainNotices().contains { if case .postingBroken = $0 { true } else { false } })
    }

    /// PLT-R306, ADR 0309: during a watchdog trip the tap receives no event at all; the lifecycle owner's
    /// re-enable forgives what was posted until then (a stalled callback is already past the echo timeout).
    @Test func reenableForgivesWhatWasPostedWhileTheTapWasDisabled() {
        let fixture = PipelineFixture()
        threeUnechoedEdits(fixture)
        fixture.clock.advance(byMicroseconds: 300_000)
        fixture.echo.forgiveLostEchoes(postedAtOrBefore: fixture.clock.now())
        fixture.keyDown(Key.d)
        #expect(!fixture.feedback.isPostingBroken)
        #expect(fixture.metrics.echoLosses.value == 0)
        #expect(fixture.echo.consecutiveMisses == 0)
    }

    /// PLT-R323: forgiveness covers only what was posted up to the re-enable; a new run of three misses on the
    /// enabled tap still breaks posting.
    @Test func missesAfterTheReenableStillBreakPosting() {
        let fixture = PipelineFixture()
        fixture.echo.forgiveLostEchoes(postedAtOrBefore: fixture.clock.now())
        fixture.clock.advance(byMicroseconds: 1_000)
        threeUnechoedEdits(fixture)
        fixture.clock.advance(byMicroseconds: 201_000)
        #expect(fixture.keyDown(Key.e) == .pass)
        #expect(fixture.feedback.isPostingBroken)
        #expect(fixture.metrics.echoLosses.value == 3)
    }

    /// PLT-R731: after the lifecycle owner clears posting broken, old misses do not break it again.
    @Test func recoveryDoesNotReuseOldMisses() {
        let fixture = PipelineFixture()
        threeUnechoedEdits(fixture)
        fixture.clock.advance(byMicroseconds: 201_000)
        fixture.press(Key.e)
        #expect(fixture.feedback.isPostingBroken)
        fixture.feedback.clearPostingBroken()
        fixture.log.clear()
        fixture.typeKeys([Key.d, Key.e])
        #expect(!fixture.feedback.isPostingBroken)
        #expect(fixture.log.feeds == [.key(KeyInput("d")), .key(KeyInput("e"))])
    }

    /// PLT-R730: a fail-open lifecycle phase passes everything, held jobs or not.
    @Test(arguments: [LifecycleSnapshot.Phase.failOpen(.permissionRevoked), .noPermission, .starting])
    func failOpenPhasesPassEverything(phase: LifecycleSnapshot.Phase) {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit in flight; the consumed keyDown's keyUp would normally be swallowed
        fixture.publish(lifecycle: PipelineFixtures.lifecycle(generation: 2, phase: phase))
        #expect(fixture.keyUp(Key.a) == .pass)
        #expect(fixture.keyDown(Key.a) == .pass)
        #expect(fixture.keyDown(Key.d) == .pass)
        #expect(fixture.log.feeds.count == 2)
    }

    /// PLT-R330: reset, log, count and tell main; the lifecycle owner re-enables and flushes.
    @Test func tapDisabledEventsResetLogAndCount() {
        let fixture = PipelineFixture()
        fixture.press(Key.a)
        #expect(fixture.send(PipelineFixtures.keyEvent(.tapDisabledByTimeout, 0)) == .pass)
        #expect(fixture.lastOutcome == nil)
        #expect(fixture.metrics.tapTimeouts.value == 1)
        #expect(fixture.log.resets == [.eventTapReenabled])
        fixture.send(PipelineFixtures.keyEvent(.tapDisabledByUserInput, 0))
        #expect(fixture.metrics.tapTimeouts.value == 1)
        let disabled = fixture.mainNotices().compactMap { notice -> Bool? in
            if case .tapDisabled(let byTimeout) = notice { return byTimeout }
            return nil
        }
        #expect(disabled == [true, false])
        #expect(taplogCodes(fixture).map(\.code) == [.tapDisabledByTimeout, .tapDisabledByUserInput])
    }

    /// PLT-R810: probe-tagged events are processed as physical, replayed as probes, and stay out of T1.
    @Test func probeEventsAreProcessedAsPhysical() throws {
        let fixture = PipelineFixture()
        let probeData = fixture.marker.userData(sequence: 3, probe: true)
        fixture.send(PipelineFixtures.keyEvent(.keyDown, Key.a, userData: probeData))
        #expect(fixture.lastOutcome == .passed)
        #expect(fixture.log.feeds == [.key(KeyInput("a"))])
        #expect(fixture.metrics.callbackDuration.snapshot().count == 0)
        fixture.keyDown(Key.a)  // physical: an edit, in flight; T1 recorded
        #expect(fixture.metrics.callbackDuration.snapshot().count == 1)
        fixture.send(PipelineFixtures.keyEvent(.keyDown, Key.d, userData: probeData))
        let held = try #require(fixture.popJobs().last?.replayed)
        #expect(held.isProbe)
    }

    /// PLT-R314: a full ring never blocks the keyboard: the event passes and the overflow is logged.
    @Test func fullQueuePassesAndLogs() {
        let fixture = PipelineFixture(queueCapacity: 2)
        fixture.press(Key.a)
        fixture.keyDown(Key.a)  // edit
        fixture.keyUp(Key.a)  // pairedKeyUp: the ring is full
        #expect(fixture.keyDown(Key.d) == .pass)
        #expect(fixture.lastOutcome == .passed)
        #expect(taplogCodes(fixture).contains { $0.code == .jobQueueFull })
    }

    @Test func keyboardTypeWithoutATableIsReportedOnce() {
        let fixture = PipelineFixture()
        var event = PipelineFixtures.keyEvent(.keyDown, Key.a)
        event.keyboardType = 41
        fixture.send(event)
        fixture.send(event)
        let types = fixture.mainNotices().compactMap { notice -> UInt32? in
            if case .keyboardTypeSeen(let type) = notice { return type }
            return nil
        }
        #expect(types == [41])
    }

    #if DEBUG
    /// PLT-R363: debug builds log table/Unicode mismatches as keycode plus source generation only.
    @Test func layoutMismatchIsLoggedWithoutContent() throws {
        let fixture = PipelineFixture()
        let b = try #require(InlineUTF16("b"))
        fixture.send(PipelineFixtures.keyEvent(.keyDown, Key.a, unicode: b))
        let record = try #require(taplogCodes(fixture).first { $0.code == .layoutMismatch })
        #expect(record.a == UInt64(Key.a))
        #expect(record.b == 1)
    }
    #endif
}

@Suite struct EngineOutputMappingTests {
    private func stubPipeline(_ fixture: PipelineFixture, _ outputs: [EngineOutput]) -> KeyPipeline<
        StubFactory, ManualClock
    > {
        KeyPipeline(context: fixture.context, factory: StubFactory(outputs: outputs), clock: fixture.clock)
    }

    private func key(_ kind: RawKeyEvent.Kind, _ code: UInt16, _ fixture: PipelineFixture) -> RawKeyEvent {
        PipelineFixtures.keyEvent(kind, code, at: fixture.clock.now())
    }

    /// ADR 0306 decision 4: an empty edit swallows the key without a job; its keyUp is swallowed too.
    @Test func emptyEditSwallowsWithoutAJob() {
        let fixture = PipelineFixture()
        let empty = EngineOutput(
            action: .edit(TextEdit(deleteCount: 0, deleteUTF16Count: 0, insert: ""), thenPassThrough: false),
            composingText: "")
        let pipeline = stubPipeline(fixture, [empty])
        #expect(pipeline.handle(key(.keyDown, Key.a, fixture)) == .swallow)
        #expect(pipeline.lastOutcome == .consumedForEdit)
        #expect(pipeline.handle(key(.keyUp, Key.a, fixture)) == .swallow)
        #expect(pipeline.lastOutcome == .consumedPairedKeyUp)
        #expect(fixture.popJobs().isEmpty)
    }

    @Test func emptyEditWithPassThroughPasses() {
        let fixture = PipelineFixture()
        let empty = EngineOutput(
            action: .edit(TextEdit(deleteCount: 0, deleteUTF16Count: 0, insert: ""), thenPassThrough: true),
            composingText: "")
        let pipeline = stubPipeline(fixture, [empty])
        #expect(pipeline.handle(key(.keyDown, Key.a, fixture)) == .pass)
        #expect(fixture.popJobs().isEmpty)
    }

    /// ENG-R861: learning signals go to main, in memory only. ENG-R862: each carries the app of the focus snapshot
    /// the key was handled with.
    @Test func learningSignalsGoToMainWithTheirApp() {
        let fixture = PipelineFixture()
        let output = EngineOutput(action: .passThrough, composingText: "", learning: .preferredRaw(raw: "abc"))
        let pipeline = stubPipeline(fixture, [output])
        _ = pipeline.handle(key(.keyDown, Key.a, fixture))
        let apps = fixture.mainNotices().compactMap { notice -> BundleKey?? in
            if case .learning(.preferredRaw(raw: "abc"), let bundle) = notice { return bundle }
            return nil
        }
        #expect(apps == [PipelineFixtures.editorBundle])
    }

    /// PLT-R405: a macro expansion types with the keycode of its first character in the current layout.
    @Test func macroEditsUseTheFirstCharacterKeyCode() throws {
        let fixture = PipelineFixture()
        let macro = EngineOutput(
            action: .edit(TextEdit(deleteCount: 3, deleteUTF16Count: 3, insert: "by the way"), thenPassThrough: true),
            composingText: "", decision: .macro)
        let pipeline = stubPipeline(fixture, [macro])
        #expect(pipeline.handle(key(.keyDown, Key.space, fixture)) == .swallow)
        let jobs = fixture.popJobs()
        let edit = try #require(jobs.first?.edit)
        #expect(edit.kind == .macro)
        #expect(edit.keyCodes.firstCharacter == KeyCode(rawValue: 0x0B))  // "b"
        #expect(edit.replacedText == "ab")
        #expect(jobs.map(\.kind) == [.edit, .replay])
    }

    /// PLT-R405: a macro a character key triggers (a comma) whose expansion starts with a character typed by an
    /// action key (a space, `kVK_Space`) types on the first character of the expansion that a non-action key types,
    /// the same choice as for an edit an action key triggered, not on the trigger.
    @Test func aMacroStartingWithASpaceTypesOnItsFirstLetter() throws {
        let fixture = PipelineFixture()
        let macro = EngineOutput(
            action: .edit(TextEdit(deleteCount: 3, deleteUTF16Count: 3, insert: " by the way"), thenPassThrough: true),
            composingText: "", decision: .macro)
        let pipeline = stubPipeline(fixture, [macro])
        #expect(pipeline.handle(key(.keyDown, Key.comma, fixture)) == .swallow)
        let edit = try #require(fixture.popJobs().first?.edit)
        #expect(edit.kind == .macro)
        #expect(edit.keyCodes.trigger == KeyCode(rawValue: Key.comma))
        #expect(edit.keyCodes.firstCharacter == KeyCode(rawValue: 0x0B))  // "b", never kVK_Space
    }
}
