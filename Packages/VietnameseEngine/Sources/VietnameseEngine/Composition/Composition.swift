// SPDX-License-Identifier: MPL-2.0

/// The composition of one token: the raw keys exactly as typed (ENG-R602) and the state derived from
/// them by the rules of section 4.
///
/// ENG-R601: the derived state is a fold of `append` over the raw keys, so it is a pure function of
/// (raw keys, configuration). Appending a key applies one more step of the same fold; every other
/// change (Backspace, ENG-R710) rebuilds the state by replaying the remaining keys
/// (`init(replaying:rules:)`). The only shortcut, dropping the last key of a literal tail, gives the
/// state that replay gives by construction; `CompositionPropertyTests` checks the equality on random
/// event streams after every event (ENG-T33).
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
    package internal(set) var camelCase = CamelCaseTracker()

    package init() {}

    /// Replays `keys` from an empty token (ENG-R601).
    package init<S: Sequence>(replaying keys: S, rules: ComposerRules) where S.Element == UInt8 {
        for key in keys { append(key, rules: rules) }
    }

    package var isLiteral: Bool { literalStart != nil }

    /// ENG-R904: the raw keys are camel case (input to rule L3b).
    package var isCamelCase: Bool { camelCase.isCamelCase }

    // MARK: - One key (4.3)

    /// Applies one key by the order of interpretation of 4.3.
    package mutating func append(_ key: UInt8, rules: ComposerRules) {
        let index = raw.count
        raw.append(key)
        // Step 1: literal mode appends verbatim.
        if literalStart != nil {
            camelCase.observeLiteral(key, at: index)
            return
        }
        // ENG-R641: bound the replay cost; restore stays exact because `raw` keeps every key.
        guard index < Self.composingKeyLimit else {
            enterLiteral(at: index)
            return
        }
        // Step 2: the key's transform role, unless its kind was escaped (ENG-R441).
        let role = rules.role(of: key)
        if let kind = role.escapeKind, !escapedKinds.contains(kind),
            applyTransform(role, key: key, at: index, rules: rules)
        {
            return
        }
        // Steps 3 and 4: a letter, or a literal character (VNI digit, bracket key).
        appendLetterOrLiteral(key, at: index, flags: [])
    }

    private mutating func applyTransform(_ role: KeyRole, key: UInt8, at index: Int, rules: ComposerRules) -> Bool {
        switch role {
        case .letter: return false
        case .tone(let tone): return applyTone(tone, key: key, at: index)
        case .toneRemoval: return removeTone(at: index)
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
    mutating func appendLetterOrLiteral(_ key: UInt8, at index: Int, flags: ComposedLetter.Flags) {
        guard let letter = Letter(ascii: key),
            appendProduced(letter, uppercase: ASCII.isUppercaseLetter(key), flags: flags, at: index)
        else {
            enterLiteral(at: index)
            return
        }
    }

    /// Appends a letter produced by key `index` if ENG-R904 and viability (3.14) allow it. `uppercase`
    /// is nil for a letter whose key has no case (bracket keys); such letters do not take part in the
    /// camel-case pattern. Returns false, with the letters unchanged, when the letter is rejected.
    mutating func appendProduced(
        _ letter: Letter, uppercase: Bool?, flags: ComposedLetter.Flags, at index: Int
    ) -> Bool {
        if let uppercase, camelCase.completes(uppercase: uppercase) { return false }
        letters.append(ComposedLetter(letter, uppercase: uppercase ?? false, flags: flags, source: index))
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
    /// letter for viability.
    mutating func escape(_ kind: EscapeKinds, key: UInt8, at index: Int) {
        escapedKinds.insert(kind)
        escapeUsed = true
        appendLetterOrLiteral(key, at: index, flags: .escape)
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
