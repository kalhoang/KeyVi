// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

extension SpecFixtures {
    /// ENG-R1113: the keyboard neighbours of the standard QWERTY layout, copied from the spec's table (letter: its
    /// neighbours in the spec's order). Symmetric and covering the 26 letters, as the bundled table must be
    /// (ENG-R1120, ENG-T56).
    public static let keyboardNeighbours: [Character: String] = [
        "q": "wa", "w": "qeas", "e": "wrsd", "r": "etdf", "t": "ryfg", "y": "tugh", "u": "yihj", "i": "uojk",
        "o": "ipkl", "p": "ol", "a": "qwsz", "s": "weadzx", "d": "ersfxc", "f": "rtdgcv", "g": "tyfhvb",
        "h": "yugjbn", "j": "uihknm", "k": "iojlm", "l": "opk", "z": "asx", "x": "sdzc", "c": "dfxv", "v": "fgcb",
        "b": "ghvn", "n": "hjbm", "m": "jkn",
    ]

    /// The English words the typo correction suites add to the 13.9 lexicon: the words the 13.12 rows correct to
    /// (`android`, `grammar`), the competing fits of the exclusion rows (`their tier thief`, `weird wired`,
    /// `please pleases pleased`), the words the exclusions would reach but for their rule (`pair hand penis chins
    /// hatch` of ENG-R1125, `truing chop group` of the shapes, `bank mess pajamas leeched` of the position rules,
    /// `example local known wren` of the context), and the list words of ENG-R1110 (c) (`ability`, beside `agility`).
    public static let correctionWords: [String] = """
        android grammar which hello server about help their tier thief weird wired pair hand penis chins hatch group \
        truing chop still bank mess pajamas leeched example local known wren please pleases pleased each with \
        receive commit until ability agility oath grade
        """.split(separator: " ").map(String.init)

    /// The correction data of the typo correction suites (ENG-R1120 in miniature): the guard list holds a name and
    /// a place (`biden`, `kbang`), the shapes and the keyings the 13.12 rows name, the spec's neighbours table.
    public static let correctionData = CorrectionData(
        guardList: ApproximateWordSet(exactly: ["biden", "kbang"]), keyboardNeighbours: keyboardNeighbours,
        unmarkedShapes: WordSet(["truong", "chuop", "thach", "gruop", "glong"]),
        vietnameseKeyings: WordSet(["phair", "phis", "hoanf", "chinhs"]))

    /// The 13.9 resources plus the words, lists and correction data of the typo correction suites (section 11A):
    /// `oauth` on the tech-always list and `gradle` on the code-only list (ENG-R1110 (c), S43, S44).
    public static func correctionResources(
        userKeepRaw: [String] = [], userKeepVietnamese: [String] = [], userNeverCorrect: [String] = [],
        macros: MacroTable = .empty, correction: CorrectionData = correctionData
    ) -> Resources {
        var resources = commitResources(
            userKeepRaw: userKeepRaw, userKeepVietnamese: userKeepVietnamese, macros: macros)
        resources.english = WordSet(englishLexicon + correctionWords)
        resources.techAlways = WordSet(techAlways + ["oauth"])
        resources.techCodeOnly = WordSet(techCodeOnly + ["gradle"])
        resources.userNeverCorrect = WordSet(userNeverCorrect)
        resources.correction = correction
        return resources
    }
}
