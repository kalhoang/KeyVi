// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// A broken invariant of spec 13.6 / QA-R7, with what is needed to reproduce it.
public struct FuzzViolation: Error, Sendable, Hashable, CustomStringConvertible {
    /// The requirement or property that failed (`ENG-T31`, `QA-R7 P2`...).
    public let invariant: String
    /// What was observed.
    public let detail: String
    /// Zero-based index of the event in the checked stream.
    public let eventIndex: Int
    /// The last events before and including the failing one, oldest first.
    public let recentEvents: [EngineEvent]

    /// A violation report.
    public init(invariant: String, detail: String, eventIndex: Int, recentEvents: [EngineEvent]) {
        self.invariant = invariant
        self.detail = detail
        self.eventIndex = eventIndex
        self.recentEvents = recentEvents
    }

    /// The invariant, the event index, the detail and the last events in corpus notation.
    public var description: String {
        "\(invariant) at event \(eventIndex): \(detail). Last events: \(KeyNotation.render(recentEvents))"
    }
}

/// Counters of a checked stream. `outputDigest` is an FNV-1a digest of every output, so two runs of the
/// same stream can be compared for determinism without storing the outputs (ENG-T33).
public struct FuzzStatistics: Sendable, Hashable {
    /// Events sent.
    public var events = 0
    /// Events that returned an edit.
    public var edits = 0
    /// Commits decided by the rules of 8.1.
    public var commits = 0
    /// Commits that restored the keys as typed.
    public var restoredCommits = 0
    /// Commits that kept the composed form.
    public var keptCommits = 0
    /// Macro expansions (ENG-R1103).
    public var macroExpansions = 0
    /// Reset events.
    public var resets = 0
    /// The most raw keys an active token held.
    public var longestToken = 0
    /// Restore-toggle probes made (ENG-T32).
    public var restoreChecks = 0
    /// Escape probes where the key applied (ENG-T36).
    public var escapeChecks = 0
    /// Replay comparisons of the cached composition (ENG-T33).
    public var replayChecks = 0
    /// Comparisons of `Engine.reduce` with `Session.handle` (ENG-T33).
    public var pureReduceChecks = 0
    /// Full comparisons of the field with the engine's view (ENG-T31).
    public var fullFieldChecks = 0
    /// The slowest event seen (QA-R7 P2).
    public var slowestEventNanoseconds: Int64 = 0
    /// Events slower than 1 ms (preemption included).
    public var eventsOverOneMillisecond = 0
    /// FNV-1a digest of every output, for determinism checks (ENG-T33).
    public var outputDigest: UInt64 = 0xCBF2_9CE4_8422_2325

    /// Empty statistics.
    public init() {}

    /// Adds the counters of `other` (the digest is combined, so the order of merging matters).
    public mutating func merge(_ other: FuzzStatistics) {
        events += other.events
        edits += other.edits
        commits += other.commits
        restoredCommits += other.restoredCommits
        keptCommits += other.keptCommits
        macroExpansions += other.macroExpansions
        resets += other.resets
        longestToken = max(longestToken, other.longestToken)
        restoreChecks += other.restoreChecks
        escapeChecks += other.escapeChecks
        replayChecks += other.replayChecks
        pureReduceChecks += other.pureReduceChecks
        fullFieldChecks += other.fullFieldChecks
        slowestEventNanoseconds = max(slowestEventNanoseconds, other.slowestEventNanoseconds)
        eventsOverOneMillisecond += other.eventsOverOneMillisecond
        digest(other.outputDigest)
    }

    mutating func digest(_ value: UInt64) {
        var hash = outputDigest
        for shift in stride(from: 0, to: 64, by: 8) {
            hash ^= (value >> UInt64(shift)) & 0xFF
            hash = hash &* 0x0000_0100_0000_01B3
        }
        outputDigest = hash
    }
}

/// Drives a `Session` and a simulated text field and checks the fuzz invariants of spec 13.6 after every
/// event:
///
/// - ENG-T30 / QA-R7 P1, P3: no trap; the history stays within `historyLimit` tokens and
///   `historyLimit x 64` entries.
/// - QA-R7 P2: no event takes longer than the hang threshold.
/// - ENG-T31 / P4: the field (passThrough inserts the key or deletes one character for Backspace, edits
///   applied exactly) ends with the engine's view (history plus active display), and no edit deletes
///   more characters than the engine produced or let through.
/// - ENG-T32 / P6: the restore toggle gives exactly the raw keys of the token, and toggling twice at the
///   token level gives the composed display back (the reducer passes a consecutive toggle through,
///   ENG-R702).
/// - ENG-T33: the cached composition equals a replay of its raw keys, and `Engine.reduce` on a copy of
///   the state gives the same output and state as `Session.handle`.
/// - ENG-T34 / P5: inserts contain no combining marks, engine-produced inserts only ASCII and the 146
///   precomposed letters (so they are NFC), an optional caller-supplied NFC check, and `deleteCount ==
///   deleteUTF16Count` for every edit.
/// - ENG-T35: in VNI every letter of the token comes from a letter typed in the token.
/// - ENG-T36: for a transform key K that applies to the token T, T + K + K ends with the literal K.
/// - ENG-T37: the letters of a composing token are viable.
/// - ENG-R710, ENG-R711: a Backspace on the active token leaves it with fewer characters than before (it
///   removes the last visible character; the replay never brings back keys as extra letters), or as
///   many when it removes an escaping key and the escaped effect comes back.
///
/// Checks that cost time proportional to the token are done every event for tokens up to a limit and
/// periodically beyond it, so tokens of 100,000 keys stay linear; the field tail is compared every event
/// over a window and in full periodically and at `finish()`.
public struct InvariantChecker: Sendable {
    /// What the checker compares, how often, and its thresholds.
    public struct Options: Sendable {
        /// Characters of the field tail compared after every event (the whole view when it is shorter).
        public var tailWindow = 48
        /// Full comparison of the field and the view, and replay checks of long tokens, every this many
        /// events.
        public var fullCheckInterval = 4_096
        /// Tokens up to this many raw keys get the replay, display and restore checks after every event.
        public var perEventTokenLimit = 256
        /// One escape probe (ENG-T36) every this many events on average.
        public var escapeCheckOneIn = 6
        /// One `Engine.reduce` comparison every this many events (small states only).
        public var pureReduceOneIn = 64
        /// QA-R7 P2 hang detector. Debug builds under parallel test load need a generous value; the
        /// release benchmark measures the 1 ms worst case of ENG-R1230.
        public var hangThresholdNanoseconds: Int64 = 250_000_000
        /// An extra NFC check of every insert (tests pass Foundation's normalisation).
        public var nfcCheck: (@Sendable (String) -> Bool)?
        /// Events kept for violation reports.
        public var reportWindow = 48
        /// Drops the field text before an empty engine view (bounded memory in long streams). Corpus runs
        /// keep the whole field.
        public var trimsField = true

        /// Empty statistics.
        public init() {}
    }

    /// The engine under test.
    public let engine: Engine
    /// The checker's options.
    public let options: Options
    /// The session the events go to.
    public private(set) var session: Session
    /// Counters of the stream so far.
    public private(set) var statistics = FuzzStatistics()

    private var field: [Character] = []
    private var recent: [EngineEvent] = []
    private var recentNext = 0
    private var probeGenerator: SeededGenerator
    private let rules: ComposerRules
    private let clock = ContinuousClock()

    /// A checker for `engine`; `probeSeed` drives the escape probes (ENG-T36).
    public init(engine: Engine, options: Options = Options(), probeSeed: UInt64 = 0xE5CA_9E00) {
        self.engine = engine
        self.options = options
        session = Session(engine: engine)
        rules = ComposerRules(engine.configuration)
        probeGenerator = SeededGenerator(seed: probeSeed)
    }

    /// The simulated field as a string.
    public var fieldText: String { String(field) }

    /// Sends one event and checks every invariant; throws the first violation.
    @discardableResult
    public mutating func send(_ event: EngineEvent) throws -> EngineOutput {
        let index = statistics.events
        remember(event)
        let produced = producedCount(before: event)
        let beforeBackspace = tokenCountBeforeBackspace(event, index: index)
        let before = takesPureReduceSample(index) ? session.state : nil
        let start = clock.now
        let output = session.handle(event)
        let elapsed = Self.nanoseconds(start.duration(to: clock.now))
        statistics.events += 1
        try record(elapsed, index: index)
        if let before { try checkPureReduce(before, event, output, index: index) }
        try checkEdit(output, produced: produced, index: index)
        try applyToField(event, output, index: index)
        try checkView(index: index)
        try checkBackspace(beforeBackspace, index: index)
        try checkState(output, index: index)
        try checkRestore(index: index)
        try checkEscape(index: index)
        count(output, event)
        trimField()
        return output
    }

    /// Sends every event in order.
    public mutating func send<S: Sequence>(_ events: S) throws where S.Element == EngineEvent {
        for event in events { try send(event) }
    }

    /// A full comparison of the field and the engine's view (ENG-T31), for the end of a stream.
    public mutating func finish() throws {
        try checkView(index: statistics.events, forceFull: true)
    }

    // MARK: - ENG-T31: the engine never deletes more than it produced

    /// The number of characters of the engine's view before the event, exact or capped. It is exact when
    /// the view is short, and for the events that can delete a whole long token (toggle, boundary,
    /// Backspace on a token of more than 64 keys); otherwise capped, which bounds every edit a composing
    /// token can make (at most 64 letters plus the key).
    private func producedCount(before event: EngineEvent) -> (count: Int, exact: Bool) {
        let state = session.state
        var mayDeleteLongToken = false
        if let token = state.active, token.composition.raw.count > Composition.composingKeyLimit || token.isMacro {
            switch event {
            case .restoreToggle, .backspace: mayDeleteLongToken = true
            case .key(let input):
                if case .boundary = TokenKey.classify(input, rules: rules) { mayDeleteLongToken = true }
            case .reset: break
            }
        }
        return viewCount(cap: mayDeleteLongToken ? nil : 4 * options.tailWindow)
    }

    private func viewCount(cap: Int?) -> (count: Int, exact: Bool) {
        let state = session.state
        let limit = cap ?? Int.max
        var count = 0
        for _ in state.activeDisplay.reversed() {
            count += 1
            if count > limit { return (count, false) }
        }
        for entry in state.history.entries.reversed() {
            switch entry {
            case .boundary: count += 1
            case .token(let committed):
                for _ in committed.committedText.reversed() {
                    count += 1
                    if count > limit { return (count, false) }
                }
            }
            if count > limit { return (count, false) }
        }
        return (count, true)
    }

    private mutating func checkEdit(_ output: EngineOutput, produced: (count: Int, exact: Bool), index: Int) throws {
        guard case .edit(let edit, _) = output.action else { return }
        statistics.edits += 1
        if edit.deleteCount < 0 || (produced.exact && edit.deleteCount > produced.count) {
            throw violation(
                "ENG-T31", "deletes \(edit.deleteCount) characters, the engine produced \(produced.count)", index)
        }
        if !produced.exact, edit.deleteCount >= produced.count {
            throw violation("ENG-T31", "a delete of \(edit.deleteCount) characters could not be verified", index)
        }
        // ENG-T34, ENG-R631.
        if edit.deleteCount != edit.deleteUTF16Count {
            throw violation(
                "ENG-T34", "deleteCount \(edit.deleteCount) != deleteUTF16Count \(edit.deleteUTF16Count)", index)
        }
        let isMacro = output.decision == .macro
        for scalar in edit.insert.unicodeScalars {
            if scalar.properties.canonicalCombiningClass.rawValue != 0 {
                throw violation("ENG-T34", "insert contains the combining mark U+\(Self.hex(scalar))", index)
            }
            // ENG-R102: the engine's own text is ASCII and the 146 precomposed letters only, so it is NFC.
            if !isMacro, scalar.value >= 0x80, LetterTable.glyph(for: scalar) == nil {
                throw violation("ENG-R102", "insert contains U+\(Self.hex(scalar)), not an engine letter", index)
            }
        }
        if let nfcCheck = options.nfcCheck, !nfcCheck(edit.insert) {
            throw violation("ENG-T34", "insert is not NFC", index)
        }
    }

    // MARK: - The simulated field

    private mutating func applyToField(_ event: EngineEvent, _ output: EngineOutput, index: Int) throws {
        switch output.action {
        case .passThrough:
            deliver(event)
        case .edit(let edit, let thenPassThrough):
            guard edit.deleteCount <= field.count else {
                throw violation(
                    "ENG-T31", "deletes \(edit.deleteCount) of \(field.count) characters in the field", index)
            }
            var units = 0
            for character in field.suffix(edit.deleteCount) { units += character.utf16.count }
            guard units == edit.deleteUTF16Count else {
                throw violation("ENG-R631", "deleteUTF16Count \(edit.deleteUTF16Count), the span has \(units)", index)
            }
            field.removeLast(edit.deleteCount)
            field.append(contentsOf: edit.insert)
            if thenPassThrough { deliver(event) }
        }
    }

    private mutating func deliver(_ event: EngineEvent) {
        switch event {
        case .key(let input): field.append(input.character)
        case .backspace: if !field.isEmpty { field.removeLast() }
        case .restoreToggle, .reset: break
        }
    }

    /// Text before an empty engine view is never compared again, so it is dropped (bounded memory).
    private mutating func trimField() {
        guard options.trimsField else { return }
        let state = session.state
        if state.active == nil, state.history.isEmpty { field.removeAll(keepingCapacity: true) }
    }

    /// ENG-T31: the field ends with the view. The comparison walks both backwards; it covers the whole
    /// view when it is shorter than the window, every `fullCheckInterval` events, and at `finish()`.
    private mutating func checkView(index: Int, forceFull: Bool = false) throws {
        let full = forceFull || index % options.fullCheckInterval == 0
        if full { statistics.fullFieldChecks += 1 }
        let limit = full ? Int.max : options.tailWindow
        let state = session.state
        var position = field.count
        var compared = 0
        func matches(_ text: String) -> Bool {
            for character in text.reversed() {
                if compared == limit { return true }
                position -= 1
                guard position >= 0, field[position] == character else { return false }
                compared += 1
            }
            return true
        }
        var ok = matches(state.activeDisplay)
        if ok {
            for entry in state.history.entries.reversed() where compared < limit {
                ok = matches(entry.text)
                if !ok { break }
            }
        }
        guard ok else {
            let tail = String(field.suffix(80))
            throw violation("ENG-T31", "field tail \(tail.debugDescription) differs from the view", index)
        }
    }

    // MARK: - ENG-R710: Backspace shortens the token

    /// The token before a Backspace: its display length and whether the Backspace removes only an escaping
    /// key (ENG-R711). Nil when the event is not a Backspace on a token. Counting is O(token), so long
    /// tokens are measured only periodically.
    private func tokenCountBeforeBackspace(_ event: EngineEvent, index: Int) -> (count: Int, removesEscape: Bool)? {
        guard case .backspace = event, let token = session.state.active,
            token.composition.raw.count <= options.perEventTokenLimit || index % options.fullCheckInterval == 0
        else { return nil }
        let composition = token.composition
        var removesEscape = false
        if !token.isMacro, !token.showsRawKeys {
            if let literalStart = composition.literalStart {
                // An escape that appends a non-letter (`ww`, `[[`, VNI `a11`) starts literal mode with its key.
                removesEscape = composition.escapeUsed && literalStart == composition.raw.count - 1
            } else {
                removesEscape = composition.letters.last?.flags.contains(.escape) ?? false
            }
        }
        return (token.display.count, removesEscape)
    }

    /// ENG-R710: Backspace removes the last visible character of the token, so the display gets shorter. A
    /// replay that turns the remaining keys into stray letters or digits (a tone key left behind by its
    /// letter) makes it as long or longer. ENG-R711: removing an escaping key brings the escaped effect
    /// back, so the length may stay (`ww` shows `w`, Backspace shows `ư`); it never grows.
    private func checkBackspace(_ before: (count: Int, removesEscape: Bool)?, index: Int) throws {
        guard let before else { return }
        let countAfter = session.state.activeDisplay.count
        guard countAfter < before.count || (before.removesEscape && countAfter == before.count) else {
            throw violation(
                "ENG-R710", "Backspace left \(countAfter) characters of a token of \(before.count)", index)
        }
    }

    // MARK: - State invariants

    private mutating func checkState(_ output: EngineOutput, index: Int) throws {
        let state = session.state
        let limit = engine.configuration.historyLimit
        // ENG-T30, QA-R7 P3: memory beyond the active token is bounded by the history limit.
        if state.history.tokenCount > limit || state.history.entries.count > History.entryLimit(forTokens: limit) {
            throw violation("ENG-T30", "history holds \(state.history.entries.count) entries", index)
        }
        // ENG-R620.
        if output.composingText != state.activeDisplay {
            throw violation("ENG-R620", "composingText differs from the active display", index)
        }
        guard let token = state.active, !token.isMacro else { return }
        let composition = token.composition
        statistics.longestToken = max(statistics.longestToken, composition.raw.count)
        let perEvent = composition.raw.count <= options.perEventTokenLimit
        if perEvent || index % options.fullCheckInterval == 0 {
            try checkReplay(token, index: index)
        }
        if !composition.isLiteral {
            // ENG-T37.
            if !ViabilityAutomaton.shared.isViable(composition.letters.map(\.letter)) {
                throw violation(
                    "ENG-T37", "composing letters of \(token.rawText.debugDescription) are not viable", index)
            }
        }
        if !rules.isTelex { try checkMethodIsolation(composition, index: index) }
    }

    /// ENG-T33, ENG-R601: the cached composition equals a replay of the raw keys, and the display is the
    /// one the flags call for.
    private mutating func checkReplay(_ token: ActiveToken, index: Int) throws {
        statistics.replayChecks += 1
        let replayed = Composition(replaying: token.composition.raw, rules: rules)
        guard replayed == token.composition else {
            throw violation(
                "ENG-T33", "cached composition differs from replay for \(token.rawText.debugDescription)", index)
        }
        if token.showsRawKeys {
            guard token.display == token.rawText else {
                throw violation("ENG-R701", "restored token does not show its raw keys", index)
            }
        } else {
            // A token re-opened by Backspace shows what its commit wrote (the ENG-R532 spelling) until the
            // next key recomputes it.
            let composed = replayed.display(style: rules.toneStyle)
            guard token.display == composed || token.display == replayed.committedText(style: rules.toneStyle) else {
                throw violation("ENG-R601", "display is not a function of the raw keys", index)
            }
        }
    }

    /// ENG-T35: in VNI every letter shown comes from a letter typed in the token (no Telex transform can
    /// leak in; `w` appears only if typed). Letters come only from keys before the literal start.
    private func checkMethodIsolation(_ composition: Composition, index: Int) throws {
        let composingKeys = composition.raw.prefix(composition.literalStart ?? composition.raw.count)
        var typed = Set<UInt8>()
        for key in composingKeys { typed.insert(ASCII.lowercased(key)) }
        for letter in composition.letters where !typed.contains(letter.letter.baseASCII) {
            throw violation("ENG-T35", "VNI shows a letter that was not typed", index)
        }
    }

    private mutating func checkPureReduce(
        _ before: EngineState, _ event: EngineEvent, _ output: EngineOutput, index: Int
    ) throws {
        statistics.pureReduceChecks += 1
        let (next, pureOutput) = engine.reduce(before, event)
        guard pureOutput == output, next == session.state else {
            throw violation("ENG-T33", "Engine.reduce and Session.handle disagree", index)
        }
    }

    private func takesPureReduceSample(_ index: Int) -> Bool {
        guard index % options.pureReduceOneIn == 0 else { return false }
        let state = session.state
        return (state.active?.composition.raw.count ?? 0) <= options.perEventTokenLimit
    }

    // MARK: - ENG-T32: restore is exact

    private mutating func checkRestore(index: Int) throws {
        let state = session.state
        // The size test comes first: comparing a long display with its raw keys is itself O(token).
        guard !state.previousEventWasRestoreToggle, let token = state.active,
            token.composition.raw.count <= options.perEventTokenLimit || index % options.fullCheckInterval == 0,
            token.display != token.rawText
        else { return }
        statistics.restoreChecks += 1
        let raw = token.rawText
        var probe = session
        let output = probe.handle(.restoreToggle)
        guard case .edit(let edit, thenPassThrough: false) = output.action, probe.state.activeDisplay == raw else {
            throw violation("ENG-T32", "the toggle does not show the raw keys \(raw.debugDescription)", index)
        }
        let display = Array(token.display)
        guard edit.deleteCount <= display.count, String(display.dropLast(edit.deleteCount)) + edit.insert == raw else {
            throw violation("ENG-T32", "the toggle's edit does not turn the display into the raw keys", index)
        }
        // Toggling twice returns the composed display (ENG-R701 second branch). The reducer passes a
        // consecutive toggle through (ENG-R702), so the second toggle is applied to the token directly.
        guard var restored = probe.state.active, !token.isMacro else { return }
        let composed = restored.composedDisplay(style: rules.toneStyle)
        guard composed != raw else { return }
        guard restored.toggleRestore(rules: rules) != nil, restored.display == composed else {
            throw violation("ENG-T32", "toggling twice does not give the composed display back", index)
        }
    }

    // MARK: - ENG-T36: escape by doubling

    private mutating func checkEscape(index: Int) throws {
        guard probeGenerator.chance(1, in: options.escapeCheckOneIn) else { return }
        let state = session.state
        guard let token = state.active, !token.isMacro, !token.showsRawKeys, !token.composition.isLiteral,
            token.composition.raw.count < Composition.composingKeyLimit - 2
        else { return }
        let key = transformKey()
        guard let byte = key.asciiValue, let kind = rules.role(of: byte).escapeKind,
            !token.composition.escapedKinds.contains(kind)
        else { return }
        var probe = session
        let letterCount = token.composition.letters.count
        let keyIndex = token.composition.raw.count
        _ = probe.handle(.key(KeyInput(key)))
        guard let after = probe.state.active?.composition, after.literalStart != keyIndex else { return }
        if after.letters.count == letterCount + 1, let last = after.letters.last, Int(last.source) == keyIndex,
            last.flags.isEmpty
        {
            return  // the key was appended as a letter: it did not apply
        }
        statistics.escapeChecks += 1
        _ = probe.handle(.key(KeyInput(key)))
        guard probe.state.activeDisplay.last == key else {
            throw violation(
                "ENG-T36",
                "\(token.rawText.debugDescription) + \(key)\(key) shows \(probe.state.activeDisplay.debugDescription)",
                index)
        }
    }

    private mutating func transformKey() -> Character {
        if !rules.isTelex { return probeGenerator.pick(FuzzAlphabet.digits) }
        var keys: [Character] = Array("sfrxjzaeowd")
        if rules.bracketKeys { keys += ["[", "]"] }
        let key = probeGenerator.pick(keys)
        return probeGenerator.chance(1, in: 5) ? Character(key.uppercased()) : key
    }

    // MARK: - Bookkeeping

    private mutating func record(_ elapsed: Int64, index: Int) throws {
        statistics.slowestEventNanoseconds = max(statistics.slowestEventNanoseconds, elapsed)
        if elapsed > 1_000_000 { statistics.eventsOverOneMillisecond += 1 }
        if elapsed > options.hangThresholdNanoseconds {
            throw violation("QA-R7 P2", "an event took \(elapsed / 1_000) µs", index)
        }
    }

    private mutating func count(_ output: EngineOutput, _ event: EngineEvent) {
        if case .reset = event { statistics.resets += 1 }
        switch output.decision {
        case .macro?: statistics.macroExpansions += 1
        case .restored?:
            statistics.commits += 1
            statistics.restoredCommits += 1
        case .kept?:
            statistics.commits += 1
            statistics.keptCommits += 1
        case nil: break
        }
        statistics.digest(Self.digest(output))
    }

    private static func digest(_ output: EngineOutput) -> UInt64 {
        var hash: UInt64 = 0x8422_2325
        func mix(_ value: UInt64) { hash = (hash ^ value) &* 0x0000_0100_0000_01B3 }
        switch output.action {
        case .passThrough: mix(1)
        case .edit(let edit, let thenPassThrough):
            mix(thenPassThrough ? 2 : 3)
            mix(UInt64(edit.deleteCount))
            mix(UInt64(edit.deleteUTF16Count))
            for byte in edit.insert.utf8 { mix(UInt64(byte)) }
        }
        let composing = output.composingText.utf8
        mix(UInt64(composing.count))
        for byte in composing.suffix(8) { mix(UInt64(byte)) }
        switch output.decision {
        case .macro?: mix(4)
        case .kept(let rule)?: mix(5 &+ UInt64(String(describing: rule).utf8.count))
        case .restored(let rule)?: mix(6 &+ UInt64(String(describing: rule).utf8.count))
        case nil: mix(7)
        }
        return hash
    }

    private mutating func remember(_ event: EngineEvent) {
        if recent.count < options.reportWindow {
            recent.append(event)
        } else {
            recent[recentNext] = event
        }
        recentNext = (recentNext + 1) % max(1, options.reportWindow)
    }

    private func violation(_ invariant: String, _ detail: String, _ index: Int) -> FuzzViolation {
        let ordered =
            recent.count < options.reportWindow ? recent : Array(recent[recentNext...] + recent[..<recentNext])
        return FuzzViolation(invariant: invariant, detail: detail, eventIndex: index, recentEvents: ordered)
    }

    private static func nanoseconds(_ duration: Duration) -> Int64 {
        let (seconds, attoseconds) = duration.components
        return seconds * 1_000_000_000 + attoseconds / 1_000_000_000
    }

    private static func hex(_ scalar: Unicode.Scalar) -> String {
        let digits = String(scalar.value, radix: 16, uppercase: true)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}
