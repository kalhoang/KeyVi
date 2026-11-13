// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Injection service fakes, implemented in the skeleton (ADR 0313) so the worker (W1-D), the pipeline harness
// (W1-F1) and the guided test (W2-C) can test in parallel. W1-D owns this directory and may add behaviours;
// existing behaviours keep their meaning.

internal import AppModel
internal import Foundation
public import Injection
internal import RealtimeSupport
internal import Synchronization

/// Records every posted event and optionally forwards it to a sink (simulated field, window-server model, echo
/// loopback). `CGEventPost` never reports failure, so a revoked permission is modelled as `.silentlyDropping`:
/// posts "succeed" but nothing is delivered and no echo comes back (ADR 0311).
public final class FakeEventPoster: EventPoster, Sendable {
    public enum Posted: Sendable, Hashable {
        case synthetic(SyntheticKeyEvent, userData: Int64)
        case replay(KeyEventRecord, userData: Int64)
    }

    public enum Mode: Sendable, Hashable {
        /// Normal: recorded in `posted` and forwarded to the sink.
        case delivering
        /// Permission revoked or OS policy: recorded in `dropped`, not forwarded (no delivery, no echo).
        case silentlyDropping
        /// `CGEvent` creation fails: throws `.eventCreationFailed`, nothing recorded.
        case failingCreation
    }

    private struct State {
        var mode: Mode = .delivering
        var posted: [Posted] = []
        var dropped: [Posted] = []
    }

    private let sink: (@Sendable (Posted) -> Void)?
    private let state = Mutex(State())

    public init(sink: (@Sendable (Posted) -> Void)? = nil) { self.sink = sink }

    /// Delivered events, in posting order.
    public var posted: [Posted] { state.withLock { $0.posted } }
    /// Events posted while `.silentlyDropping`.
    public var dropped: [Posted] { state.withLock { $0.dropped } }
    public var mode: Mode { state.withLock { $0.mode } }
    public func setMode(_ mode: Mode) { state.withLock { $0.mode = mode } }

    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) {
        try deliver(.synthetic(event, userData: userData))
    }

    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) {
        try deliver(.replay(record, userData: userData))
    }

    private func deliver(_ item: Posted) throws(PostError) {
        let mode = state.withLock { state -> Mode in
            switch state.mode {
            case .delivering: state.posted.append(item)
            case .silentlyDropping: state.dropped.append(item)
            case .failingCreation: break
            }
            return state.mode
        }
        switch mode {
        case .delivering: sink?(item)
        case .silentlyDropping: return
        case .failingCreation: throw .eventCreationFailed
        }
    }
}

extension FakeEventPoster.Posted {
    /// The `kCGEventSourceUserData` the event carried.
    public var userData: Int64 {
        switch self {
        case .synthetic(_, let userData), .replay(_, let userData): userData
        }
    }
}

/// AX field access backed by a `SimulatedTextField`; can time out, be unavailable or ignore writes on demand.
public final class FakeFocusedFieldAccess: FocusedFieldAccess, Sendable {
    /// `writesIgnored`: every write reports success and does nothing. `textWritesIgnored`: selection writes
    /// apply, text writes report success and do nothing (4.5 "writes may silently do nothing").
    public enum Behaviour: Sendable, Hashable { case normal, timeout, unavailable, writesIgnored, textWritesIgnored }

    private let field: SimulatedTextField
    private let behaviourState: Mutex<Behaviour>
    private let calls = Atomic<Int>(0)

    public init(field: SimulatedTextField, behaviour: Behaviour = .normal) {
        self.field = field
        behaviourState = Mutex(behaviour)
    }

    public var behaviour: Behaviour { behaviourState.withLock { $0 } }
    public func setBehaviour(_ behaviour: Behaviour) { behaviourState.withLock { $0 = behaviour } }
    /// Number of AX calls made (bounded-call tests, PLT-R342).
    public var callCount: Int { calls.load(ordering: .relaxed) }

    public func selectedRange(_ field: FieldHandle, timeout: Duration) -> AXCallResult<Injection.TextRange> {
        read { self.field.axSelectedRange() }
    }

    public func text(_ field: FieldHandle, in range: Injection.TextRange, timeout: Duration) -> AXCallResult<String> {
        read { self.field.axText(in: range) }
    }

    public func setSelectedRange(_ field: FieldHandle, to range: Injection.TextRange, timeout: Duration)
        -> AXCallResult<Void>
    {
        write(text: false) { self.field.axSetSelectedRange(range) }
    }

    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: Duration) -> AXCallResult<Void> {
        write(text: true) { self.field.axSetSelectedText(text) }
    }

    private func read<Value: Sendable>(_ body: () -> Value) -> AXCallResult<Value> {
        calls.wrappingAdd(1, ordering: .relaxed)
        switch behaviour {
        case .normal, .writesIgnored, .textWritesIgnored: return .success(body())
        case .timeout: return .timedOut
        case .unavailable: return .unavailable
        }
    }

    private func write(text: Bool, _ body: () -> Void) -> AXCallResult<Void> {
        calls.wrappingAdd(1, ordering: .relaxed)
        switch behaviour {
        case .normal:
            body()
            return .success(())
        case .textWritesIgnored:
            if !text { body() }
            return .success(())
        case .writesIgnored: return .success(())
        case .timeout: return .timedOut
        case .unavailable: return .unavailable
        }
    }
}

/// Multi-item, multi-type pasteboard with file promises, lazy data and slow reads for PLT-R461 tests.
public final class FakePasteboard: PasteboardAccess, Sendable {
    /// Conditions a real pasteboard can be in that make a snapshot impossible (PLT-R461 step 1).
    public enum Condition: Sendable, Hashable {
        case filePromise
        case lazyDataUnavailable
        case slowRead
        case writeFails
    }

    private struct State {
        var items: [PasteboardItemData]
        var changeCount = 1
        var conditions: Set<Condition> = []
        var writes = 0
    }

    private let state: Mutex<State>

    public init(items: [PasteboardItemData] = []) { state = Mutex(State(items: items)) }

    public var changeCount: Int { state.withLock { $0.changeCount } }
    public var items: [PasteboardItemData] { state.withLock { $0.items } }
    /// Number of `writeTransient` calls (coalescing tests).
    public var transientWriteCount: Int { state.withLock { $0.writes } }

    /// The plain-text value Command+V would paste (wire into `SimulatedTextField(pasteboardText:)`).
    public var plainText: String? {
        state.withLock { state in
            state.items.first?.data[PasteboardTypeName.plainText].flatMap { String(data: $0, encoding: .utf8) }
        }
    }

    public func set(_ condition: Condition, _ active: Bool) {
        state.withLock { state in
            if active { state.conditions.insert(condition) } else { state.conditions.remove(condition) }
        }
    }

    /// Simulates the user copying something during the restore window.
    public func userCopies(_ item: PasteboardItemData) {
        state.withLock { state in
            state.items = [item]
            state.changeCount += 1
        }
    }

    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        let result: Result<PasteboardSnapshot, PasteboardError> = state.withLock { state in
            if state.conditions.contains(.filePromise) { return .failure(.filePromise) }
            if state.conditions.contains(.lazyDataUnavailable) { return .failure(.lazyDataUnavailable) }
            if state.conditions.contains(.slowRead) { return .failure(.timedOut) }
            let total = state.items.reduce(0) { sum, item in sum + item.data.values.reduce(0) { $0 + $1.count } }
            if total > limits.maxTotalBytes { return .failure(.tooLarge) }
            return .success(PasteboardSnapshot(changeCount: state.changeCount, items: state.items, totalBytes: total))
        }
        return try result.get()
    }

    public func writeTransient(_ text: String) throws(PasteboardError) -> Int {
        let result: Result<Int, PasteboardError> = state.withLock { state in
            if state.conditions.contains(.writeFails) { return .failure(.writeFailed) }
            var data: [String: Data] = [PasteboardTypeName.plainText: Data(text.utf8)]
            for marker in PasteboardTypeName.markers { data[marker] = Data() }
            state.items = [
                PasteboardItemData(types: [PasteboardTypeName.plainText] + PasteboardTypeName.markers, data: data)
            ]
            state.changeCount += 1
            state.writes += 1
            return .success(state.changeCount)
        }
        return try result.get()
    }

    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) {
        let failed = state.withLock { state -> Bool in
            if state.conditions.contains(.writeFails) { return true }
            state.items = snapshot.items
            state.changeCount += 1
            return false
        }
        if failed { throw .writeFailed }
    }
}
