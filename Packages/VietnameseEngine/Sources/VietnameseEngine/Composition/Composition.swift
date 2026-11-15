// SPDX-License-Identifier: MPL-2.0

/// The composition of one token: the raw keys exactly as typed (ENG-R602) and the state derived from
/// them by the rules of section 4.
///
/// ENG-R601: the derived state is a fold of `append` over the raw keys, so it is a pure function of
/// (raw keys, configuration). The Caps Lock state of the bracket keys (ENG-R906) is part of that input:
/// it is kept next to the raw keys (`capsLockKeys`) because a bracket key's byte has no case. Appending a
/// key applies one more step of the same fold; every other change (Backspace, ENG-R710) rebuilds the
/// state by replaying the remaining keys (`init(replaying:capsLockKeys:droppingIdle:rules:)`). The only shortcut,
/// dropping the last key of a literal tail, gives the state that replay gives by construction;
/// `CompositionPropertyTests` checks the equality on random event streams after every event (ENG-T33).
package struct Composition: Sendable, Hashable {
    /// ENG-R641: once a composing token holds this many raw keys, the next key enters literal mode.
    /// This bounds replay and keeps every composing key index below 64 (`KeySet`).
    package static let composingKeyLimit = 64

    /// The keys of the token exactly as typed: ASCII letters, VNI digits and enabled bracket keys
    /// (`TokenKey`). Growable (ENG-R640).
    package internal(set) var raw: [UInt8] = []
    /// Letters while composing; frozen when literal mode starts (ENG-R420).
    package internal(set) var letters: [ComposedLetter] = []
    package internal(set) var tone: Tone = .level
    /// Every key that set or removed the tone (ENG-R710 removes them with the toned letter).
    package internal(set) var toneSources = KeySet()
    package internal(set) var escapedKinds: EscapeKinds = []
    /// An escape happened in this token (rule L4 of 8.1).
    package internal(set) var escapeUsed = false
    /// Raw index of the key that started literal mode; nil while composing (4.5).
    package internal(set) var literalStart: Int?
    /// Set when the key that started literal mode was appended by an escape (4.7, ENG-R442: `ass`,
    /// `ww`): the raw indices of the earlier keys whose effect it undid, which Backspace removes with it
    /// (ENG-R711). Nil otherwise.
    package internal(set) var literalEscapeUndone: KeySet?
    /// ENG-R411: raw indices of the tone-removal keys (Telex `z`, VNI `0`) that removed letter marks
    /// rather than a tone.
    package internal(set) var markRemovalSources = KeySet()
    package internal(set) var camelCase = CamelCaseTracker()
    /// ENG-R906: raw indices of the bracket keys typed with Caps Lock on while composing. Literal keys
    /// never become letters, so they are not recorded.
    package internal(set) var capsLockKeys = KeySet()

    package init() {}

    /// Replays `keys` from an empty token (ENG-R601); `capsLockKeys` holds the offsets in `keys` of the
    /// keys typed with Caps Lock on (ENG-R906).
    ///
    /// Backspace uses the two other sets (ENG-R710, ENG-R711) for keys that acted as transforms where they
    /// were first typed and must not come back as letters:
    /// - `idleTransforms` (mark removals): such a key is left out when, replayed here, it would be
    ///   appended as a letter or a literal character (`aaz` + Backspace is empty).
    /// - `toneChain` (the keys that set or removed the tone): such a key that finds no vowel yet waits for
    ///   the next letter and is tried again, in order, after each letter; it is left out only when no
    ///   later letter takes it. A tone key typed before the vowel that an escape removed then lands on
    ///   the vowel that follows (`wsaw` + Backspace is `á`, ENG-R432) or goes with the deleted letter
    ///   (`WSw` + Backspace is empty). A waiting key moves after the letter that takes it in `raw`, so the
    ///   raw keys still replay to this state.
    package init<S: Sequence>(
        replaying keys: S, capsLockKeys: KeySet = KeySet(), droppingIdle idleTransforms: KeySet = KeySet(),
        deferringTone toneChain: KeySet = KeySet(), rules: ComposerRules
    ) where S.Element == UInt8 {
        var waiting: [UInt8] = []
        for (offset, key) in keys.enumerated() {
            let capsLock = capsLockKeys.contains(offset)
            let isTone = toneChain.contains(offset)
            guard isTone || idleTransforms.contains(offset) else {
                append(key, capsLock: capsLock, rules: rules)
                if !waiting.isEmpty { waiting = appendingWaiting(waiting, rules: rules) }
                continue
            }
            if !appendIfTransform(key, capsLock: capsLock, rules: rules), isTone { waiting.append(key) }
        }
    }

    /// Appends `key` only when it acts as a transform (ENG-R710); returns whether it did.
    private mutating func appendIfTransform(_ key: UInt8, capsLock: Bool = false, rules: ComposerRules) -> Bool {
        var trial = self
        guard trial.append(key, capsLock: capsLock, rules: rules) else { return false }
        self = trial
        return true
    }

    /// Tries the waiting tone keys again in order and returns those that still find no vowel.
    private mutating func appendingWaiting(_ waiting: [UInt8], rules: ComposerRules) -> [UInt8] {
        waiting.filter { !appendIfTransform($0, rules: rules) }
    }

    package var isLiteral: Bool { literalStart != nil }

    /// ENG-R904: the raw keys are camel case (input to rule L3b).
    package var isCamelCase: Bool { camelCase.isCamelCase }

    // MARK: - One key (4.3)

    /// Applies one key by the order of interpretation of 4.3. `capsLock` is the key's Caps Lock state,
    /// which only bracket keys use (ENG-R906). Returns true when the key acted by its transform role
    /// (step 2, an escape included) and false when it was appended as a letter or a literal character.
    @discardableResult
    package mutating func append(_ key: UInt8, capsLock: Bool = false, rules: ComposerRules) -> Bool {
        let index = raw.count
        raw.append(key)
        // Step 1: literal mode appends verbatim.
        if literalStart != nil {
            camelCase.observeLiteral(key, at: index)
            return false
        }
        // ENG-R641: bound the replay cost; restore stays exact because `raw` keeps every key.
        guard index < Self.composingKeyLimit else {
            enterLiteral(at: index)
            return false
        }
        if capsLock, ASCII.isBracket(key) { capsLockKeys.formUnion(KeySet(index: index)) }
        // Step 2: the key's transform role, unless its kind was escaped (ENG-R441).
        let role = rules.role(of: key)
        if let kind = role.escapeKind, !escapedKinds.contains(kind),
            applyTransform(role, key: key, at: index, rules: rules)
        {
            return true
        }
        // Steps 3 and 4: a letter, or a literal character (VNI digit, bracket key).
        appendLetterOrLiteral(key, at: index, flags: [])
        return false
    }

    private mutating func applyTransform(_ role: KeyRole, key: UInt8, at index: Int, rules: ComposerRules) -> Bool {
        switch role {
        case .letter: return false
        case .tone(let tone): return applyTone(tone, key: key, at: index)
        case .toneRemoval: return removeToneOrMarks(at: index)
        case .circumflex(let base): return applyCircumflex(base, key: key, at: index)
        case .hornOrBreve(let scope):
            return applyHornOrBreve(scope, standalone: rules.standaloneW, key: key, at: index)
        case .stroke: return applyStroke(key: key, at: index)
        case .bracket(let letter): return applyBracket(letter, key: key, at: index)
        }
    }

    // MARK: - Letters, literal mode, escapes

    /// 4.3 steps 3 and 4: append the key as a letter; enter literal mode if it is not a letter, if it
    /// completes a camel-case pattern (ENG-R904) or if the letters stop being viable (ENG-R420).
    /// `undoing` is set for the key of an escape: the keys whose effect it undid (ENG-R711).
    mutating func appendLetterOrLiteral(
        _ key: UInt8, at index: Int, flags: ComposedLetter.Flags, undoing: KeySet? = nil
    ) {
        guard let letter = Letter(ascii: key),
            appendProduced(
                letter, uppercase: ASCII.isUppercaseLetter(key), flags: flags, at: index,
                undoing: undoing ?? KeySet())
        else {
            enterLiteral(at: index)
            literalEscapeUndone = undoing
            return
        }
    }

    /// Appends a letter produced by key `index` if ENG-R904 and viability (3.14) allow it. `uppercase`
    /// is nil for a letter whose key has no case (bracket keys); such letters do not take part in the
    /// camel-case pattern. Returns false, with the letters unchanged, when the letter is rejected.
    mutating func appendProduced(
        _ letter: Letter, uppercase: Bool?, flags: ComposedLetter.Flags, at index: Int, undoing: KeySet = KeySet()
    ) -> Bool {
        if let uppercase, camelCase.completes(uppercase: uppercase) { return false }
        letters.append(
            ComposedLetter(letter, uppercase: uppercase ?? false, flags: flags, source: index, undoneKeys: undoing))
        guard isViable else {
            letters.removeLast()
            return false
        }
        if let uppercase { camelCase.observe(uppercase: uppercase, at: index) }
        return true
    }

    /// ENG-R420: freezes the display; the key `index` and every later key are appended verbatim.
    mutating func enterLiteral(at index: Int) {
        literalStart = index
        camelCase.observeLiteral(raw[index], at: index)
    }

    /// 4.7: the effect was removed by the caller; mark the kind (sticky, ENG-R441) and append the key
    /// as a letter (Telex) or literal character (VNI). ENG-R442: the escaped letter is an ordinary
    /// letter for viability. `undoing` holds the earlier keys whose effect the escape removed; Backspace
    /// on the escape letter removes them with it (ENG-R711).
    mutating func escape(_ kind: EscapeKinds, key: UInt8, at index: Int, undoing: KeySet) {
        escapedKinds.insert(kind)
        escapeUsed = true
        appendLetterOrLiteral(key, at: index, flags: .escape, undoing: undoing)
    }

    // MARK: - Orthography of the current letters

    /// The parse (3.13) of the current letters.
    @inline(__always)
    var parse: SyllableParse { SyllableParser.parse(LetterView(letters)) }

    /// ENG-R345: the current letters, normalised for display (5.5), are a prefix of a Tier B syllable.
    @inline(__always)
    var isViable: Bool {
        let view = LetterView(letters)
        return ViabilityAutomaton.shared.accepts(DisplayLetterView(view, parse: SyllableParser.parse(view)))
    }

    /// Whether a letter carries a vowel mark (breve, circumflex, horn) or the stroke (ENG-R411).
    var hasMarkedLetter: Bool { letters.contains { $0.letter.modifier != .none } }

    /// Offset of the letter that shows the tone (5.1), nil without tone or vowel group.
    package func toneOffset(style: ToneStyle) -> Int? {
        guard tone != .level else { return nil }
        return placementOffset(style: style)
    }

    /// Offset of the letter a tone would be shown on (5.1) whatever the current tone, nil without a
    /// vowel group. After a removal (ENG-R411) the tone is level but its keys still belong to this
    /// letter (ENG-R710).
    package func placementOffset(style: ToneStyle) -> Int? {
        let view = LetterView(letters)
        let parse = SyllableParser.parse(view)
        return TonePlacement.toneOffset(in: DisplayLetterView(view, parse: parse), parse: parse, style: style)
    }

    // MARK: - Mutation helpers

    mutating func setTone(_ newTone: Tone, byKey index: Int?) {
        tone = newTone
        if let index { toneSources.formUnion(KeySet(index: index)) }
    }

    /// Drops the last raw key of a literal tail (the state replay of the shorter keys gives).
    mutating func popLastRawKey() {
        camelCase.forget(raw.count - 1)
        raw.removeLast()
    }
}
