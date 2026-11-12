// SPDX-License-Identifier: MPL-2.0

/// Adaptive casing of an expansion to the case of the span as typed (ENG-R1103).
package enum MacroCase {
    /// - Trigger typed in all capitals (at least two letters, all uppercase): the expansion uppercased.
    /// - First letter capital: the first letter of the expansion capitalised.
    /// - Otherwise, with `adaptCase: false`, or when the span has no letters: as stored.
    ///
    /// Reading: a single capital letter (`V` for a trigger `v`) counts as "first letter capital", not as
    /// "all capitals", because a capitalised sentence start is far more likely than a request for an
    /// all-caps expansion. Case mapping is the standard library's, which is locale independent (ENG-R905).
    package static func adapt(_ expansion: String, toTyped typed: [UInt8], adaptCase: Bool) -> String {
        guard adaptCase else { return expansion }
        var letterCount = 0
        var uppercaseCount = 0
        var firstIsUppercase = false
        for byte in typed where ASCII.isLetter(byte) {
            let uppercase = ASCII.isUppercaseLetter(byte)
            if letterCount == 0 { firstIsUppercase = uppercase }
            letterCount += 1
            if uppercase { uppercaseCount += 1 }
        }
        if letterCount >= 2, uppercaseCount == letterCount { return expansion.uppercased() }
        if letterCount >= 1, firstIsUppercase { return capitalisingFirstLetter(expansion) }
        return expansion
    }

    /// The expansion with its first letter uppercased. Leading punctuation and whitespace are skipped
    /// (`(xin chào)` -> `(Xin chào)`); a digit before the first letter leaves the text unchanged
    /// (`1st` stays `1st`).
    package static func capitalisingFirstLetter(_ text: String) -> String {
        var index = text.startIndex
        while index != text.endIndex {
            let character = text[index]
            if character.isNumber { return text }
            if character.isLetter {
                let upper = character.uppercased()
                guard upper != String(character) else { return text }
                return String(text[..<index]) + upper + text[text.index(after: index)...]
            }
            text.formIndex(after: &index)
        }
        return text
    }
}
