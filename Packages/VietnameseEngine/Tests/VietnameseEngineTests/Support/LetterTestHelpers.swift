// SPDX-License-Identifier: MPL-2.0
import VietnameseEngine

/// Lowercase letters of a spelling; fails the calling test through a precondition if a character is
/// not an engine letter (test data is written by hand).
func letters(_ spelling: String) -> [Letter] {
    guard let result = Letter.letters(spelling) else { preconditionFailure("not engine letters: \(spelling)") }
    return result
}

/// Renders lowercase letters with `tone` on the letter chosen by the engine's placement rules.
func placed(_ spelling: String, _ tone: Tone, _ style: ToneStyle = .traditional) -> String {
    let word = letters(spelling)
    let offset = TonePlacement.toneOffset(in: word, style: style)
    var text = ""
    for (index, letter) in word.enumerated() {
        text.unicodeScalars.append(LetterTable.scalar(letter, tone: index == offset ? tone : .level, uppercase: false))
    }
    return text
}
