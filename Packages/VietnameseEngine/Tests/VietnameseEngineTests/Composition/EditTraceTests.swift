// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// The edit traces of spec 6.2 (ENG-R610, ENG-R611), exactly, plus relocation (5.4, ENG-R520) and
/// Backspace actions (ENG-R712).
@Suite("Edit traces (6.2)")
struct EditTraceTests {
    enum Step: Equatable, CustomStringConvertible {
        case pass
        case edit(Int, String)

        var description: String {
            switch self {
            case .pass: return "passThrough"
            case .edit(let count, let insert): return "edit(delete \(count), insert \(insert))"
            }
        }
    }

    private func trace(_ keys: String, _ configuration: EngineConfiguration = EngineConfiguration()) throws -> [Step] {
        var driver = EngineDriver(configuration: configuration)
        try driver.type(keys)
        return driver.outputs.map { output in
            switch output.action {
            case .passThrough: return .pass
            case .edit(let edit, let thenPassThrough):
                #expect(!thenPassThrough)
                #expect(edit.deleteCount == edit.deleteUTF16Count)  // ENG-R631
                return .edit(edit.deleteCount, edit.insert)
            }
        }
    }

    @Test func vieejt() throws {
        #expect(try trace("vieejt") == [.pass, .pass, .pass, .edit(1, "ê"), .edit(1, "ệ"), .pass])
    }

    @Test func hoafn() throws {
        #expect(try trace("hoafn") == [.pass, .pass, .pass, .edit(2, "òa"), .edit(2, "oàn")])
    }

    @Test func vniDuoc795() throws {
        let vni = EngineConfiguration(inputMethod: .vni)
        #expect(
            try trace("duoc795", vni) == [
                .pass, .pass, .pass, .pass, .edit(3, "ươc"), .edit(4, "đươc"), .edit(2, "ợc"),
            ])
    }

    @Test func relocationIsMinimal() throws {
        // 5.4: g i s -> gí, + u -> giú, + p -> giúp.
        #expect(try trace("gisup") == [.pass, .pass, .edit(1, "í"), .edit(1, "iú"), .pass])
    }

    @Test func swallowedKeyChangesNothingVisible() throws {
        // ENG-R610: `tuwo` shows tương's vowels already; the second `w` only completes the stored horn.
        #expect(try trace("tuwow").last == .edit(0, ""))
    }

    @Test func backspaceActions() throws {
        // ENG-R712: plain deletion passes through; relocation swallows the Backspace and edits. An escape
        // letter goes with the keys it undid, so its Backspace passes through too (ENG-R711, 15/11/2026).
        #expect(try trace("vieejt⌫").last == .pass)
        #expect(try trace("hoafn⌫").last == .edit(3, "òa"))
        #expect(try trace("nhaamff⌫").last == .pass)
        #expect(try trace("ass⌫").last == .pass)
    }

    @Test func literalKeysPassThrough() throws {
        #expect(try trace("mother") == [.pass, .pass, .pass, .pass, .pass, .pass])
        #expect(try trace("text") == [.pass, .pass, .edit(1, "ẽ"), .pass])
    }
}
