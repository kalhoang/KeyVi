// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Production implementations of the injection services. They need granted permissions and are exercised by
// the self-hosted integration suite (13.2), never by hosted CI or on the maintainer's everyday Mac.

internal import AppModel

/// CoreGraphics poster (PLT-R320-R322, PLT-R324).
public final class CGEventPoster: EventPoster {
    public init() { unimplemented() }
    public func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError) { unimplemented() }
    public func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError) { unimplemented() }
}

/// Bounded AX field access (PLT-R343).
public final class AXFocusedFieldAccess: FocusedFieldAccess {
    public init() { unimplemented() }
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

/// AppKit pasteboard (PLT-R461). `pasteboardName` nil = general pasteboard.
public final class NSPasteboardAccess: PasteboardAccess {
    public init(pasteboardName: String?) { unimplemented() }
    public var changeCount: Int { unimplemented() }
    public func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot { unimplemented() }
    public func writeTransient(_ text: String) throws(PasteboardError) -> Int { unimplemented() }
    public func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError) { unimplemented() }
}
