// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The scripted engine's rules and the engine event log the step and property suites inspect.

public import InputHost
internal import Synchronization
public import VietnameseEngine

/// Tiny Telex-like composer. Rules: `aa` -> `â`; `s` puts an acute accent on the last vowel; `w` turns a final
/// `u` into `ư` or types `ư` alone; `x` marks the token as "English" so a boundary restores the raw keys with
/// `thenPassThrough` (the P0-3 shape); backspace over an accented vowel removes the accent (a consumed
/// backspace); `restoreToggle` types the raw keys back once and passes on the second press (ENG-R701, ENG-R702).
struct ScriptedComposer {
    private(set) var display = ""
    private var raw = ""
    private var english = false
    private var restored = false

    private static let acute: [Character: Character] = [
        "a": "á", "â": "ấ", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "ư": "ứ",
    ]
    private static let plain: [Character: Character] = Dictionary(uniqueKeysWithValues: acute.map { ($1, $0) })
    private static let separators: Set<Character> = [" ", ",", ".", ";", ":", "!", "?", "\n", "\t"]

    mutating func handle(_ event: EngineEvent) -> EngineOutput {
        let wasRestored = restored
        restored = false
        let action: KeyAction
        switch event {
        case .key(let input): action = key(input.character)
        case .backspace: action = backspace()
        case .restoreToggle: action = restoreToggle(secondPress: wasRestored)
        case .reset:
            clear()
            action = .passThrough
        }
        return EngineOutput(action: action, composingText: display)
    }

    private mutating func key(_ character: Character) -> KeyAction {
        if Self.separators.contains(character) { return commit() }
        raw.append(character)
        if character == "a", display.last == "a" { return replaceTail(count: 1, with: "â") }
        if character == "w" {
            if display.last == "u" { return replaceTail(count: 1, with: "ư") }
            display.append("ư")
            return Self.edit(delete: "", insert: "ư")
        }
        if character == "s", let index = display.lastIndex(where: { Self.acute[$0] != nil }) {
            let tail = String(display[index...])
            let accented = String(Self.acute[display[index]]!) + tail.dropFirst()
            display.replaceSubrange(index..., with: accented)
            return Self.edit(delete: tail, insert: accented)
        }
        if character == "x" { english = true }
        display.append(character)
        return .passThrough
    }

    private mutating func commit() -> KeyAction {
        defer { clear() }
        guard english, display != raw, !display.isEmpty else { return .passThrough }
        let edit = TextEdit(deleteCount: display.count, deleteUTF16Count: display.utf16.count, insert: raw)
        return .edit(edit, thenPassThrough: true)
    }

    private mutating func backspace() -> KeyAction {
        guard let last = display.last else { return .passThrough }
        if let base = Self.plain[last] { return replaceTail(count: 1, with: String(base)) }
        display.removeLast()
        if !raw.isEmpty { raw.removeLast() }
        return .passThrough
    }

    private mutating func restoreToggle(secondPress: Bool) -> KeyAction {
        guard !secondPress, !display.isEmpty, display != raw else { return .passThrough }
        let edit = TextEdit(deleteCount: display.count, deleteUTF16Count: display.utf16.count, insert: raw)
        display = raw
        restored = true
        return .edit(edit, thenPassThrough: false)
    }

    private mutating func replaceTail(count: Int, with text: String) -> KeyAction {
        let removed = String(display.suffix(count))
        display.removeLast(count)
        display.append(text)
        return Self.edit(delete: removed, insert: text)
    }

    private mutating func clear() {
        display = ""
        raw = ""
        english = false
    }

    private static func edit(delete removed: String, insert: String) -> KeyAction {
        .edit(
            TextEdit(deleteCount: removed.count, deleteUTF16Count: removed.utf16.count, insert: insert),
            thenPassThrough: false)
    }
}

/// Everything the scripted engines of one factory saw, in order, plus the PLT-R210 reset check: after `mark()`
/// (a host transition), the first feed must follow a reset or a fresh engine unless the engine was clean.
public final class EngineEventLog: Sendable {
    public enum Entry: Sendable, Hashable {
        case made(EngineVariant)
        case event(EngineEvent)
    }

    private struct State {
        var entries: [Entry] = []
        var feedsSinceReset = 0
        var markPending = false
        var dirtyAtMark = false
        var violations = 0
    }

    private let state = Mutex(State())
    /// Keep the full entry list (step tests); the property suite only needs the counters.
    private let keepsEntries: Bool

    public init(keepsEntries: Bool = true) { self.keepsEntries = keepsEntries }

    public var entries: [Entry] { state.withLock { $0.entries } }
    public var events: [EngineEvent] {
        entries.compactMap {
            if case .event(let event) = $0 { return event }
            return nil
        }
    }
    /// Feeds (key, backspace, restore) that reached an engine without a reset after a marked transition.
    public var resetViolations: Int { state.withLock { $0.violations } }

    /// A host transition happened (PLT-R210): the composition must be fresh before the next feed.
    public func mark() {
        state.withLock {
            $0.markPending = true
            $0.dirtyAtMark = $0.feedsSinceReset > 0
        }
    }

    public func clear() { state.withLock { $0.entries.removeAll() } }

    func made(_ variant: EngineVariant) { record(.made(variant), isReset: true, isFeed: false) }

    func handled(_ event: EngineEvent) {
        if case .reset = event {
            record(.event(event), isReset: true, isFeed: false)
        } else {
            record(.event(event), isReset: false, isFeed: true)
        }
    }

    private func record(_ entry: Entry, isReset: Bool, isFeed: Bool) {
        let keep = keepsEntries
        state.withLock { state in
            if keep { state.entries.append(entry) }
            if isReset {
                state.feedsSinceReset = 0
                state.markPending = false
            }
            if isFeed {
                if state.markPending && state.dirtyAtMark { state.violations += 1 }
                state.markPending = false
                state.feedsSinceReset += 1
            }
        }
    }
}
