// SPDX-License-Identifier: LicenseRef-App-Pending

internal import AppModel
public import Injection
internal import RealtimeSupport

/// Records every posted event; optionally forwards it to a sink (simulated field, echo loopback).
public final class FakeEventPoster: EventPoster, Sendable {
    public enum Posted: Sendable, Hashable {
        case synthetic(SyntheticKeyEvent, userData: Int64)
        case replay(KeyEventRecord, userData: Int64)
    }

    public init(sink: (@Sendable (Posted) -> Void)? = nil) { unimplemented() }
    public var posted: [Posted] { unimplemented() }
    /// Makes subsequent posts throw `.notPermitted` (fail-open tests, PLT-R730).
    public func revokePermission() { unimplemented() }
    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) { unimplemented() }
    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) { unimplemented() }
}

/// AX field access backed by a `SimulatedTextField`; can time out or be unavailable on demand.
public final class FakeFocusedFieldAccess: FocusedFieldAccess, Sendable {
    public enum Behaviour: Sendable { case normal, timeout, unavailable, writesIgnored }
    public init(field: SimulatedTextField, behaviour: Behaviour = .normal) { unimplemented() }
    public func selectedRange(_ field: FieldHandle, timeout: Duration) -> AXCallResult<TextRange> { unimplemented() }
    public func text(_ field: FieldHandle, in range: TextRange, timeout: Duration) -> AXCallResult<String> {
        unimplemented()
    }
    public func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: Duration) -> AXCallResult<Void> {
        unimplemented()
    }
    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: Duration) -> AXCallResult<Void> {
        unimplemented()
    }
}

/// Multi-item, multi-type pasteboard with file promises and lazy data for PLT-R461 tests.
public final class FakePasteboard: PasteboardAccess, Sendable {
    public init(items: [PasteboardItemData] = []) { unimplemented() }
    public var changeCount: Int { unimplemented() }
    public var items: [PasteboardItemData] { unimplemented() }
    /// Simulates the user copying something during the restore window.
    public func userCopies(_ item: PasteboardItemData) { unimplemented() }
    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot { unimplemented() }
    public func writeTransient(_ text: String) throws(PasteboardError) -> Int { unimplemented() }
    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { unimplemented() }
}
