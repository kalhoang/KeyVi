// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Worker property suite with a scripted producer (W1-D acceptance): random interleavings of edits, held events,
// paired keyUps, boundaries, focus changes, clock advances and worker runs are checked against an exact model.
// Properties: FIFO order, held events replayed once and in order, stale generations discarded with the
// trigger replayed, liveness at 150 ms and 256 jobs abandons only unstarted edits, paired keyUps dropped after
// execution and replayed after abandonment (ADR 0308), exactly one `finished` per job with an expectation iff
// it posted (ADR 0311).

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

private enum ModelJob {
    case edit(id: UInt64, generation: UInt64, deleteCount: Int, at: UInt64)
    case replay(id: UInt64, kind: KeyEventRecord.Kind, at: UInt64)
    case paired(id: UInt64, forJob: UInt64, at: UInt64)
    case boundary(id: UInt64)

    var id: UInt64 {
        switch self {
        case .edit(let id, _, _, _), .replay(let id, _, _), .paired(let id, _, _), .boundary(let id): id
        }
    }

    var waitingSince: UInt64? {
        switch self {
        case .edit(_, _, _, let at), .replay(_, _, let at), .paired(_, _, let at): at
        case .boundary: nil
        }
    }
}

private struct ScriptedProducer {
    static let triggerKeyCode: UInt16 = 0x01
    static let ceilingNanoseconds: UInt64 = 150_000_000

    var generator: SplitMix64
    let rig = WorkerRig()
    var pending: [ModelJob] = []
    var expectedEvents: [Emitted] = []
    var expectedOutcomes: [UInt64: JobOutcome] = [:]
    var unpairedEdits: [UInt64] = []
    var generation: UInt64 = 1

    init(seed: UInt64) { generator = SplitMix64(seed: seed) }

    var now: UInt64 { rig.clock.now().nanoseconds }

    static func insertion(for id: UInt64) -> String { String(Character(UnicodeScalar(UInt32(0x4E00 + id % 20_000))!)) }

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

    mutating func pushEdit() {
        let deleteCount = Int.random(in: 0...2, using: &generator)
        let id = rig.nextSequence()
        let job = Fixture.job(
            sequence: id, deleteCount: deleteCount, insertion: Self.insertion(for: id), generation: generation,
            trigger: record(.keyDown, id: id), createdAt: rig.clock.now())
        precondition(rig.queue.push(.edit(job)))
        pending.append(.edit(id: id, generation: generation, deleteCount: deleteCount, at: now))
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
        precondition(rig.queue.push(.pairedKeyUp(JobSequence(rawValue: id), record(.keyUp, id: id), forJob: JobSequence(rawValue: forJob))))
        pending.append(.paired(id: id, forJob: forJob, at: now))
    }

    /// The model of one `runUntilIdle`: leading boundaries, then a flush if the oldest waiting key is older than
    /// the ceiling (or more than 256 jobs wait), otherwise normal execution. Time does not move during a run.
    mutating func modelRun() -> Set<UInt64> {
        var posted = Set<UInt64>()
        var flushing = pending.count > 256
        for job in pending {
            if !flushing, let since = job.waitingSince, now - since > Self.ceilingNanoseconds { flushing = true }
            if apply(job, flushing: flushing) { posted.insert(job.id) }
        }
        pending.removeAll()
        unpairedEdits.removeAll()
        return posted
    }

    /// Returns whether the job posted anything.
    private mutating func apply(_ job: ModelJob, flushing: Bool) -> Bool {
        switch job {
        case .edit(let id, let jobGeneration, let deleteCount, _):
            let outcome: JobOutcome =
                flushing ? .abandoned : (jobGeneration < generation ? .discardedForGeneration : .executed)
            expectedOutcomes[id] = outcome
            guard outcome == .executed else {
                expectedEvents.append(.replay(kind: .keyDown, id: UInt32(id)))
                return true
            }
            for _ in 0..<deleteCount {
                expectedEvents += [.synthetic(keyCode: 0x33, down: true, text: ""), .synthetic(keyCode: 0x33, down: false, text: "")]
            }
            let text = Self.insertion(for: id)
            expectedEvents += [
                .synthetic(keyCode: Self.triggerKeyCode, down: true, text: text),
                .synthetic(keyCode: Self.triggerKeyCode, down: false, text: text),
            ]
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
        let posters = modelRun()
        rig.run()
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
        for seed in 0..<1_000 {
            var producer = ScriptedProducer(seed: UInt64(seed) &* 0x9E37_79B9)
            for _ in 0..<200 { producer.step() }
            producer.runAndCheck()
        }
    }
}
