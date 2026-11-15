// SPDX-License-Identifier: MPL-2.0
//
// ENG-R850 as amended on 15/11/2026 (REG-35) with the bundled data. The product owner wrote a Vietnamese message
// to a command-line assistant in iTerm2 (compat rule `terminal.default`, so the code context): the keys
// `Suwar looxi chinhs tar"` committed `Sửa lỗi chính tar"`, twice in a row, because rule L9 restored the
// code-only word `tar` whatever the words around it. L9 now follows the line: in Vietnamese text a code-only
// word is decided as in the general context, while a shell line keeps its commands as typed.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-R850: rule L9 follows the line, with the bundled data")
struct CodeContextRealDataTests {
    static let configurations = [
        EngineConfiguration(appContext: .code), EngineConfiguration(appContext: .code, lookaheadRevision: false),
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
        ])
    func shellLines(_ keys: String, _ expected: String) throws {
        for configuration in Self.configurations {
            #expect(try Self.field(keys, configuration).field.string == expected, "\(keys)")
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
        #expect(!reached.isEmpty)
    }
}
