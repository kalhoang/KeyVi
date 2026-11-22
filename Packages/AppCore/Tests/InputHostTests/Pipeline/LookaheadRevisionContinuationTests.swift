// SPDX-License-Identifier: GPL-3.0-or-later
//
// ENG-R1211 amendment of 19/11/2026 (PLT-R340 late focus change; VM run of 19/11/2026,
// `testhost.panel.inlineCompletionTwice`): a state that holds no committed token is the same under two engine
// configurations that differ only in `lookaheadRevision`, because that switch governs only what is decided at a
// commit (ENG-R829). The host relies on it to continue the word being typed with the engine of a field whose rule
// turns the switch off (`launcher.spotlight`) instead of resetting it. Real engine, bundled data.

import Testing
import VietnameseEngine
import VietnameseEngineData

@Suite struct LookaheadRevisionContinuationTests {
    private static let resources: Resources = {
        do {
            return try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
        } catch {
            return .empty
        }
    }()

    /// The configurations a host builds (both methods, both contexts, restore on and off), each with the switch on.
    private static var configurations: [EngineConfiguration] {
        var all: [EngineConfiguration] = []
        for method in [InputMethod.telex(TelexOptions()), .vni] {
            for context in [AppContext.general, .code] {
                for restore in [true, false] {
                    all.append(
                        EngineConfiguration(
                            inputMethod: method, autoRestore: restore, appContext: context, lookaheadRevision: true,
                            typoCorrection: false))
                }
            }
        }
        return all
    }

    private enum Step: Hashable {
        case key(Character)
        case backspace
        case toggle

        var event: EngineEvent {
            switch self {
            case .key(let character): .key(KeyInput(character))
            case .backspace: .backspace
            case .toggle: .restoreToggle
            }
        }
    }

    /// Feeds `steps` to both engines from the initial state and compares after every step. A step that commits
    /// leaves the domain of the amendment, so the sequences never contain a separator and none may commit.
    private static func expectSameStates(_ steps: [Step], _ on: EngineConfiguration) {
        var off = on
        off.lookaheadRevision = false
        var withSwitch = Session(engine: Engine(configuration: on, resources: resources))
        var withoutSwitch = Session(engine: Engine(configuration: off, resources: resources))
        for step in steps {
            let first = withSwitch.handle(step.event)
            let second = withoutSwitch.handle(step.event)
            #expect(first.decision == nil && second.decision == nil, "\(steps) committed under \(on)")
            #expect(first.action == second.action && first.composingText == second.composingText)
            #expect(withSwitch.state == withoutSwitch.state, "\(steps) under \(on)")
        }
    }

    private static func steps(_ keys: String) -> [Step] { keys.map { .key($0) } }

    @Test func wordsBeingTypedHaveTheSameStateWithAndWithoutTheSwitchENGR1211() {
        #expect(Self.resources.english.contains("file"), "the bundled data must load")
        let telex = [
            "vieejt", "tieengs", "dduowngf", "nghieeng", "khuyeenr", "Ddaay", "hoafn", "thuowr", "chown", "awk", "tar",
            "Tar", "file", "server", "the", "my", "as", "off", "mess", "pass", "www", "useState", "VIEETJ", "duws",
            "tarr", "turn", "cos", "has", "been", "such", "me", "too", "day", "sale", "a", "hello", "duongz",
        ]
        let vni = ["vie65t", "tie61ng", "d9u7o7ng2", "hoa2n", "thu7o73", "as", "file", "tar", "Vie65t"]
        for configuration in Self.configurations {
            let words: [String]
            if case .vni = configuration.inputMethod { words = vni } else { words = telex }
            for word in words {
                Self.expectSameStates(Self.steps(word), configuration)
                Self.expectSameStates(Self.steps(word) + [.backspace, .backspace], configuration)
                Self.expectSameStates(Self.steps(word) + [.toggle], configuration)
                Self.expectSameStates(Self.steps(word) + [.toggle, .toggle] + Self.steps("s"), configuration)
            }
        }
    }

    /// Seeded sequences of letters, Backspace and the restore toggle, never a separator.
    @Test func randomSequencesHaveTheSameStateWithAndWithoutTheSwitchENGR1211() {
        var generator = SplitMix64(seed: 19_112_026)
        let letters = Array("aeiouydwsfrxjzqcnghtmklpbvAEIODW")
        let digits = Array("0123456789")
        for configuration in Self.configurations {
            let alphabet: [Character]
            if case .vni = configuration.inputMethod { alphabet = letters + digits } else { alphabet = letters }
            for _ in 0..<300 {
                let length = Int(generator.next() % 12) + 1
                var steps: [Step] = []
                for _ in 0..<length {
                    switch generator.next() % 10 {
                    case 0: steps.append(.backspace)
                    case 1: steps.append(.toggle)
                    default: steps.append(.key(alphabet[Int(generator.next() % UInt64(alphabet.count))]))
                    }
                }
                Self.expectSameStates(steps, configuration)
            }
        }
    }
}

/// Deterministic generator for the seeded sequences (no global state).
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
