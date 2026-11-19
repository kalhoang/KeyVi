// SPDX-License-Identifier: MPL-2.0
//
// ENG-R850 as amended on 15/11/2026 (REG-35) with the bundled data. The product owner wrote a Vietnamese message
// to a command-line assistant in iTerm2 (compat rule `terminal.default`, so the code context): the keys
// `Suwar looxi chinhs tar"` committed `Sửa lỗi chính tar"`, twice in a row, because rule L9 restored the
// code-only word `tar` whatever the words around it. L9 now follows the line: in Vietnamese text a code-only
// word is decided as in the general context, while a shell line keeps its commands as typed. Since the product
// owner's decision of 18/11/2026 (REG-38) this holds for code-only words whose keys are not English (`chown`, `ef`,
// `awk`), for which L9 is evaluated right after L5, before L6 and L7 would keep them.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-R850: rule L9 follows the line, with the bundled data")
struct CodeContextRealDataTests {
    static let configurations = [
        EngineConfiguration(appContext: .code, typoCorrection: false),
        EngineConfiguration(appContext: .code, lookaheadRevision: false, typoCorrection: false),
    ]

    /// The field after typing `keys` from an empty field.
    static func field(_ keys: String, _ configuration: EngineConfiguration) throws -> EngineDriver {
        var driver = EngineDriver(configuration: configuration, resources: try RealData.resources())
        try driver.type(keys)
        return driver
    }

    @Test("REG-35: the product owner's terminal message keeps chính tả, twice in a row")
    func productOwnerMessage() throws {
        for configuration in Self.configurations {
            let message = "Suwar looxi chinhs tar\""
            var driver = try Self.field(message, configuration)
            #expect(driver.field.string == "Sửa lỗi chính tả\"")
            #expect(driver.outputs.last?.decision == .kept(.ambiguityTable))
            try driver.type("\n" + message)
            #expect(driver.field.string == "Sửa lỗi chính tả\"\nSửa lỗi chính tả\"")
            #expect(driver.outputs.last?.decision == .kept(.ambiguityTable))
        }
    }

    @Test(
        "Vietnamese prose in a terminal composes as elsewhere",
        arguments: [
            ("Phaanf moo tar trong PR ", "Phần mô tả trong PR "),
            ("Ngooif laau quas tee car chaan ", "Ngồi lâu quá tê cả chân "),
            ("tay tee quas ", "tay tê quá "),
            ("con chim nayf host hay ", "con chim này hót hay "),
            ("vaawn tar canhr ", "văn tả cảnh "),
            // Punctuation followed by a space is prose, so the no-space join rule does not reach it.
            ("vieejt. tar canhr ", "việt. tả cảnh "),
        ])
    func vietnameseProse(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.field(keys, configuration).field.string == expected, "\(keys)")
        }
    }

    @Test(
        "Shell lines keep their commands as typed",
        arguments: [
            ("tar -xzf a.tgz ", "tar -xzf a.tgz "),
            ("sudo tar -xzf a.tgz ", "sudo tar -xzf a.tgz "),
            ("git log | less ", "git log | less "),
            ("echo \"xin chaof\" | tee log.txt ", "echo \"xin chào\" | tee log.txt "),
            ("ssh -p 22 host ", "ssh -p 22 host "),
            ("connect to the host ", "connect to the host "),
            ("cd ~/a && tar -xzf b ", "cd ~/a && tar -xzf b "),
            // File, directory and user names that are Vietnamese syllables, joined to a code-only word with no
            // space between them, are code joins, not Vietnamese text (ENG-R850 (c)).
            ("cp anh.tar.gz /tmp/ ", "cp anh.tar.gz /tmp/ "),
            ("scp anh.tar.gz host:/tmp ", "scp anh.tar.gz host:/tmp "),
            ("mv anh.tar backup/ ", "mv anh.tar backup/ "),
            ("ssh minh@host ", "ssh minh@host "),
            ("tar czf phim.tar.gz phim/ ", "tar czf phim.tar.gz phim/ "),
            ("cd anh && tar xf a ", "cd anh && tar xf a "),
        ])
    func shellLines(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.field(keys, configuration).field.string == expected, "\(keys)")
        }
    }

    @Test("Known cost (ENG-R850): `;` is prose punctuation, so a name before it reaches the next word")
    func semicolonIsProsePunctuation() throws {
        for configuration in Self.configurations {
            #expect(try Self.field("cd anh; tar xf a ", configuration).field.string == "cd anh; tả xf a ")
        }
    }

    @Test("No code-only word is restored by L9 right after a Vietnamese word; at a line start L9 restores")
    func everyCodeOnlyWord() throws {
        let resources = try RealData.resources()
        var reached: [String] = []
        for word in try RealData.codeOnlyWords() {
            for configuration in Self.configurations {
                var driver = EngineDriver(configuration: configuration, resources: resources)
                try driver.type(word + " ")
                let atStart = driver.outputs.last?.decision
                if atStart == .restored(.codeContext), configuration.lookaheadRevision { reached.append(word) }
                try driver.type("\nvieejt " + word + " ")
                let afterVietnamese = driver.outputs.last?.decision
                #expect(afterVietnamese != .restored(.codeContext), "\(word) after việt")
                if atStart == .restored(.codeContext) {
                    // The word is a collision word: after a Vietnamese word the general context's rules keep it.
                    #expect(afterVietnamese?.restores == false, "\(word) after việt")
                }
            }
        }
        print("[ENG-R850] code-only words that rule L9 reaches with the bundled data (Telex): \(reached)")
        // REG-38 (product owner, 18/11/2026): the code-only words whose keys are not English reach L9 too.
        #expect(reached == ["awk", "chown", "ef", "host", "tar", "tee"])
    }

    @Test(
        "REG-38: a code-only word whose keys are not English follows the line as tar does",
        arguments: [
            ("sudo chown -R minh ", "sudo chown -R minh "), ("ls; chown minh ", "ls; chown minh "),
            ("ps -ef ", "ps -ef "), ("awk -F ", "awk -F "), ("chown\n", "chown\n"), ("tay chown ", "tay chơn "),
            ("vieejt ef ", "việt è "), ("Chown ", "Chơn "), ("chown thuwr ", "chơn thử "), ("dungf awk ", "dùng ăk "),
        ])
    func notEnglishCodeOnlyWords(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.field(keys, configuration).field.string == expected, "\(keys.debugDescription)")
        }
        // The general context never reaches L9: `chown`, `ef` and `awk` keep `chơn`, `è` and `ăk` there.
        #expect(
            try Self.field("sudo chown -R ", EngineConfiguration(typoCorrection: false)).field.string == "sudo chơn -R "
        )
    }

    @Test("REG-38: in VNI no code-only word reaches L9 (plain letters, digit words show no syllable)")
    func vniNeverReachesTheCodeRule() throws {
        let resources = try RealData.resources()
        let vni = EngineConfiguration(inputMethod: .vni, appContext: .code, typoCorrection: false)
        var reached: [String] = []
        for word in try RealData.codeOnlyWords() {
            var driver = EngineDriver(configuration: vni, resources: resources)
            try driver.type(word + " ")
            if driver.outputs.last?.decision == .restored(.codeContext) { reached.append(word) }
        }
        #expect(reached.isEmpty, "\(reached)")
    }
}
