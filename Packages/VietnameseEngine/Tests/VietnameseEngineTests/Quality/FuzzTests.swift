// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// Environment knobs of the fuzz campaign (QA-R8). `ENGINE_FUZZ_EVENTS` sets the number of random stream
/// events (default 1,000,000; nightly 100,000,000); `ENGINE_FUZZ_SEED` offsets every seed (default 0, so
/// pull requests replay the same streams); `ENGINE_FUZZ_HANG_MS` sets the hang detector of QA-R7 P2.
enum FuzzEnvironment {
    static func integer(_ name: String) -> Int? {
        ProcessInfo.processInfo.environment[name].flatMap { Int($0.replacingOccurrences(of: "_", with: "")) }
    }

    static let streamEvents = max(80, integer("ENGINE_FUZZ_EVENTS") ?? FuzzCampaign.defaultEventCount)
    static let seedOffset = UInt64(truncatingIfNeeded: integer("ENGINE_FUZZ_SEED") ?? 0)

    static var options: InvariantChecker.Options {
        var options = InvariantChecker.Options()
        options.nfcCheck = { $0.precomposedStringWithCanonicalMapping == $0 }
        if let milliseconds = integer("ENGINE_FUZZ_HANG_MS") {
            options.hangThresholdNanoseconds = Int64(milliseconds) * 1_000_000
        }
        return options
    }

    /// A table of 1,000 random triggers, punctuation-only triggers included (13.6).
    static let macros: MacroTable = {
        do {
            return try RandomMacroTable.table()
        } catch {
            Issue.record("random macro table: \(error)")
            return .empty
        }
    }()
}

/// The fuzz campaign of spec 13.6 and QA-R7 / QA-R8: seeded random streams over the full alphabet, every
/// option combination with and without a random 1,000-trigger macro table, and long tokens up to 100,000
/// keys. The default `swift test` sends `ENGINE_FUZZ_EVENTS` (1,000,000) stream events plus about 420,000
/// long-token events, all from fixed seeds; every invariant is checked after every event
/// (`InvariantChecker`).
@Suite("Fuzz campaign (13.6, QA-R7, QA-R8)")
struct FuzzTests {
    static let combinations = FuzzCombination.all

    @Test("Random streams, every option combination (ENG-T30 to ENG-T37)", arguments: Array(combinations.indices))
    func randomStreams(_ index: Int) throws {
        let combination = Self.combinations[index]
        let events = (FuzzEnvironment.streamEvents + Self.combinations.count - 1) / Self.combinations.count
        let seed = 0x0136_0000 &+ UInt64(index) &+ FuzzEnvironment.seedOffset
        let statistics: FuzzStatistics
        do {
            statistics = try FuzzCampaign.run(
                combination, seed: seed, events: events, macros: FuzzEnvironment.macros,
                options: FuzzEnvironment.options)
        } catch let violation as FuzzViolation {
            Issue.record("\(combination) seed \(seed): \(violation)")
            return
        }
        #expect(statistics.events == events)
        // The streams reach what they are meant to exercise.
        #expect(statistics.commits > 0 && statistics.edits > 0 && statistics.resets > 0)
        #expect(statistics.restoreChecks > 0 && statistics.escapeChecks > 0 && statistics.replayChecks > 0)
        #expect(statistics.pureReduceChecks > 0 && statistics.fullFieldChecks > 0)
        if combination.withMacros { #expect(statistics.macroExpansions > 0, "\(combination)") }
        if combination.configuration.autoRestore, combination.fixtureResources {
            #expect(statistics.restoredCommits > 0, "\(combination)")
        }
        #expect(statistics.longestToken >= 33, "\(combination)")
    }

    static let longTokenCases: [(length: Int, vni: Bool, singleKey: Bool)] = {
        var cases: [(Int, Bool, Bool)] = []
        for length in [33, 64, 65, 256, 1_000, 4_096, 100_000] {
            for vni in [false, true] {
                for singleKey in [false, true] { cases.append((length, vni, singleKey)) }
            }
        }
        return cases
    }()

    /// REG-02, ENG-R640, ENG-R641: tokens of 33 to 100,000 keys, mixed keys with Backspace and toggles
    /// inside or one key repeated; the toggle shows the raw keys exactly and nothing traps.
    @Test("Long tokens up to 100,000 keys (REG-02)", arguments: Array(longTokenCases.indices))
    func longTokens(_ index: Int) throws {
        let testCase = Self.longTokenCases[index]
        let configuration = EngineConfiguration(inputMethod: testCase.vni ? .vni : .telex(TelexOptions()))
        let seed = 0x0136_1000 &+ UInt64(index) &+ FuzzEnvironment.seedOffset
        do {
            let statistics = try FuzzCampaign.longToken(
                configuration: configuration, length: testCase.length, seed: seed, singleKey: testCase.singleKey,
                edits: !testCase.singleKey, options: FuzzEnvironment.options)
            #expect(statistics.longestToken >= testCase.length - testCase.length / 50)
        } catch let violation as FuzzViolation {
            Issue.record("long token \(testCase) seed \(seed): \(violation)")
        }
    }

    /// ENG-T33: the same stream gives the same outputs, run after run.
    @Test("Determinism and replay (ENG-T33)")
    func determinism() throws {
        for index in [0, 17, 72] {
            let combination = Self.combinations[index]
            let runs = try (0..<2).map { _ in
                try FuzzCampaign.run(
                    combination, seed: 0xD00D, events: 20_000, macros: FuzzEnvironment.macros,
                    options: FuzzEnvironment.options)
            }
            #expect(runs[0].outputDigest == runs[1].outputDigest, "\(combination)")
            #expect(runs[0].commits == runs[1].commits && runs[0].edits == runs[1].edits)
        }
    }

    /// ENG-R906: the random streams of every Telex combination with bracket keys send bracket keys with
    /// Caps Lock on, so the replay and restore checks of `randomStreams` see that state on every pull
    /// request; no other combination and no other key carries Caps Lock.
    @Test("The bracket combinations of the random streams send Caps Lock bracket keys (ENG-R906)")
    func capsLockBracketKeysInStreams() {
        var bracketCombinations = 0
        for (index, combination) in Self.combinations.enumerated() {
            var bracketKeys = false
            if case .telex(let options) = combination.configuration.inputMethod { bracketKeys = options.bracketKeys }
            let seed = 0x0136_0000 &+ UInt64(index) &+ FuzzEnvironment.seedOffset
            var source = FuzzEventSource(
                seed: seed, configuration: combination.configuration, triggers: FuzzEnvironment.macros.triggers)
            var capsLockBrackets = 0
            var capsLockOthers = 0
            for event in source.events(20_000) {
                guard case .key(let input) = event, input.capsLock else { continue }
                if input.character == "[" || input.character == "]" {
                    capsLockBrackets += 1
                } else {
                    capsLockOthers += 1
                }
            }
            #expect(capsLockOthers == 0, "\(combination)")
            if bracketKeys {
                bracketCombinations += 1
                #expect(capsLockBrackets > 0, "\(combination)")
            } else {
                #expect(capsLockBrackets == 0, "\(combination)")
            }
        }
        #expect(bracketCombinations == 32)
    }

    @Test("The random macro table has 1,000 triggers, punctuation-only ones included, NFC expansions")
    func macroTable() {
        let entries = RandomMacroTable.entries(count: 1_000, seed: 0x5EED_00AC_0001)
        #expect(FuzzEnvironment.macros.triggers.count == 1_000)
        #expect(entries.map(\.trigger) == FuzzEnvironment.macros.triggers)
        let punctuationOnly = entries.filter { $0.trigger.allSatisfy { !$0.isLetter && !$0.isNumber } }
        #expect(punctuationOnly.count >= 100)
        #expect(entries.contains { $0.expansion.count == 4_000 } && entries.contains { $0.expansion.isEmpty })
        for entry in entries {
            #expect(entry.expansion.precomposedStringWithCanonicalMapping == entry.expansion)
            #expect(entry.expansion.unicodeScalars.allSatisfy { $0.value < 0x1_0000 })
        }
    }

    @Test("The byte encoding covers the whole alphabet")
    func byteEncoding() {
        let events = FuzzAlphabet.events(forBytes: 0...255)
        var resets = Set<ResetReason>()
        var keypadDigits = 0
        for event in events {
            switch event {
            case .reset(let reason): resets.insert(reason)
            case .key(let input) where input.fromKeypad: keypadDigits += 1
            default: break
            }
        }
        #expect(resets.count == FuzzAlphabet.resetReasons.count)
        #expect(keypadDigits == 10)
        #expect(events.contains(.backspace) && events.contains(.restoreToggle))
        for byte in UInt8(0x20)...0x7E {
            #expect(FuzzAlphabet.event(forByte: byte) == .key(KeyInput(Character(Unicode.Scalar(byte)))))
        }
        #expect(
            Set(FuzzAlphabet.nonASCIILetters).isSubset(
                of: Set(
                    events.compactMap { event -> Character? in
                        if case .key(let input) = event { return input.character }
                        return nil
                    })))
    }

    @Test("A violation report renders the events in corpus notation")
    func violationReport() {
        let events = KeyNotation.events("a⌫⎋⟲ ") + [.key(KeyInput("\n")), .key(KeyInput("1", fromKeypad: true))]
        #expect(KeyNotation.render(events) == "a⌫⎋⟲\\s\\n⌨1")
        let violation = FuzzViolation(invariant: "ENG-T31", detail: "x", eventIndex: 3, recentEvents: events)
        #expect(violation.description.contains("ENG-T31 at event 3"))
    }
}
