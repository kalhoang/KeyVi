// SPDX-License-Identifier: MPL-2.0
//
// SCAFFOLD STUB: the data track implements loading of the bundled resources (spec/01-engine.md 8.2, 12.2).

public import VietnameseEngine

extension Resources {
    public enum LoadError: Error, Sendable { case missingResource(String), malformedResource(String) }

    public static func bundled(
        userKeepRaw: WordSet, userKeepVietnamese: WordSet, macros: MacroTable = .empty
    ) throws -> Resources {
        Resources(
            english: WordSet([]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
            attestedSyllables: WordSet([]), ambiguity: [:],
            userKeepRaw: userKeepRaw, userKeepVietnamese: userKeepVietnamese, macros: macros)
    }
}
