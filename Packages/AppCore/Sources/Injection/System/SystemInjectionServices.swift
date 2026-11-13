// SPDX-License-Identifier: GPL-3.0-or-later
//
// Production implementations of the injection services. They need granted permissions and are exercised by
// the self-hosted integration suite (13.2), never by hosted CI or on the maintainer's everyday Mac.
// Each is a thin wrapper: the logic lives in `CGEventFactory`, `AXFieldCalls` and `PasteboardIO`, which are
// unit-tested without posting, AX trust or the general pasteboard.

internal import AppModel
internal import ApplicationServices
public import RealtimeSupport

/// CoreGraphics poster (PLT-R320-R322, PLT-R324).
public final class CGEventPoster: EventPoster {
    private let factory: CGEventFactory

    public init() { factory = CGEventFactory() }

    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) {
        try factory.makeEvent(event, userData: userData).post(tap: .cgSessionEventTap)
    }

    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) {
        try factory.makeReplay(record, userData: userData).post(tap: .cgSessionEventTap)
    }
}

/// Bounded AX field access (PLT-R343).
public final class AXFocusedFieldAccess: FocusedFieldAccess {
    public init() {}
    public func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<TextRange> {
        AXFieldCalls.selectedRange(field.element?.element, timeout: timeout)
    }
    public func text(_ field: FieldHandle, in range: TextRange, timeout: TimeSpan) -> AXCallResult<String> {
        AXFieldCalls.text(field.element?.element, in: range, timeout: timeout)
    }
    public func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: TimeSpan) -> AXCallResult<Void> {
        AXFieldCalls.setSelectedRange(field.element?.element, to: range, timeout: timeout)
    }
    public func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void> {
        AXFieldCalls.setSelectedText(field.element?.element, to: text, timeout: timeout)
    }
}

/// AppKit pasteboard (PLT-R461). `pasteboardName` nil = general pasteboard.
public final class NSPasteboardAccess: PasteboardAccess {
    private let io: PasteboardIO

    public init(pasteboardName: String?) { io = PasteboardIO(name: pasteboardName) }
    public var changeCount: Int { io.changeCount }
    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot {
        try io.snapshot(limits: limits)
    }
    public func writeTransient(_ text: String) throws(PasteboardError) -> Int { try io.writeTransient(text) }
    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { try io.restore(snapshot) }
}
