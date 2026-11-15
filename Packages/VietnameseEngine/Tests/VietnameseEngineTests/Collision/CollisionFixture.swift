// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine
import VietnameseEngineTesting

/// A small, readable fixture for the collision rules (spec 8.1 L9a to L9c, ENG-R823, ENG-R825 to ENG-R829,
/// ENG-R863, ENG-R864): the 13.9 resources plus a few English words, two extra ambiguity rows and tiny
/// collision lists. The bundled lists are tested in VietnameseEngineDataTests.
enum CollisionFixture {
    static let extraEnglish = [
        "hell", "such", "soon", "great", "job", "if", "but", "of", "course", "it", "have", "your", "me", "too", "yes",
        "she", "he", "my", "we", "be", "by", "then", "them", "am", "tows",
    ]

    static let lists = CollisionLists(
        phrases: PhraseList(["as hell", "such as", "has been", "this is", "as soon as", "me too", "of course"]),
        supplement: WordSet(["cos", "gif"]),
        boundaryParticles: WordSet(["as"]),
        runExempt: WordSet(["tows"]),
        readingKinds: [
            "as": .particle, "has": .particle, "these": .particle, "been": .function, "car": .function,
            "did": .function, "its": .function, "there": .function, "theme": .function,
        ],
        englishFunctionWords: WordSet(
            """
            a an the and or but if of to in on at by for with from is are was were be been am have has had do does did \
            you your he she it we they me my this that these those there here as not no too
            """.split(separator: " ").map(String.init)),
        englishLean: WordSet(["the", "i", "my", "he", "she", "we", "by", "be", "then", "them", "me", "am"]),
        tailWords: WordSet(["nha", "nhé", "à", "rồi", "quá"]),
        tailParticles: WordSet(["nha", "nhé", "à"]),
        preGuard: WordSet(
            """
            the a an my your his her its our their this that these those i you he she we they it have has had is are \
            was were be been am do does did to of in on at for with and or but
            """.split(separator: " ").map(String.init)))

    /// The fixture resources with an optional learned memory.
    static func resources(memory: CollisionMemorySnapshot = .empty, lists: CollisionLists = Self.lists) -> Resources {
        var resources = SpecFixtures.commitResources()
        resources.english = WordSet(SpecFixtures.englishLexicon + extraEnglish)
        var ambiguity = resources.ambiguity
        ambiguity["of"] = .vietnamese
        ambiguity["tows"] = .vietnamese
        resources.ambiguity = ambiguity
        resources.collision = lists
        resources.collisionMemory = memory
        return resources
    }

    /// A driver over the fixture (Telex, defaults) after typing `keys` (`⌫` Backspace, `⎋` toggle, `⟲` reset).
    static func driver(
        _ keys: String, configuration: EngineConfiguration = EngineConfiguration(),
        resources: Resources = CollisionFixture.resources()
    ) throws -> EngineDriver {
        var driver = EngineDriver(configuration: configuration, resources: resources)
        try driver.send(KeyNotation.events(keys))
        return driver
    }

    /// The field after typing `keys`.
    static func field(
        _ keys: String, configuration: EngineConfiguration = EngineConfiguration(),
        resources: Resources = CollisionFixture.resources()
    ) throws -> String {
        try driver(keys, configuration: configuration, resources: resources).field.string
    }

    /// Every collision signal the events produced, in order.
    static func signals(_ driver: EngineDriver) -> [CollisionSignal] { driver.outputs.flatMap(\.collisionSignals) }

    /// The revision reasons the events produced, in order.
    static func revisions(_ driver: EngineDriver) -> [RevisionReason] { driver.outputs.compactMap(\.revision) }

    /// The decisions of the commits, in order.
    static func decisions(_ driver: EngineDriver) -> [CommitDecision] { driver.outputs.compactMap(\.decision) }
}
