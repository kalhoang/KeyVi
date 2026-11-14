// SPDX-License-Identifier: MPL-2.0
//
// ENG-R823 with the bundled data (product owner, 14/11/2026, REG-32): Vietnamese users write Vietnamese
// sentences with English loanwords (`app`, `win`, `tricky`, `server`), and a word that is also English right
// after such a loanword must stay Vietnamese. The run is English only when the window of the previous three
// committed tokens holds an English token and no Vietnamese one; a token kept Vietnamese by rule L11 is
// evidence of neither language.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-R823 English run with the bundled data")
struct EnglishRunRealDataTests {
    /// Checks the field after typing `keys` in Telex with default options, from an empty field.
    static func expect(_ keys: String, gives expected: String, sourceLocation: SourceLocation = #_sourceLocation)
        throws
    {
        var driver = EngineDriver(configuration: EngineConfiguration(), resources: try RealData.resources())
        try driver.type(keys)
        let field = driver.field.string
        #expect(
            field == expected, "\(keys.debugDescription) typed \(field.debugDescription)",
            sourceLocation: sourceLocation)
    }

    @Test("REG-32: the product owner's sentence keeps á after the English word tricky")
    func productOwnerSentence() throws {
        try Self.expect(
            "Khusc caif cacs app caafn thieest treen win cungx tricky as.",
            gives: "Khúc cài các app cần thiết trên win cũng tricky á.")
        try Self.expect("dduwowcj as.", gives: "được á.")
        try Self.expect("as.", gives: "á.")
    }

    @Test("REG-32: collisions after an English loanword in a Vietnamese sentence stay Vietnamese")
    func loanwordsInVietnameseSentences() throws {
        try Self.expect("treen server been kia ", gives: "trên server bên kia ")
        try Self.expect("guwir file car team ", gives: "gửi file cả team ")
    }

    @Test("ENG-R823: English sentences stay English")
    func englishSentences() throws {
        // ENG-R824: the first word is not corrected afterwards (`this` alone keeps `thí`).
        try Self.expect("this is the best car ", gives: "thí is the best car ")
        try Self.expect("I think this is as good as it gets ", gives: "I think this is as good as it gets ")
        // `Thí`, kept by its ambiguity row, is neutral, so `is` then `as` are read in an English run.
        try Self.expect("This is as good ", gives: "Thí is as good ")
        // Only English in the window at the start of a message.
        try Self.expect("tricky as hell ", gives: "tricky as hell ")
    }

    @Test("REG-32: after a loanword in a Vietnamese sentence the whole lexicon commits as in Vietnamese context")
    func lexiconAfterALoanword() throws {
        // The window [`tricky` en, `cũng` vi] is not an English run, so every word of the ENG-T10 list commits
        // exactly as after `việt` (ENG-R872): the `vi` rows keep their Vietnamese display. The known cost of the
        // rule is the same window read the other way: an English word typed within three tokens after a switch
        // from Vietnamese to English (`việt and`) is also committed as in Vietnamese context.
        let words = try RealData.englishCorpusWords()
        let report = EnglishCorpusCheck.run(
            words: words, resources: try RealData.resources(), englishSeed: "cungx tricky")
        print(
            "[ENG-R823] \(words.count) words, \(report.changedInEnglishRun.count) changed after `cũng tricky`, "
                + "\(report.changedInVietnameseContext.count) after `việt`")
        #expect(report.changedInEnglishRun == report.changedInVietnameseContext)
    }
}
