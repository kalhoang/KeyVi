// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-T38 on every key sequence of up to five keys (six over the smallest alphabet) over small alphabets
/// of transform keys, where
/// escapes, tone removals, mark removals (ENG-R411), standalone `w` and bracket letters meet. Each
/// sequence is typed, then Backspace is pressed until the field is empty; every press must delete
/// exactly the last character or match a documented exception of ENG-R714 (`BackspaceProbe`). The
/// corpora of the other Backspace tests are real words, which never reach most of these orders
/// (`wsaw`, `wzow`, `]ous]`, `dwndw`; ENG-R710, ENG-R711).
@Suite("Backspace on every short key sequence (ENG-T38)")
struct BackspaceExhaustiveTests {
    struct Space: Sendable, CustomTestStringConvertible {
        let name: String
        let alphabet: [Character]
        let configuration: EngineConfiguration
        var boundary: Character?
        var length = 5

        var testDescription: String { name }
    }

    static let spaces: [Space] = [
        Space(
            name: "Telex escapes", alphabet: ["w", "s", "f", "z", "a", "o", "d", "n", "W", "e"],
            configuration: EngineConfiguration(typoCorrection: false)),
        Space(
            name: "Telex brackets", alphabet: ["]", "[", "s", "z", "a", "o", "u", "w"],
            configuration: EngineConfiguration(
                inputMethod: .telex(TelexOptions(bracketKeys: true)), typoCorrection: false)),
        Space(
            name: "Telex brackets, uppercase", alphabet: ["]", "[", "S", "Z", "A", "O", "U", "W", "d"],
            configuration: EngineConfiguration(
                inputMethod: .telex(TelexOptions(bracketKeys: true)), typoCorrection: false)),
        Space(
            name: "VNI", alphabet: ["1", "2", "0", "6", "7", "8", "9", "a", "o", "u", "d"],
            configuration: EngineConfiguration(inputMethod: .vni, typoCorrection: false)),
        Space(
            name: "Telex re-opened after a space", alphabet: ["w", "s", "z", "a", "o", "d", "e"],
            configuration: EngineConfiguration(typoCorrection: false), boundary: " "),
        // Six keys: a stroke that applied while an escaped `ư` stood, with a tone key that lost its vowel
        // (`dwnsdw`, `d]nsd]`, ENG-R711 fallback 2).
        Space(
            name: "Telex strokes and tones, six keys", alphabet: ["w", "s", "a", "d", "n", "]", "["],
            configuration: EngineConfiguration(
                inputMethod: .telex(TelexOptions(bracketKeys: true)), typoCorrection: false), length: 6),
    ]

    @Test(arguments: spaces)
    func everyPressDeletesTheLastCharacter(_ space: Space) throws {
        let engine = Engine(configuration: space.configuration, resources: .empty)
        var violations: [String] = []
        var layer = [""]
        for _ in 1...space.length {
            layer = layer.flatMap { prefix in space.alphabet.map { prefix + String($0) } }
            for keys in layer {
                for finding in try BackspaceProbe.run(keys: keys, boundary: space.boundary, engine: engine)
                where finding.outcome == .violation || finding.overDeleted {
                    violations.append(finding.description)
                }
            }
        }
        #expect(violations.isEmpty, "\(violations.count) violations, first: \(violations.prefix(10))")
    }
}
