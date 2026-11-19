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
}
