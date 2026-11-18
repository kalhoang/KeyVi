// SPDX-License-Identifier: MPL-2.0
//
// Scoring of a fixture replay as the W11 research scored it (spec/01-engine.md 13.11, ENG-R876): collision
// accuracy by intended language, revisions good and bad (a revised token is good when it ends as the intended word),
// non-collision changes (a word that is not a collision and that the collision rules commit differently from the
// engine without them, `lookaheadRevision` off, ENG-R829), exact sentences, hidden collisions left intact, and the
// breakdowns by position tag, category, sentence group and deciding rule. `report` prints the summary line of the
// research replay kit, the bad revisions and changed words, then the tables.

import Foundation
import VietnameseEngine

/// Right out of total.
struct Tally: Hashable {
    let right: Int
    let total: Int

    init(right: Int = 0, total: Int = 0) {
        self.right = right
        self.total = total
    }

    func adding(_ ok: Bool) -> Tally { Tally(right: right + (ok ? 1 : 0), total: total + 1) }

    var share: Double { total == 0 ? 0 : Double(right) / Double(total) }
    var percent: String { String(format: "%.1f", share * 100) }
    var wrong: Int { total - right }
}

/// The two intended languages of a collision row of a table.
struct LanguagePair: Hashable {
    var english = Tally()
    var vietnamese = Tally()

    func adding(_ ok: Bool, intended: Language) -> LanguagePair {
        var pair = self
        if intended == .english { pair.english = english.adding(ok) } else { pair.vietnamese = vietnamese.adding(ok) }
        return pair
    }
}

/// The score of one fixture file.
struct CorpusScore {
    private(set) var sentences = 0
    private(set) var tokens = 0
    private(set) var collisions = LanguagePair()
    private(set) var hidden = Tally()
    private(set) var revisions = 0
    /// `id: raw -> output (intended), reason` for every revised token that does not end as the intended word.
    private(set) var badRevisions: [String] = []
    /// `id: raw -> with (without), rule` for every non-collision word the collision rules changed.
    private(set) var nonCollisionChanges: [String] = []
    /// `id: raw -> with (without)` for every doubled word whose two forms are English that the collision rules brought
    /// back to the keys typed, its intended word: rule L4 reads the English run, English-lean words included, and the
    /// phrases (amended by the product owner on 17/11/2026, REG-37), so `The mess` and `Turn off` keep the word typed
    /// only with the rules on. Not a non-collision change: it never damages a word.
    private(set) var escapesBroughtBack: [String] = []
    private(set) var exactSentences = 0
    /// Sentences whose field or revisions differ from the frozen fixture.
    private(set) var mismatches: [String] = []
    /// Sentences whose words, tokens and fixture words do not line up (a harness or fixture problem).
    private(set) var alignmentErrors: [String] = []
    private(set) var byPosition: [String: LanguagePair] = [:]
    private(set) var byCategory: [String: LanguagePair] = [:]
    private(set) var byGroup: [String: LanguagePair] = [:]
    private(set) var byRule: [String: Tally] = [:]
    private(set) var decisionRules: [String: Int] = [:]

    var goodRevisions: Int { revisions - badRevisions.count }

    /// Scores `results` (the replay of each sentence) against the fixture; `baseline` is the replay without the
    /// collision rules (nil: non-collision changes are not counted, as for the adversarial sets).
    static func score(_ sentences: [CorpusSentence], _ results: [ReplayResult], baseline: [ReplayResult]?)
        -> CorpusScore
    {
        var score = CorpusScore()
        for (index, sentence) in sentences.enumerated() {
            score.add(sentence, results[index], baseline: baseline?[index])
        }
        return score
    }

    private mutating func add(_ sentence: CorpusSentence, _ result: ReplayResult, baseline: ReplayResult?) {
        sentences += 1
        let words = result.words
        let baseWords = baseline?.words
        guard words.count == sentence.words.count, result.tokens.count == words.count,
            baseWords.map({ $0.count == words.count }) ?? true
        else {
            alignmentErrors.append(
                "\(sentence.id): \(words.count) words, \(result.tokens.count) tokens, \(sentence.words.count) in the fixture"
            )
            return
        }
        let revised = Dictionary(
            uniqueKeysWithValues: result.tokens.enumerated().compactMap { index, token in
                token.revision.map { (index, RevisionName.of($0)) }
            })
        if result.notation != sentence.expected || revised != sentence.revised {
            mismatches.append(
                "\(sentence.id): expected \(sentence.expected) revised \(sentence.revised.sorted { $0.key < $1.key })\n"
                    + "      actual   \(result.notation) revised \(revised.sorted { $0.key < $1.key })")
        }
        var exact = true
        for (index, word) in sentence.words.enumerated() {
            tokens += 1
            let output = words[index]
            let token = result.tokens[index]
            let ok = output == word.intended
            exact = exact && ok
            decisionRules[Self.ruleName(token.decision), default: 0] += 1
            if let reason = token.revision {
                revisions += 1
                if !ok {
                    badRevisions.append(
                        "\(sentence.id): \(token.raw) -> \(output) (\(word.intended)), \(RevisionName.of(reason))")
                }
            }
            switch word.label {
            case .hidden:
                hidden = hidden.adding(ok)
            case .plain:
                if let baseWords, baseWords[index] != output {
                    let change = "\(sentence.id): \(token.raw) -> \(output) (\(baseWords[index]))"
                    if token.decision == .restored(.escape), ok {
                        escapesBroughtBack.append(change)
                    } else {
                        nonCollisionChanges.append(change + ", \(Self.ruleName(token.decision))")
                    }
                }
            case .collision(let intended, let category, let positions):
                collisions = collisions.adding(ok, intended: intended)
                byCategory[category, default: LanguagePair()] = byCategory[category, default: LanguagePair()]
                    .adding(ok, intended: intended)
                byGroup[sentence.group, default: LanguagePair()] = byGroup[sentence.group, default: LanguagePair()]
                    .adding(ok, intended: intended)
                for tag in positions {
                    byPosition[tag, default: LanguagePair()] = byPosition[tag, default: LanguagePair()]
                        .adding(ok, intended: intended)
                }
                let rule = token.revision.map(Self.revisionRule) ?? Self.ruleName(token.decision)
                byRule[rule, default: Tally()] = byRule[rule, default: Tally()].adding(ok)
            }
        }
        if exact { exactSentences += 1 }
    }

    /// The spec 8.1 rule of a decision (ENG-R801).
    static func ruleName(_ decision: CommitDecision) -> String {
        let rule: CommitRule
        switch decision {
        case .kept(let kept): rule = kept
        case .restored(let restored): rule = restored
        case .macro: return "macro"
        }
        switch rule {
        case .unchanged: return "L0"
        case .userChoice: return "L1"
        case .userList: return "L2"
        case .abbreviation: return "L3"
        case .camelCase: return "L3b"
        case .escape: return "L4"
        case .toneRemoval: return "L4a"
        case .invalid: return "L5"
        case .extendedSpelling: return "L6"
        case .notEnglish: return "L7"
        case .notAttested: return "L8"
        case .codeContext: return "L9"
        case .boundaryParticle: return "L9a"
        case .phrase: return "L9b"
        case .learned: return "L9c"
        case .englishRun: return "L10"
        case .ambiguityTable, .techList, .defaultVietnamese: return "L11"
        }
    }

    /// The revision rule of ENG-R828.
    static func revisionRule(_ reason: RevisionReason) -> String {
        switch reason {
        case .phrase: "RV1"
        case .particleTail: "RV2"
        case .nextEnglish: "RV3"
        case .nextVietnamese: "RV4"
        case .lineVietnamese: "RV5"
        }
    }

    /// The summary line of the research replay kit, then the problem lists and the breakdown tables. Formatting
    /// uses only `%d` and `%f` so that it reads the same on Linux (QA-R5).
    func report(title: String) -> String {
        let everything = Tally(
            right: collisions.english.right + collisions.vietnamese.right,
            total: collisions.english.total + collisions.vietnamese.total)
        let english = collisions.english
        let vietnamese = collisions.vietnamese
        let perThousand = tokens == 0 ? 0 : 1000 * Double(revisions) / Double(tokens)
        var lines = [
            "[QA-R68] \(title): \(sentences) sentences, \(tokens) tokens",
            "EN \(english.percent) (\(english.right)/\(english.total))  VI \(vietnamese.percent) "
                + "(\(vietnamese.right)/\(vietnamese.total))  all \(everything.percent)  revisions \(revisions) good "
                + "\(goodRevisions) bad \(badRevisions.count)  per1k \(String(format: "%.1f", perThousand))  "
                + "non-collision changes \(nonCollisionChanges.count)  escapes brought back \(escapesBroughtBack.count)  "
                + "exact \(exactSentences)  hidden \(hidden.right)/\(hidden.total)",
        ]
        lines += badRevisions.prefix(20).map { "BAD \($0)" }
        lines += nonCollisionChanges.prefix(20).map { "NONC \($0)" }
        lines += escapesBroughtBack.prefix(20).map { "L4 \($0)" }
        lines += Self.table("By position", byPosition)
        lines += Self.table("By category", byCategory)
        lines += Self.table("By group", byGroup)
        let rules = byRule.sorted { Self.ruleOrder($0.key) < Self.ruleOrder($1.key) }
        lines.append(
            "Deciding rule of the collisions (right / wrong): "
                + rules.map { "\($0.key) \($0.value.right) / \($0.value.wrong)" }.joined(separator: "; "))
        return lines.joined(separator: "\n")
    }

    /// Rules in the order of spec 8.1, then the revision rules.
    private static let rules = [
        "L0", "L1", "L2", "L3", "L3b", "L4", "L5", "L6", "L7", "L8", "L9", "L9a", "L9b", "L9c", "L10", "L11", "macro",
        "RV1", "RV2", "RV3", "RV4",
    ]

    private static func ruleOrder(_ rule: String) -> Int { rules.firstIndex(of: rule) ?? rules.count }

    private static func table(_ title: String, _ rows: [String: LanguagePair]) -> [String] {
        ["\(title) (EN right/total %, VI right/total %):"]
            + rows.sorted { $0.key < $1.key }.map { key, pair in
                "  " + padded(key) + padded(cell(pair.english)) + "   " + cell(pair.vietnamese)
            }
    }

    private static func cell(_ tally: Tally) -> String {
        tally.total == 0 ? "-" : "\(tally.right)/\(tally.total) \(tally.percent)"
    }

    private static func padded(_ text: String, to width: Int = 16) -> String {
        text + String(repeating: " ", count: max(0, width - text.count))
    }
}
