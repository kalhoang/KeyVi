// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// A text field that applies the engine's actions the way a host does (ENG-T31): `passThrough`
/// delivers the original key (a character is inserted, Backspace deletes one character, a pass-through
/// restore toggle or reset changes nothing), an edit deletes `deleteCount` characters before the
/// cursor, inserts its text and then delivers the key if `thenPassThrough` is set. The cursor is
/// always at the end.
public struct SimulatedTextField: Sendable, Hashable {
    /// A violation of the output contract (ENG-R630, ENG-R631, ENG-T31).
    public struct Violation: Error, Sendable, Hashable, CustomStringConvertible {
        public let event: EngineEvent
        public let reason: String
        public var description: String { "\(event): \(reason)" }
    }

    public private(set) var text: [Character]

    public init(text: String = "") { self.text = Array(text) }

    public var string: String { String(text) }

    /// Applies one event's output. Throws when the engine asks to delete more characters than the
    /// field holds or when `deleteCount` and `deleteUTF16Count` describe different spans.
    public mutating func apply(_ event: EngineEvent, _ output: EngineOutput) throws {
        switch output.action {
        case .passThrough:
            deliver(event)
        case .edit(let edit, let thenPassThrough):
            guard edit.deleteCount >= 0, edit.deleteCount <= text.count else {
                throw Violation(event: event, reason: "deletes \(edit.deleteCount) of \(text.count) characters")
            }
            let deleted = text.suffix(edit.deleteCount)
            let deletedUTF16 = deleted.reduce(0) { $0 + $1.utf16.count }
            guard deletedUTF16 == edit.deleteUTF16Count else {
                throw Violation(
                    event: event,
                    reason: "deleteUTF16Count \(edit.deleteUTF16Count) but the span has \(deletedUTF16) units")
            }
            text.removeLast(edit.deleteCount)
            text.append(contentsOf: edit.insert)
            if thenPassThrough { deliver(event) }
        }
    }

    private mutating func deliver(_ event: EngineEvent) {
        switch event {
        case .key(let input): text.append(input.character)
        case .backspace: if !text.isEmpty { text.removeLast() }
        case .restoreToggle, .reset: break
        }
    }
}

extension EngineState {
    /// The text the engine believes precedes the cursor: the history entries it still holds (committed
    /// texts and boundary characters, oldest first) followed by the active display (ENG-T31).
    public var viewText: String {
        var text = ""
        for entry in history.entries { text += entry.text }
        return text + activeDisplay
    }
}

/// Runs events through a `Session` and a `SimulatedTextField`, checking after every event that the
/// field ends with the engine's view (history plus active display), that the engine never asks to delete
/// more characters than it produced, and that every edit is well formed (ENG-T31, ENG-T34).
public struct EngineDriver: Sendable {
    public private(set) var session: Session
    public private(set) var field: SimulatedTextField
    public private(set) var outputs: [EngineOutput] = []

    public init(configuration: EngineConfiguration, resources: Resources = .empty) {
        session = Session(engine: Engine(configuration: configuration, resources: resources))
        field = SimulatedTextField()
    }

    public init(engine: Engine) {
        session = Session(engine: engine)
        field = SimulatedTextField()
    }

    public var state: EngineState { session.state }

    /// Sends one event; throws on a contract violation.
    @discardableResult
    public mutating func send(_ event: EngineEvent) throws -> EngineOutput {
        let viewCount = session.state.viewText.count
        let output = session.handle(event)
        outputs.append(output)
        try field.apply(event, output)
        if case .edit(let edit, _) = output.action {
            guard edit.deleteCount <= viewCount else {
                throw SimulatedTextField.Violation(
                    event: event, reason: "deletes \(edit.deleteCount) characters, the engine produced \(viewCount)")
            }
            guard edit.deleteCount == edit.deleteUTF16Count else {
                throw SimulatedTextField.Violation(event: event, reason: "deleteCount != deleteUTF16Count (ENG-R631)")
            }
        }
        guard output.composingText == session.state.activeDisplay else {
            throw SimulatedTextField.Violation(event: event, reason: "composingText differs from the display")
        }
        let view = session.state.viewText
        guard field.text.ends(with: view) else {
            throw SimulatedTextField.Violation(event: event, reason: "field \(field.string) does not end with \(view)")
        }
        return output
    }

    /// Sends every event in order.
    public mutating func send(_ events: [EngineEvent]) throws {
        for event in events { try send(event) }
    }

    /// Types each character of `keys` as a key event (`⌫` is Backspace).
    public mutating func type(_ keys: String) throws {
        try send(SpecExamples.events(typing: keys))
    }
}

extension Array where Element == Character {
    fileprivate func ends(with suffix: String) -> Bool {
        let tail = Array(suffix)
        return tail.count <= count && self[(count - tail.count)...].elementsEqual(tail)
    }
}
