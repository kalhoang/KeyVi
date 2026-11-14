// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-T38: Backspace only deletes (ENG-R710 to ENG-R712, ENG-R1002, ENG-R1003). Every generated
/// syllable (ENG-T02 orders O1 to O4 in Telex and VNI, both tone styles, the ENG-T03 variants) plus the
/// extra orders of `extraOrders` (horn first, horn/circumflex changes of mind, standalone `w`) and a
/// mixed-case spelling of every O1 case is
/// typed, then Backspace is pressed until the field is empty, once before any boundary and once after a
/// space (the first Backspace re-opens the word). Every press must take exactly the last character and
/// leave every other character as it was, except the documented exceptions that `BackspaceProbe`
/// classifies: tone relocation by the placement rule (W240), escapes (ENG-R711) and the literal-mode
/// recompute (ENG-R421). No Backspace edit may delete more than the active token's display.
///
/// Resources are empty, so the commit keeps every valid Vietnamese word (rule L7) and the re-opened
/// word is composed; the English list and the bundled data are covered by `BackspaceRealDataTests` in
/// VietnameseEngineDataTests.
@Suite("Backspace only deletes (ENG-T38)")
struct BackspacePropertyTests {
    static let shardCount = 40
    static let shards = Array(0..<shardCount)

    /// Findings of one shard, grouped by outcome, with a few examples of each violation.
    private struct Tally {
        var runs = 0
        var outcomes: [BackspaceProbe.Outcome: Int] = [:]
        var violations: [String] = []
        var violationCount = 0
        var overDeleted = 0

        mutating func record(_ findings: [BackspaceProbe.Finding], method: CorpusMethod, style: ToneStyle) {
            runs += 1
            for finding in findings {
                outcomes[finding.outcome, default: 0] += 1
                if finding.overDeleted { overDeleted += 1 }
                guard finding.outcome == .violation || finding.overDeleted else { continue }
                violationCount += 1
                if violations.count < 30 { violations.append("\(method) \(style) \(finding)") }
            }
        }

        mutating func record(error: any Error, keys: String) {
            runs += 1
            violationCount += 1
            if violations.count < 30 { violations.append("\(keys): \(error)") }
        }
    }

    /// One engine per (method, style) with default options and no resources.
    private struct Engines {
        private let engines: [EngineConfiguration: Engine]

        init() {
            var engines: [EngineConfiguration: Engine] = [:]
            for method in CorpusMethod.allCases {
                for style in [ToneStyle.traditional, .modern] {
                    let configuration = EngineConfiguration(inputMethod: method.inputMethod, toneStyle: style)
                    engines[configuration] = Engine(configuration: configuration, resources: .empty)
                }
            }
            self.engines = engines
        }

        func engine(_ method: CorpusMethod, _ style: ToneStyle) -> Engine {
            let configuration = EngineConfiguration(inputMethod: method.inputMethod, toneStyle: style)
            return engines[configuration] ?? Engine(configuration: configuration, resources: .empty)
        }
    }

    private static func probe(
        _ keys: String, method: CorpusMethod, style: ToneStyle, engines: Engines, into tally: inout Tally
    ) {
        let engine = engines.engine(method, style)
        for boundary in [nil, " "] as [Character?] {
            do {
                let findings = try BackspaceProbe.run(keys: keys, boundary: boundary, engine: engine)
                tally.record(findings, method: method, style: style)
            } catch {
                tally.record(error: error, keys: keys)
            }
        }
    }

    /// Extra key orders of an O1 case, each the O1 keys with one pattern replaced (nil entries are
    /// patterns the keys do not contain):
    /// - `ươ` with the horn typed on the `u` first, the `o` left for horn completion (ENG-R530): Telex
    ///   `uow` -> `uwo`, VNI `uo7` -> `u7o`;
    /// - a change of mind between horn and circumflex (ENG-R533): `ươ` typed `uô` first (Telex `uoow`,
    ///   VNI `uo67`), `uô` typed `ươ` first (Telex `uowo`, VNI `uo76`);
    /// - Telex standalone `w` for `ư` (ENG-R103): `uw` -> `w`, and `uoo` -> `woo` (`ư` then a circumflex
    ///   on the `o`, the documented `selfMarkedHorn` exception of `BackspaceProbe`).
    static func extraOrders(_ generated: GeneratedCase) -> [String] {
        guard generated.kind == .order(.o1) else { return [] }
        let patterns: [(String, String)] =
            generated.method == .telex
            ? [("uow", "uwo"), ("uow", "uoow"), ("uoo", "uowo"), ("uw", "w"), ("uoo", "woo")]
            : [("uo7", "u7o"), ("uo7", "uo67"), ("uo6", "uo76")]
        return patterns.compactMap { replacingFirst($0.0, with: $0.1, in: generated.keys) }
    }

    private static func replacingFirst(_ pattern: String, with replacement: String, in keys: String) -> String? {
        let characters = Array(keys)
        let needle = Array(pattern)
        guard characters.count >= needle.count,
            let start = (0...(characters.count - needle.count)).first(where: { characters[$0...].starts(with: needle) })
        else { return nil }
        var result = characters
        result.replaceSubrange(start..<(start + needle.count), with: Array(replacement))
        return String(result)
    }

    /// An O1 case with every other letter key uppercase (ENG-R901: each letter takes the case of its
    /// key; transform keys ignore case, ENG-R902). Nil for the other orders.
    static func mixedCase(_ generated: GeneratedCase) -> String? {
        guard generated.kind == .order(.o1) else { return nil }
        var letterIndex = 0
        return String(
            generated.keys.map { key -> Character in
                guard key.isLetter else { return key }
                letterIndex += 1
                return letterIndex.isMultiple(of: 2) ? Character(key.uppercased()) : key
            })
    }

    private static func report(_ tally: Tally, _ label: String) {
        #expect(tally.runs > 0, "\(label): no cases")
        let examples = tally.violations.joined(separator: "\n")
        #expect(
            tally.violationCount == 0,
            "\(label): \(tally.violationCount) violations, \(tally.overDeleted) over-deletions, outcomes \(tally.outcomes)\n\(examples)"
        )
    }

    @Test(arguments: shards)
    func orderCases(shard: Int) {
        let engines = Engines()
        var tally = Tally()
        GeneratedCorpus.forEachOrderCase(shard: shard, of: Self.shardCount) { generated in
            Self.probe(generated.keys, method: generated.method, style: generated.style, engines: engines, into: &tally)
            for extra in Self.extraOrders(generated) + [Self.mixedCase(generated)].compactMap({ $0 }) {
                Self.probe(extra, method: generated.method, style: generated.style, engines: engines, into: &tally)
            }
        }
        Self.report(tally, "order shard \(shard)")
    }

    @Test(arguments: shards)
    func variantCases(shard: Int) {
        let engines = Engines()
        var tally = Tally()
        GeneratedCorpus.forEachVariantCase(shard: shard, of: Self.shardCount) { generated in
            Self.probe(generated.keys, method: generated.method, style: generated.style, engines: engines, into: &tally)
        }
        Self.report(tally, "variant shard \(shard)")
    }
}
