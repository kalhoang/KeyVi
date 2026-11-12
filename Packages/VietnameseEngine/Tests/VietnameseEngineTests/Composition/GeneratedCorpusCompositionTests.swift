// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// ENG-T02 / ENG-T04: every O1 to O4 case of the generated corpus (237,824 cases: every Tier A toned
/// syllable, both methods, both styles), and ENG-T03: every Titlecase, all-caps and explicit `uwow`
/// variant (31,676 cases). The display after the last key must equal the oracle (ENG-T01) for 100 % of
/// the cases. The composed form written at commit (ENG-R532, `Composition.committedText`) is checked
/// against the oracle's committed spelling too; the commit itself (section 8) is tested elsewhere.
///
/// The corpus is split into shards that Swift Testing runs in parallel. Every case of every shard is
/// run by the default `swift test` (no subset).
@Suite("Generated corpus through the engine (ENG-T02 to ENG-T04)")
struct GeneratedCorpusCompositionTests {
    static let shardCount = 40
    static let shards = Array(0..<shardCount)

    /// One engine per (method, style) for the default options.
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

        subscript(_ configuration: EngineConfiguration) -> Engine {
            engines[configuration] ?? Engine(configuration: configuration, resources: .empty)
        }
    }

    /// Runs one case; returns a failure description or nil. The outputs are applied to a simulated
    /// field, which must end up holding exactly the display (ENG-T31, ENG-R611 over the whole corpus).
    private static func failure(of generated: GeneratedCase, engines: Engines) -> String? {
        var session = Session(engine: engines[generated.configuration])
        var field = SimulatedTextField()
        for event in generated.events {
            do {
                try field.apply(event, session.handle(event))
            } catch {
                return "\(generated.keys): \(error)"
            }
        }
        let display = session.state.activeDisplay
        let committed = session.state.active?.composition.committedText(style: generated.style) ?? ""
        guard display == generated.expectedDisplay, committed == generated.expectedCommitted,
            field.text.elementsEqual(display)
        else {
            return
                "\(generated.method) \(generated.style) \(generated.kind) \(generated.keys): display \(display) "
                + "(oracle \(generated.expectedDisplay)), committed \(committed) (oracle \(generated.expectedCommitted)), "
                + "field \(field.string)"
        }
        return nil
    }

    private struct Tally {
        var cases = 0
        var failures: [String] = []

        mutating func record(_ failure: String?) {
            cases += 1
            if let failure, failures.count < 25 { failures.append(failure) }
            if failure != nil { failureCount += 1 }
        }

        var failureCount = 0
    }

    @Test(arguments: shards)
    func orderCases(shard: Int) {
        let engines = Engines()
        var tally = Tally()
        GeneratedCorpus.forEachOrderCase(shard: shard, of: Self.shardCount) {
            tally.record(Self.failure(of: $0, engines: engines))
        }
        #expect(tally.cases > 0)
        #expect(
            tally.failureCount == 0,
            "shard \(shard): \(tally.failureCount) of \(tally.cases) failed\n\(tally.failures.joined(separator: "\n"))")
    }

    @Test(arguments: shards)
    func variantCases(shard: Int) {
        let engines = Engines()
        var tally = Tally()
        GeneratedCorpus.forEachVariantCase(shard: shard, of: Self.shardCount) {
            tally.record(Self.failure(of: $0, engines: engines))
        }
        #expect(tally.cases > 0)
        #expect(
            tally.failureCount == 0,
            "shard \(shard): \(tally.failureCount) of \(tally.cases) failed\n\(tally.failures.joined(separator: "\n"))")
    }

    @Test func shardsPartitionTheCorpus() {
        var orders = 0
        var variants = 0
        for shard in Self.shards {
            GeneratedCorpus.forEachOrderCase(shard: shard, of: Self.shardCount) { _ in orders += 1 }
            GeneratedCorpus.forEachVariantCase(shard: shard, of: Self.shardCount) { _ in variants += 1 }
        }
        let counts = GeneratedCorpus.counts()
        #expect(orders == counts.orders && variants == counts.variants)
        print("[ENG-T04] engine run over \(orders) O1-O4 cases and \(variants) ENG-T03 variants")
    }
}
