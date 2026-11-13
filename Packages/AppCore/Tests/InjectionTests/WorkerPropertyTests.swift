// SPDX-License-Identifier: GPL-3.0-or-later
//
// Worker property suite with a scripted producer (W1-D acceptance): random interleavings of edits (some paced,
// some macros), held events, paired keyUps, boundaries, focus changes, clock advances and worker runs are checked
// against an exact model that advances time while a paced job runs. Properties: FIFO order, held events
// replayed once and in order, stale generations discarded with the trigger replayed, liveness at 150 ms (1 s for
// keys held behind a macro, PLT-R480) and 256 jobs abandons only unstarted edits (a started job runs to
// completion, PLT-R314), paired keyUps dropped after execution and replayed after abandonment (ADR 0308),
// exactly one `finished` per job with an expectation iff it posted (ADR 0311).

import AppModel
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

/// What one posted event looks like, independent of marker sequences.
private enum Emitted: Hashable {
    case synthetic(keyCode: UInt16, down: Bool, text: String)
    case replay(kind: KeyEventRecord.Kind, id: UInt32)
}

/// An edit as the model sees it: what it posts and how long its pacing makes it run.
private struct ModelEdit {
    var id: UInt64
    var generation: UInt64
    var deleteCount: Int
    var text: String
    var isMacro: Bool
    var durationNanoseconds: UInt64
    var at: UInt64
}

/// How often the scenarios behind the PLT-R314 / PLT-R480 sub-properties occurred, so the suite proves it
/// exercised them.
private struct Coverage {
    /// A flush started after a paced job that was already running when the ceiling passed.
    var flushesAfterARunningJob = 0
    /// A key older than 150 ms was executed normally because it waited behind a macro (1 s ceiling).
    var keysKeptByTheMacroCeiling = 0
}

private enum ModelJob {
    case edit(ModelEdit)
    case replay(id: UInt64, kind: KeyEventRecord.Kind, at: UInt64)
    case paired(id: UInt64, forJob: UInt64, at: UInt64)
    case boundary(id: UInt64)

    var id: UInt64 {
        switch self {
        case .edit(let edit): edit.id
        case .replay(let id, _, _), .paired(let id, _, _), .boundary(let id): id
        }
    }

    var waitingSince: UInt64? {
        switch self {
        case .edit(let edit): edit.at
        case .replay(_, _, let at), .paired(_, _, let at): at
        case .boundary: nil
        }
    }
}

private struct ScriptedProducer {
    static let triggerKeyCode: UInt16 = 0x01
    static let ceilingNanoseconds: UInt64 = 150_000_000
    static let macroCeilingNanoseconds: UInt64 = 1_000_000_000

    var generator: SplitMix64
    let rig = WorkerRig()
    var pending: [ModelJob] = []
    var expectedEvents: [Emitted] = []
    var expectedOutcomes: [UInt64: JobOutcome] = [:]
    var unpairedEdits: [UInt64] = []
    var generation: UInt64 = 1
    /// Mirrors the worker: keys received before the last macro finished use the 1 s ceiling.
    var lastMacroFinishedAt: UInt64?
    var coverage = Coverage()

    init(seed: UInt64) { generator = SplitMix64(seed: seed) }

    var now: UInt64 { rig.clock.now().nanoseconds }

    static func character(_ index: UInt64) -> String {
        String(Character(UnicodeScalar(UInt32(0x4E00 + index % 20_000))!))
    }

    mutating func step() {
        let roll = Int.random(in: 0..<1_000, using: &generator)
        switch roll {
        case 0..<300: pushEdit()
        case 300..<600: pushReplay()
        case 600..<700: pushPaired()
        case 700..<750: pending.append(.boundary(id: rig.pushBoundary()))
        case 750..<800:
            generation += 1
            rig.generation.store(FocusGeneration(rawValue: generation))
        case 800..<900: rig.clock.advance(byMicroseconds: UInt64.random(in: 0...100_000, using: &generator))
        case 900..<997: runAndCheck()
        default:
            if pending.count > 240 { runAndCheck() }
            for _ in 0..<260 { pushReplay() }
        }
        if pending.count > 400 { runAndCheck() }
    }

    private func record(_ kind: KeyEventRecord.Kind, id: UInt64) -> KeyEventRecord {
        KeyEventRecord(
            kind: kind, keyCode: KeyCode(rawValue: Self.triggerKeyCode), flags: 0, autorepeat: false,
            keyboardType: UInt32(id), unicode: InlineUTF16("s") ?? .empty, receivedAt: rig.clock.now(), isProbe: false)
    }

    /// A quarter of the edits are paced (up to the 50 ms PLT-R408 cap per gap) and some are macros of up to six
    /// characters, so jobs take real time and keys wait behind them; every job stays under its length cap.
    mutating func pushEdit() {
        let deleteCount = Int.random(in: 0...2, using: &generator)
        let isMacro = Int.random(in: 0..<100, using: &generator) < 15
        let length = isMacro ? Int.random(in: 1...6, using: &generator) : 1
        let paced = Int.random(in: 0..<4, using: &generator) == 0
        let interEventUs = paced ? Int.random(in: 1...50, using: &generator) * 1_000 : 0
        let id = rig.nextSequence()
        let text = (0..<UInt64(length)).map { Self.character(id &* 8 &+ $0) }.joined()
        let parameters = Fixture.parameters { $0.interEventDelayUs = interEventUs }
        let job = Fixture.job(
            sequence: id, deleteCount: deleteCount, insertion: text, plan: Fixture.plan(parameters: parameters),
            generation: generation, kind: isMacro ? .macro : .compose, trigger: record(.keyDown, id: id),
            createdAt: rig.clock.now())
        precondition(rig.queue.push(.edit(job)))
        let gaps = UInt64(deleteCount + length - 1)
        let edit = ModelEdit(
            id: id, generation: generation, deleteCount: deleteCount, text: text, isMacro: isMacro,
            durationNanoseconds: gaps * UInt64(interEventUs) * 1_000, at: now)
        pending.append(.edit(edit))
        unpairedEdits.append(id)
    }

    mutating func pushReplay() {
        let kind: KeyEventRecord.Kind = Bool.random(using: &generator) ? .keyDown : .keyUp
        let id = rig.nextSequence()
        precondition(rig.queue.push(.replay(JobSequence(rawValue: id), record(kind, id: id))))
        pending.append(.replay(id: id, kind: kind, at: now))
    }

    /// The tap pushes a pairedKeyUp only while its edit is still queued (ADR 0308); otherwise it reads the board.
    mutating func pushPaired() {
        guard !unpairedEdits.isEmpty else { return }
        let forJob = unpairedEdits.removeFirst()
        let id = rig.nextSequence()
        precondition(
            rig.queue.push(
                .pairedKeyUp(JobSequence(rawValue: id), record(.keyUp, id: id), forJob: JobSequence(rawValue: forJob))))
        pending.append(.paired(id: id, forJob: forJob, at: now))
    }

    /// The model of one `runUntilIdle`, returning the jobs that posted and the clock after the run. Before each
    /// job the head's wait is checked against its ceiling (1 s if received before the last macro finished); once
    /// exceeded, or with more than 256 jobs waiting, every remaining job is flushed. A job that started runs to
    /// completion and moves the clock by its paced duration.
    mutating func modelRun() -> (posted: Set<UInt64>, end: UInt64) {
        var posted = Set<UInt64>()
        var clock = now
        var flushing = pending.count > 256
        for (index, job) in pending.enumerated() {
            if !flushing, let since = job.waitingSince {
                let waited = clock - since
                let behindMacro = lastMacroFinishedAt.map { since < $0 } ?? false
                if waited > (behindMacro ? Self.macroCeilingNanoseconds : Self.ceilingNanoseconds) {
                    flushing = true
                    if index > 0, clock > now { coverage.flushesAfterARunningJob += 1 }
                } else if behindMacro, waited > Self.ceilingNanoseconds {
                    coverage.keysKeptByTheMacroCeiling += 1
                }
            }
            if apply(job, flushing: flushing) { posted.insert(job.id) }
            if case .edit(let edit) = job, expectedOutcomes[edit.id] == .executed {
                clock += edit.durationNanoseconds
                if edit.isMacro { lastMacroFinishedAt = clock }
            }
        }
        pending.removeAll()
        unpairedEdits.removeAll()
        return (posted, clock)
    }

    /// Returns whether the job posted anything.
    private mutating func apply(_ job: ModelJob, flushing: Bool) -> Bool {
        switch job {
        case .edit(let edit):
            let outcome: JobOutcome =
                flushing ? .abandoned : (edit.generation < generation ? .discardedForGeneration : .executed)
            expectedOutcomes[edit.id] = outcome
            guard outcome == .executed else {
                expectedEvents.append(.replay(kind: .keyDown, id: UInt32(edit.id)))
                return true
            }
            for _ in 0..<edit.deleteCount {
                expectedEvents += [
                    .synthetic(keyCode: 0x33, down: true, text: ""), .synthetic(keyCode: 0x33, down: false, text: ""),
                ]
            }
            for character in edit.text {
                expectedEvents += [
                    .synthetic(keyCode: Self.triggerKeyCode, down: true, text: String(character)),
                    .synthetic(keyCode: Self.triggerKeyCode, down: false, text: String(character)),
                ]
            }
            return true
        case .replay(let id, let kind, _):
            expectedEvents.append(.replay(kind: kind, id: UInt32(id)))
            return true
        case .paired(let id, let forJob, _):
            guard expectedOutcomes[forJob] != .executed else { return false }
            expectedEvents.append(.replay(kind: .keyUp, id: UInt32(id)))
            return true
        case .boundary:
            return false
        }
    }

    mutating func runAndCheck() {
        let jobs = pending.map(\.id)
        let (posters, end) = modelRun()
        rig.run()
        #expect(rig.clock.now().nanoseconds == end)
        let actual = rig.poster.posted.map { posted -> Emitted in
            switch posted {
            case .synthetic(let event, _):
                .synthetic(keyCode: event.keyCode.rawValue, down: event.isKeyDown, text: event.unicode.string)
            case .replay(let record, _): .replay(kind: record.kind, id: record.keyboardType)
            }
        }
        #expect(actual == expectedEvents)
        let expectations = rig.drainExpectations()
        #expect(Set(expectations.map(\.job.rawValue)) == posters)
        #expect(expectations.count == posters.count)
        #expect(rig.queue.inFlight == 0)
        // The 64-entry board keeps the outcome of every edit no later sequence can have overwritten.
        let newest = jobs.max() ?? 0
        for id in jobs where id + UInt64(WorkerFeedback.boardSize) > newest {
            if let outcome = expectedOutcomes[id] { #expect(rig.outcome(id) == outcome) }
        }
    }
}

@Suite struct WorkerPropertyTests {
    @Test func scriptedProducerMatchesTheModel() {
        var coverage = Coverage()
        for seed in 0..<1_000 {
            var producer = ScriptedProducer(seed: UInt64(seed) &* 0x9E37_79B9)
            for _ in 0..<200 { producer.step() }
            producer.runAndCheck()
            coverage.flushesAfterARunningJob += producer.coverage.flushesAfterARunningJob
            coverage.keysKeptByTheMacroCeiling += producer.coverage.keysKeptByTheMacroCeiling
        }
        // The PLT-R314 "only unstarted edits" and PLT-R480 macro-ceiling scenarios really occurred.
        #expect(coverage.flushesAfterARunningJob > 0)
        #expect(coverage.keysKeptByTheMacroCeiling > 0)
    }
}
