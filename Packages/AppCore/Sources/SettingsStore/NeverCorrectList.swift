// SPDX-License-Identifier: GPL-3.0-or-later
//
// Adding to the never-correct list (03-product.md PRD-R81, spec/01-engine.md ENG-R1118, 1.1.0). The restore key's
// `LearningSignal.neverCorrect` adds its word at once, for every app (one signal is enough: the user undid a change
// they saw); the field in Settings goes through the same rule. The list is user content: never logged.

extension UserSettings {
    /// Adds `raw` to the never-correct list after `NeverCorrectEntry.normalized`. Returns true when the word is on the
    /// list afterwards (added now or already there), false when it was refused (not 1 to 64 ASCII letters).
    @discardableResult
    public mutating func neverCorrect(_ raw: String) -> Bool {
        guard let word = NeverCorrectEntry.normalized(raw) else { return false }
        neverCorrect.insert(word)
        return true
    }
}
