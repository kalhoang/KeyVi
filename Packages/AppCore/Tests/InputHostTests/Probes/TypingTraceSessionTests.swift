// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R905 typing trace flow over the real `CaptureController` with in-memory storage and virtual time: 60 s
// default, 180 s maximum, a countdown for the HUD, Stop or the time limit ends it, review before export,
// deletion right after export or discard.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

final class TraceBench: Sendable {
    let wallClock = FixedWallClock()
    let clock = ManualClock()
    let scheduler: ManualScheduler
    let fileSystem: InMemoryFileSystem
    let capture: CaptureController
    private let log = StateLog()
    let session: TypingTraceSession

    init() {
        scheduler = ManualScheduler(clock: clock)
        let wall = wallClock
        fileSystem = InMemoryFileSystem(now: { wall.now() })
        capture = CaptureController(
            directory: URL(fileURLWithPath: "/logs/App/captures"), fileSystem: fileSystem, wallClock: wallClock,
            clock: clock, scheduler: scheduler)
        let log = log
        session = TypingTraceSession(capture: capture, scheduler: scheduler, wallClock: wallClock) { state in
            log.values.withLock { $0.append(state) }
        }
    }

    var published: [TypingTraceSession.State] { log.values.withLock { $0 } }

    func advance(seconds: Int) {
        wallClock.advance(by: TimeInterval(seconds))
        scheduler.advance(by: .seconds(seconds))
    }

    var captureFiles: [String] {
        fileSystem.nodes.keys.filter { $0.hasSuffix(".jsonl") }.sorted()
    }
}

final class StateLog: Sendable {
    let values = Mutex<[TypingTraceSession.State]>([])
}

@Suite("Typing trace session (PLT-R905)")
struct TypingTraceSessionTests {
    @Test func durationsAreClampedToTheLimits() {
        #expect(TypingTraceSession.duration(seconds: nil) == .seconds(60))
        #expect(TypingTraceSession.duration(seconds: 500) == .seconds(180))
        #expect(TypingTraceSession.duration(seconds: 0) == .seconds(1))
        #expect(TypingTraceSession.duration(seconds: 90) == .seconds(90))
    }

    @Test func countdownThenStopThenReviewAndExport() throws {
        let bench = TraceBench()
        bench.session.start()
        guard case .recording(let id, let remaining) = bench.session.state else {
            Issue.record("not recording")
            return
        }
        #expect(remaining == .seconds(60) && bench.capture.isRecording)
        bench.advance(seconds: 1)
        #expect(bench.session.state == .recording(id, remaining: .seconds(59)))
        bench.session.stop()
        #expect(bench.session.state == .finished(id) && !bench.capture.isRecording)
        let review = try #require(bench.session.review(language: .english))
        #expect(!review.isEmpty)
        let destination = URL(fileURLWithPath: "/exports/trace.jsonl")
        #expect(bench.session.export(to: destination))
        #expect(bench.session.state == .exported)
        #expect(bench.captureFiles == [destination.path])  // the capture itself is gone
        #expect(bench.published.first == .recording(id, remaining: .seconds(60)))
        #expect(bench.published.last == .exported)
        #expect(bench.scheduler.pendingCount == 0)  // no countdown left behind
    }

    @Test func theTimeLimitEndsTheRecordingByItself() {
        let bench = TraceBench()
        bench.session.start(duration: TypingTraceSession.duration(seconds: 5))
        guard case .recording(let id, _) = bench.session.state else {
            Issue.record("not recording")
            return
        }
        bench.advance(seconds: 6)
        #expect(bench.session.state == .finished(id))
        #expect(bench.published.filter { $0 == .finished(id) }.count == 1)
        bench.session.stop()  // nothing to stop any more
        #expect(bench.session.state == .finished(id))
    }

    @Test func discardDeletesAtOnce() {
        let bench = TraceBench()
        bench.session.start()
        #expect(bench.captureFiles.count == 1)
        bench.session.discard()
        #expect(bench.session.state == .discarded)
        #expect(bench.captureFiles.isEmpty)
        bench.session.discard()  // idempotent
        #expect(bench.session.review(language: .vietnamese) == nil)
        #expect(!bench.session.export(to: URL(fileURLWithPath: "/exports/x.jsonl")))
    }

    @Test func oneTraceAtATimeAndAnUnreviewedTraceNeverLingers() {
        let bench = TraceBench()
        bench.session.start()
        let first = bench.session.state
        bench.session.start()  // ignored while recording
        #expect(bench.session.state == first)
        bench.session.stop()
        bench.session.start()
        #expect(bench.captureFiles.count == 1)  // the stopped, unreviewed trace was discarded
    }

    @Test func invalidDurationAndLostTracesFail() {
        let bench = TraceBench()
        bench.session.start(duration: .seconds(181))
        #expect(bench.session.state == .failed(.invalidDuration))
        bench.session.start(duration: .seconds(10))
        bench.session.stop()
        for path in bench.captureFiles { try? bench.fileSystem.removeItem(at: URL(fileURLWithPath: path)) }
        #expect(bench.session.review(language: .english) == nil)
        #expect(bench.session.state == .failed(.unknownSession))
    }

    @Test func storageFailuresAreReported() {
        #expect(TypingTraceSession.failure(CaptureError.alreadyRecording) == .alreadyRecording)
        #expect(TypingTraceSession.failure(CaptureError.storage(.ioFailure(path: "/x", errno: 5))) == .storage)
        #expect(TypingTraceSession.failure(CocoaError(.fileNoSuchFile)) == .storage)
    }
}
