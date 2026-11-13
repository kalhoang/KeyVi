// SPDX-License-Identifier: GPL-3.0-or-later
//
// W3-A: the app side of the integration hooks (ADR 0502, "Integration hooks") with an in-memory directory, a
// manual watcher and scripted actions: every request answered once with its own sequence number, never deleted,
// the error codes, one command at a time, and the scan at start.

import AppModel
import Diagnostics
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

/// The hooks directory in memory. Requests are written by the test (the harness), responses by the server.
final class FakeHookFiles: IntegrationHookFileAccess, Sendable {
    private struct State {
        var requests: [UInt64: Result<Data, HookFileRefusal>] = [:]
        var responses: [UInt64: Data] = [:]
        var writes: [UInt64] = []
        var prepared = 0
        var prepareError: HookDirectoryError?
        var failingWrites = 0
    }

    private let state = Mutex(State())

    func addRequest(_ sequence: UInt64, _ command: AppHookCommand) {
        add(sequence, .success(try! JSONEncoder().encode(AppHookRequest(sequence: sequence, command: command))))
    }

    func add(_ sequence: UInt64, json: String) { add(sequence, .success(Data(json.utf8))) }
    func add(_ sequence: UInt64, _ content: Result<Data, HookFileRefusal>) {
        state.withLock { $0.requests[sequence] = content }
    }

    /// What the harness does after reading an answer: remove the request, then the response.
    func harnessRemoves(_ sequence: UInt64) {
        state.withLock {
            $0.requests[sequence] = nil
            $0.responses[sequence] = nil
        }
    }

    func failPrepare(_ error: HookDirectoryError?) { state.withLock { $0.prepareError = error } }
    /// The next `count` response writes fail (disk full, the directory replaced between the scan and the write).
    func failWrites(_ count: Int) { state.withLock { $0.failingWrites = count } }

    var preparedCount: Int { state.withLock { $0.prepared } }
    var writes: [UInt64] { state.withLock { $0.writes } }
    var requestCount: Int { state.withLock { $0.requests.count } }

    func response(_ sequence: UInt64) throws -> AppHookResponse? {
        guard let data = state.withLock({ $0.responses[sequence] }) else { return nil }
        return try JSONDecoder().decode(AppHookResponse.self, from: data)
    }

    func prepare() throws(HookDirectoryError) {
        let error = state.withLock { state -> HookDirectoryError? in
            state.prepared += 1
            return state.prepareError
        }
        if let error { throw error }
    }

    func requestSequences() -> [UInt64] { state.withLock { $0.requests.keys.sorted() } }

    func readRequest(_ sequence: UInt64, maxBytes: Int) -> Result<Data, HookFileRefusal> {
        guard let content = state.withLock({ $0.requests[sequence] }) else { return .failure(.missing) }
        if case .success(let data) = content, data.count > maxBytes { return .failure(.tooLarge) }
        return content
    }

    func responseExists(_ sequence: UInt64) -> Bool { state.withLock { $0.responses[sequence] != nil } }

    func writeResponse(_ data: Data, sequence: UInt64) throws(HookDirectoryError) {
        let failed = state.withLock { state -> Bool in
            guard state.failingWrites == 0 else {
                state.failingWrites -= 1
                return true
            }
            state.responses[sequence] = data
            state.writes.append(sequence)
            return false
        }
        if failed { throw .io(errno: ENOSPC) }
    }
}

final class ManualDirectoryWatcher: DirectoryChangeWatching, Sendable {
    private let handler = Mutex<(@Sendable (DirectoryChange) -> Void)?>(nil)
    private let starts = Atomic<Int>(0)
    private let stops = Atomic<Int>(0)

    func start(onChange: @escaping @Sendable (DirectoryChange) -> Void) throws(HookDirectoryError) {
        handler.withLock { $0 = onChange }
        starts.wrappingAdd(1, ordering: .relaxed)
    }

    func stop() {
        handler.withLock { $0 = nil }
        stops.wrappingAdd(1, ordering: .relaxed)
    }

    var startCount: Int { starts.load(ordering: .relaxed) }
    var stopCount: Int { stops.load(ordering: .relaxed) }
    var isWatching: Bool { handler.withLock { $0 != nil } }
}

/// Scripted actions; `latencyProbe` can be held until the test releases it (one command at a time).
final class ScriptedHookActions: IntegrationHookActions, Sendable {
    private struct State {
        var calls: [String] = []
        var tapTimeout = HookActionOutcome.done
        var permission = HookActionOutcome.done
        var update = HookActionOutcome.done
        var probe = LatencyProbeOutcome.unavailable
        var holdProbe = false
        var heldProbe: CheckedContinuation<Void, Never>?
    }

    private let state = Mutex(State())
    let snapshot: AppStateSnapshot

    init(snapshot: AppStateSnapshot) { self.snapshot = snapshot }

    var calls: [String] { state.withLock { $0.calls } }
    func set(tapTimeout: HookActionOutcome) { state.withLock { $0.tapTimeout = tapTimeout } }
    func set(permission: HookActionOutcome) { state.withLock { $0.permission = permission } }
    func set(update: HookActionOutcome) { state.withLock { $0.update = update } }
    func set(probe: LatencyProbeOutcome, hold: Bool = false) {
        state.withLock {
            $0.probe = probe
            $0.holdProbe = hold
        }
    }

    var probeIsHeld: Bool { state.withLock { $0.heldProbe != nil } }
    func releaseProbe() { state.withLock { $0.heldProbe }?.resume() }

    private func record(_ call: String) { state.withLock { $0.calls.append(call) } }

    func state() async -> AppStateSnapshot {
        record("state")
        return snapshot
    }

    func resetMetrics() async { record("resetMetrics") }

    func simulateTapTimeout() async -> HookActionOutcome {
        record("tapTimeout")
        return state.withLock { $0.tapTimeout }
    }

    func setAccessibilityRevoked(_ revoked: Bool) async -> HookActionOutcome {
        record(revoked ? "revoke" : "restore")
        return state.withLock { $0.permission }
    }

    func runLatencyProbe(_ profile: LatencyProbeResult.Profile) async -> LatencyProbeOutcome {
        record("latencyProbe:" + profile.rawValue)
        if state.withLock({ $0.holdProbe }) {
            await withCheckedContinuation { continuation in state.withLock { $0.heldProbe = continuation } }
        }
        return state.withLock { $0.probe }
    }

    func checkForUpdates() async -> HookActionOutcome {
        record("checkForUpdates")
        return state.withLock { $0.update }
    }
}

private let metrics = MetricsSnapshot(
    callbackDuration: .empty, decideToPosted: .empty, decideToPostedWithAX: .empty, echoRoundTrip: .empty,
    heldWait: .empty, focusRefresh: .empty, flushes: 0, tapTimeouts: 0, fallbackActivations: 0, echoLosses: 0,
    watchdogTrips: 0, lostWhilePostingBroken: 0)

private let readyState = AppStateSnapshot(processIdentifier: 321, state: .ready, mode: .vietnamese, metrics: metrics)

/// Sequence numbers as the harness picks them: a random multiple of 2^20 plus a counter, never 1.
private let base: UInt64 = 7 << 20

private struct Rig {
    let files = FakeHookFiles()
    let watcher = ManualDirectoryWatcher()
    let actions = ScriptedHookActions(snapshot: readyState)
    let logger = RecordingLogger()
    let server: IntegrationHookServer

    init() { server = IntegrationHookServer(files: files, watcher: watcher, actions: actions, logger: logger) }

    /// The fixed messages the server logged, at error level, in the diagnostics category (PLT-R902: no content).
    var notes: [String] {
        logger.entries.compactMap { entry in
            guard case .note(let message, .diagnostics) = entry.event, entry.level == .error else { return nil }
            return message.description
        }
    }
}

@Suite struct IntegrationHookServerTests {
    /// A request written before the watcher started is answered by the first scan (W2-E2 sequence rules).
    @Test func answersARequestWrittenBeforeTheStart() async throws {
        let rig = Rig()
        rig.files.addRequest(base + 1, .state)
        try await rig.server.start()
        let response = try #require(try rig.files.response(base + 1))
        #expect(response.sequence == base + 1 && response.ok && response.state == readyState)
        #expect(rig.files.preparedCount == 1 && rig.watcher.isWatching)
        #expect(rig.files.requestCount == 1, "the app never deletes a request")
    }

    /// Each request gets one answer with its own number, however many scans run before the harness removes it.
    @Test func answersEachRequestOnceWithItsOwnNumber() async throws {
        let rig = Rig()
        try await rig.server.start()
        rig.files.addRequest(base + 5, .resetMetrics)
        rig.files.addRequest(base + 2, .state)
        await rig.server.scan()
        await rig.server.scan()
        #expect(rig.files.writes == [base + 2, base + 5])
        #expect(try rig.files.response(base + 5)?.sequence == base + 5)
        #expect(rig.actions.calls == ["state", "resetMetrics"])
        rig.files.harnessRemoves(base + 2)
        rig.files.harnessRemoves(base + 5)
        await rig.server.scan()
        #expect(rig.files.writes.count == 2)
    }

    /// A response already present (an earlier app process answered) is not written again.
    @Test func anExistingResponseIsLeftAlone() async throws {
        let rig = Rig()
        try rig.files.writeResponse(Data("{}".utf8), sequence: base + 1)
        rig.files.addRequest(base + 1, .state)
        try await rig.server.start()
        #expect(rig.files.writes == [base + 1] && rig.actions.calls.isEmpty)
    }

    @Test func commandsReachTheirActions() async throws {
        let rig = Rig()
        try await rig.server.start()
        let commands: [AppHookCommand] = [
            .trigger(.tapTimeout), .trigger(.revokePermission), .trigger(.restorePermission), .checkForUpdates,
            .latencyProbe(.fast),
        ]
        for (offset, command) in commands.enumerated() { rig.files.addRequest(base + UInt64(offset), command) }
        await rig.server.scan()
        #expect(rig.actions.calls == ["tapTimeout", "revoke", "restore", "checkForUpdates", "latencyProbe:fast"])
        for offset in 0..<4 { #expect(try rig.files.response(base + UInt64(offset))?.ok == true) }
        #expect(try rig.files.response(base + 4)?.errorCode == .unsupported)  // probe unavailable
    }

    /// Outcomes map to the contract's codes: unavailable is `unsupported`, a timeout or a lost probe is `busy`.
    @Test func outcomesMapToErrorCodes() async throws {
        let rig = Rig()
        try await rig.server.start()
        rig.actions.set(tapTimeout: .unavailable)
        rig.actions.set(permission: .timedOut)
        rig.actions.set(update: .unavailable)
        rig.actions.set(probe: .interrupted)
        let commands: [AppHookCommand] = [
            .trigger(.tapTimeout), .trigger(.revokePermission), .checkForUpdates, .latencyProbe(.normal),
        ]
        for (offset, command) in commands.enumerated() { rig.files.addRequest(base + UInt64(offset), command) }
        await rig.server.scan()
        let codes = try (0..<4).map { try rig.files.response(base + UInt64($0))?.errorCode }
        #expect(codes == [.unsupported, .busy, .unsupported, .busy])
        let probe = LatencyProbeResult(
            ranAt: Date(timeIntervalSince1970: 0),
            results: [
                .init(
                    profile: .normal, decideToPostedP50Microseconds: 1, decideToPostedP99Microseconds: 2,
                    endToEndDeltaP50Microseconds: 3, endToEndDeltaP99Microseconds: 4, samples: 12)
            ])
        rig.actions.set(probe: .result(probe))
        rig.files.addRequest(base + 9, .latencyProbe(.normal))
        await rig.server.scan()
        #expect(try rig.files.response(base + 9)?.latencyProbe == probe)
    }

    @Test func malformedRequestsAreRefused() async throws {
        let rig = Rig()
        try await rig.server.start()
        rig.files.add(base + 1, json: #"{"formatVersion":1,"sequence":\#(base + 1),"command":"typeText"}"#)
        rig.files.add(base + 2, json: #"{"formatVersion":2,"sequence":\#(base + 2),"command":"state"}"#)
        rig.files.add(base + 3, json: #"{"formatVersion":1,"sequence":4,"command":"state"}"#)
        rig.files.add(base + 4, json: "not json")
        rig.files.add(base + 5, json: #"{"formatVersion":1,"sequence":\#(base + 5),"command":"latencyProbe"}"#)
        rig.files.add(base + 6, .success(Data(repeating: 0x20, count: IntegrationHookServer.maximumRequestBytes + 1)))
        rig.files.add(base + 7, .failure(.unreadable(errno: EIO)))
        await rig.server.scan()
        let codes = try (1...7).map { try rig.files.response(base + UInt64($0))?.errorCode }
        #expect(
            codes == [
                .unknownCommand, .unsupported, .unsupported, .unsupported, .unsupported, .unsupported, .unsupported,
            ])
        let mismatched = try #require(try rig.files.response(base + 3))
        #expect(mismatched.sequence == base + 3, "the answer carries the file's number")
        #expect(rig.actions.calls.isEmpty)
    }

    /// Links, other users' files and non-regular files are not the harness's: refused without an answer.
    @Test func foreignFilesAreNeverAnswered() async throws {
        let rig = Rig()
        rig.files.add(base + 1, .failure(.symbolicLink))
        rig.files.add(base + 2, .failure(.foreignOwner))
        rig.files.add(base + 3, .failure(.notRegularFile))
        rig.files.add(base + 4, .failure(.missing))
        try await rig.server.start()
        await rig.server.scan()
        #expect(rig.files.writes.isEmpty && rig.actions.calls.isEmpty)
    }

    /// One command at a time: a request that arrives while the latency probe runs is answered `busy`; the probe's
    /// own answer follows when it ends.
    @Test func aSecondRequestWhileOneRunsIsBusy() async throws {
        let rig = Rig()
        try await rig.server.start()
        rig.actions.set(probe: .unavailable, hold: true)
        rig.files.addRequest(base + 1, .latencyProbe(.burst))
        let first = Task { await rig.server.scan() }
        while !rig.actions.probeIsHeld { await Task.yield() }
        rig.files.addRequest(base + 2, .state)
        await rig.server.scan()
        #expect(try rig.files.response(base + 2)?.errorCode == .busy)
        #expect(try rig.files.response(base + 1) == nil)
        rig.actions.releaseProbe()
        await first.value
        #expect(try rig.files.response(base + 1)?.errorCode == .unsupported)
        #expect(rig.actions.calls == ["latencyProbe:burst"])
    }

    @Test func watcherChangesScanAndAReplacedDirectoryIsPreparedAgain() async throws {
        let rig = Rig()
        try await rig.server.start()
        rig.files.addRequest(base + 1, .state)
        await rig.server.changed(.contents)
        #expect(rig.files.writes == [base + 1])
        await rig.server.changed(.replaced)
        #expect(rig.files.preparedCount == 2 && rig.watcher.startCount == 2 && rig.watcher.isWatching)
        await rig.server.stop()
        #expect(!rig.watcher.isWatching)
        rig.files.addRequest(base + 2, .state)
        await rig.server.changed(.contents)  // a late event after stop does nothing
        #expect(rig.files.writes == [base + 1])
    }

    @Test func anUnusableDirectoryStartsNothing() async {
        let rig = Rig()
        rig.files.failPrepare(.symbolicLink)
        rig.files.addRequest(base + 1, .state)
        await #expect(throws: HookDirectoryError.symbolicLink) { try await rig.server.start() }
        #expect(rig.watcher.startCount == 0 && rig.files.writes.isEmpty)
    }

    /// Runbook section 8: an unusable directory is named in the log (a reason code, never a path), so a silent
    /// test build is not mistaken for one built without the hooks.
    @Test func anUnusableDirectoryIsLoggedWithItsReason() async {
        let reasons: [(HookDirectoryError, String)] = [
            (.symbolicLink, "symbolic link"), (.notDirectory, "not a directory"), (.foreignOwner, "another user"),
            (.io(errno: EACCES), "permission denied"), (.io(errno: ENOSPC), "disk full"),
            (.io(errno: EIO), "I/O error"),
        ]
        for (error, reason) in reasons {
            let rig = Rig()
            rig.files.failPrepare(error)
            await #expect(throws: error) { try await rig.server.start() }
            #expect(rig.notes.count == 1)
            #expect(rig.notes.first?.contains(reason) == true, "\(error)")
        }
    }

    /// A response that could not be written is written again by the next scan, without running the command a
    /// second time (a repeated tapTimeout would count a second recovery).
    @Test func aFailedWriteIsRetriedWithoutRunningTheCommandAgain() async throws {
        let rig = Rig()
        try await rig.server.start()
        rig.files.failWrites(1)
        rig.files.addRequest(base + 1, .trigger(.tapTimeout))
        await rig.server.scan()
        #expect(try rig.files.response(base + 1) == nil)
        #expect(rig.notes.count == 1)
        await rig.server.scan()
        #expect(try rig.files.response(base + 1)?.ok == true)
        #expect(rig.actions.calls == ["tapTimeout"])
        await rig.server.scan()
        #expect(rig.files.writes == [base + 1])
    }

    @Test func remembersABoundedNumberOfAnswers() async throws {
        let rig = Rig()
        try await rig.server.start()
        let count = IntegrationHookServer.rememberedSequences + 10
        for offset in 0..<count { rig.files.addRequest(base + UInt64(offset), .resetMetrics) }
        await rig.server.scan()
        await rig.server.scan()  // the oldest answers are forgotten, but their response files guard them
        #expect(rig.files.writes.count == count)
    }
}
