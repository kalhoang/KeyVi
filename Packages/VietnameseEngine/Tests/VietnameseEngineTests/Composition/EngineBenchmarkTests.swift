// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Microbenchmark sanity check for ENG-R1230 (p50 5 µs, p99 25 µs, p99.9 100 µs per event in release
/// builds). Not a gate: it prints per-event latencies; ENG-T40 (E4) owns the calibrated gate. Meaningful
/// numbers need a release build: `Scripts/bench-composition.sh` or
/// `swift test -c release --filter EngineBenchmarkTests`.
@Suite("Engine microbenchmark (ENG-R1230 sanity)", .serialized)
struct EngineBenchmarkTests {
    /// Resources for the benchmark: the 13.9 fixture word lists and a macro table of 10,000 entries
    /// (ENG-R1105: tables of that size must stay within ENG-R1230).
    static let resources: Resources = {
        var entries = (0..<10_000).map { MacroTable.Entry(trigger: "m\($0)", expansion: "macro \($0)") }
        entries.append(MacroTable.Entry(trigger: "vn", expansion: "Việt Nam"))
        let macros = (try? MacroTable(entries)) ?? .empty
        return SpecFixtures.commitResources(macros: macros)
    }()

    /// Every Tier A syllable typed in Telex O1 and O3 and VNI O1, each followed by a space (so every token
    /// is committed by the rules of 8.1 and looked up in the macro table), plus English words that go
    /// literal or are restored at a punctuation boundary, Backspace runs that re-open committed tokens,
    /// macro expansions and restore toggles.
    static func workload() -> [(Engine, [EngineEvent])] {
        let telex = Engine(configuration: EngineConfiguration(typoCorrection: false), resources: resources)
        let vni = Engine(
            configuration: EngineConfiguration(inputMethod: .vni, typoCorrection: false), resources: resources)
        var telexEvents: [EngineEvent] = []
        var vniEvents: [EngineEvent] = []
        GeneratedCorpus.forEachOrderCase { generated in
            guard generated.style == .traditional else { return }
            switch (generated.method, generated.kind) {
            case (.telex, .order(.o1)), (.telex, .order(.o3)):
                telexEvents += generated.events + [.key(KeyInput(" "))]
            case (.vni, .order(.o1)):
                vniEvents += generated.events + [.key(KeyInput(" "))]
            default: break
            }
        }
        for word in ["password", "keyboard", "useState", "traffic", "wifi", "verbose"] {
            telexEvents += SpecExamples.events(typing: word + "⌫⌫ ")
            telexEvents += SpecExamples.events(typing: word + ", ⌫⌫⌫ ")
        }
        for _ in 0..<200 {
            telexEvents += KeyNotation.events("vn m9999. ⌫⌫⎋ and this is the best car\n")
        }
        telexEvents += SpecExamples.events(typing: "vieejt") + [.restoreToggle, .backspace, .restoreToggle]
        return [(telex, telexEvents), (vni, vniEvents)]
    }

    @Test func perEventLatency() {
        let workload = Self.workload()
        let clock = ContinuousClock()
        var samples: [Int64] = []
        var commitSamples: [Int64] = []
        samples.reserveCapacity(workload.reduce(0) { $0 + $1.1.count })
        var sink = 0
        for round in 0..<2 {  // the first round warms the tables and caches
            samples.removeAll(keepingCapacity: true)
            commitSamples.removeAll(keepingCapacity: true)
            for (engine, events) in workload {
                var session = Session(engine: engine)
                for event in events {
                    let start = clock.now
                    let output = session.handle(event)
                    let elapsed = start.duration(to: clock.now)
                    sink &+= output.composingText.utf8.count
                    guard round == 1 else { continue }
                    samples.append(Self.nanoseconds(elapsed))
                    if output.decision != nil { commitSamples.append(Self.nanoseconds(elapsed)) }
                }
            }
        }
        #expect(!samples.isEmpty && !commitSamples.isEmpty && sink >= 0)
        #if DEBUG
        let mode = "debug build: numbers are not comparable with the budget"
        #else
        let mode = "release build"
        #endif
        print("[ENG-R1230] \(Self.summary(samples, "events")) (\(mode); budget p50 5, p99 25, p99.9 100)")
        print("[ENG-R1230] \(Self.summary(commitSamples, "commits and macro expansions")) (\(mode))")
    }

    private static func summary(_ unsorted: [Int64], _ label: String) -> String {
        let samples = unsorted.sorted()
        func percentile(_ fraction: Double) -> Double {
            Double(samples[min(samples.count - 1, Int(Double(samples.count) * fraction))]) / 1_000
        }
        return "\(samples.count) \(label): p50 \(percentile(0.5)) µs, p99 \(percentile(0.99)) µs, "
            + "p99.9 \(percentile(0.999)) µs, max \(Double(samples.last ?? 0) / 1_000) µs"
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }
}
