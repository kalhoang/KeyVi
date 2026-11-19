// SPDX-License-Identifier: MPL-2.0
//
// ENG-T40 performance benchmark (spec/01-engine.md 12.4 and 13.7, spec/04-quality-release.md QA-R14).
// Build and run in release:
//   swift run -c release engine-benchmark --output Benchmarks/results/latest.json
// Compare with the baseline (ENG-R1233):
//   python3 -I Benchmarks/compare.py Benchmarks/baseline.json Benchmarks/results/latest.json

import Foundation
import VietnameseEngine
import VietnameseEngineData
import VietnameseEngineTesting

struct BenchmarkReport: Codable {
    struct Machine: Codable {
        var cpu: String
        var model: String
        var operatingSystem: String
        var processors: Int
    }

    struct ResourcesFigures: Codable {
        /// The bundled word lists are present (they contain the English word `the`).
        var available: Bool
        var coldLoadMilliseconds: Double
        var medianLoadMilliseconds: Double
        var residentBytes: Int
    }

    struct WorkloadFigures: Codable {
        var name: String
        var latency: Percentiles
        /// Percentiles of the per-event minimum over the runs (see `latencyStable`).
        var stable: Percentiles
    }

    struct WorstCase: Codable {
        var events: Int
        /// The slowest event as measured, preemption included.
        var maxRawNanoseconds: Int64
        /// The slowest event after re-running every event slower than 20 µs five times from the same state
        /// and keeping the fastest run (removes preemption, keeps genuinely slow events).
        var maxRemeasuredNanoseconds: Int64
        var eventsOverBudgetRaw: Int
        var eventsOverBudgetRemeasured: Int
        /// The slowest event after re-measurement: its kind and the size of the state it ran on.
        var slowestEvent: String
    }

    struct LongToken: Codable {
        var length: Int
        var keys: String
        /// The slowest key event of the token.
        var maxKeyNanoseconds: Int64
        /// The boundary that commits the token (a restore rewrites the whole token, ENG-R611).
        var boundaryNanoseconds: Int64
        /// The restore toggle on the token (an edit to the raw keys when the display differs).
        var toggleNanoseconds: Int64
    }

    struct Budget: Codable {
        var p50: Int64 = 5_000
        var p99: Int64 = 25_000
        var p999: Int64 = 100_000
        var max: Int64 = 1_000_000
        var resourcesLoadMilliseconds: Double = 50
        var resourcesResidentBytes: Int = 8 * 1_024 * 1_024
        /// ENG-R1122: a commit that evaluates a typo correction candidate.
        var correctionP99: Int64 = 50_000
        var correctionMax: Int64 = 200_000
    }

    /// ENG-T55: the committing spaces of the candidate tokens (`Workloads.correctionCandidates`), always with the
    /// typo correction on. `p50` and `p99` are the median over the runs; `p50Stable`, `p99Stable` and `max` take
    /// each commit's fastest time over the runs first (the same events replay from the same states, so the minimum
    /// drops preemption and keeps the engine's work, as `maxRemeasuredNanoseconds` does for ENG-R1230). The gate
    /// of ENG-R1122 (`Benchmarks/compare.py`) reads `p99Stable` and `max`.
    struct CorrectionFigures: Codable {
        var events: Int
        var tokens: Int
        /// Commits that corrected the token (informational: the share depends on the bundled data).
        var corrected: Int
        var p50: Int64
        var p99: Int64
        var max: Int64
        /// The slowest commit of the median run, preemption included.
        var maxRaw: Int64
        /// p50 and p99 of each commit's fastest time over the runs (preemption removed, as `max`).
        var p50Stable: Int64
        var p99Stable: Int64
    }

    var schema = 1
    var date: String
    var configuration: String
    var machine: Machine
    var runs: Int
    var clockOverheadNanoseconds: Int64
    /// Median time of the fixed reference loop (ENG-R1233 calibration).
    var referenceNanoseconds: Int64
    /// The first `Engine.init` of the process, which builds the generated tables.
    var engineColdInitMilliseconds: Double
    var resources: ResourcesFigures
    /// The word lists every workload uses: the bundled resources with a 10,000-entry macro table.
    var wordLists = "bundled"
    /// Words of the prose corpus (13.4) each typist types; 0 when the corpus was not found.
    var proseTokens = 0
    /// All prose, typist and fuzz events of a run together; the median of each percentile over the runs (QA-R14).
    /// The budget gate reads this.
    var latency: Percentiles
    /// Percentiles of each event's fastest time over the runs. Every run replays the same events from the
    /// same states, so the minimum removes preemption and keeps the engine's own cost; the baseline gate
    /// reads this, because tail percentiles of a shared machine move with its load, not with the code.
    var latencyStable: Percentiles
    var workloads: [WorkloadFigures]
    var worstCase: WorstCase
    var longTokens: [LongToken]
    /// The typo correction switch the ENG-T40 workloads ran with (`--typo-correction`, default off: comparable with
    /// `Benchmarks/baseline.json`, measured on 1.0); `Scripts/benchmark.sh` runs both (ENG-R1233).
    var typoCorrection = false
    var correction: CorrectionFigures?
    var budget = Budget()
}

@main
struct EngineBenchmark {
    struct Options {
        var runs = 5
        var fuzzEvents = 1_000_000
        var worstCaseEvents = 10_000_000
        /// Words of the prose corpus each of the three typists types (0: the whole corpus).
        var proseTokens = 50_000
        var prose: String?
        var output: String?
        /// The typo correction switch of the ENG-T40 workloads; the `correction` workload always runs with it on.
        var typoCorrection = false
        var correctionCandidates = 10_000
        var adversarialCandidates = 1_000

        init(_ arguments: [String]) {
            var iterator = arguments.dropFirst().makeIterator()
            while let argument = iterator.next() {
                switch argument {
                case "--runs": runs = iterator.next().flatMap(Int.init) ?? runs
                case "--fuzz-events": fuzzEvents = iterator.next().flatMap(Int.init) ?? fuzzEvents
                case "--worst-case-events": worstCaseEvents = iterator.next().flatMap(Int.init) ?? worstCaseEvents
                case "--output": output = iterator.next()
                case "--prose": prose = iterator.next()
                case "--prose-tokens": proseTokens = iterator.next().flatMap(Int.init) ?? proseTokens
                case "--typo-correction":
                    switch iterator.next() {
                    case "on": typoCorrection = true
                    case "off": typoCorrection = false
                    default:
                        FileHandle.standardError.write(Data("--typo-correction takes on or off\n".utf8))
                        exit(2)
                    }
                case "--quick":
                    runs = 1
                    fuzzEvents = 100_000
                    worstCaseEvents = 1_000_000
                    proseTokens = 5_000
                    correctionCandidates = 2_000
                    adversarialCandidates = 200
                default:
                    FileHandle.standardError.write(Data("unknown argument \(argument)\n".utf8))
                    exit(2)
                }
            }
        }
    }

    static func main() throws {
        let options = Options(CommandLine.arguments)
        var sink = 0
        #if DEBUG
        let configuration = "debug"
        print("warning: debug build; the budget applies to release builds (swift run -c release)")
        #else
        let configuration = "release"
        #endif

        // The first engine of the process builds the generated tables (Engine.init).
        let coldStart = Timing.clock.now
        let probe = Engine(
            configuration: EngineConfiguration(typoCorrection: options.typoCorrection), resources: .empty)
        let coldInit = Double(Timing.nanoseconds(coldStart.duration(to: Timing.clock.now))) / 1e6
        sink &+= probe.configuration.historyLimit

        let resourcesFigures = try measureResources()
        let clockOverhead = Timing.clockOverhead()
        let reference = Percentiles((0..<5).map { _ in Timing.referenceLoop(sink: &sink) }).p50

        let resources = try Workloads.resources()
        let proseFile = options.prose.map { URL(fileURLWithPath: $0) } ?? Workloads.defaultProseCorpus
        let paragraphs = try Workloads.proseParagraphs(proseFile, limit: options.proseTokens)
        if paragraphs == nil { print("note: no prose corpus at \(proseFile.path); prose workloads skipped") }
        let switchOn = options.typoCorrection
        let workloads =
            Workloads.prose(resources: resources, paragraphs: paragraphs ?? [], typoCorrection: switchOn)
            + Workloads.typists(resources: resources, typoCorrection: switchOn)
            + Workloads.fuzz(
                resources: resources, events: options.fuzzEvents, seed: 0xBE7C_0F00, typoCorrection: switchOn)
        for workload in workloads { _ = Timing.perEvent(workload, sink: &sink) }  // warm-up run

        var combinedRuns: [Percentiles] = []
        var perWorkloadRuns: [[Percentiles]] = Array(repeating: [], count: workloads.count)
        var minimums: [[Int64]] = workloads.map { Array(repeating: Int64.max, count: $0.events.count) }
        for _ in 0..<options.runs {
            var all: [Int64] = []
            for (index, workload) in workloads.enumerated() {
                let samples = Timing.perEvent(workload, sink: &sink)
                perWorkloadRuns[index].append(Percentiles(samples))
                for (event, sample) in samples.enumerated() where sample < minimums[index][event] {
                    minimums[index][event] = sample
                }
                all += samples
            }
            combinedRuns.append(Percentiles(all))
        }
        let budget = BenchmarkReport.Budget()
        let worstCase = measureWorstCase(
            Workloads.fuzz(
                resources: resources, events: options.worstCaseEvents, seed: 0xBE7C_1000, typoCorrection: switchOn),
            budget: budget.max, sink: &sink)
        let candidates = try Workloads.correctionCandidates(
            resources: resources, count: options.correctionCandidates, adversarial: options.adversarialCandidates,
            seed: 0xBE7C_11A0)
        let correction = measureCorrection(candidates, runs: options.runs, sink: &sink)
        let longTokens = measureLongTokens(resources: resources, sink: &sink)

        var report = BenchmarkReport(
            date: ISO8601DateFormatter().string(from: Date()), configuration: configuration,
            machine: .init(
                cpu: SystemInfo.cpuName(), model: SystemInfo.model(),
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                processors: ProcessInfo.processInfo.activeProcessorCount),
            runs: options.runs, clockOverheadNanoseconds: clockOverhead, referenceNanoseconds: reference,
            engineColdInitMilliseconds: coldInit, resources: resourcesFigures,
            latency: Percentiles.median(combinedRuns), latencyStable: Percentiles(minimums.flatMap { $0 }),
            workloads: workloads.indices.map { index in
                .init(
                    name: workloads[index].name, latency: Percentiles.median(perWorkloadRuns[index]),
                    stable: Percentiles(minimums[index]))
            },
            worstCase: worstCase, longTokens: longTokens)
        report.proseTokens = paragraphs?.reduce(0) { $0 + $1.count } ?? 0
        report.typoCorrection = switchOn
        report.correction = correction
        try write(report, to: options.output)
        printSummary(report)
        if sink == Int.min { print(sink) }  // keeps the measured work observable
    }

    /// ENG-R1231: `Resources.bundled` load time and the memory it adds.
    static func measureResources() throws -> BenchmarkReport.ResourcesFigures {
        let before = SystemInfo.residentBytes()
        let start = Timing.clock.now
        let loaded = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        let cold = Double(Timing.nanoseconds(start.duration(to: Timing.clock.now))) / 1e6
        let resident = max(0, SystemInfo.residentBytes() - before)
        var loads: [Int64] = []
        for _ in 0..<5 {
            let again = Timing.clock.now
            _ = try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
            loads.append(Timing.nanoseconds(again.duration(to: Timing.clock.now)))
        }
        return .init(
            available: loaded.english.contains("the"), coldLoadMilliseconds: cold,
            medianLoadMilliseconds: Double(Percentiles(loads).p50) / 1e6, residentBytes: resident)
    }

    /// ENG-T55, ENG-R1122: the latency of each candidate's committing space over `runs` replays (after a warm-up),
    /// nil when there is no candidate (no lexicon file).
    static func measureCorrection(_ workload: Workload, runs: Int, sink: inout Int) -> BenchmarkReport
        .CorrectionFigures?
    {
        guard !workload.commits.isEmpty else { return nil }
        _ = Timing.perEvent(workload, sink: &sink)  // warm-up run
        var perRun: [Percentiles] = []
        var minimums = [Int64](repeating: .max, count: workload.commits.count)
        for _ in 0..<max(1, runs) {
            let samples = Timing.perEvent(workload, sink: &sink)
            let commits = workload.commits.map { samples[$0] }
            perRun.append(Percentiles(commits))
            for (index, sample) in commits.enumerated() where sample < minimums[index] { minimums[index] = sample }
        }
        var session = Session(engine: workload.engine)
        var corrected = 0
        for event in workload.events {
            if case .corrected? = session.handle(event).decision { corrected += 1 }
        }
        let median = Percentiles.median(perRun)
        let stable = Percentiles(minimums)
        return .init(
            events: workload.events.count, tokens: workload.commits.count, corrected: corrected, p50: median.p50,
            p99: median.p99, max: stable.max, maxRaw: median.max, p50Stable: stable.p50, p99Stable: stable.p99)
    }

    /// Events slower than this are re-run from the same state to separate preemption from engine work.
    static let remeasureThreshold: Int64 = 20_000

    /// ENG-R1230 worst case over a long fuzz run. A shadow session one event behind provides the state
    /// before each event, so an event slower than `remeasureThreshold` can be re-run five times from the
    /// same state; the fastest run is kept (the copy of the state that the re-run makes is included, so
    /// the figure is an upper bound).
    static func measureWorstCase(_ workloads: [Workload], budget: Int64, sink: inout Int) -> BenchmarkReport.WorstCase {
        var result = BenchmarkReport.WorstCase(
            events: 0, maxRawNanoseconds: 0, maxRemeasuredNanoseconds: 0, eventsOverBudgetRaw: 0,
            eventsOverBudgetRemeasured: 0, slowestEvent: "")
        for workload in workloads {
            var session = Session(engine: workload.engine)
            var shadow = Session(engine: workload.engine)
            for event in workload.events {
                let start = Timing.clock.now
                let output = session.handle(event)
                let elapsed = Timing.nanoseconds(start.duration(to: Timing.clock.now))
                sink &+= output.composingText.utf8.count
                result.events += 1
                result.maxRawNanoseconds = max(result.maxRawNanoseconds, elapsed)
                var kept = elapsed
                if elapsed > budget { result.eventsOverBudgetRaw += 1 }
                if elapsed > remeasureThreshold {
                    for _ in 0..<5 {
                        var replay = shadow
                        let again = Timing.clock.now
                        _ = replay.handle(event)
                        kept = min(kept, Timing.nanoseconds(again.duration(to: Timing.clock.now)))
                    }
                    if kept > budget { result.eventsOverBudgetRemeasured += 1 }
                }
                if kept > result.maxRemeasuredNanoseconds {
                    result.maxRemeasuredNanoseconds = kept
                    result.slowestEvent = describe(event, before: shadow.state)
                }
                _ = shadow.handle(event)
            }
        }
        return result
    }

    private static func describe(_ event: EngineEvent, before state: EngineState) -> String {
        let kind: String
        switch event {
        case .key(let input):
            kind = "key \(KeyNotation.render([event])) \(input.character.isLetter ? "letter" : "other")"
        case .backspace: kind = "backspace"
        case .restoreToggle: kind = "restore toggle"
        case .reset: kind = "reset"
        }
        return
            "\(kind); active token \(state.activeRawKeys.utf8.count) keys, display \(state.activeDisplay.utf8.count) bytes, "
            + "\(state.historyCount) history tokens"
    }

    /// Informational: tokens far beyond any syllable (REG-02). Key events stay constant time once the
    /// token is literal; the boundary that restores a long token rewrites it (ENG-R611), so its cost is
    /// proportional to the token.
    static func measureLongTokens(resources: Resources, sink: inout Int) -> [BenchmarkReport.LongToken] {
        var result: [BenchmarkReport.LongToken] = []
        for length in [64, 256, 4_096, 100_000] {
            for keys in ["m", "ddam"] {
                let committing = Workloads.longToken(
                    length: length, keys: keys, ending: .key(KeyInput(" ")), resources: resources)
                let toggling = Workloads.longToken(
                    length: length, keys: keys, ending: .restoreToggle, resources: resources)
                func last(_ workload: Workload) -> Int64 {
                    Percentiles((0..<3).map { _ in Timing.perEvent(workload, sink: &sink).last ?? 0 }).p50
                }
                let keySamples = Timing.perEvent(committing, sink: &sink).dropLast()
                result.append(
                    .init(
                        length: length, keys: keys, maxKeyNanoseconds: keySamples.max() ?? 0,
                        boundaryNanoseconds: last(committing), toggleNanoseconds: last(toggling)))
            }
        }
        return result
    }

    static func write(_ report: BenchmarkReport, to path: String?) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard let path else {
            FileHandle.standardOutput.write(data)
            print()
            return
        }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    static func printSummary(_ report: BenchmarkReport) {
        func us(_ value: Int64) -> String { String(format: "%.3f µs", Double(value) / 1_000) }
        let latency = report.latency
        print(
            "[ENG-T40] \(report.machine.cpu), \(report.configuration), median of \(report.runs) runs; "
                + "\(report.wordLists) word lists, \(report.proseTokens) prose words per typist")
        print(
            "[ENG-R1230] \(latency.events) events: p50 \(us(latency.p50)), p99 \(us(latency.p99)), "
                + "p99.9 \(us(latency.p999)), max \(us(latency.max)) (budget 5 / 25 / 100 µs)")
        let stable = report.latencyStable
        print(
            "[ENG-R1233] per-event minimum over the runs: p50 \(us(stable.p50)), p99 \(us(stable.p99)), "
                + "p99.9 \(us(stable.p999)), max \(us(stable.max)) (baseline gate)")
        for workload in report.workloads {
            let figures = workload.latency
            print(
                "  \(workload.name): \(figures.events) events, p50 \(us(figures.p50)), p99 \(us(figures.p99)), "
                    + "p99.9 \(us(figures.p999)), max \(us(figures.max))")
        }
        let worst = report.worstCase
        print(
            "[ENG-R1230] worst case over \(worst.events) fuzz events: raw \(us(worst.maxRawNanoseconds)), "
                + "re-measured \(us(worst.maxRemeasuredNanoseconds)) (budget 1 ms); over budget raw "
                + "\(worst.eventsOverBudgetRaw), re-measured \(worst.eventsOverBudgetRemeasured); slowest: \(worst.slowestEvent)"
        )
        print(
            "[ENG-R1231] Resources.bundled: available \(report.resources.available), cold "
                + String(
                    format: "%.3f ms, median %.3f ms, ", report.resources.coldLoadMilliseconds,
                    report.resources.medianLoadMilliseconds)
                + "resident +\(report.resources.residentBytes) bytes (budget 50 ms, 8 MB)")
        print(
            String(
                format: "engine cold init %.3f ms; reference loop %.3f ms; clock overhead %lld ns",
                report.engineColdInitMilliseconds, Double(report.referenceNanoseconds) / 1e6,
                report.clockOverheadNanoseconds))
        if let correction = report.correction {
            print(
                "[ENG-R1122] typo correction: \(correction.tokens) candidate commits (\(correction.corrected) corrected): "
                    + "p50 \(us(correction.p50)), p99 \(us(correction.p99)) (stable \(us(correction.p99Stable))), max \(us(correction.max)) "
                    + "(raw \(us(correction.maxRaw))) (budget p99 50 µs, max 200 µs); ENG-T40 workloads with the switch "
                    + (report.typoCorrection ? "on" : "off"))
        } else {
            print("note: no English lexicon file; the typo correction workload was skipped")
        }
        for token in report.longTokens {
            print(
                "  long token \(token.length) x \(token.keys): max key \(us(token.maxKeyNanoseconds)), "
                    + "boundary \(us(token.boundaryNanoseconds)), toggle \(us(token.toggleNanoseconds))")
        }
    }
}
