// SPDX-License-Identifier: GPL-3.0-or-later
//
// Platform services used by the inject thread. Production implementations live in Injection/System;
// TestSupport provides fakes so every strategy is testable without permissions (QA-R1 layer 4).

public import AppModel
public import ApplicationServices
public import Foundation
public import RealtimeSupport

/// One synthetic key event. Flags are always explicit (PLT-R320, PLT-R406); backspace carries no Unicode
/// string (PLT-R407).
public struct SyntheticKeyEvent: Sendable, Hashable, BitwiseCopyable {
    public var keyCode: KeyCode
    public var isKeyDown: Bool
    public var flags: UInt64
    public var unicode: InlineUTF16

    public init(keyCode: KeyCode, isKeyDown: Bool, flags: UInt64, unicode: InlineUTF16) {
        self.keyCode = keyCode
        self.isKeyDown = isKeyDown
        self.flags = flags
        self.unicode = unicode
    }
}

/// `CGEventPost` returns nothing: a revoked permission makes posts vanish silently, so the only reliable
/// signal is echo loss (PLT-R323, ADR 0311). The poster reports only what it can see.
public enum PostError: Error, Sendable, Hashable {
    /// `CGEvent(keyboardEventSource:virtualKey:keyDown:)` returned nil.
    case eventCreationFailed
}

/// Production: `CGEventSource(stateID: .privateState)` with `localEventsSuppressionInterval = 0` (PLT-R320),
/// `CGEvent(keyboardEventSource:virtualKey:keyDown:)`, explicit `flags`, `keyboardSetUnicodeString`,
/// `setIntegerValueField(.eventSourceUserData, value:)`, then `post(tap: .cgSessionEventTap)` (PLT-R322).
/// It never calls `CGPreflightPostEventAccess()` per post; that check runs off the inject thread only after an
/// echo miss (ADR 0311).
public protocol EventPoster: Sendable {
    func post(_ event: SyntheticKeyEvent, userData: Int64) throws(PostError)
    /// Recreates a held physical event with all PLT-R324 fields and the marker.
    func replay(_ record: KeyEventRecord, userData: Int64) throws(PostError)
}

/// UTF-16 range, `CFRange` semantics (`AXValue` of type `.cfRange`).
public struct TextRange: Sendable, Hashable {
    public var location: Int
    public var length: Int
    public init(location: Int, length: Int) {
        self.location = location
        self.length = length
    }
}

/// The caret of a field as `forwardDelete` reads it (PLT-R423): the selected range and the field's length in UTF-16
/// units (`kAXNumberOfCharactersAttribute`), read together so they describe the same moment.
public struct FieldCaret: Sendable, Hashable {
    public var selection: TextRange
    public var characterCount: Int
    public init(selection: TextRange, characterCount: Int) {
        self.selection = selection
        self.characterCount = characterCount
    }

    /// An empty selection at the end of the text: a Forward Delete there deletes no character of the field.
    public var isAtEndOfText: Bool { selection.length == 0 && selection.location == characterCount }
}

public enum AXCallResult<Value: Sendable>: Sendable {
    case success(Value)
    case timedOut
    case unavailable
    case failed(code: Int32)  // AXError raw value
}

/// Bounded AX access for injection (PLT-R342, PLT-R343, PLT-R420, PLT-R423, 4.5). Never reads a full `AXValue`.
/// Production: `AXUIElementCopyAttributeValue(kAXSelectedTextRangeAttribute)`,
/// `AXUIElementCopyMultipleAttributeValues(kAXSelectedTextRangeAttribute, kAXNumberOfCharactersAttribute)`,
/// `AXUIElementCopyParameterizedAttributeValue(kAXStringForRangeParameterizedAttribute)`,
/// `AXUIElementSetAttributeValue(kAXSelectedTextRangeAttribute / kAXSelectedTextAttribute)`, each after
/// `AXUIElementSetMessagingTimeout` with the requested timeout.
public protocol FocusedFieldAccess: Sendable {
    func selectedRange(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<TextRange>
    /// PLT-R423: the selected range and the character count in one call (one round trip to the app).
    func caret(_ field: FieldHandle, timeout: TimeSpan) -> AXCallResult<FieldCaret>
    /// At most 64 UTF-16 units (PLT-R343); longer ranges are clamped by the implementation.
    func text(_ field: FieldHandle, in range: TextRange, timeout: TimeSpan) -> AXCallResult<String>
    func setSelectedRange(_ field: FieldHandle, to range: TextRange, timeout: TimeSpan) -> AXCallResult<Void>
    func setSelectedText(_ field: FieldHandle, to text: String, timeout: TimeSpan) -> AXCallResult<Void>
}

/// `AXUIElement` wrapper. AX references are immutable CF objects that may be used from any thread.
public final class AXElementReference: @unchecked Sendable, Hashable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
    public static func == (lhs: AXElementReference, rhs: AXElementReference) -> Bool {
        CFEqual(lhs.element, rhs.element)
    }
    public func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
}

/// One pasteboard item: every type with its data (PLT-R461 step 1).
public struct PasteboardItemData: Sendable, Hashable {
    public var types: [String]
    public var data: [String: Data]
    public init(types: [String], data: [String: Data]) {
        self.types = types
        self.data = data
    }
}

public struct PasteboardSnapshot: Sendable, Hashable {
    public var changeCount: Int
    public var items: [PasteboardItemData]
    public var totalBytes: Int
    public init(changeCount: Int, items: [PasteboardItemData], totalBytes: Int) {
        self.changeCount = changeCount
        self.items = items
        self.totalBytes = totalBytes
    }
}

public struct PasteboardLimits: Sendable, Hashable {
    public var readTimeout: TimeSpan = .milliseconds(100)
    public var maxTotalBytes: Int = 10 * 1_024 * 1_024
    public init() {}
}

public enum PasteboardError: Error, Sendable, Hashable {
    case unreadableItem, filePromise, lazyDataUnavailable, tooLarge, timedOut, writeFailed
}

/// Production: `NSPasteboard.general` (tests: `NSPasteboard(name:)` with a unique name, 13.1).
/// `writeTransient` writes one item with `public.utf8-plain-text` plus `org.nspasteboard.TransientType`,
/// `org.nspasteboard.ConcealedType` and `org.nspasteboard.AutoGeneratedType` (PLT-R461 step 2).
/// Thread: called on `inject`; VERIFY thread safety, else the implementation hops to main asynchronously and
/// the worker waits on its own condition with a timeout (PLT-R462).
public protocol PasteboardAccess: Sendable {
    var changeCount: Int { get }
    func snapshot(limits: PasteboardLimits) throws(PasteboardError) -> PasteboardSnapshot
    /// Returns the new `changeCount`.
    func writeTransient(_ text: String) throws(PasteboardError) -> Int
    func restore(_ snapshot: PasteboardSnapshot) throws(PasteboardError)
}
