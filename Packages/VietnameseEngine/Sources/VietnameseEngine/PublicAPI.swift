// SPDX-License-Identifier: MPL-2.0
//
// Public API of the engine, as proposed in spec/01-engine.md section 12.2.
// The types and signatures are the contract shared by every track. Do not change a public signature
// without updating docs/architecture/contracts.md and every caller. Composition lives in Composition/
// and Engine/, commit rules (section 8) in Commit/, macros (section 11) in Macros/.

public enum InputMethod: Sendable, Hashable {
    case telex(TelexOptions)
    case vni
}

public struct TelexOptions: Sendable, Hashable {
    public var standaloneW: Bool  // default true (ENG-R103)
    public var bracketKeys: Bool  // default false (ENG-R104)
    public init(standaloneW: Bool = true, bracketKeys: Bool = false) {
        self.standaloneW = standaloneW
        self.bracketKeys = bracketKeys
    }
}

public enum ToneStyle: Sendable, Hashable { case traditional, modern }
public enum AppContext: Sendable, Hashable { case general, code }

public struct EngineConfiguration: Sendable, Hashable {
    public var inputMethod: InputMethod
    public var toneStyle: ToneStyle
    public var autoRestore: Bool
    public var appContext: AppContext
    public var historyLimit: Int
    public init(
        inputMethod: InputMethod = .telex(TelexOptions()),
        toneStyle: ToneStyle = .traditional,
        autoRestore: Bool = true,
        appContext: AppContext = .general,
        historyLimit: Int = 16
    ) {
        self.inputMethod = inputMethod
        self.toneStyle = toneStyle
        self.autoRestore = autoRestore
        self.appContext = appContext
        self.historyLimit = max(1, historyLimit)
    }
}

public struct KeyInput: Sendable, Hashable {
    public var character: Character
    public var fromKeypad: Bool
    public init(_ character: Character, fromKeypad: Bool = false) {
        self.character = character
        self.fromKeypad = fromKeypad
    }
}

public enum ResetReason: Sendable, Hashable {
    case cursorMoved, pointerClicked, focusChanged, applicationChanged,
        inputSourceChanged, secureInputChanged, eventTapReenabled,
        shortcut, forwardDelete, modeToggled, configurationChanged, unknown
}

public enum EngineEvent: Sendable, Hashable {
    case key(KeyInput)
    case backspace
    case restoreToggle
    case reset(ResetReason)
}

public struct TextEdit: Sendable, Hashable {
    public var deleteCount: Int  // grapheme clusters before the cursor (ENG-R630)
    public var deleteUTF16Count: Int  // the same span in UTF-16 code units (ENG-R631)
    public var insert: String  // NFC, may be empty
    public init(deleteCount: Int, deleteUTF16Count: Int, insert: String) {
        self.deleteCount = deleteCount
        self.deleteUTF16Count = deleteUTF16Count
        self.insert = insert
    }
}

public enum KeyAction: Sendable, Hashable {
    case passThrough
    case edit(TextEdit, thenPassThrough: Bool)
}

public enum CommitRule: Sendable, Hashable {
    case unchanged, userChoice, userList, abbreviation, camelCase, escape,
        invalid, extendedSpelling, notEnglish, notAttested,
        codeContext, englishRun, ambiguityTable, techList, defaultVietnamese
}

public enum CommitDecision: Sendable, Hashable {
    case kept(CommitRule)
    case restored(CommitRule)
    case macro  // section 11
}

public struct MacroTable: Sendable {
    public struct Entry: Sendable, Hashable {
        public var trigger: String  // 1...32 printable ASCII, no whitespace
        public var expansion: String  // NFC, at most 4,000 characters
        public var adaptCase: Bool  // default true
        public init(trigger: String, expansion: String, adaptCase: Bool = true) {
            self.trigger = trigger
            self.expansion = expansion
            self.adaptCase = adaptCase
        }
    }

    public enum ValidationError: Error, Sendable, Hashable {
        case emptyTrigger(String)
        case triggerTooLong(String)
        case invalidTriggerCharacter(String)
        case expansionTooLong(String)
        case duplicateTrigger(String)
        case shadowedByShorterTrigger(trigger: String, shorter: String)
    }

    let entries: [Entry]
    /// Lowercased trigger -> index into `entries` (ENG-R1105).
    let lookup: [MacroKey: Int]

    /// Validates the table (ENG-R1101, ENG-R1103; Macros/MacroTable+Validation.swift).
    public init(_ entries: [Entry]) throws {
        self.lookup = try Self.validatedLookup(entries)
        self.entries = entries
    }

    init(validated entries: [Entry]) {
        self.entries = entries
        self.lookup = Self.unvalidatedLookup(entries)
    }

    public static let empty = MacroTable(validated: [])
}

public enum LearningSignal: Sendable, Hashable {
    case preferredRaw(raw: String)
    case preferredVietnamese(raw: String)
}

public struct EngineOutput: Sendable, Hashable {
    public var action: KeyAction
    public var composingText: String
    public var decision: CommitDecision?
    public var learning: LearningSignal?
    public init(
        action: KeyAction, composingText: String, decision: CommitDecision? = nil,
        learning: LearningSignal? = nil
    ) {
        self.action = action
        self.composingText = composingText
        self.decision = decision
        self.learning = learning
    }
}

public struct EngineState: Sendable, Hashable {
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

public struct WordSet: Sendable {
    let storage: Set<String>
    public init<S: Sequence>(_ words: S) where S.Element == String { storage = Set(words) }
    public func contains(_ word: some StringProtocol) -> Bool { storage.contains(String(word)) }
}

public enum Language: Sendable, Hashable { case vietnamese, english }

public struct Resources: Sendable {
    public var english: WordSet
    public var techAlways: WordSet
    public var techCodeOnly: WordSet
    public var attestedSyllables: WordSet
    public var ambiguity: [String: Language]
    public var userKeepRaw: WordSet
    public var userKeepVietnamese: WordSet
    public var macros: MacroTable

    public init(
        english: WordSet, techAlways: WordSet, techCodeOnly: WordSet,
        attestedSyllables: WordSet, ambiguity: [String: Language],
        userKeepRaw: WordSet, userKeepVietnamese: WordSet,
        macros: MacroTable = .empty
    ) {
        self.english = english
        self.techAlways = techAlways
        self.techCodeOnly = techCodeOnly
        self.attestedSyllables = attestedSyllables
        self.ambiguity = ambiguity
        self.userKeepRaw = userKeepRaw
        self.userKeepVietnamese = userKeepVietnamese
        self.macros = macros
    }

    public static let empty = Resources(
        english: WordSet([]), techAlways: WordSet([]), techCodeOnly: WordSet([]),
        attestedSyllables: WordSet([]), ambiguity: [:],
        userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([]))
}

public struct Engine: Sendable {
    public let configuration: EngineConfiguration
    public let resources: Resources
    /// The composition rules derived from `configuration` once (Engine/Reducer.swift).
    package let rules: ComposerRules
    /// The restore policy of 8.1 for this configuration and these resources (Commit/CommitRules.swift).
    package let commitPolicy: CommitPolicy

    public init(configuration: EngineConfiguration, resources: Resources) {
        self.configuration = configuration
        self.resources = resources
        self.rules = ComposerRules(configuration)
        self.commitPolicy = CommitPolicy(resources: resources, configuration: configuration)
    }

    /// The pure reducer of section 2 (ENG-R1210). The work is done by `process(_:_:)`.
    public func reduce(_ state: EngineState, _ event: EngineEvent) -> (EngineState, EngineOutput) {
        var next = state
        let output = process(&next, event)
        return (next, output)
    }
}

public struct Session: Sendable {
    public let engine: Engine
    public private(set) var state: EngineState

    public init(engine: Engine, state: EngineState = .initial) {
        self.engine = engine
        self.state = state
    }

    /// Same result as `engine.reduce(state, event)`, computed in place (no copy of the state).
    public mutating func handle(_ event: EngineEvent) -> EngineOutput {
        engine.process(&state, event)
    }
}

public enum Validity: Sendable, Hashable { case standard, extended, invalid }
public enum Tone: Int, Sendable, Hashable { case level, acute, grave, hook, tilde, dot }

public struct SyllableAnalysis: Sendable, Hashable {
    public var onset: String
    public var vowelGroup: String
    public var coda: String
    public var tone: Tone
    public var validity: Validity
    public var toneLetterOffset: Int?  // offset in characters, nil if no tone
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
