// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-R1005 (product owner, 15/11/2026, REG-33): a re-opened token that a commit rule restored shows its
/// raw keys until the first Backspace after which the composed display of the remaining raw keys equals the
/// text shown; from then on it composes like a token typed afresh with those keys. A token the user
/// restored with the toggle (L1) stays literal (ENG-R701, E02b). Resources: the 13.9 fixtures.
@Suite("Re-opened restored token (ENG-R1005)")
struct ReopenedRestoredTokenTests {
    private let vni = EngineConfiguration(inputMethod: .vni)

    /// The product owner's traces and their siblings: deleting back past the keys that made the word
    /// invalid or English and typing again gives Vietnamese. The first version kept the keys as typed
    /// (`tieesn`, `baasm`, `huuw`).
    @Test(arguments: [
        ("tiesng ⌫⌫⌫⌫⌫eesn", "tiến"), ("tiesng ⌫⌫⌫⌫⌫eesng ", "tiếng "), ("baas ⌫⌫⌫⌫aasm", "bấm"),
        ("baas ⌫⌫⌫⌫aasm ", "bấm "), ("huux ⌫⌫w", "hưu"), ("huux ⌫⌫wx ", "hữu "), ("text ⌫⌫⌫x", "tẽ"),
        ("text ⌫⌫⌫xt ", "text "), ("test ⌫⌫⌫s", "té"), ("test ⌫⌫⌫st ", "test "), ("tricky as ⌫⌫s", "tricky á"),
        ("tricky as ⌫⌫s ", "tricky as "), ("tiesng ⌫⌫⌫⌫eesng ", "tieesng "),
    ])
    func retypingAfterDeletingBackComposes(keys: String, expected: String) throws {
        #expect(try Committing.text(keys) == expected, "\(keys)")
    }

    @Test func vniRetypingComposes() throws {
        #expect(try Committing.text("tie1ng ⌫⌫⌫⌫⌫e61ng", vni) == "tiếng")
        #expect(try Committing.text("ba61 ⌫⌫⌫⌫a61m ", vni) == "bấm ")
    }

    /// The Backspace that ends the restore changes nothing else on screen (ENG-R714): it passes through.
    @Test func theBackspaceThatEndsTheRestoreOnlyDeletes() throws {
        var driver = try Committing.driver("tiesng ⌫⌫⌫⌫")
        #expect(driver.field.string == "tie" && driver.outputs.last?.action == .passThrough)
        #expect(driver.state.active?.showsRawKeys == false)
        try driver.type("e")
        #expect(driver.field.string == "tiê")
    }

    /// Until the remaining keys compose to themselves the token stays restored: keys are appended as typed
    /// and the toggle composes it (ENG-R704). Keys typed before such a Backspace stay as typed.
    @Test(arguments: [
        ("text ⌫", "text"), ("text ⌫⎋", "tẽt"), ("text ⌫s", "texts"), ("text ⌫s ", "tét "), ("boss ⌫⌫", "bos"),
        ("text ⌫⌫", "tex"), ("tiesng ⌫⌫⌫", "ties"),
    ])
    func restoreLastsWhileAKeyStillTransforms(keys: String, expected: String) throws {
        #expect(try Committing.text(keys) == expected, "\(keys)")
    }

    /// At the boundary a re-opened token is decided by 8.1 on its raw keys at that moment, like any token,
    /// also while it still shows them as typed. Known cost: `text`, space, two Backspaces, space gives `tẽ `.
    @Test(arguments: [("tieesngg ⌫⌫ ", "tiếng "), ("boss ⌫⌫ ", "bó "), ("text ⌫⌫ ", "tẽ ")])
    func boundaryDecidesOnTheRawKeys(keys: String, expected: String) throws {
        #expect(try Committing.text(keys) == expected, "\(keys)")
    }

    /// A user restore (L1) stays literal for the rest of the token whatever is deleted; the toggle
    /// composes it again (ENG-R701, E02b, ED028).
    @Test func userRestoreStaysLiteral() throws {
        #expect(try Committing.text("vieejt⎋ ⌫⌫⌫⌫⌫eejt ") == "vieejt ")
        #expect(try Committing.text("vieejt⎋⌫⎋") == "việ")
        let driver = try Committing.driver("vieejt⎋ ⌫⌫⌫⌫")
        #expect(driver.state.active?.showsRawKeys == true)
    }

    /// A literal token kept as typed already recomposes once Backspace removes the key that made it
    /// literal (ENG-R421); ENG-R1005 gives restored tokens the same behaviour.
    @Test func keptLiteralTokenRecomposes() throws {
        #expect(try Committing.text("chuognw ⌫⌫⌫⌫ngw ") == "chương ")
        #expect(try Committing.text("thuowr ⌫⌫") == "thu")
    }

    /// Property: every generated syllable made invalid by one more key (`q`) is restored by L5 at the
    /// space. Re-opened and shortened by Backspace to the first point where the remaining keys compose to
    /// themselves, then completed with the rest of the syllable's keys, it shows exactly what the syllable
    /// typed afresh shows (ENG-R1005, ENG-R601). A sample of the ENG-T02 orders, both methods.
    @Test(arguments: Array(0..<8))
    func retypedSyllableEqualsAFreshOne(shard: Int) throws {
        var checked = 0
        var failures: [String] = []
        var index = 0
        GeneratedCorpus.forEachOrderCase(shard: shard, of: 8) { generated in
            index += 1
            guard generated.style == .traditional, index % 7 == 0 else { return }
            checked += 1
            if let failure = Self.retypeFailure(generated.keys, method: generated.method), failures.count < 20 {
                failures.append(failure)
            }
        }
        #expect(checked > 100)
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    private static func retypeFailure(_ keys: String, method: CorpusMethod) -> String? {
        let configuration = EngineConfiguration(inputMethod: method.inputMethod)
        let resources = Resources.empty
        do {
            var fresh = EngineDriver(configuration: configuration, resources: resources)
            try fresh.type(keys)
            let expected = fresh.field.string
            var driver = EngineDriver(configuration: configuration, resources: resources)
            try driver.type(keys + "q ")
            guard driver.outputs.last?.decision == .restored(.invalid) else { return nil }
            try driver.send(.backspace)  // re-opens the restored token (ENG-R1002)
            var remaining = keys + "q"
            while !remaining.isEmpty {
                try driver.send(.backspace)
                remaining.removeLast()
                if try composesToItself(remaining, configuration) { break }
            }
            guard driver.state.active?.showsRawKeys != true else { return "\(keys): still restored at \(remaining)" }
            try driver.type(String(keys.dropFirst(remaining.count)))
            return driver.field.string == expected ? nil : "\(keys): \(driver.field.string) != \(expected)"
        } catch {
            return "\(keys): \(error)"
        }
    }

    private static func composesToItself(_ keys: String, _ configuration: EngineConfiguration) throws -> Bool {
        var driver = EngineDriver(configuration: configuration)
        try driver.type(keys)
        return driver.field.string == keys
    }
}
