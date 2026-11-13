// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Text field model used by the injection tests (W1-D), the pipeline harness (W1-F1) and the guided-test tests
// (W2-C): caret, selection, inline-completion suggestion, per-event processing. Applies synthetic and replayed
// events the way a Cocoa field does. Shared fake implemented in the skeleton (ADR 0313): integrator-owned and
// frozen in wave 1; a workstream that needs another behaviour asks the integrator.
//
// Key codes are the public macOS virtual key codes (Carbon `Events.h`): Delete 0x33, Forward Delete 0x75,
// arrows 0x7B-0x7E, Return 0x24, Tab 0x30, Escape 0x35, ANSI V 0x09.

internal import AppModel
internal import CoreGraphics
public import Injection
public import InputHost
internal import RealtimeSupport
internal import Synchronization

public final class SimulatedTextField: Sendable {
    public enum Behaviour: Sendable, Hashable {
        /// Plain Cocoa field.
        case cocoa
        /// Address bar, Spotlight, Sheets (4.3): after an insertion at the end, if the text is a proper prefix of
        /// a suggestion, the remainder is appended and selected. Backspace then deletes only the selection.
        case inlineCompletion(suggestions: [String])
        /// Edit-mode transition (section 6): the first keyDown after focus (init, `click`, `reset`) is dropped.
        case dropsFirstEventAfterFocus
        /// Remote clients: synthetic events insert the character their key code produces in the layout, not
        /// their Unicode payload (needs a layout in `apply(_:layout:)`).
        case ignoresUnicodePayload
        /// Terminals: events are buffered and applied `maxEventsPerRead` at a time (`flushPendingReads()`
        /// applies the rest). Shift+arrow does not select.
        case terminalReadsInBatches(maxEventsPerRead: Int)
    }

    public enum KeyCodes {
        public static let delete: UInt16 = 0x33
        public static let forwardDelete: UInt16 = 0x75
        public static let leftArrow: UInt16 = 0x7B
        public static let rightArrow: UInt16 = 0x7C
        public static let downArrow: UInt16 = 0x7D
        public static let upArrow: UInt16 = 0x7E
        public static let returnKey: UInt16 = 0x24
        public static let tab: UInt16 = 0x30
        public static let escape: UInt16 = 0x35
        public static let ansiV: UInt16 = 0x09
    }

    /// PLT-R343: bounded AX reads.
    public static let maximumAXTextUnits = 64

    private enum Operation: Sendable {
        case insert(String)
        case backspace
        case forwardDelete
        case moveLeft(extend: Bool)
        case moveRight(extend: Bool)
        case paste
        case ignored
    }

    private struct State {
        var text: String
        var selection: TextRange
        var dropNextKeyDown: Bool
        var pending: [Operation] = []
        var droppedEvents = 0
        var appliedEvents = 0
    }

    public let behaviour: Behaviour
    private let pasteboardText: (@Sendable () -> String?)?
    private let state: Mutex<State>

    /// `pasteboardText` answers Command+V (for example `FakePasteboard.plainText`).
    public init(behaviour: Behaviour = .cocoa, text: String = "", pasteboardText: (@Sendable () -> String?)? = nil) {
        self.behaviour = behaviour
        self.pasteboardText = pasteboardText
        let caret = text.utf16.count
        state = Mutex(
            State(
                text: text, selection: TextRange(location: caret, length: 0),
                dropNextKeyDown: behaviour == .dropsFirstEventAfterFocus))
    }

    public var text: String { state.withLock { $0.text } }
    /// UTF-16 selection (`CFRange` semantics).
    public var selection: TextRange { state.withLock { $0.selection } }
    public var selectedText: String {
        state.withLock { Self.substring($0.text, $0.selection) }
    }
    /// KeyDowns dropped by `dropsFirstEventAfterFocus`.
    public var droppedEventCount: Int { state.withLock { $0.droppedEvents } }
    /// KeyDowns that changed or could have changed the text.
    public var appliedEventCount: Int { state.withLock { $0.appliedEvents } }
    /// Buffered events not yet read (terminal behaviour).
    public var pendingReadCount: Int { state.withLock { $0.pending.count } }

    /// A synthetic event posted by the worker. `layout` resolves Command+V on non-QWERTY layouts and is
    /// required by `ignoresUnicodePayload`.
    public func apply(_ event: SyntheticKeyEvent, layout: LayoutTable? = nil) {
        guard event.isKeyDown else { return }
        let operation = decode(
            keyCode: event.keyCode, flags: event.flags, unicode: event.unicode, layout: layout,
            preferLayout: behaviour == .ignoresUnicodePayload)
        submit(operation)
    }

    /// A replayed or passed-through physical event. Uses the event's Unicode string like Cocoa does, falling
    /// back to the layout table when the string is empty.
    public func apply(_ record: KeyEventRecord, layout: LayoutTable) {
        guard record.kind == .keyDown else { return }
        let operation = decode(
            keyCode: record.keyCode, flags: record.flags, unicode: record.unicode, layout: layout, preferLayout: false)
        submit(operation)
    }

    /// Mouse click: moves the caret, clears the selection, counts as a focus change.
    public func click(at offset: Int) {
        state.withLock { state in
            let caret = min(max(0, offset), state.text.utf16.count)
            state.selection = TextRange(location: caret, length: 0)
            if behaviour == .dropsFirstEventAfterFocus { state.dropNextKeyDown = true }
        }
    }

    /// New focus with fresh content.
    public func reset(text: String = "") {
        state.withLock { state in
            state = State(
                text: text, selection: TextRange(location: text.utf16.count, length: 0),
                dropNextKeyDown: behaviour == .dropsFirstEventAfterFocus)
        }
    }

    /// Terminal behaviour: applies every buffered event.
    public func flushPendingReads() {
        state.withLock { state in
            let pending = state.pending
            state.pending.removeAll()
            for operation in pending { perform(operation, on: &state) }
        }
    }

    // MARK: AX surface used by FakeFocusedFieldAccess

    public func axSelectedRange() -> TextRange { selection }

    /// At most `maximumAXTextUnits` UTF-16 units (PLT-R343).
    public func axText(in range: TextRange) -> String {
        state.withLock { state in
            let clamped = Self.clamp(range, in: state.text)
            let bounded = TextRange(location: clamped.location, length: min(clamped.length, Self.maximumAXTextUnits))
            return Self.substring(state.text, bounded)
        }
    }

    public func axSetSelectedRange(_ range: TextRange) {
        state.withLock { $0.selection = Self.clamp(range, in: $0.text) }
    }

    /// Replaces the selection like `kAXSelectedTextAttribute` does; no inline completion is offered.
    public func axSetSelectedText(_ text: String) {
        state.withLock { state in Self.replaceSelection(with: text, in: &state) }
    }

    // MARK: Decoding

    private func decode(
        keyCode: KeyCode, flags: UInt64, unicode: InlineUTF16, layout: LayoutTable?, preferLayout: Bool
    ) -> Operation {
        let cgFlags = CGEventFlags(rawValue: flags)
        let shift = cgFlags.contains(.maskShift)
        if cgFlags.contains(.maskCommand) {
            let pasteCode = layout?.keyCode(producing: "v")?.rawValue ?? KeyCodes.ansiV
            return keyCode.rawValue == pasteCode || unicode.string.lowercased() == "v" ? .paste : .ignored
        }
        if cgFlags.contains(.maskControl) { return .ignored }
        switch keyCode.rawValue {
        case KeyCodes.delete: return .backspace
        case KeyCodes.forwardDelete: return .forwardDelete
        case KeyCodes.leftArrow: return .moveLeft(extend: shift)
        case KeyCodes.rightArrow: return .moveRight(extend: shift)
        case KeyCodes.upArrow, KeyCodes.downArrow, KeyCodes.returnKey, KeyCodes.tab, KeyCodes.escape: return .ignored
        default: break
        }
        if !preferLayout, unicode.count > 0 { return .insert(unicode.string) }
        guard let layout else { return .ignored }
        let capsLock = cgFlags.contains(.maskAlphaShift)
        let modifierState: LayoutModifierState =
            switch (shift, capsLock) {
            case (false, false): .none
            case (true, false): .shift
            case (false, true): .capsLock
            case (true, true): .shiftCapsLock
            }
        if case .character(let character) = layout.entry(for: keyCode, state: modifierState) {
            return .insert(String(character))
        }
        return .ignored
    }

    private func submit(_ operation: Operation) {
        state.withLock { state in
            if state.dropNextKeyDown {
                state.dropNextKeyDown = false
                state.droppedEvents += 1
                return
            }
            if case .terminalReadsInBatches(let maximum) = behaviour {
                state.pending.append(operation)
                if state.pending.count >= max(1, maximum) {
                    let pending = state.pending
                    state.pending.removeAll()
                    for queued in pending { perform(queued, on: &state) }
                }
                return
            }
            perform(operation, on: &state)
        }
    }

    // MARK: Editing

    private func perform(_ operation: Operation, on state: inout State) {
        switch operation {
        case .ignored:
            return
        case .insert(let inserted):
            Self.replaceSelection(with: inserted, in: &state)
            offerCompletion(&state)
        case .paste:
            Self.replaceSelection(with: pasteboardText?() ?? "", in: &state)
        case .backspace:
            if state.selection.length > 0 {
                Self.replaceSelection(with: "", in: &state)
            } else if state.selection.location > 0 {
                let start = Self.previousBoundary(state.text, before: state.selection.location)
                state.selection = TextRange(location: start, length: state.selection.location - start)
                Self.replaceSelection(with: "", in: &state)
            }
        case .forwardDelete:
            if state.selection.length > 0 {
                Self.replaceSelection(with: "", in: &state)
            } else if state.selection.location < state.text.utf16.count {
                let end = Self.nextBoundary(state.text, after: state.selection.location)
                state.selection = TextRange(location: state.selection.location, length: end - state.selection.location)
                Self.replaceSelection(with: "", in: &state)
            }
        case .moveLeft(let extend):
            moveLeft(extend: extend, &state)
        case .moveRight(let extend):
            moveRight(extend: extend, &state)
        }
        state.appliedEvents += 1
    }

    private func moveLeft(extend: Bool, _ state: inout State) {
        let isTerminal = if case .terminalReadsInBatches = behaviour { true } else { false }
        if extend && isTerminal { return }
        let selection = state.selection
        if extend {
            guard selection.location > 0 else { return }
            let start = Self.previousBoundary(state.text, before: selection.location)
            state.selection = TextRange(location: start, length: selection.length + selection.location - start)
        } else if selection.length > 0 {
            state.selection = TextRange(location: selection.location, length: 0)
        } else if selection.location > 0 {
            state.selection = TextRange(
                location: Self.previousBoundary(state.text, before: selection.location), length: 0)
        }
    }

    private func moveRight(extend: Bool, _ state: inout State) {
        let isTerminal = if case .terminalReadsInBatches = behaviour { true } else { false }
        if extend && isTerminal { return }
        let selection = state.selection
        let end = selection.location + selection.length
        if extend {
            guard end < state.text.utf16.count else { return }
            let newEnd = Self.nextBoundary(state.text, after: end)
            state.selection = TextRange(location: selection.location, length: newEnd - selection.location)
        } else if selection.length > 0 {
            state.selection = TextRange(location: end, length: 0)
        } else if end < state.text.utf16.count {
            state.selection = TextRange(location: Self.nextBoundary(state.text, after: end), length: 0)
        }
    }

    private func offerCompletion(_ state: inout State) {
        guard case .inlineCompletion(let suggestions) = behaviour, !state.text.isEmpty,
            state.selection.length == 0, state.selection.location == state.text.utf16.count,
            let match = suggestions.first(where: { $0.hasPrefix(state.text) && $0.count > state.text.count })
        else { return }
        let remainder = String(match.dropFirst(state.text.count))
        let location = state.text.utf16.count
        state.text += remainder
        state.selection = TextRange(location: location, length: remainder.utf16.count)
    }

    // MARK: UTF-16 helpers (fake only: texts in tests are well-formed)

    private static func clamp(_ range: TextRange, in text: String) -> TextRange {
        let count = text.utf16.count
        let location = min(max(0, range.location), count)
        return TextRange(location: location, length: min(max(0, range.length), count - location))
    }

    private static func index(_ text: String, _ offset: Int) -> String.Index {
        String.Index(utf16Offset: min(max(0, offset), text.utf16.count), in: text)
    }

    private static func substring(_ text: String, _ range: TextRange) -> String {
        let clamped = clamp(range, in: text)
        return String(text[index(text, clamped.location)..<index(text, clamped.location + clamped.length)])
    }

    private static func replaceSelection(with inserted: String, in state: inout State) {
        let clamped = clamp(state.selection, in: state.text)
        let range = index(state.text, clamped.location)..<index(state.text, clamped.location + clamped.length)
        state.text.replaceSubrange(range, with: inserted)
        state.selection = TextRange(location: clamped.location + inserted.utf16.count, length: 0)
    }

    /// UTF-16 offset of the grapheme boundary before `offset`.
    private static func previousBoundary(_ text: String, before offset: Int) -> Int {
        let position = index(text, offset)
        guard position > text.startIndex else { return 0 }
        return text.index(before: position).utf16Offset(in: text)
    }

    /// UTF-16 offset of the grapheme boundary after `offset`.
    private static func nextBoundary(_ text: String, after offset: Int) -> Int {
        let position = index(text, offset)
        guard position < text.endIndex else { return text.utf16.count }
        return text.index(after: position).utf16Offset(in: text)
    }
}
