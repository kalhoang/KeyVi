// SPDX-License-Identifier: MPL-2.0
//
// The typo correction of section 11A (1.1.0): one more step at the commit, after the decision of 8.1 and before the
// edit of ENG-R803 is formed. It reads the token alone (its raw keys, its display, its flags, the 8.1 decision, the
// committing key and the character before it) and the resources, and replaces one clearly mistyped English word
// with the only word it can be (ENG-R1110 to ENG-R1116). The two open choices Q10 and Q11 are read from
// `CorrectionPolicy`, never decided here.

/// A correction: the text that replaces the token's display and the 8.1 rule that would have decided the token
/// (ENG-R1115). The text is user content: never logged (ENG-R1121).
package struct Correction: Sendable, Hashable {
    package let text: String
    package let rule: CommitRule

    package init(text: String, rule: CommitRule) {
        self.text = text
        self.rule = rule
    }
}

/// The typo correction for one engine (section 11A). Built only when `typoCorrection` is on, the app context is
/// `general` and auto restore is on (`CommitPolicy.corrector`, ENG-R1119, ENG-R1112, ENG-R802).
package struct TypoCorrector: Sendable {
    let resources: Resources
    let index: CorrectionIndex
    let edits: EditModel

    package init(resources: Resources, configuration: EngineConfiguration) {
        self.resources = resources
        index = resources.correctionIndex
        edits = EditModel(neighbours: resources.correction.keyboardNeighbours)
    }

    /// The correction of a token the decision of 8.1 has decided as `decision`, nil when the token is not a
    /// candidate (ENG-R1110) or not exactly one word fits (ENG-R1114, ENG-R1125). `context.boundary` is the
    /// committing key and `context.characterBefore` the character right before the token.
    package func correction(
        for inputs: CommitInputs, decision: CommitDecision, token: ActiveToken, context: CommitContext
    ) -> Correction? {
        guard let rule = candidateRule(decision, inputs: inputs, token: token),
            let letterCase = Self.letterCase(of: inputs.raw, context: context),
            Self.allowsContext(context), isCandidateWord(inputs, clusterCase: decision == .kept(.extendedSpelling)),
            let fit = onlyFit(inputs.rawLowercased)
        else { return nil }
        return Correction(text: letterCase.apply(to: fit), rule: rule)
    }

    // MARK: ENG-R1110 (b): the decision

    /// The rule of the decision when it leaves the typed word on screen (L0, a restore by any rule but L1 and L2) or
    /// is the cluster case of L6 (`grẩm` kept for the lowercase `gramar`); nil for every other decision and for a
    /// re-opened token that was corrected or restored before (ENG-R1117), a macro expansion and the user's toggle.
    private func candidateRule(_ decision: CommitDecision, inputs: CommitInputs, token: ActiveToken) -> CommitRule? {
        guard !token.isMacro, token.userChoice == .none, !token.restoredByRule else { return nil }
        switch decision {
        case .kept(.unchanged): return .unchanged
        case .restored(let rule) where rule != .userChoice && rule != .userList: return rule
        case .kept(.extendedSpelling) where Self.isClusterCase(inputs): return .extendedSpelling
        default: return nil
        }
    }

    /// ENG-R1110 (b): the onset of `C` is one of the place-name clusters (3.3) and the typed word is all lowercase.
    /// (L6 keeps a token only when its raw keys are not English.)
    private static func isClusterCase(_ inputs: CommitInputs) -> Bool {
        guard inputs.raw.utf8.allSatisfy(ASCII.isLowercaseLetter) else { return false }
        return CorrectionPolicy.clusterOnsets.contains(String(inputs.facts.lowercased.prefix(2)))
    }

    // MARK: ENG-R1110 (c), (d): lists and Vietnamese

    /// The typed word is no word of any list (ENG-R1110 (c)) and not Vietnamese (ENG-R1110 (d); the edits one key
    /// away are checked by `onlyFit`, ENG-R1125).
    private func isCandidateWord(_ inputs: CommitInputs, clusterCase: Bool) -> Bool {
        let word = inputs.rawLowercased
        let listed =
            resources.english.contains(word) || resources.techAlways.contains(word)
            || resources.techCodeOnly.contains(word) || resources.correction.guardList.mayContain(word)
            || resources.userKeepRaw.contains(word) || resources.userKeepVietnamese.contains(word)
            || resources.userNeverCorrect.contains(word) || resources.ambiguity[word] != nil
            || resources.collision.supplement.contains(word)
        guard !listed else { return false }
        // The cluster case is Tier B by definition; any other display that is a syllable is Vietnamese.
        if !clusterCase, inputs.facts.validity != .invalid { return false }
        return !resources.correction.unmarkedShapes.contains(word)
    }

    // MARK: ENG-R1111: letters, length and case

    /// The case of the typed word when it may be corrected (ENG-R1111): ASCII letters only, 5 to 24 of them, no chat
    /// elongation; lowercase anywhere, sentence case at a sentence start only (Q10), any other case never.
    static func letterCase(of raw: String, context: CommitContext) -> LetterCase? {
        var count = 0
        var uppercase = 0
        var firstIsUppercase = false
        var last: UInt8 = 0
        var run = 0
        for byte in raw.utf8 {
            guard ASCII.isLetter(byte) else { return nil }
            if ASCII.isUppercaseLetter(byte) {
                uppercase += 1
                if count == 0 { firstIsUppercase = true }
            }
            let lower = ASCII.lowercased(byte)
            run = lower == last ? run + 1 : 1
            last = lower
            count += 1
            guard count <= CorrectionPolicy.maximumLetters else { return nil }
        }
        guard count >= CorrectionPolicy.minimumLetters, run < 3 else { return nil }
        if uppercase == 0 { return .lowercase }
        guard uppercase == 1, firstIsUppercase, CorrectionPolicy.sentenceStart == .corrected,
            context.memoryContext == .sentenceStart
        else { return nil }
        return .sentenceCase
    }

    /// The case of a typed word that may be corrected; the correction keeps it (ENG-R1111).
    enum LetterCase: Sendable {
        case lowercase
        case sentenceCase

        func apply(to word: String) -> String {
            guard self == .sentenceCase, let first = word.first else { return word }
            return first.uppercased() + word.dropFirst()
        }
    }

    // MARK: ENG-R1112: context

    /// The committing key is whitespace, Return, Tab (as Q11 allows) or an ASCII closer of prose, and the character
    /// before the token is a space, a no-break space or an opener, or nothing (the start of the history: a field, a
    /// line after Return or Tab, a reset).
    static func allowsContext(_ context: CommitContext) -> Bool {
        let key = context.boundary
        let commits: Bool
        switch key {
        case " ": commits = true
        case "\n", "\r", "\r\n", "\t": commits = CorrectionPolicy.commitKeys == .everyCommitKey
        default: commits = CorrectionPolicy.closers.contains(key)
        }
        guard commits else { return false }
        guard let before = context.characterBefore else { return true }
        return CorrectionPolicy.openers.contains(before)
    }

    // MARK: ENG-R1113, ENG-R1114, ENG-R1125: the edit search

    /// The one word of the correction lexicon that fits `word` (ENG-R1114), nil when none or several do, or when one
    /// edit reaches Vietnamese (ENG-R1125). The fits are searched first (the edits of ENG-R1113 with the position
    /// rules, stopping at the second distinct word), then, for a word with exactly one fit, every edit without them
    /// for a Vietnamese keying or shape (stopping at the first); the result is the same in either order, and most
    /// candidates have no fit or several, so the second pass rarely runs. Every edit is checked against the
    /// prefilter before its lookup. Nothing here allocates until the fit is turned into the correction's text
    /// (ENG-R1122).
    private func onlyFit(_ word: String) -> String? {
        let fit = word.utf8.withContiguousStorageIfAvailable { bytes in
            withUnsafeTemporaryAllocation(of: UInt8.self, capacity: EditModel.maximumLength + 1) { first in
                let count = firstOfTheOnlyFit(bytes, into: first)
                guard count > 0, !isWithinOneEditOfVietnamese(bytes) else { return String?.none }
                return String(decoding: UnsafeBufferPointer(rebasing: first[..<count]), as: UTF8.self)
            }
        }
        return fit ?? nil
    }

    /// Writes the one fit of `word` into `first` and returns its length; 0 when no word or several distinct words fit.
    private func firstOfTheOnlyFit(_ word: UnsafeBufferPointer<UInt8>, into first: UnsafeMutableBufferPointer<UInt8>)
        -> Int
    {
        var count = 0
        var several = false
        edits.forEachEdit(of: word, positionRules: true) { edit in
            guard edit.count >= CorrectionPolicy.minimumFitLetters, index.mightHold(edit), index.lexiconContains(edit)
            else { return true }
            if count == 0 {
                _ = first.initialize(from: edit)
                count = edit.count
                return true
            }
            if edit.elementsEqual(UnsafeBufferPointer(rebasing: first[..<count])) { return true }
            several = true
            return false
        }
        return several ? 0 : count
    }

    /// ENG-R1125: one edit of `word`, without the position rules, gives a Vietnamese keying or an unmarked shape.
    private func isWithinOneEditOfVietnamese(_ word: UnsafeBufferPointer<UInt8>) -> Bool {
        var found = false
        edits.forEachEdit(of: word, positionRules: false) { edit in
            found = index.mightHold(edit) && index.isVietnameseKeyingOrShape(edit)
            return !found
        }
        return found
    }
}
