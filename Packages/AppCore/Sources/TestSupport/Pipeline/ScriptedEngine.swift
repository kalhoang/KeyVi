// SPDX-License-Identifier: GPL-3.0-or-later
//
// The scripted engine's rules and the engine event log the step and property suites inspect.

public import InputHost
internal import RealtimeSupport
public import VietnameseEngine

/// Tiny Telex-like composer. Rules: `aa` -> `â`; `s` puts an acute accent on the last vowel; `w` turns a final
/// `u` into `ư` or types `ư` alone; `x` marks the token as "English" so a boundary restores the raw keys with
/// `thenPassThrough` (the P0-3 shape); backspace over an accented vowel removes the accent (a consumed
/// backspace); `restoreToggle` types the raw keys back once and passes on the second press (ENG-R701, ENG-R702).
/// A one-word history models ENG-R1002: Backspace over the separators after a committed word re-opens it.
/// Revisions (ENG-R828, PLT-R357), when the variant allows them: a token whose raw keys contain `q`, committed
/// right after a word followed by exactly one space, restores that word's raw keys in the same edit (the
/// engine's minimal edit over the word, the space and the token, then the boundary key, reason `phrase`); a
/// restore toggle right after it undoes the revision (ENG-R829) and reports a strong collision signal; a toggle on
/// the active word reports one too (ENG-R864).
struct ScriptedComposer {
    private struct Word {
        var display: String
        var raw: String
        var english: Bool
        /// Decided by its own commit, not by a revision: the next commit may revise it.
        var revisable = true
    }

    /// The revising commit just made, for the undo.
    private struct Revision {
        var previousOld: String
        var previousNew: String
        var previousRaw: String
        var currentText: String
        var boundary: Character
    }

    private(set) var display = ""
    private var raw = ""
    private var english = false
    private var restored = false
    /// The last committed word and the separators typed after it.
    private var previous: Word?
    private var separatorsAfterPrevious = 0
    /// The separator that committed `previous`.
    private var previousBoundary: Character?
    private var revision: Revision?
    /// `EngineConfiguration.lookaheadRevision` (the variant's flag in these tests).
    let revisions: Bool

    init(revisions: Bool = true) { self.revisions = revisions }

    private static let acute: [Character: Character] = [
        "a": "á", "â": "ấ", "e": "é", "i": "í", "o": "ó", "u": "ú", "y": "ý", "ư": "ứ",
    ]
    private static let plain: [Character: Character] = Dictionary(uniqueKeysWithValues: acute.map { ($1, $0) })
    private static let separators: Set<Character> = [" ", ",", ".", ";", ":", "!", "?", "\n", "\t"]

    mutating func handle(_ event: EngineEvent) -> EngineOutput {
        let wasRestored = restored
        restored = false
        let revised = revision
        revision = nil
        switch event {
        case .key(let input):
            if Self.separators.contains(input.character) { return commit(input.character) }
            return EngineOutput(action: key(input.character), composingText: display)
        case .backspace: return EngineOutput(action: backspace(), composingText: display)
        case .restoreToggle:
            if let revised, !wasRestored { return undo(revised) }
            return restoreToggle(secondPress: wasRestored)
        case .reset:
            clear()
            previous = nil
            return EngineOutput(action: .passThrough, composingText: display)
        }
    }

    private mutating func key(_ character: Character) -> KeyAction {
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

    private mutating func commit(_ boundary: Character) -> EngineOutput {
        defer { clear() }
        guard !display.isEmpty else {
            if previous != nil { separatorsAfterPrevious += 1 }
            return EngineOutput(action: .passThrough, composingText: "")
        }
        let restores = english && display != raw
        let text = restores ? raw : display
        let decision: CommitDecision = restores ? .restored(.englishRun) : .kept(.notEnglish)
        if let revisedOutput = revise(currentText: text, boundary: boundary, decision: decision) {
            return revisedOutput
        }
        previous = Word(display: text, raw: raw, english: english)
        separatorsAfterPrevious = 1
        previousBoundary = boundary
        guard restores else { return EngineOutput(action: .passThrough, composingText: "", decision: decision) }
        let edit = TextEdit(deleteCount: display.count, deleteUTF16Count: display.utf16.count, insert: raw)
        return EngineOutput(action: .edit(edit, thenPassThrough: true), composingText: "", decision: decision)
    }

    /// ENG-R828 shape: one minimal edit from `previous + " " + display` to `raw(previous) + " " + text`.
    private mutating func revise(currentText text: String, boundary: Character, decision: CommitDecision)
        -> EngineOutput?
    {
        guard revisions, raw.contains("q"), let word = previous, word.revisable, word.display != word.raw,
            separatorsAfterPrevious == 1, previousBoundary == " "
        else { return nil }
        let edit = Self.minimalEdit(from: word.display + " " + display, to: word.raw + " " + text)
        revision = Revision(
            previousOld: word.display, previousNew: word.raw, previousRaw: word.raw, currentText: text,
            boundary: boundary)
        previous = Word(display: text, raw: raw, english: english)
        separatorsAfterPrevious = 1
        previousBoundary = boundary
        return EngineOutput(
            action: .edit(edit, thenPassThrough: true), composingText: "", decision: decision, revision: .phrase)
    }

    /// ENG-R829: the toggle right after a revising commit puts the previous word back; t+1, the space and the
    /// boundary character stay; one strong signal for the side the word showed first.
    private mutating func undo(_ revised: Revision) -> EngineOutput {
        let tail = " " + revised.currentText + String(revised.boundary)
        let edit = Self.minimalEdit(from: revised.previousNew + tail, to: revised.previousOld + tail)
        restored = true
        previous?.revisable = false  // ENG-R828: no revision after a toggle between two commits
        let signal = CollisionSignal(
            word: revised.previousRaw.lowercased(), context: .afterNeutral, side: .vietnamese, strength: .strong)
        return EngineOutput(
            action: .edit(edit, thenPassThrough: false), composingText: display, collisionSignals: [signal])
    }

    /// The common prefix by character is kept (ENG-R611).
    private static func minimalEdit(from old: String, to new: String) -> TextEdit {
        let common = zip(old, new).prefix { $0 == $1 }.count
        let deleted = old.dropFirst(common)
        return TextEdit(
            deleteCount: deleted.count, deleteUTF16Count: deleted.utf16.count, insert: String(new.dropFirst(common)))
    }

    private mutating func backspace() -> KeyAction {
        guard let last = display.last else {
            reopenPreviousIfReached()
            return .passThrough
        }
        if let base = Self.plain[last] { return replaceTail(count: 1, with: String(base)) }
        display.removeLast()
        if !raw.isEmpty { raw.removeLast() }
        return .passThrough
    }

    /// ENG-R1002: the Backspace removed a separator; removing the last one re-opens the committed word.
    private mutating func reopenPreviousIfReached() {
        guard let word = previous, separatorsAfterPrevious > 0 else { return }
        separatorsAfterPrevious -= 1
        guard separatorsAfterPrevious == 0 else { return }
        display = word.display
        raw = word.raw
        english = word.english
        previous = nil
    }

    private mutating func restoreToggle(secondPress: Bool) -> EngineOutput {
        guard !secondPress, !display.isEmpty, display != raw else {
            return EngineOutput(action: .passThrough, composingText: display)
        }
        let edit = TextEdit(deleteCount: display.count, deleteUTF16Count: display.utf16.count, insert: raw)
        let signal = CollisionSignal(word: raw.lowercased(), context: .afterNeutral, side: .english, strength: .strong)
        display = raw
        restored = true
        previous?.revisable = false  // ENG-R828: no revision after a toggle between two commits
        return EngineOutput(
            action: .edit(edit, thenPassThrough: false), composingText: display, collisionSignals: [signal])
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
