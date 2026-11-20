// SPDX-License-Identifier: MPL-2.0

/// The user's restore-toggle choice for a token (7.2).
package enum UserChoice: UInt8, Sendable, Hashable {
    case none
    /// ENG-R701 first branch: the token shows its raw keys, literal for the rest of the token, and
    /// commit never changes it (rule L1).
    case restored
    /// ENG-R701 second branch: the token shows its composed form and commit keeps it (rule L1).
    case kept
}

/// What a literal token stands for: a macro expansion (ENG-R1104) or a typo correction (ENG-R1115, ENG-R1117).
package enum LiteralKind: Sendable, Hashable {
    case macro
    /// The correction of section 11A and the rule of 8.1 that would have decided the token.
    case corrected(CommitRule)
}

/// The keys of a literal token, a macro expansion (ENG-R1104) or a typo correction (ENG-R1115), re-opened from
/// history: its raw keys are the span as typed plus any key typed into it since.
package struct LiteralTokenKeys: Sendable, Hashable {
    package private(set) var raw: [UInt8]
    /// Keys appended after the expansion or the correction; Backspace takes them back first.
    package private(set) var appendedCount = 0
    package let kind: LiteralKind

    package init(span: [UInt8], kind: LiteralKind) {
        raw = span
        self.kind = kind
    }

    /// The keys as typed before the expansion or the correction, without the keys appended since.
    package var span: ArraySlice<UInt8> { raw.dropLast(appendedCount) }

    mutating func append(_ key: UInt8) {
        raw.append(key)
        appendedCount += 1
    }

    mutating func dropAppendedKey() {
        guard appendedCount > 0 else { return }
        raw.removeLast()
        appendedCount -= 1
    }
}

/// The token being composed: its composition, the cached display and its flags.
package struct ActiveToken: Sendable, Hashable {
    package private(set) var composition = Composition()
    /// What the engine believes is on screen for the token (6.1). Cached so that literal and restored
    /// tokens grow by appending (ENG-R640) and so that `composingText` shares the storage.
    package private(set) var display = ""
    package private(set) var userChoice = UserChoice.none
    /// Set when a token that a commit rule restored is re-opened (section 10): it shows its raw keys and
    /// the toggle can bring the composed form back (ENG-R701, ENG-R704). Cleared by the first Backspace
    /// after which the remaining raw keys compose to the text shown (ENG-R1005).
    package private(set) var restoredByRule = false
    /// Non-nil for a literal token: a macro expansion (ENG-R1104), whose `composition` is then unused, or a typo
    /// correction (ENG-R1117), whose `composition` holds the raw keys (so the macro span of ENG-R1102 reads them).
    package private(set) var literalKeys: LiteralTokenKeys?
    /// Set when the toggle undid a typo correction (ENG-R1117): the token shows its raw keys as the user's choice,
    /// and its next commit reports `kept(userChoice)` (rule L1) whatever rule L0 would say.
    package private(set) var correctionUndone = false
    /// ENG-R804 (REG-40): the raw keys this token shows leave out the key of each w doubling (`R′`,
    /// `Composition.wDoublings`), because the restore of rule L4 put them back so, or the typo correction read them so
    /// (11A): a re-opened token shows `R′` (ENG-R1005) and a correction's keys are `R′` (ENG-R1117). Cleared when the
    /// token stops showing its raw keys or the toggle makes another choice.
    package private(set) var omitsWDoublings = false
    /// Set when the token is re-opened showing the commit spelling `uơ` of an open `ươ` (ENG-R532,
    /// ENG-R1002) instead of its composed display; cleared by the next event, which shows the composed
    /// display again.
    private var showsCommittedSpelling = false
    /// ENG-R861, ENG-R864: the raw keys for which the user's current choice was reported by a signal, so a
    /// later commit of the same choice for the same keys (after Backspace re-opened the token) reports
    /// nothing new; keys edited since make another word, whose choice was never reported. Cleared by the
    /// next toggle, which is a new choice.
    private var signalledRaw: String?
    /// ENG-R864: the side a revision (ENG-R828) gave the token when it was re-opened (true: the raw keys)
    /// and the raw keys it decided, so that a toggle against the revision counts as a correction while the
    /// raw keys are still those; keys edited since make another word.
    private var revision: RevisionSide?

    private struct RevisionSide: Sendable, Hashable {
        let raw: String
        let restored: Bool
    }

    package init() {}

    /// A token rebuilt from history: `display` is what is on screen for it.
    package init(composition: Composition, display: String, userChoice: UserChoice, restoredByRule: Bool) {
        self.composition = composition
        self.display = display
        self.userChoice = userChoice
        self.restoredByRule = restoredByRule
    }

    /// ENG-R1104: the history token of a macro expansion, raw keys = the span as typed, display = the
    /// expansion, literal.
    package init(macroSpan: [UInt8], expansion: String) {
        display = expansion
        literalKeys = LiteralTokenKeys(span: macroSpan, kind: .macro)
    }

    /// ENG-R1115, ENG-R1117: the history token of a typo correction: the raw keys of `token` as typed, display = the
    /// correction, literal, with the rule of 8.1 that would have decided it. With `omittingWDoublings` its keys are the
    /// typed word `R′`, the keys without each w doubling that the restore would have shown (ENG-R804, REG-40); the
    /// composition keeps every key typed.
    package init(correcting token: ActiveToken, correction: String, rule: CommitRule, omittingWDoublings: Bool = false)
    {
        composition = token.composition
        display = correction
        let keys = omittingWDoublings ? token.composition.rawWithoutWDoublings : token.composition.raw
        literalKeys = LiteralTokenKeys(span: keys, kind: .corrected(rule))
        omitsWDoublings = omittingWDoublings
    }

    /// This token re-opened from history with `display` on screen (ENG-R1002); `revisionRestored` is the
    /// side of the revision that last changed it, if any.
    package func reopened(display: String, restoredByRule: Bool, revisionRestored: Bool? = nil) -> ActiveToken {
        var token = self
        token.display = display
        token.restoredByRule = restoredByRule
        token.revision = revisionRestored.map { RevisionSide(raw: rawText, restored: $0) }
        token.showsCommittedSpelling = !token.isLiteral && token.composition.writesOpenHornPairAtCommit
        return token
    }

    /// This token with the user's choice `choice` (the toggle that undoes a revision marks the revised token
    /// as the user's choice, ENG-R829).
    package func choosing(_ choice: UserChoice) -> ActiveToken {
        var token = self
        token.userChoice = choice
        return token
    }

    /// This token as its commit left it (REG-40): showing its raw keys without the key of each w doubling when the
    /// restore wrote `R′` (ENG-R804, ENG-R904, ENG-R1005), otherwise not; every commit sets or clears it, so a
    /// re-opened token always shows the text its last commit wrote (ENG-R701).
    package func omittingWDoublings(_ omits: Bool) -> ActiveToken {
        var token = self
        token.omitsWDoublings = omits
        return token
    }

    /// This token with its current choice reported for its raw keys (ENG-R861, ENG-R864).
    package func reportingChoice() -> ActiveToken {
        var token = self
        token.signalledRaw = rawText
        return token
    }

    /// The user's current choice was already reported for these raw keys (ENG-R861, ENG-R864).
    package var choiceSignalled: Bool { signalledRaw == rawText }

    /// The side the revision gave these raw keys, if a revision changed the token before it was re-opened
    /// (ENG-R864).
    package var revisionRestored: Bool? { revision?.raw == rawText ? revision?.restored : nil }

    package var isMacro: Bool { literalKeys?.kind == .macro }

    /// The rule of a typo correction re-opened from history (ENG-R1117), nil for any other token.
    package var correctedRule: CommitRule? {
        guard case .corrected(let rule)? = literalKeys?.kind else { return nil }
        return rule
    }

    /// The token shows its raw keys: restored by the user, or by a commit rule and not kept since.
    package var showsRawKeys: Bool {
        literalKeys == nil && (userChoice == .restored || (userChoice == .none && restoredByRule))
    }

    /// Literal for the rest of the token: literal mode (4.5), restored (ENG-R701), a macro expansion (ENG-R1104)
    /// or a typo correction (ENG-R1117).
    package var isLiteral: Bool { literalKeys != nil || composition.isLiteral || showsRawKeys }

    package var isEmpty: Bool { literalKeys != nil ? display.isEmpty : composition.raw.isEmpty }

    package var rawText: String {
        guard let literalKeys else { return composition.rawText }
        return ASCII.string(literalKeys.raw)
    }

    /// The raw keys as the token shows them while it shows its raw keys (`showsRawKeys`): without the key of each w
    /// doubling when the restore of rule L4 left them out (ENG-R804, REG-40), otherwise `rawText`.
    package var shownRawText: String {
        guard omitsWDoublings, literalKeys == nil else { return rawText }
        return ASCII.string(composition.rawWithoutWDoublings)
    }

    /// The typed word of a typo correction, lowercased: the keys as typed before the correction, without the keys
    /// appended since (ENG-R1118); nil for any other token.
    package var correctedWord: String? {
        guard let literalKeys, case .corrected = literalKeys.kind else { return nil }
        return ASCII.string(Array(literalKeys.span), lowercasing: true)
    }

    /// The composed form (the display the rules give, whatever the restore flags say).
    package func composedDisplay(style: ToneStyle) -> String { composition.display(style: style) }

    // MARK: - Events

    /// A key of the token (4.3). Literal, restored and macro tokens append the key verbatim
    /// (`passThrough`); composing tokens recompute the display and return the minimal edit (ENG-R610,
    /// ENG-R611). `capsLock` is the key's Caps Lock state (ENG-R906).
    package mutating func append(_ key: UInt8, capsLock: Bool = false, rules: ComposerRules) -> KeyAction {
        showsCommittedSpelling = false
        if literalKeys != nil {
            literalKeys?.append(key)
            if correctedRule != nil { composition.append(key, capsLock: capsLock, rules: rules) }
            display.unicodeScalars.append(Unicode.Scalar(key))
            return .passThrough
        }
        let appendsVerbatim = showsRawKeys || composition.isLiteral
        composition.append(key, capsLock: capsLock, rules: rules)
        if appendsVerbatim {
            display.unicodeScalars.append(Unicode.Scalar(key))
            return .passThrough
        }
        let newDisplay = composition.display(style: rules.toneStyle)
        let action = DisplayEdit.actionForKey(key, from: display, to: newDisplay)
        display = newDisplay
        return action
    }

    /// Backspace inside the token (7.4). A restored token is literal: it loses its last raw key, and a
    /// token a commit rule restored composes again once no remaining key transforms anything
    /// (ENG-R1005). Long literal tails shrink in place (no full render). A macro expansion loses its last
    /// character (ENG-R1104), and a key typed into it since the expansion if there is one.
    package mutating func backspace(rules: ComposerRules) -> KeyAction {
        if let keys = literalKeys {
            display.removeLast()
            literalKeys?.dropAppendedKey()
            if correctedRule != nil, keys.appendedCount > 0 { composition.removeLastKey(rules: rules) }
            return .passThrough
        }
        if showsRawKeys {
            // REG-40: a w doubling the token does not show goes with the character before it.
            while omitsWDoublings, let last = composition.raw.indices.last, composition.wDoublings.contains(last) {
                composition.removeLastKey(rules: rules)
            }
            composition.removeLastKey(rules: rules)
            display.unicodeScalars.removeLast()
            endRuleRestoreIfComposedMatches(rules: rules)
            return .passThrough
        }
        if let literalStart = composition.literalStart, composition.raw.count - 1 > literalStart {
            composition.removeLastKey(rules: rules)
            display.unicodeScalars.removeLast()
            return .passThrough
        }
        composition.backspace(rules: rules, showsCommittedSpelling: showsCommittedSpelling)
        showsCommittedSpelling = false
        let newDisplay = composition.display(style: rules.toneStyle)
        let action = DisplayEdit.actionForBackspace(from: display, to: newDisplay)
        display = newDisplay
        return action
    }

    /// ENG-R1005: the restore of a re-opened token that a commit rule restored ends at the first Backspace
    /// after which the composed display of the remaining raw keys equals the text shown, so the token
    /// composes like one typed afresh with those keys (`tiesng`, space, five Backspaces, `eesn` shows
    /// `tiến`). Nothing changes on screen. A user restore (L1) stays literal (ENG-R701, E02b). While the
    /// composition is literal the flag changes nothing observable, and skipping the render there keeps a
    /// long literal token's Backspace bounded (ENG-R641, ENG-R1232); the check runs again once a
    /// Backspace leaves literal mode.
    private mutating func endRuleRestoreIfComposedMatches(rules: ComposerRules) {
        guard userChoice == .none, restoredByRule, !composition.isLiteral,
            composition.display(style: rules.toneStyle) == display
        else { return }
        restoredByRule = false
        omitsWDoublings = false
    }

    /// The restore toggle (ENG-R701, ENG-R703); the consecutive case (ENG-R702) is handled by the
    /// reducer. Returns nil when neither branch applies, so the key passes through.
    package mutating func toggleRestore(rules: ComposerRules) -> KeyAction? {
        showsCommittedSpelling = false
        signalledRaw = nil
        if let literalKeys { return restoreLiteralSpan(literalKeys, rules: rules) }
        let raw = rawText
        // A token that shows its raw keys without its w doublings shows its raw keys (REG-40): the second branch.
        if display != (showsRawKeys ? shownRawText : raw) {
            // ENG-R701 first branch, ENG-R705: the raw keys exactly as typed.
            let edit = DisplayEdit.edit(from: display, to: raw)
            display = raw
            userChoice = .restored
            omitsWDoublings = false
            return .edit(edit, thenPassThrough: false)
        }
        guard showsRawKeys else { return nil }
        let composed = composition.display(style: rules.toneStyle)
        guard composed != display else { return nil }
        // ENG-R701 second branch.
        let edit = DisplayEdit.edit(from: display, to: composed)
        display = composed
        userChoice = .kept
        omitsWDoublings = false
        return .edit(edit, thenPassThrough: false)
    }

    /// ENG-R1104, ENG-R1117: the toggle on a re-opened expansion or correction brings back the keys as typed. The
    /// token becomes an ordinary user-restored token whose raw keys are those keys, so it behaves like any restored
    /// token from then on (literal, kept at commit by L1, never expanded or corrected again).
    private mutating func restoreLiteralSpan(_ keys: LiteralTokenKeys, rules: ComposerRules) -> KeyAction? {
        let raw = rawText
        guard display != raw else { return nil }
        let edit = DisplayEdit.graphemeEdit(from: display, to: raw)
        self = restored(keys, rules: rules)
        return .edit(edit, thenPassThrough: false)
    }

    /// ENG-R1117: this corrected token as the toggle leaves it once it undid the correction (the history token of
    /// `Engine.undoCorrection`); the token itself for any other token.
    package func undoingCorrection(rules: ComposerRules) -> ActiveToken {
        guard let literalKeys, correctedRule != nil else { return self }
        return restored(literalKeys, rules: rules)
    }

    /// The user-restored token that shows `keys`. A correction whose keys left out the w doublings (REG-40) keeps its
    /// composition, every key typed, so that the toggle composes `C` again; any other token replays `keys`.
    private func restored(_ keys: LiteralTokenKeys, rules: ComposerRules) -> ActiveToken {
        let isCorrection = correctedRule != nil
        let keepsComposition = isCorrection && omitsWDoublings
        var token = ActiveToken(
            composition: keepsComposition ? composition : Composition(replaying: keys.raw, rules: rules),
            display: ASCII.string(keys.raw), userChoice: .restored, restoredByRule: false)
        token.correctionUndone = isCorrection
        token.omitsWDoublings = keepsComposition
        return token
    }
}
