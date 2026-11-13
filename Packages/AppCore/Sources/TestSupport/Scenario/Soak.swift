// SPDX-License-Identifier: LicenseRef-App-Pending
//
// `compat-harness soak` (QA-R16, 02-platform.md 13.6): replays exactly N keystrokes of Telex words through
// the real pipeline into the scenario targets in turn (TextEdit, a Chrome page, Terminal by default), checks
// the text of every chunk, samples the footprint of the app under test for M2 (gate 5 MB/h, 8.1) and checks
// that no modifier is left held. The live monitor (proc_pid_rusage, CGEventSource flags) runs on the runner.

internal import Foundation
public import RealtimeSupport

/// Telex words with unambiguous output (no tone-placement variants such as "hoà"/"hòa"), every one a valid
/// Vietnamese syllable, so neither tone style nor English restore can change the expected text.
public enum SoakCorpus {
    public static let words: [(keys: String, text: String)] = [
        ("vieetj", "việt"), ("nam", "nam"), ("tieengs", "tiếng"), ("nguwowif", "người"), ("dduwowngf", "đường"),
        ("duyeetj", "duyệt"), ("xin", "xin"), ("chaof", "chào"), ("banj", "bạn"), ("cuar", "của"),
        ("khoong", "không"), ("laf", "là"), ("mootj", "một"), ("ddi", "đi"), ("hocj", "học"),
        ("nuwowcs", "nước"), ("giowf", "giờ"), ("thanhf", "thành"), ("phoos", "phố"), ("sinh", "sinh"),
    ]
}

public struct SoakChunk: Sendable, Hashable {
    public var target: Int
    public var keys: [String]
    public var expectedText: String
}

public struct SoakPlan: Sendable, Hashable {
    /// Smallest `--keystrokes` accepted: every chunk must hold its framing keys and at least one word.
    public static let minimumKeystrokes = 16
    public static let defaultChunkKeystrokes = 400

    public var chunks: [SoakChunk]
    public var keystrokes: Int { chunks.reduce(0) { $0 + $1.keys.count } }

    /// Exactly `keystrokes` keys split over `targets` round robin. Terminal targets end each chunk with
    /// Return (the capture reads the last line); the others start with Command+A, Backspace to clear.
    public static func make(
        keystrokes: Int, targets: [Scenario], seed: UInt64, chunkKeystrokes: Int = defaultChunkKeystrokes
    ) -> SoakPlan {
        guard !targets.isEmpty, keystrokes >= minimumKeystrokes else { return SoakPlan(chunks: []) }
        let size = max(chunkKeystrokes, minimumKeystrokes)
        var generator = SeededGenerator(seed: seed)
        var chunks: [SoakChunk] = []
        var remaining = keystrokes
        while remaining > 0 {
            // The last chunk takes the remainder when another full chunk would leave too little behind.
            let budget = remaining - size < minimumKeystrokes ? remaining : size
            let target = chunks.count % targets.count
            chunks.append(chunk(budget, target: target, terminal: targets[target].readback == .terminalCapture, &generator))
            remaining -= budget
        }
        return SoakPlan(chunks: chunks)
    }

    private static func chunk(
        _ budget: Int, target: Int, terminal: Bool, _ generator: inout SeededGenerator
    ) -> SoakChunk {
        let prefix = terminal ? [] : ["command+a", "backspace"]
        let suffix = terminal ? ["return"] : []
        let available = budget - prefix.count - suffix.count
        var body: [String] = []
        var texts: [String] = []
        while true {
            let word = SoakCorpus.words[Int(generator.next() % UInt64(SoakCorpus.words.count))]
            let cost = word.keys.count + (texts.isEmpty ? 0 : 1)
            if body.count + cost > available { break }
            if !texts.isEmpty { body.append("space") }
            body += word.keys.map(String.init)
            texts.append(word.text)
        }
        let padding = available - body.count
        body += Array(repeating: "space", count: padding)
        let text = texts.joined(separator: " ") + String(repeating: " ", count: padding)
        return SoakChunk(target: target, keys: prefix + body + suffix, expectedText: text)
    }
}

/// App-under-test observations during the soak. Live: CompatHarness/Live (runner only).
public protocol SoakMonitor: Sendable {
    func footprintMegabytes() async throws -> Double
    /// `CGEventFlags` of the combined session state after the run.
    func heldModifierFlags() -> UInt64
}

public struct SoakSummary: Sendable, Hashable, Codable {
    public struct Failure: Sendable, Hashable, Codable {
        public var chunk: Int
        public var scenario: String
        public var outcome: ScenarioResult.Outcome
    }

    public struct Sample: Sendable, Hashable, Codable {
        public var elapsedSeconds: Double
        public var megabytes: Double
    }

    /// M2 gate (8.1): at most 5 MB/h growth.
    public static let growthGateMegabytesPerHour = 5.0
    /// shift, control, option, command (device-independent `CGEventFlags` masks).
    public static let modifierMask: UInt64 = 0x001E_0000

    public var keystrokes: Int
    public var chunks: Int
    public var failures: [Failure]
    public var samples: [Sample]
    public var growthMegabytesPerHour: Double?
    public var stuckModifierFlags: UInt64
    public var passed: Bool

    /// Least-squares slope of footprint over time in MB/h; nil with fewer than two distinct sample times.
    public static func growth(_ samples: [Sample]) -> Double? {
        guard samples.count >= 2 else { return nil }
        let hours = samples.map { $0.elapsedSeconds / 3600 }
        let meanX = hours.reduce(0, +) / Double(samples.count)
        let meanY = samples.reduce(0) { $0 + $1.megabytes } / Double(samples.count)
        var numerator = 0.0
        var denominator = 0.0
        for (x, sample) in zip(hours, samples) {
            numerator += (x - meanX) * (sample.megabytes - meanY)
            denominator += (x - meanX) * (x - meanX)
        }
        return denominator > 0 ? numerator / denominator : nil
    }
}

public struct SoakRunner: Sendable {
    private let targets: [Scenario]
    private let runner: ScenarioRunner
    private let monitor: (any SoakMonitor)?
    private let clock: any MonotonicClock
    private let sampleEveryChunks: Int

    public init(
        targets: [Scenario], runner: ScenarioRunner, monitor: (any SoakMonitor)?, clock: any MonotonicClock,
        sampleEveryChunks: Int = 10
    ) {
        self.targets = targets
        self.runner = runner
        self.monitor = monitor
        self.clock = clock
        self.sampleEveryChunks = max(1, sampleEveryChunks)
    }

    public func run(_ plan: SoakPlan) async -> SoakSummary {
        let start = clock.now().nanoseconds
        var failures: [SoakSummary.Failure] = []
        var samples: [SoakSummary.Sample] = []
        for (index, chunk) in plan.chunks.enumerated() {
            var scenario = targets[chunk.target]
            scenario.keys = chunk.keys
            scenario.expect = Scenario.Expectation(text: chunk.expectedText)
            let result = await runner.run(scenario)
            if result.outcome != .pass {
                failures.append(.init(chunk: index, scenario: scenario.id, outcome: result.outcome))
            }
            if index % sampleEveryChunks == 0 || index == plan.chunks.count - 1,
                let megabytes = try? await monitor?.footprintMegabytes()
            {
                let elapsed = Double(clock.now().nanoseconds &- start) / 1_000_000_000
                samples.append(.init(elapsedSeconds: elapsed, megabytes: megabytes))
            }
        }
        let growth = SoakSummary.growth(samples)
        let stuck = (monitor?.heldModifierFlags() ?? 0) & SoakSummary.modifierMask
        let passed = failures.isEmpty && stuck == 0 && (growth ?? 0) <= SoakSummary.growthGateMegabytesPerHour
        return SoakSummary(
            keystrokes: plan.keystrokes, chunks: plan.chunks.count, failures: failures, samples: samples,
            growthMegabytesPerHour: growth, stuckModifierFlags: stuck, passed: passed)
    }
}
