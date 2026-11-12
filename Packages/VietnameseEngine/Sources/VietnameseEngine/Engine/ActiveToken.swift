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

/// The token being composed: its composition, the cached display and its flags.
package struct ActiveToken: Sendable, Hashable {
    package private(set) var composition = Composition()
    /// What the engine believes is on screen for the token (6.1). Cached so that literal and restored
    /// tokens grow by appending (ENG-R640) and so that `composingText` shares the storage.
    package private(set) var display = ""
    package private(set) var userChoice = UserChoice.none
    /// Set by section 10 (E3) when a token that a commit rule restored is re-opened: it shows its raw
    /// keys and the toggle can bring the composed form back (ENG-R701, ENG-R704).
    package private(set) var restoredByRule = false

    package init() {}

    /// A token rebuilt from history (E3): `display` is what is on screen for it.
    package init(composition: Composition, display: String, userChoice: UserChoice, restoredByRule: Bool) {
        self.composition = composition
        self.display = display
        self.userChoice = userChoice
        self.restoredByRule = restoredByRule
    }

    /// The token shows its raw keys: restored by the user, or by a commit rule and not kept since.
    package var showsRawKeys: Bool {
        userChoice == .restored || (userChoice == .none && restoredByRule)
    }

    /// Literal for the rest of the token: literal mode (4.5) or restored (ENG-R701).
    package var isLiteral: Bool { composition.isLiteral || showsRawKeys }

    package var isEmpty: Bool { composition.raw.isEmpty }

    package var rawText: String { composition.rawText }

    /// The composed form (the display the rules give, whatever the restore flags say).
    package func composedDisplay(style: ToneStyle) -> String { composition.display(style: style) }

    // MARK: - Events

    /// A key of the token (4.3). Literal and restored tokens append the key verbatim (`passThrough`);
    /// composing tokens recompute the display and return the minimal edit (ENG-R610, ENG-R611).
    package mutating func append(_ key: UInt8, rules: ComposerRules) -> KeyAction {
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
    /// literal tails shrink in place (no full render).
    package mutating func backspace(rules: ComposerRules) -> KeyAction {
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
}
