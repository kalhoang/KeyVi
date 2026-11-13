// SPDX-License-Identifier: MPL-2.0
import Testing
import VietnameseEngine

/// Spec 3.14 (ENG-R345, ENG-R346).
@Suite("Viability automaton (3.14)")
struct ViabilityTests {
    private let automaton = ViabilityAutomaton.shared

    private func viable(_ spelling: String) -> Bool { automaton.isViable(letters(spelling)) }

    @Test(arguments: [
        "", "t", "ti", "tie", "tieng", "tiêng", "ng", "ngh", "nghi", "nghiêng", "q", "qu", "quơ", "quơn", "gi", "giê",
        "giêc", "dz", "dzo", "dzoo", "dzô", "kr", "kroong", "krông", "duong", "dương", "đuo", "dd" + "", "huơ",
        "thuơ", "tuơ", "tuơn", "hươ", "thy", "pia", "buyt", "hok", "za", "a", "ao", "uyê", "yê", "ye", "ka",
    ])
    func viablePrefixes(_ spelling: String) {
        if spelling == "dd" {
            #expect(!viable(spelling))  // no `dd` onset: the second d is a letter only after escape
        } else {
            #expect(viable(spelling), "\(spelling)")
        }
    }

    @Test(arguments: [
        // W216-W225 and REG-13, REG-20, REG-26: the first impossible letter.
        "f", "j", "w", "qw", "moth", "st", "key", "yea", "chưâ", "cuâ", "khoâ", "hoê", "ngha", "nghô", "nghă",
        "ăo", "ci", "ngi", "ge", "ghă", "ưâ", "đz", "iêu", "kuy",
    ])
    func nonViable(_ spelling: String) {
        #expect(!viable(spelling), "\(spelling)")
    }

    @Test func automatonIsSmallAndStartsLive() {
        #expect(automaton.start != ViabilityAutomaton.dead)
        #expect(automaton.stateCount > 2)
        print("[ENG-R346] viability automaton: \(automaton.stateCount) states x \(Letter.count) letters")
    }

    @Test func everyPrefixOfEveryTierBSyllableIsViable() {
        for pair in SyllableTables.extendedPairs {
            let word = HornNormalisation.display(pair.letters)
            for length in 0...word.count {
                #expect(automaton.accepts(word.prefix(length)), "\(pair.spelling) prefix \(length)")
            }
        }
    }

    /// Reference: the set of every prefix of every normalised Tier B spelling together with every way
    /// of writing it with modified letters replaced by their unmodified base (the ENG-R345 wildcard
    /// read backwards). Built without the automaton.
    private static let referencePrefixes: Set<[Letter]> = {
        var result = Set<[Letter]>()
        for pair in SyllableTables.extendedPairs {
            let word = HornNormalisation.display(pair.letters)
            for length in 0...word.count {
                var variants: [[Letter]] = [[]]
                for letter in word.prefix(length) {
                    let options = letter.modifier == .none ? [letter] : [letter, letter.unmodified]
                    variants = variants.flatMap { prefix in options.map { prefix + [$0] } }
                }
                result.formUnion(variants)
            }
        }
        return result
    }()

    @Test func automatonEqualsReferenceOnAllShortStrings() {
        // Every string of up to three letters (36,000+ queries).
        var queries: [[Letter]] = [[]]
        for _ in 0..<3 {
            queries = queries.flatMap { prefix in Letter.all.map { prefix + [$0] } }
            for query in queries {
                #expect(automaton.accepts(query) == Self.referencePrefixes.contains(query), "\(Letter.spelling(query))")
            }
        }
    }

    @Test func automatonEqualsReferenceOnSingleLetterMutations() {
        // Every Tier B spelling with one letter replaced by each of the 33 letters.
        var checked = 0
        for pair in SyllableTables.extendedPairs {
            let word = HornNormalisation.display(pair.letters)
            for position in word.indices {
                for letter in Letter.all {
                    var query = word
                    query[position] = letter
                    let expected = Self.referencePrefixes.contains(query)
                    if automaton.accepts(query) != expected {
                        Issue.record("mismatch for \(Letter.spelling(query))")
                    }
                    checked += 1
                }
            }
        }
        let expected = SyllableTables.extendedPairs.reduce(0) { $0 + $1.letters.count * Letter.count }
        #expect(checked == expected)
        print("[ENG-R345] viability mutations checked against the reference: \(checked)")
    }
}
