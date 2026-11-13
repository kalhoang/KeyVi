// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// A seeded, weighted stream of events over the full alphabet of spec 13.6 (`FuzzAlphabet`).
///
/// Besides single random events it emits, with small probability, multi-event "moves" that random keys
/// rarely produce on their own: a word that exercises a commit rule, a macro trigger of the table
/// followed by a boundary, Backspace runs that walk back into the history, consecutive restore toggles,
/// and bursts of token keys with no boundary (long tokens, up to `maximumBurst` keys, ENG-R640, REG-02).
/// The stream depends only on the seed and the parameters (ENG-T33).
public struct FuzzEventSource: Sendable {
    /// The stream is for Telex (else VNI).
    public let isTelex: Bool
    /// Bracket keys are token keys (Telex option).
    public let bracketKeys: Bool
    /// Triggers of the macro table in use (typed as moves so that expansions are frequent).
    public let triggers: [String]
    /// The longest burst of token keys without a boundary.
    public let maximumBurst: Int

    private var generator: SeededGenerator
    private var pending: [EngineEvent] = []
    private var pendingIndex = 0

    /// Words that reach the interesting commit rules and composition paths with the 13.9 fixtures.
    private static let telexWords = [
        "vieejt", "dduwowcj", "nguwowif", "tuwowng", "thuowr", "huow", "cuwowis", "traffic", "password",
        "test", "tets", "this", "car", "is", "as", "did", "ddid", "ass", "www", "wifi", "USB", "useState",
        "iPhone", "Kroong", "DDawsk", "ddc", "DDL", "dzaayj", "heoj", "tar", "boooong", "nhaamff", "giuwax",
        "quys", "quz", "QUZ", "qqz", "Quzhou", "hoafn", "khoer", "thuyr", "uww", "aww", "[[", "]]", "w", "thw",
    ]
    private static let vniWords = [
        "vie65t", "d9uo7c5", "duoc795", "ba6c3", "a11", "d99", "a87", "qu0", "qut0", "Vie65t", "thuo73",
        "hoa2n", "nguye64n", "tie61ng", "o@gmail", "u7o7",
    ]

    /// A stream for `configuration` from `seed`; `triggers` are typed as moves, bursts stay within `maximumBurst` keys.
    public init(seed: UInt64, configuration: EngineConfiguration, triggers: [String] = [], maximumBurst: Int = 4_096) {
        generator = SeededGenerator(seed: seed)
        switch configuration.inputMethod {
        case .telex(let options):
            isTelex = true
            bracketKeys = options.bracketKeys
        case .vni:
            isTelex = false
            bracketKeys = false
        }
        self.triggers = triggers
        self.maximumBurst = maximumBurst
    }

    /// The next event.
    public mutating func next() -> EngineEvent {
        if pendingIndex == pending.count {
            pendingIndex = 0
            refill()
        }
        defer { pendingIndex += 1 }
        return pending[pendingIndex]
    }

    /// The next `count` events.
    public mutating func events(_ count: Int) -> [EngineEvent] {
        (0..<count).map { _ in next() }
    }

    /// One token key of the active method: a letter, a VNI digit, or a bracket key when enabled.
    public mutating func tokenKey() -> Character {
        let roll = generator.nextInt(below: 100)
        if !isTelex, roll < 25 { return generator.pick(FuzzAlphabet.digits) }
        if bracketKeys, roll < 4 { return generator.chance(1, in: 2) ? "[" : "]" }
        if roll < 70 { return generator.pick(FuzzAlphabet.composingLetters) }
        return generator.pick(FuzzAlphabet.letters)
    }

    private mutating func refill() {
        let roll = generator.nextInt(below: 1_000)
        switch roll {
        case 0..<8: burst()
        case 8..<50: word()
        case 50..<75 where !triggers.isEmpty: trigger()
        case 75..<90: backspaceRun()
        case 90..<95: pending = [.restoreToggle, .restoreToggle]
        default: pending = [single()]
        }
    }

    private mutating func single() -> EngineEvent {
        let roll = generator.nextInt(below: 100)
        switch roll {
        case 0..<42:
            let letter = generator.pick(FuzzAlphabet.composingLetters)
            return key(generator.chance(1, in: 10) ? Character(letter.uppercased()) : letter)
        case 42..<54: return key(generator.pick(FuzzAlphabet.letters))
        case 54..<63:
            return .key(KeyInput(generator.pick(FuzzAlphabet.digits), fromKeypad: generator.chance(1, in: 10)))
        case 63..<72: return key(generator.pick(FuzzAlphabet.spaces))
        case 72..<78: return key(generator.pick(FuzzAlphabet.punctuation))
        case 78..<80: return key(generator.pick(FuzzAlphabet.hardBoundaries))
        case 80..<82: return key(generator.pick(FuzzAlphabet.nonASCIILetters))
        case 82..<95: return .backspace
        case 95..<99: return .restoreToggle
        default: return .reset(generator.pick(FuzzAlphabet.resetReasons))
        }
    }

    /// A word that exercises a commit rule or a composition path, then a boundary.
    private mutating func word() {
        let word = generator.pick(isTelex ? Self.telexWords : Self.vniWords)
        let cased = generator.chance(1, in: 8) ? word.uppercased() : word
        pending = KeyNotation.events(cased) + [boundary()]
    }

    /// A macro trigger of the table, sometimes with adapted case, then a boundary.
    private mutating func trigger() {
        var text = generator.pick(triggers)
        switch generator.nextInt(below: 6) {
        case 0: text = text.uppercased()
        case 1: text = text.prefix(1).uppercased() + text.dropFirst()
        default: break
        }
        if generator.chance(1, in: 4) { text = " " + text }
        pending = text.map(key) + [boundary()]
        if generator.chance(1, in: 6) { pending += [.backspace, .backspace, .restoreToggle] }
    }

    /// Backspace runs walk back over boundaries into committed tokens (10.1).
    private mutating func backspaceRun() {
        pending = Array(repeating: .backspace, count: 1 + generator.nextInt(below: 8))
        if generator.chance(1, in: 3) { pending.append(key(generator.pick(FuzzAlphabet.composingLetters))) }
    }

    /// A long token (ENG-R640, ENG-R641, REG-02): up to `maximumBurst` token keys with occasional
    /// Backspace and restore toggles, then a boundary or a reset.
    private mutating func burst() {
        let lengths = [33, 63, 64, 65, 256, 1_000, 4_096, 100_000].filter { $0 <= maximumBurst }
        let length = lengths.isEmpty ? maximumBurst : generator.pick(lengths)
        let single = generator.chance(1, in: 4) ? tokenKey() : nil
        var events: [EngineEvent] = []
        events.reserveCapacity(length + 2)
        for _ in 0..<length {
            switch generator.nextInt(below: 200) {
            case 0: events.append(.backspace)
            case 1: events.append(.restoreToggle)
            default: events.append(key(single ?? tokenKey()))
            }
        }
        events.append(generator.chance(1, in: 10) ? .reset(.unknown) : boundary())
        pending = events
    }

    private mutating func boundary() -> EngineEvent {
        switch generator.nextInt(below: 10) {
        case 0..<6: return key(" ")
        case 6..<9: return key(generator.pick(FuzzAlphabet.punctuation))
        default: return key(generator.pick(FuzzAlphabet.hardBoundaries))
        }
    }

    private func key(_ character: Character) -> EngineEvent { .key(KeyInput(character)) }
}
