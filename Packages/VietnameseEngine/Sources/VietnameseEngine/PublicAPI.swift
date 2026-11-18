// SPDX-License-Identifier: MPL-2.0
//
// Public API of the engine, as proposed in spec/01-engine.md section 12.2.
// The types and signatures are the contract shared by every track. Do not change a public signature
// without updating docs/architecture/contracts.md and every caller. Composition lives in Composition/
// and Engine/, commit rules (section 8) in Commit/, macros (section 11) in Macros/.

/// The input method: Telex with its two options, or VNI (ENG-R101).
public enum InputMethod: Sendable, Hashable {
    /// Telex (spec 4.1): letters for tones and modifiers.
    case telex(TelexOptions)
    /// VNI (spec 4.2): main-row digits for tones and modifiers.
    case vni
}

/// The two Telex options of spec 4.8. There are no other engine options in v1 (ENG-R450).
public struct TelexOptions: Sendable, Hashable {
    /// `w` typed while the token has no vowel yet is the vowel `ư` (`thw` -> `thư`). Default on (ENG-R103).
    public var standaloneW: Bool
    /// `[` types `ơ` and `]` types `ư`; when off, brackets are boundaries. Default off (ENG-R104).
    public var bracketKeys: Bool

    /// Telex options; the defaults are those of ENG-R103 and ENG-R104.
    public init(standaloneW: Bool = true, bracketKeys: Bool = false) {
        self.standaloneW = standaloneW
        self.bracketKeys = bracketKeys
    }
}

/// Tone placement for the open pairs `oa`, `oe`, `uy` (spec 5.2, ENG-R105).
public enum ToneStyle: Sendable, Hashable {
    /// `hòa`, `khỏe`, `thủy`. The default (ENG-R510).
    case traditional
    /// `hoà`, `khoẻ`, `thuỷ` (the textbook convention of Decision 1989/QĐ-BGDĐT).
    case modern
}

/// The kind of field the host is typing into (spec 8.6, ENG-R850). The engine never learns which app.
public enum AppContext: Sendable, Hashable {
    /// Every ordinary text field. The default.
    case general
    /// Terminals, IDEs and code editors: rule L9 restores code-only tech words (`tar`) outside Vietnamese text,
    /// so `tar -xzf` stays as typed and `chinhs tar` still gives `chính tả` (ENG-R850).
    case code
}

/// Everything that configures an engine (spec 12.2). Changing it means creating a new ``Engine`` and
/// sending ``ResetReason/configurationChanged`` (ENG-R1211).
public struct EngineConfiguration: Sendable, Hashable {
    /// Telex (with options) or VNI. Default: Telex with default options.
    public var inputMethod: InputMethod
    /// Traditional or modern tone placement. Default: traditional (ENG-R510).
    public var toneStyle: ToneStyle
    /// Restore non-Vietnamese words at commit (spec 8). Default on (ENG-R106). When off, rules L3b to L11
    /// never restore; the user's own choices (L1, L2) still apply (ENG-R802).
    public var autoRestore: Bool
    /// General or code context (ENG-R850). Default: general.
    public var appContext: AppContext
    /// Committed tokens kept for Backspace re-opening (ENG-R1001). Default 16, minimum 1.
    public var historyLimit: Int
    /// The context rules for words that are both English and Vietnamese (ENG-R829): rules L9a and L9b, the
    /// `run: vi` exemption of L10, the English-lean words of the window (ENG-R823), the revision of the
    /// previous token (ENG-R828) and its undo. Default on; the host passes the app's effective value. Off,
    /// the engine decides exactly as it did without them. The learned memory (L9c) is governed by
    /// `Resources.collisionMemory` (empty: off) and the collision signals are emitted either way (ENG-R864).
    public var lookaheadRevision: Bool
    /// The revision RV5 of the code context (ENG-R828, ENG-R850): a code-only word that rule L9 restored at the
    /// start of a line takes its Vietnamese display when the next word shows the line is Vietnamese text. Default
    /// on; the host passes the user's D29 switch alone, because the rules turn `lookaheadRevision` off in every
    /// code-context app (PLT-R357) while RV5 only completes L9's own line rule. Read only in the code context and
    /// with auto restore on; it does not depend on `lookaheadRevision`.
    public var lineStartRevision: Bool

    /// A configuration; every argument defaults to the spec's default. `historyLimit` is raised to 1 if
    /// smaller.
    public init(
        inputMethod: InputMethod = .telex(TelexOptions()),
        toneStyle: ToneStyle = .traditional,
        autoRestore: Bool = true,
        appContext: AppContext = .general,
        historyLimit: Int = 16,
        lookaheadRevision: Bool = true,
        lineStartRevision: Bool = true
    ) {
        self.inputMethod = inputMethod
        self.toneStyle = toneStyle
        self.autoRestore = autoRestore
        self.appContext = appContext
        self.historyLimit = max(1, historyLimit)
        self.lookaheadRevision = lookaheadRevision
        self.lineStartRevision = lineStartRevision
    }
}

/// One key as the host delivers it: a character after keyboard-layout mapping (spec 0, section 2). The
/// engine never sees key codes, so every layout works the same (REG-16).
public struct KeyInput: Sendable, Hashable {
    /// The character the key produced (`"a"`, `"A"`, `"6"`, `" "`, `"\n"`). Shifted digits arrive as
    /// their symbols (ENG-R402).
    public var character: Character
    /// The key is on the numeric keypad: its digits are boundaries, never VNI keys (ENG-R401).
    public var fromKeypad: Bool
    /// Caps Lock was on for this key. Keys with a case already arrive in their case (ENG-R902); only keys
    /// without case use it: a Telex bracket key then types an uppercase letter (ENG-R906).
    public var capsLock: Bool

    /// A key event for `character`.
    public init(_ character: Character, fromKeypad: Bool = false, capsLock: Bool = false) {
        self.character = character
        self.fromKeypad = fromKeypad
        self.capsLock = capsLock
    }
}

/// Why the host can no longer vouch for the text before the cursor (spec 10.2, ENG-R1010). Every reason
/// has the same effect: the token and the history are dropped and nothing is edited (ENG-R1011).
public enum ResetReason: Sendable, Hashable {
    /// Arrow keys, Home, End, Page Up or Down, with or without modifiers.
    case cursorMoved
    /// A mouse click in the text area.
    case pointerClicked
    /// Focus moved to another field.
    case focusChanged
    /// Another application became active.
    case applicationChanged
    /// The input source changed.
    case inputSourceChanged
    /// Secure Event Input turned on or off.
    case secureInputChanged
    /// The event tap was re-enabled after a timeout (REG-22).
    case eventTapReenabled
    /// A shortcut with Command or Control.
    case shortcut
    /// Forward Delete.
    case forwardDelete
    /// The Vietnamese/English mode toggle.
    case modeToggled
    /// A new engine configuration (ENG-R1211).
    case configurationChanged
    /// Any other case where the host cannot vouch for the text.
    case unknown
    /// Input reached the app that the host never saw (a keyUp without its keyDown, PLT-R397A).
    case unseenInput
}

/// One input to ``Engine/reduce(_:_:)``.
public enum EngineEvent: Sendable, Hashable {
    /// A typed character.
    case key(KeyInput)
    /// Backspace (sections 7.4 and 10.1).
    case backspace
    /// The restore toggle (section 7.2, ENG-R108); the host sends it only when the user binds a hotkey.
    case restoreToggle
    /// The host's picture of the text is no longer reliable (section 10.2).
    case reset(ResetReason)
}

/// Text replacement before the cursor (spec 6.2, 6.4): delete, then insert.
public struct TextEdit: Sendable, Hashable {
    /// User-perceived characters (grapheme clusters) to delete before the cursor; only text the engine
    /// produced or let through (ENG-R630).
    public var deleteCount: Int
    /// The same span in UTF-16 code units, for accessibility and marked-text hosts (ENG-R631). Equal to
    /// `deleteCount` for every engine-produced span.
    public var deleteUTF16Count: Int
    /// Text to insert after the deletion: NFC, precomposed letters only (ENG-R102); may be empty.
    public var insert: String

    /// An edit.
    public init(deleteCount: Int, deleteUTF16Count: Int, insert: String) {
        self.deleteCount = deleteCount
        self.deleteUTF16Count = deleteUTF16Count
        self.insert = insert
    }
}

/// What the host does with the original key (ENG-R610).
public enum KeyAction: Sendable, Hashable {
    /// Deliver the original key unchanged (for Backspace: the app deletes one character).
    case passThrough
    /// Apply the edit; then deliver the original key if `thenPassThrough` (boundaries: the space or
    /// punctuation reaches the app as a real key, ENG-R803). An empty edit without pass-through swallows
    /// the key.
    case edit(TextEdit, thenPassThrough: Bool)
}

/// The rule of spec 8.1 that decided a commit (ENG-R801). Reason codes carry no text (ENG-R1220).
public enum CommitRule: Sendable, Hashable {
    /// L0: the committed display equals the keys typed.
    case unchanged
    /// L1: the user toggled the token (user-restored or user-kept).
    case userChoice
    /// L2: the keys are in the user's keep-as-typed or keep-Vietnamese list.
    case userList
    /// L3: no vowel letter (`đc`, `ĐL`): kept.
    case abbreviation
    /// L3b: camel-case keys (`useState`, ENG-R904): restored.
    case camelCase
    /// L4: an escape by doubling was used in the token.
    case escape
    /// L4a: a tone-removal key (Telex `z`, VNI `0`) removed the tone or the letter marks: kept, unless the keys are
    /// English (ENG-R411, REG-39).
    case toneRemoval
    /// L5: the display is not a syllable of Tier A or B: restored.
    case invalid
    /// L6: Tier B only; restored when the keys are English.
    case extendedSpelling
    /// L7: valid Tier A and the keys are not English: kept.
    case notEnglish
    /// L8: English keys whose display is not an attested syllable: restored.
    case notAttested
    /// L9: code context and a code-only tech word outside Vietnamese text: restored (ENG-R850).
    case codeContext
    /// L9a: a boundary particle (`as`) ended by `.`, `!`, `?` or Return: kept (ENG-R825).
    case boundaryParticle
    /// L9b: the token continues a bundled English phrase with the previous tokens: restored (ENG-R826).
    case phrase
    /// L9c: the learned memory voted for this word in this context (ENG-R863).
    case learned
    /// L10: the run is in English (ENG-R823): restored.
    case englishRun
    /// L11: the ambiguity table row decided (`en` restores, `vi` keeps).
    case ambiguityTable
    /// L11 without a row: a tech-always word, restored.
    case techList
    /// L11 without a row: kept as Vietnamese.
    case defaultVietnamese
}

/// The outcome of a commit at a boundary (spec 8.1, section 11).
public enum CommitDecision: Sendable, Hashable {
    /// The composed form was kept.
    case kept(CommitRule)
    /// The keys as typed replaced the composed form.
    case restored(CommitRule)
    /// A macro trigger was expanded (ENG-R1103, ENG-R1104).
    case macro
}

/// The user's text expansions (spec section 11). Matching is on the keys as typed, ignoring case, in
/// constant time whatever the table size (ENG-R1105).
public struct MacroTable: Sendable {
    /// One macro.
    public struct Entry: Sendable, Hashable {
        /// 1 to 32 printable ASCII characters without whitespace (ENG-R1101).
        public var trigger: String
        /// NFC text of at most 4,000 characters, newlines allowed (ENG-R1101). The host normalises it.
        public var expansion: String
        /// Adapt the expansion to the case the trigger was typed in (ENG-R1103). Default true.
        public var adaptCase: Bool

        /// A macro entry.
        public init(trigger: String, expansion: String, adaptCase: Bool = true) {
            self.trigger = trigger
            self.expansion = expansion
            self.adaptCase = adaptCase
        }
    }

    /// Why a table was rejected. The associated values are triggers, never expansions (ENG-R1106).
    public enum ValidationError: Error, Sendable, Hashable {
        /// A trigger is empty.
        case emptyTrigger(String)
        /// A trigger is longer than 32 characters.
        case triggerTooLong(String)
        /// A trigger contains whitespace or a character outside printable ASCII.
        case invalidTriggerCharacter(String)
        /// An expansion is longer than 4,000 characters.
        case expansionTooLong(String)
        /// Two triggers are equal ignoring case.
        case duplicateTrigger(String)
        /// `trigger` is `shorter` plus punctuation, so it could never fire (ENG-R1103).
        case shadowedByShorterTrigger(trigger: String, shorter: String)
    }

    package let entries: [Entry]
    /// Lowercased trigger -> index into `entries` (ENG-R1105).
    let lookup: [MacroKey: Int]

    /// Validates the entries (ENG-R1101, ENG-R1103) and builds the lookup. Throws the first problem, in
    /// entry order.
    public init(_ entries: [Entry]) throws {
        self.lookup = try Self.validatedLookup(entries)
        self.entries = entries
    }

    private init(entries: [Entry], lookup: [MacroKey: Int]) {
        self.entries = entries
        self.lookup = lookup
    }

    /// The table the engine ships with: no macros (ENG-R110).
    public static let empty = MacroTable(entries: [], lookup: [:])
}

/// A hint for the host's user lists (ENG-R861), sent when the user's toggle disagreed with the rules.
/// The engine never stores it.
public enum LearningSignal: Sendable, Hashable {
    /// The user restored a word the rules would keep: a candidate for the keep-as-typed list.
    case preferredRaw(raw: String)
    /// The user kept a word the rules would restore: a candidate for the keep-Vietnamese list.
    case preferredVietnamese(raw: String)
}

/// The result of one event (spec 6.2, 6.3).
public struct EngineOutput: Sendable, Hashable {
    /// What the host does with the original key.
    public var action: KeyAction
    /// The full display of the active token, empty when there is none, for marked-text hosts (ENG-R620).
    public var composingText: String
    /// Set when the event committed a token or expanded a macro (ENG-R801).
    public var decision: CommitDecision?
    /// Set when a toggled token was committed against the rules (ENG-R861).
    public var learning: LearningSignal?
    /// Set when the commit also revised the previous token (ENG-R828): `action` is then one edit that covers
    /// the previous token, its separator and the current token (ENG-R803).
    public var revision: RevisionReason?
    /// Learning signals for words of the bundled collision list (ENG-R864); empty for most events.
    public var collisionSignals: [CollisionSignal]

    /// An output.
    public init(
        action: KeyAction, composingText: String, decision: CommitDecision? = nil,
        learning: LearningSignal? = nil, revision: RevisionReason? = nil, collisionSignals: [CollisionSignal] = []
    ) {
        self.action = action
        self.composingText = composingText
        self.decision = decision
        self.learning = learning
        self.revision = revision
        self.collisionSignals = collisionSignals
    }
}

/// Everything the engine knows about the text before the cursor: the active token, the history of the
/// run and the restore-toggle flag. A value: the host keeps it and passes it back (spec 2).
public struct EngineState: Sendable, Hashable {
    /// The state of an empty field, and after every reset (ENG-R1011, ENG-R1012).
    public static let initial = EngineState()

    /// The token being composed; nil between tokens (after a boundary, a reset, or when Backspace
    /// removed its last key).
    package var active: ActiveToken?
    /// The committed tokens and boundary characters of the run (section 10).
    package var history = History()
    /// The previous event was a restore toggle (ENG-R702).
    package var previousEventWasRestoreToggle = false
    /// The languages of the last three committed tokens of the run (ENG-R823). Kept across Return and Tab
    /// (the run goes on), cleared by a reset.
    package var recentLanguages = RecentLanguages()
    /// The newest committed token may still be revised by the next commit (ENG-R828): set by every commit,
    /// cleared by a restore toggle, a Backspace into the history, a macro expansion and a reset.
    package var newestTokenRevisable = false
    /// The previous event was a commit that revised the token before it; a restore toggle now undoes the
    /// revision (ENG-R829).
    package var previousEventRevised = false
    /// The weak signals of the newest committed tokens, not yet final (ENG-R864).
    package var pendingSignals = PendingSignals()

    init() {}

    /// The display of the active token (6.1), empty when there is none. After Backspace re-opens a
    /// committed token (ENG-R1002) it is the text that commit left on screen.
    public var activeDisplay: String { active?.display ?? "" }
    /// The raw keys of the active token exactly as typed (ENG-R602); for a re-opened macro expansion the
    /// span as typed (ENG-R1104).
    public var activeRawKeys: String { active?.rawText ?? "" }
    /// The active token is in literal mode (4.5), shows its raw keys (ENG-R701) or is a re-opened macro
    /// expansion (ENG-R1104).
    public var isLiteral: Bool { active?.isLiteral ?? false }
    /// Committed tokens kept in the history (ENG-R1001); a macro expansion counts as one token
    /// (ENG-R1104). A re-opened token is active, not in the history.
    public var historyCount: Int { history.tokenCount }
}

/// An immutable set of lowercase words (spec 8.2) with hash lookups (ENG-R1232).
public struct WordSet: Sendable {
    let storage: Set<String>
    /// The longest word in UTF-8 bytes: a longer word is rejected without hashing it, so a lookup costs
    /// O(1) for the long literal tokens of REG-02 (ENG-R1232).
    let maximumUTF8Count: Int

    /// A set of `words`; duplicates are ignored.
    public init<S: Sequence>(_ words: S) where S.Element == String {
        storage = Set(words)
        maximumUTF8Count = storage.reduce(0) { max($0, $1.utf8.count) }
    }

    /// Whether `word` is in the set (exact match; callers pass lowercased text).
    public func contains(_ word: some StringProtocol) -> Bool {
        word.utf8.count <= maximumUTF8Count && storage.contains(String(word))
    }

    /// The set's own string equal to `word`, nil when it is not in the set (ENG-R866).
    func member(_ word: String) -> String? {
        guard word.utf8.count <= maximumUTF8Count, let index = storage.firstIndex(of: word) else { return nil }
        return storage[index]
    }
}

/// A decision of the ambiguity table (spec 8.3, ENG-R821).
public enum Language: Sendable, Hashable {
    /// Keep the Vietnamese form.
    case vietnamese
    /// Restore the keys as typed.
    case english
}

/// The data the restore policy of spec 8.1 reads, supplied by the host (the bundled lists of
/// VietnameseEngineData and the user's own lists, ENG-R812, ENG-R860).
public struct Resources: Sendable {
    /// Common English words, lowercase ASCII ("R is English", 8.1).
    public var english: WordSet
    /// Words that always stay as typed (`wifi`, `usb`); also count as English.
    public var techAlways: WordSet
    /// Shell words restored only in the code context, outside Vietnamese text (rule L9, ENG-R850).
    public var techCodeOnly: WordSet
    /// Code-only words that configuration and protocol text writes capitalized at the start of a line (`host`):
    /// rule L9 still restores them there in sentence case, where it leaves other words to the rules after it
    /// (ENG-R850 as amended on 16/11/2026).
    public var techCodeCapitalized: WordSet
    /// Vietnamese syllables that occur, lowercase with tone (rule L8 only, never to block typing).
    public var attestedSyllables: WordSet
    /// The ambiguity table: lowercased raw keys -> decision (rule L11). Unreviewed rows behave as `vi`.
    public var ambiguity: [String: Language]
    /// The user's keep-as-typed list, lowercased raw keys (rule L2).
    public var userKeepRaw: WordSet
    /// The user's keep-Vietnamese list, lowercased raw keys (rule L2).
    public var userKeepVietnamese: WordSet
    /// The user's macros (section 11); empty when the host disables macros for the field (ENG-R1107).
    public var macros: MacroTable
    /// The bundled lists of the collision rules (ENG-R825 to ENG-R828).
    public var collision: CollisionLists
    /// The host's learned memory for collision words (ENG-R865); the engine only reads it.
    public var collisionMemory: CollisionMemorySnapshot

    /// Resources from the given lists.
    public init(
        english: WordSet, techAlways: WordSet, techCodeOnly: WordSet, techCodeCapitalized: WordSet = WordSet([]),
        attestedSyllables: WordSet, ambiguity: [String: Language],
        userKeepRaw: WordSet, userKeepVietnamese: WordSet,
        macros: MacroTable = .empty, collision: CollisionLists = .empty,
        collisionMemory: CollisionMemorySnapshot = .empty
    ) {
        self.english = english
        self.techAlways = techAlways
        self.techCodeOnly = techCodeOnly
        self.techCodeCapitalized = techCodeCapitalized
        self.attestedSyllables = attestedSyllables
        self.ambiguity = ambiguity
        self.userKeepRaw = userKeepRaw
        self.userKeepVietnamese = userKeepVietnamese
        self.macros = macros
        self.collision = collision
        self.collisionMemory = collisionMemory
    }

    /// No word lists and no macros: the rules that need data never match (tests, and a host without
    /// bundled data).
    public static let empty = Resources(
        english: WordSet([]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
        attestedSyllables: WordSet([]), ambiguity: [:],
        userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
}

/// The Vietnamese composition engine: a pure function from (state, event) to (state, output) for one
/// configuration and one set of resources (spec section 2, 12.2). No global state, no I/O, no clock
/// (ENG-R1202, ENG-R1210).
public struct Engine: Sendable {
    /// The configuration this engine was created with (fixed, ENG-R1211).
    public let configuration: EngineConfiguration
    /// The resources this engine reads at commit.
    public let resources: Resources
    /// The composition rules derived from `configuration` once (Engine/Reducer.swift).
    package let rules: ComposerRules
    /// The restore policy of 8.1 for this configuration and these resources (Commit/CommitRules.swift).
    package let commitPolicy: CommitPolicy
    /// A value read from every generated table (Engine/Reducer.swift `prepareSharedTables`), stored so
    /// that the tables' one-time construction cannot be optimised away from `init`.
    package let preparedTables: Int

    /// An engine. The first engine of a process also builds the generated tables (about 12 ms on an
    /// Apple M4 in a release build), so the host should create it at launch, not in the event tap.
    public init(configuration: EngineConfiguration, resources: Resources) {
        self.configuration = configuration
        self.resources = resources
        self.rules = ComposerRules(configuration)
        self.commitPolicy = CommitPolicy(resources: resources, configuration: configuration)
        self.preparedTables = Self.prepareSharedTables(rules)
    }

    /// The pure reducer of section 2: deterministic and side-effect free (ENG-R1210). Same state and
    /// event, same result. ``Session/handle(_:)`` gives the same result without copying the state.
    public func reduce(_ state: EngineState, _ event: EngineEvent) -> (EngineState, EngineOutput) {
        var next = state
        let output = process(&next, event)
        return (next, output)
    }
}

/// An engine and the state of one text field, updated in place.
public struct Session: Sendable {
    /// The engine of this session.
    public let engine: Engine
    /// The current state; replaced by every ``handle(_:)``.
    public private(set) var state: EngineState

    /// A session starting from `state` (by default an empty field).
    public init(engine: Engine, state: EngineState = .initial) {
        self.engine = engine
        self.state = state
    }

    /// Same result as `engine.reduce(state, event)`, computed in place (no copy of the state), so long
    /// tokens grow without copies (ENG-R640, ENG-R1230).
    public mutating func handle(_ event: EngineEvent) -> EngineOutput {
        engine.process(&state, event)
    }
}

/// The tier of a syllable (spec 3.12).
public enum Validity: Sendable, Hashable {
    /// Tier A: standard Vietnamese.
    case standard
    /// Tier B: names, loans, colloquial and teencode spellings (`Krông`, `buýt`, `dzô`), not Tier A.
    case extended
    /// Neither: restored at commit (rule L5).
    case invalid
}

/// The six tones, numbered 0 to 5 as in spec 3.2.
public enum Tone: Int, Sendable, Hashable {
    /// Ngang: no mark.
    case level
    /// Sắc: acute.
    case acute
    /// Huyền: grave.
    case grave
    /// Hỏi: hook above.
    case hook
    /// Ngã: tilde.
    case tilde
    /// Nặng: dot below.
    case dot
}

/// The parse and classification of one word (spec 3.13), for the diagnostics window and tests
/// (ENG-R1212).
public struct SyllableAnalysis: Sendable, Hashable {
    /// The onset letters (`ngh`, `qu`, `gi`), lowercase; empty when there is none.
    public var onset: String
    /// The vowel letters after the onset, without tone marks.
    public var vowelGroup: String
    /// The consonant coda letters; empty when there is none.
    public var coda: String
    /// The tone the word carries.
    public var tone: Tone
    /// Tier A, Tier B or invalid.
    public var validity: Validity
    /// The offset, in characters, of the letter that carries the tone; nil without a tone.
    public var toneLetterOffset: Int?

    /// An analysis.
    public init(
        onset: String, vowelGroup: String, coda: String, tone: Tone, validity: Validity,
        toneLetterOffset: Int?
    ) {
        self.onset = onset
        self.vowelGroup = vowelGroup
        self.coda = coda
        self.tone = tone
        self.validity = validity
        self.toneLetterOffset = toneLetterOffset
    }
}

// `Orthography` (analyze, validity) lives in Orthography/Orthography.swift.
