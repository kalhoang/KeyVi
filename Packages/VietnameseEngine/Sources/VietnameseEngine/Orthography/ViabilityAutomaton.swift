// SPDX-License-Identifier: MPL-2.0

/// Viability (spec 3.14): whether letters can still grow into a Tier B syllable.
///
/// ENG-R346: the structure is generated from the tier tables, never written by hand. Every Tier B
/// pair (tone ignored) is spelled, normalised for display (5.5), and inserted into a trie; a subset
/// construction then turns the trie into a deterministic automaton over the 33 letters in which an
/// unmodified vowel letter follows every modified variant and `d` also follows `đ` (ENG-R345);
/// finally equivalent states are merged. A query is one table lookup per letter, so the cost is
/// proportional to the token length and allocation free (ENG-R1230, ENG-R1232).
package struct ViabilityAutomaton: Sendable {
    /// The automaton for the engine's Tier B inventory, `dz` included.
    package static let shared = ViabilityAutomaton(syllables: SyllableTables.extendedPairs.map {
        HornNormalisation.display($0.letters)
    })

    /// The state for "no letter typed yet".
    package let start: UInt16
    /// The rejecting sink. Every other state accepts: any prefix of a syllable is viable.
    package static let dead: UInt16 = 0
    /// `transitions[state * Letter.count + letter.code]`.
    private let transitions: [UInt16]
    /// Number of states, the dead state included.
    package let stateCount: Int

    /// Builds the automaton accepting every prefix of `syllables` under the wildcard of ENG-R345.
    package init(syllables: [[Letter]]) {
        let trie = Trie(syllables)
        let subsets = SubsetAutomaton(trie: trie)
        let minimal = Self.minimise(subsets)
        start = minimal.start
        transitions = minimal.transitions
        stateCount = minimal.stateCount
    }

    /// The state after reading `letter` in `state`; `dead` once the letters can no longer grow
    /// into a syllable.
    @inline(__always)
    package func step(_ state: UInt16, _ letter: Letter) -> UInt16 {
        transitions[Int(state) &* Letter.count &+ Int(letter.code)]
    }

    /// Whether `letters`, already normalised for display, are viable.
    @inline(__always)
    package func accepts<S: Sequence>(_ letters: S) -> Bool where S.Element == Letter {
        var state = start
        for letter in letters {
            state = step(state, letter)
            if state == Self.dead { return false }
        }
        return true
    }

    /// ENG-R345: viability of the current letters of a token, after the display normalisation of 5.5.
    package func isViable(_ letters: [Letter]) -> Bool {
        accepts(HornNormalisation.display(letters))
    }

    // MARK: - Construction

    /// A trie over the exact letters of the syllable spellings.
    private struct Trie {
        /// `children[node * Letter.count + letter]`, -1 for no child. Node 0 is the root.
        var children: [Int32] = [Int32](repeating: -1, count: Letter.count)
        var nodeCount = 1

        init(_ words: [[Letter]]) {
            for word in words {
                var node = 0
                for letter in word {
                    let slot = node * Letter.count + Int(letter.code)
                    if children[slot] < 0 {
                        children[slot] = Int32(nodeCount)
                        nodeCount += 1
                        children.append(contentsOf: repeatElement(-1, count: Letter.count))
                    }
                    node = Int(children[slot])
                }
            }
        }
    }

    /// The deterministic automaton whose states are sets of trie nodes. State 0 is the empty set
    /// (dead), state 1 the root. States are numbered in breadth-first order, so every transition goes
    /// from a lower to a higher number (the trie is acyclic and all nodes of a set share one depth).
    private struct SubsetAutomaton {
        var transitions: [Int] = []
        var stateCount = 0

        init(trie: Trie) {
            // For each typed letter, the trie letters it stands for (ENG-R345).
            let targets: [[Int]] = Letter.all.map { typed in
                Letter.all.filter { typed.viabilityMatches($0) }.map { Int($0.code) }
            }
            var sets: [[Int32]] = [[], [0]]
            var index: [[Int32]: Int] = [[]: 0, [0]: 1]
            transitions = [Int](repeating: 0, count: 2 * Letter.count)
            var state = 1
            while state < sets.count {
                for typed in 0..<Letter.count {
                    var next: [Int32] = []
                    for node in sets[state] {
                        for target in targets[typed] {
                            let child = trie.children[Int(node) * Letter.count + target]
                            if child >= 0 { next.append(child) }
                        }
                    }
                    guard !next.isEmpty else { continue }
                    next.sort()
                    let id: Int
                    if let known = index[next] {
                        id = known
                    } else {
                        id = sets.count
                        sets.append(next)
                        index[next] = id
                        transitions.append(contentsOf: repeatElement(0, count: Letter.count))
                    }
                    transitions[state * Letter.count + typed] = id
                }
                state += 1
            }
            stateCount = sets.count
        }
    }

    /// Merges states with identical outgoing transitions, children first (reverse breadth-first
    /// order). All live states accept, so equal transitions mean equal languages.
    private static func minimise(_ automaton: SubsetAutomaton) -> (start: UInt16, transitions: [UInt16], stateCount: Int) {
        var canonical = [Int](repeating: 0, count: automaton.stateCount)
        var registry: [[Int]: Int] = [:]
        var representatives: [[Int]] = [[Int](repeating: 0, count: Letter.count)]  // dead state
        for state in stride(from: automaton.stateCount - 1, through: 1, by: -1) {
            let base = state * Letter.count
            let signature = (0..<Letter.count).map { canonical[automaton.transitions[base + $0]] }
            if let known = registry[signature] {
                canonical[state] = known
            } else {
                let id = representatives.count
                representatives.append(signature)
                registry[signature] = id
                canonical[state] = id
            }
        }
        precondition(representatives.count <= Int(UInt16.max), "viability automaton too large")
        let flat = representatives.flatMap { $0.map { UInt16($0) } }
        return (UInt16(canonical[1]), flat, representatives.count)
    }
}
