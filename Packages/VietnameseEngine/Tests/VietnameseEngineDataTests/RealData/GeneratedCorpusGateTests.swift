// SPDX-License-Identifier: MPL-2.0
//
// ENG-R870 with the bundled data: every case of the generated corpus (every Tier A toned syllable, orders
// O1 to O4, both methods and tone styles, plus the ENG-T03 variants), committed by a space after the
// Vietnamese seed token `việt`, equals the oracle, 100 %. The only allowed exclusions are raw strings that
// are `en` rows of the ambiguity table; they must be restored and the test lists them.
//
// English words whose display is a valid but unattested Tier A syllable are restored by rule L8
// (docs/decisions/0103, open issue); the data lists them as `en` rows or attests the syllable
// (docs/decisions/0202), so no other exclusion exists.

import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-R870 generated corpus with the bundled data")
struct GeneratedCorpusGateTests {
    static let shardCount = 24
    static let seed = "vieejt "
    static let seedText = "việt "

    @Test("ENG-R870: committed text equals the oracle, en rows excluded", arguments: Array(0..<shardCount))
    func shard(_ shard: Int) throws {
        let resources = try RealData.resources()
        var sessions: [EngineConfiguration: Session] = [:]
        var cases = 0
        var excluded: Set<String> = []
        var failures: [String] = []
        func check(_ generated: GeneratedCase) {
            cases += 1
            let configuration = generated.configuration
            if sessions[configuration] == nil {
                var session = Session(engine: Engine(configuration: configuration, resources: resources))
                for key in Self.seed { _ = session.handle(.key(KeyInput(key))) }
                sessions[configuration] = session
            }
            guard var session = sessions[configuration] else { return }
            var field = SimulatedTextField(text: Self.seedText)
            var decision: CommitDecision?
            for event in generated.events + [.key(KeyInput(" "))] {
                let output = session.handle(event)
                do { try field.apply(event, output) } catch {
                    failures.append("\(generated.keys): edit contract violation \(error)")
                    return
                }
                decision = output.decision ?? decision
            }
            let committed = String(field.string.dropFirst(Self.seedText.count))
            if resources.ambiguity[generated.keys.lowercased()] == .english {
                excluded.insert(generated.keys)
                // ENG-R843: an `en` row restores the raw keys in Vietnamese context.
                if committed != generated.keys + " " { failures.append("\(generated.keys): en row not restored") }
                return
            }
            if committed != generated.expectedCommitted + " " {
                failures.append(
                    "\(generated.method) \(generated.style) \(generated.kind) \(generated.keys): committed "
                        + "\(committed.debugDescription) (oracle \(generated.expectedCommitted)) "
                        + (decision.map { "\($0)" } ?? ""))
            }
        }
        GeneratedCorpus.forEachOrderCase(shard: shard, of: Self.shardCount, check)
        GeneratedCorpus.forEachVariantCase(shard: shard, of: Self.shardCount, check)
        #expect(cases > 0)
        #expect(failures.isEmpty, "shard \(shard): \(failures.count) failures\n\(failures.joined(separator: "\n"))")
        print(
            "[ENG-R870] shard \(shard): \(cases) cases, excluded en rows: \(excluded.sorted().joined(separator: " "))")
    }

    /// The total of the per-shard exclusions, so that docs/decisions/0202 copies the number instead of adding
    /// up 24 lists. The shards assert that each excluded case is really restored; this test only counts.
    @Test("ENG-R870: total of the excluded en rows over all shards")
    func exclusionTotal() throws {
        let resources = try RealData.resources()
        var cases = 0
        var variants: Set<String> = []
        func count(_ generated: GeneratedCase) {
            cases += 1
            if resources.ambiguity[generated.keys.lowercased()] == .english { variants.insert(generated.keys) }
        }
        for shard in 0..<Self.shardCount {
            GeneratedCorpus.forEachOrderCase(shard: shard, of: Self.shardCount, count)
            GeneratedCorpus.forEachVariantCase(shard: shard, of: Self.shardCount, count)
        }
        let rawStrings = Set(variants.map { $0.lowercased() })
        print(
            "[ENG-R870] total: \(cases) cases; excluded \(variants.count) case variants of \(rawStrings.count) raw "
                + "strings, all en rows")
        #expect(cases > 0)
        #expect(rawStrings.allSatisfy { resources.ambiguity[$0] == .english })
    }
}
