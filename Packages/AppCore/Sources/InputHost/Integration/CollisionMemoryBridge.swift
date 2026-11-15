// SPDX-License-Identifier: GPL-3.0-or-later
//
// Engine <-> store vocabulary for the learned collision memory (ENG-R863 to ENG-R866, PLT-R914). SettingsStore keeps
// the counters without depending on the engine; the engine reads an immutable snapshot (ENG-R865) and emits signals
// (ENG-R864). The words are bundled vocabulary; they are content all the same and are never logged (PLT-R901).

internal import RealtimeSupport
internal import SettingsStore
internal import VietnameseEngine

enum CollisionMemoryBridge {
    /// The store's votes as the engine's snapshot (conflicts included: a context entry in conflict hides the
    /// any-context entry, ENG-R863).
    static func snapshot(_ votes: [CollisionMemoryVote]) -> CollisionMemorySnapshot {
        CollisionMemorySnapshot(
            votes.map {
                CollisionMemorySnapshot.Vote(word: $0.word, context: context($0.context), choice: choice($0.choice))
            })
    }

    /// The engine's signals as the store records them.
    static func signals(_ signals: [CollisionSignal]) -> [CollisionMemorySignal] {
        signals.map {
            CollisionMemorySignal(
                word: $0.word, context: context($0.context), side: $0.side == .english ? .english : .vietnamese,
                strength: $0.strength == .strong ? .strong : .weak)
        }
    }

    static func context(_ context: CollisionMemoryContext?) -> CollisionContext? {
        switch context {
        case .sentenceStart?: .sentenceStart
        case .afterVietnamese?: .afterVietnamese
        case .afterEnglish?: .afterEnglish
        case .afterNeutral?: .afterNeutral
        case nil: nil
        }
    }

    static func context(_ context: CollisionContext) -> CollisionMemoryContext {
        switch context {
        case .sentenceStart: .sentenceStart
        case .afterVietnamese: .afterVietnamese
        case .afterEnglish: .afterEnglish
        case .afterNeutral: .afterNeutral
        }
    }

    static func choice(_ choice: CollisionMemoryChoice) -> CollisionVote {
        switch choice {
        case .english: .english
        case .vietnamese: .vietnamese
        case .conflict: .conflict
        }
    }
}

/// For the learned-words sheet (PRD-R78): the Vietnamese reading of a collision word (`as` -> `á`), computed by the
/// engine from the bundled word itself with Telex and no restore, so the sheet never stores or shows anything the
/// user typed.
public enum CollisionWordReading {
    private static let engine = Engine(
        configuration: EngineConfiguration(inputMethod: .telex(TelexOptions()), autoRestore: false),
        resources: .empty)

    /// The display of `word` typed key by key; the word itself when it does not compose.
    public static func vietnamese(_ word: String) -> String {
        var session = Session(engine: engine)
        for character in word { _ = session.handle(.key(KeyInput(character))) }
        let display = session.state.activeDisplay
        return display.isEmpty ? word : display
    }
}

/// The bundled collision list for the main thread's learning tracker (ENG-R862 amendment), set once on the utility
/// queue when the bundled lists are loaded.
final class CollisionVocabularyBox: Sendable {
    private let vocabulary = Mutex<CollisionVocabulary?>(nil)

    var current: CollisionVocabulary? { vocabulary.withLock { $0 } }
    func set(_ value: CollisionVocabulary) { vocabulary.withLock { $0 = value } }
}
