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

/// A macro expansion re-opened from history (ENG-R1104): its raw keys are the span as typed plus any key
/// typed into it since.
package struct MacroTokenKeys: Sendable, Hashable {
    package private(set) var raw: [UInt8]
    /// Keys appended after the expansion; Backspace takes them back first.
    package private(set) var appendedCount = 0

    package init(span: [UInt8]) { raw = span }

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
    /// the toggle can bring the composed form back (ENG-R701, ENG-R704).
    package private(set) var restoredByRule = false
    /// Non-nil for a macro expansion (ENG-R1104); `composition` is then unused.
    package private(set) var macroKeys: MacroTokenKeys?

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
        macroKeys = MacroTokenKeys(span: macroSpan)
    }

    /// This token re-opened from history with `display` on screen (ENG-R1002).
    package func reopened(display: String, restoredByRule: Bool) -> ActiveToken {
        var token = self
        token.display = display
        token.restoredByRule = restoredByRule
        return token
    }

    package var isMacro: Bool { macroKeys != nil }

    /// The token shows its raw keys: restored by the user, or by a commit rule and not kept since.
    package var showsRawKeys: Bool {
        !isMacro && (userChoice == .restored || (userChoice == .none && restoredByRule))
    }

    /// Literal for the rest of the token: literal mode (4.5), restored (ENG-R701) or a macro expansion
    /// (ENG-R1104).
    package var isLiteral: Bool { isMacro || composition.isLiteral || showsRawKeys }

    package var isEmpty: Bool { isMacro ? display.isEmpty : composition.raw.isEmpty }

    package var rawText: String {
        guard let macroKeys else { return composition.rawText }
        return ASCII.string(macroKeys.raw)
    }

    /// The composed form (the display the rules give, whatever the restore flags say).
    package func composedDisplay(style: ToneStyle) -> String { composition.display(style: style) }

    // MARK: - Events

    /// A key of the token (4.3). Literal, restored and macro tokens append the key verbatim
    /// (`passThrough`); composing tokens recompute the display and return the minimal edit (ENG-R610,
    /// ENG-R611).
    package mutating func append(_ key: UInt8, rules: ComposerRules) -> KeyAction {
        if macroKeys != nil {
            macroKeys?.append(key)
            display.unicodeScalars.append(Unicode.Scalar(key))
            return .passThrough
        }
        let appendsVerbatim = showsRawKeys || composition.isLiteral
        composition.append(key, rules: rules)
        if appendsVerbatim {
            display.unicodeScalars.append(Unicode.Scalar(key))
            return .passThrough
        }
        let newDisplay = composition.display(style: rules.toneStyle)
        let action = DisplayEdit.actionForKey(key, from: display, to: newDisplay)
        display = newDisplay
        return action
    }

    /// Backspace inside the token (7.4). A restored token is literal: it loses its last raw key. Long
    /// literal tails shrink in place (no full render). A macro expansion loses its last character
    /// (ENG-R1104), and a key typed into it since the expansion if there is one.
    package mutating func backspace(rules: ComposerRules) -> KeyAction {
        if macroKeys != nil {
            display.removeLast()
            macroKeys?.dropAppendedKey()
            return .passThrough
        }
        if showsRawKeys {
            composition.removeLastKey(rules: rules)
            display.unicodeScalars.removeLast()
            return .passThrough
        }
        if let literalStart = composition.literalStart, composition.raw.count - 1 > literalStart {
            composition.removeLastKey(rules: rules)
            display.unicodeScalars.removeLast()
            return .passThrough
        }
        composition.backspace(rules: rules)
        let newDisplay = composition.display(style: rules.toneStyle)
        let action = DisplayEdit.actionForBackspace(from: display, to: newDisplay)
        display = newDisplay
        return action
    }

    /// The restore toggle (ENG-R701, ENG-R703); the consecutive case (ENG-R702) is handled by the
    /// reducer. Returns nil when neither branch applies, so the key passes through.
    package mutating func toggleRestore(rules: ComposerRules) -> KeyAction? {
        if let macroKeys { return restoreMacroSpan(macroKeys, rules: rules) }
        let raw = rawText
        if display != raw {
            // ENG-R701 first branch, ENG-R705: the raw keys exactly as typed.
            let edit = DisplayEdit.edit(from: display, to: raw)
            display = raw
            userChoice = .restored
            return .edit(edit, thenPassThrough: false)
        }
        guard showsRawKeys else { return nil }
        let composed = composition.display(style: rules.toneStyle)
        guard composed != raw else { return nil }
        // ENG-R701 second branch.
        let edit = DisplayEdit.edit(from: display, to: composed)
        display = composed
        userChoice = .kept
        return .edit(edit, thenPassThrough: false)
    }

    /// ENG-R1104: the toggle on a re-opened expansion brings back the span as typed. The token becomes an
    /// ordinary user-restored token whose raw keys are the span, so it behaves like any restored token
    /// from then on (literal, kept at commit by L1, never expanded again).
    private mutating func restoreMacroSpan(_ keys: MacroTokenKeys, rules: ComposerRules) -> KeyAction? {
        let raw = rawText
        guard display != raw else { return nil }
        let edit = DisplayEdit.graphemeEdit(from: display, to: raw)
        self = ActiveToken(
            composition: Composition(replaying: keys.raw, rules: rules), display: raw, userChoice: .restored,
            restoredByRule: false)
        return .edit(edit, thenPassThrough: false)
    }
}
