// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// ENG-T12: the spot list of spec/01-engine.md that MUST stay unchanged after commit with default
/// options in any context. Shared by the fixture run (`SpotListTests`, the 13.9 resources) and the gate
/// on the bundled data (`SpotListGateTests`), so both type the same words in the same contexts.
public enum SpotList {
    /// The 27 words, in the spec's order.
    public static let words: [String] = """
        text user case wifi USB data verbose password traffic boss coffee less tomorrow mother keyboard startup \
        facebook java year plans grows ask zoom two wow does www
        """.split(separator: " ").map(String.init)

    /// "Any context": no previous token, a Vietnamese run (`việt`), an English run (`and`, ENG-R823).
    public static let seeds = ["", "vieejt ", "and "]

    /// Both app contexts (ENG-R850).
    public static let appContexts: [AppContext] = [.general, .code]

    /// A spot word that changed: what the field gained after the seed instead of the word and a space.
    public struct Failure: Sendable, Hashable, CustomStringConvertible {
        /// The spot word.
        public let word: String
        /// The keys typed before it.
        public let seed: String
        /// The app context.
        public let appContext: AppContext
        /// What the commit wrote, the space included.
        public let committed: String

        /// `word -> committed after seed in context`.
        public var description: String {
            "\(word) -> \(committed.debugDescription) after \(seed.debugDescription) in \(appContext)"
        }
    }

    /// Types every seed and `word` + space with default options in each app context, and returns every
    /// case where the field did not gain exactly `word` + space after the seed.
    public static func failures(words: [String] = words, resources: Resources) throws -> [Failure] {
        var failures: [Failure] = []
        for word in words {
            for seed in seeds {
                for appContext in appContexts {
                    let committed = try commit(word, after: seed, in: appContext, resources: resources)
                    guard committed != word + " " else { continue }
                    failures.append(Failure(word: word, seed: seed, appContext: appContext, committed: committed))
                }
            }
        }
        return failures
    }

    /// What typing `word` + space after `seed` adds to the field (the whole field if the seed's text
    /// changed).
    private static func commit(
        _ word: String, after seed: String, in appContext: AppContext, resources: Resources
    ) throws -> String {
        var driver = EngineDriver(configuration: EngineConfiguration(appContext: appContext), resources: resources)
        try driver.send(KeyNotation.events(seed))
        let seedText = driver.field.string
        try driver.send(KeyNotation.events(word + " "))
        let field = driver.field.string
        return field.hasPrefix(seedText) ? String(field.dropFirst(seedText.count)) : field
    }
}
