// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// ENG-T38: Backspace only deletes. Types a word, optionally a boundary key, then presses Backspace
/// until the field is empty, and checks every press against the field it started from: the field
/// loses its last character and every other character stays as it was (ENG-R710, ENG-R1003).
///
/// The documented exceptions of ENG-R714 are classified instead of reported: the tone moving to the
/// letter the placement rule now picks (ENG-R501, W240), the `ư` of a standalone `w` or bracket key that
/// the field showed as `u` coming back, a `u` whose horn only completed the pair with a bracket `ơ`
/// losing it with that `ơ`, and a bracket letter following the case of the word (ENG-R906). Every other
/// difference is a violation, also on an escape letter and on the key that started literal mode: since
/// 15/11/2026 Backspace removes an escape letter with the keys it undid (ENG-R711), so both take exactly
/// the last character (the recompute of ENG-R421 gives back the display frozen before that key).
public enum BackspaceProbe {
    /// How one Backspace changed the field.
    public enum Outcome: String, Sendable, Hashable, CaseIterable {
        /// The field lost exactly its last character.
        case deletedOnly
        /// ENG-R501, W240: the letters are the expected ones and the tone moved by the placement rule.
        case toneRelocated
        /// ENG-R103, ENG-R104: the letter before the deleted one is the `ư` of a standalone `w` or a
        /// bracket key, shown as `u` (a circumflex removed its horn, ENG-R533, or a re-opened word shows
        /// the commit spelling `uơ`, ENG-R532); that key is the only key left for it, so it shows `ư`
        /// again (`woo` shows `uô`, Backspace gives `ư`).
        case selfMarkedHorn
        /// ENG-R530: the letter before the deleted `ơ` of a bracket key is a plain `u` that showed a horn
        /// only to complete the pair; it shows as typed again (`u[` shows `ươ`, Backspace gives `u`).
        case hornCompletion
        /// ENG-R906: a bracket letter takes the case of the word, and the deletion changed whether the
        /// word is all caps (`]OU` shows `ƯƠU`, Backspace gives `ưƠ`).
        case bracketCase
        /// Anything else: a letter that was not deleted changed, or more than one character went.
        case violation
    }

    /// One Backspace whose outcome is not `deletedOnly`.
    public struct Finding: Sendable, Hashable, CustomStringConvertible {
        /// What happened.
        public let outcome: Outcome
        /// The keys typed before the Backspace presses (`⌫` marks earlier presses of the same run).
        public let keys: String
        /// The field before the press.
        public let before: String
        /// The field after the press.
        public let after: String
        /// A Backspace-triggered edit asked to delete more than the active token's display (ENG-T38).
        public let overDeleted: Bool

        /// One line for a test report.
        public var description: String {
            "\(outcome.rawValue) \(keys): \(before) -> \(after)\(overDeleted ? " (over-deleted)" : "")"
        }
    }

    /// Types `keys`, then `boundary` if given, then presses Backspace until the field is empty (at most
    /// `keys.count + 2` presses). Every press is classified; the outcomes other than `deletedOnly` are
    /// returned in order. Contract violations of the simulated field (ENG-T31) are thrown.
    public static func run(keys: String, boundary: Character?, engine: Engine) throws -> [Finding] {
        var driver = EngineDriver(engine: engine)
        try driver.type(keys)
        if let boundary { try driver.send(.key(KeyInput(boundary))) }
        var findings: [Finding] = []
        var typed = keys + (boundary.map(String.init) ?? "")
        for _ in 0..<(keys.count + 2) where !driver.field.text.isEmpty {
            let before = driver.field.string
            let token = driver.state.active
            let output = try driver.send(.backspace)
            let after = driver.field.string
            let outcome = classify(before: before, after: after, token: token)
            let overDeleted = deletesMoreThanToken(output, token: token)
            if outcome != .deletedOnly || overDeleted {
                findings.append(
                    Finding(outcome: outcome, keys: typed, before: before, after: after, overDeleted: overDeleted))
            }
            typed += "⌫"
        }
        return findings
    }

    /// ENG-T38 guard: an edit answering a Backspace deletes at most the active token's display. With no
    /// active token the Backspace must pass through (ENG-R1002).
    static func deletesMoreThanToken(_ output: EngineOutput, token: ActiveToken?) -> Bool {
        guard case .edit(let edit, _) = output.action else { return false }
        return edit.deleteCount > (token?.display.count ?? 0)
    }

    /// The outcome of a Backspace that turned the field `before` into `after`, with `token` the active
    /// token before the press. The fuzz checker (ENG-T38) passes the field tails it keeps.
    static func classify(before: String, after: String, token: ActiveToken?) -> Outcome {
        let expected = String(before.dropLast())
        if after == expected { return .deletedOnly }
        guard let token, !token.isMacro, !token.showsRawKeys else { return .violation }
        let composition = token.composition
        guard composition.literalStart == nil else { return .violation }
        let letters = composition.letters
        if isToneRelocation(expected: expected, after: after) { return .toneRelocated }
        if letters.contains(where: { $0.flags.contains(.bracket) }), lowercased(expected) == lowercased(after) {
            return .bracketCase
        }
        guard letters.count >= 2, onlyLastLetterDiffers(expected: expected, after: after) else { return .violation }
        let previous = letters[letters.count - 2]
        let deleted = letters[letters.count - 1]
        let hornComesBack =
            expected.unicodeScalars.last?.properties.lowercaseMapping == "u"
            && after.unicodeScalars.last?.properties.lowercaseMapping == "ư"
        let hornGoes =
            expected.unicodeScalars.last?.properties.lowercaseMapping == "ư"
            && after.unicodeScalars.last?.properties.lowercaseMapping == "u"
        if hornComesBack, previous.flags.contains(.standaloneW) || previous.flags.contains(.bracket) {
            return .selfMarkedHorn
        }
        if hornGoes, previous.letter == .u, deleted.letter == .oHorn, deleted.flags.contains(.bracket) {
            return .hornCompletion
        }
        return .violation
    }

    /// The two texts have the same length and differ only in their last character.
    private static func onlyLastLetterDiffers(expected: String, after: String) -> Bool {
        let left = Array(expected.unicodeScalars)
        let right = Array(after.unicodeScalars)
        return left.count == right.count && !left.isEmpty && left.dropLast() == right.dropLast()
    }

    /// The letters (modifiers and case included) are the expected ones and exactly one tone mark moved:
    /// the tones differ at two positions, one losing the tone the other gains.
    static func isToneRelocation(expected: String, after: String) -> Bool {
        let expectedGlyphs = glyphs(expected)
        let afterGlyphs = glyphs(after)
        guard expectedGlyphs.count == afterGlyphs.count else { return false }
        var lost: [Tone] = []
        var gained: [Tone] = []
        for (left, right) in zip(expectedGlyphs, afterGlyphs) {
            guard left.base == right.base else { return false }
            guard left.tone != right.tone else { continue }
            if left.tone != .level { lost.append(left.tone) }
            if right.tone != .level { gained.append(right.tone) }
        }
        return lost.count == 1 && lost == gained
    }

    private static func lowercased(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars { result += scalar.properties.lowercaseMapping }
        return result
    }

    private struct ToneSplit: Hashable {
        var base: Unicode.Scalar
        var tone: Tone
    }

    private static func glyphs(_ text: String) -> [ToneSplit] {
        text.unicodeScalars.map { scalar in
            guard let glyph = LetterTable.glyph(for: scalar) else { return ToneSplit(base: scalar, tone: .level) }
            let base = LetterTable.scalar(glyph.letter, tone: .level, uppercase: glyph.isUppercase)
            return ToneSplit(base: base, tone: glyph.tone)
        }
    }
}
