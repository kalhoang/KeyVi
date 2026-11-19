// SPDX-License-Identifier: MPL-2.0

public import VietnameseEngine

/// The candidate tokens of the typo correction benchmark (ENG-T55, ENG-R1122): typos of lexicon words and
/// adversarial tokens, typed after a space and committed by a space. Generated from fixed inputs and seeds, so every
/// run replays the same events; shared by `engine-benchmark` (bundled data) and its debug sanity check
/// (`EngineBenchmarkTests.candidateLatency`, fixture data).
public enum CorrectionCandidates {
    /// The longest typed word the correction considers (ENG-R1111).
    static let maximumLetters = 24

    /// `count` typos of the words of `lexicon` that have 5 to 24 letters `a` to `z` (with 25 letters for the
    /// deletions), one random edit each: a transposition of two neighbouring letters, a deletion, an insertion of a
    /// random letter, a doubled letter or, when `neighbours` is not empty, a neighbouring key (ENG-R1113). A typo that
    /// is itself a word of `lexicon` is drawn again. Empty when `lexicon` has no such word.
    public static func typos(of lexicon: [String], neighbours: [Character: String], count: Int, seed: UInt64)
        -> [String]
    {
        let words = lexicon.filter { word in
            (5...25).contains(word.utf8.count) && word.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A }
        }.sorted()
        guard !words.isEmpty else { return [] }
        let known = Set(lexicon)
        var generator = SeededGenerator(seed: seed)
        var result: [String] = []
        result.reserveCapacity(count)
        var attempts = 0
        while result.count < count, attempts < count * 20 {
            attempts += 1
            let typo = edit(Array(generator.pick(words).utf8), neighbours: neighbours, generator: &generator)
            guard (5...maximumLetters).contains(typo.count) else { continue }
            let text = String(decoding: typo, as: UTF8.self)
            if !known.contains(text) { result.append(text) }
        }
        return result
    }

    /// `count` adversarial tokens of 24 letters, the longest candidates (ENG-R1111): half are typos of the longest
    /// words of `lexicon` (one transposition in the middle, so most have one fit and run both passes of the edit
    /// search), half are chains of the lexicon's most frequent trigrams, which pass the prefilter at almost every
    /// edit and have no fit.
    public static func adversarial(lexicon: [String], count: Int, seed: UInt64) -> [String] {
        let words = lexicon.filter { $0.utf8.allSatisfy { $0 >= 0x61 && $0 <= 0x7A } }
        guard !words.isEmpty else { return [] }
        var generator = SeededGenerator(seed: seed)
        let longest = words.filter { (20...maximumLetters).contains($0.utf8.count) }.sorted()
        var result: [String] = []
        for index in 0..<(longest.isEmpty ? 0 : count / 2) {
            var bytes = Array(longest[index % longest.count].utf8)
            let middle = bytes.count / 2 + (index % 3) - 1
            bytes.swapAt(middle, middle + 1)
            result.append(String(decoding: bytes, as: UTF8.self))
        }
        let chains = TrigramChains(words)
        let known = Set(lexicon)
        while result.count < count {
            let chain = chains.chain(letters: maximumLetters, generator: &generator)
            if !known.contains(chain) { result.append(chain) }
        }
        return result
    }

    /// The events that type every token after the previous one's committing space, and the index of each token's
    /// committing space (the event whose latency ENG-R1122 bounds).
    public static func events(_ tokens: [String]) -> (events: [EngineEvent], commits: [Int]) {
        var events: [EngineEvent] = []
        var commits: [Int] = []
        for token in tokens {
            for character in token { events.append(.key(KeyInput(character))) }
            commits.append(events.count)
            events.append(.key(KeyInput(" ")))
        }
        return (events, commits)
    }

    private static func edit(_ word: [UInt8], neighbours: [Character: String], generator: inout SeededGenerator)
        -> [UInt8]
    {
        var bytes = word
        let index = generator.nextInt(below: bytes.count)
        switch generator.nextInt(below: neighbours.isEmpty ? 4 : 5) {
        case 0:
            let left = min(index, bytes.count - 2)
            bytes.swapAt(left, left + 1)
        case 1: bytes.remove(at: index)
        case 2: bytes.insert(UInt8(0x61 + generator.nextInt(below: 26)), at: index)
        case 3: bytes.insert(bytes[index], at: index)
        default:
            let key = Character(Unicode.Scalar(bytes[index]))
            if let row = neighbours[key], !row.isEmpty {
                bytes[index] = generator.pick(Array(row.utf8))
            }
        }
        return bytes
    }

    /// Letter chains that follow the most frequent trigrams of a word list.
    private struct TrigramChains {
        /// For each bigram (`26 * a + b`), the letters that most often follow it, most frequent first.
        let followers: [[UInt8]]
        /// The bigrams that most often start a word.
        let starts: [Int]

        init(_ words: [String]) {
            var counts = [Int](repeating: 0, count: 26 * 26 * 26)
            var startCounts = [Int](repeating: 0, count: 26 * 26)
            for word in words {
                let letters = word.utf8.map { Int($0) - 0x61 }
                guard letters.count >= 3 else { continue }
                startCounts[letters[0] * 26 + letters[1]] += 1
                for index in 2..<letters.count {
                    counts[(letters[index - 2] * 26 + letters[index - 1]) * 26 + letters[index]] += 1
                }
            }
            followers = (0..<(26 * 26)).map { bigram in
                let ranked = (0..<26).filter { counts[bigram * 26 + $0] > 0 }
                    .sorted { counts[bigram * 26 + $0] > counts[bigram * 26 + $1] }
                return ranked.prefix(3).map { UInt8(0x61 + $0) }
            }
            starts = (0..<(26 * 26)).filter { startCounts[$0] > 0 }.sorted { startCounts[$0] > startCounts[$1] }
                .prefix(20).map { $0 }
        }

        func chain(letters count: Int, generator: inout SeededGenerator) -> String {
            let start = starts.isEmpty ? 0 : generator.pick(starts)
            var bytes: [UInt8] = [UInt8(0x61 + start / 26), UInt8(0x61 + start % 26)]
            while bytes.count < count {
                let bigram = (Int(bytes[bytes.count - 2]) - 0x61) * 26 + Int(bytes[bytes.count - 1]) - 0x61
                let next = followers[bigram]
                bytes.append(next.isEmpty ? UInt8(0x61 + generator.nextInt(below: 26)) : generator.pick(next))
            }
            // A chat elongation is no candidate (ENG-R1111): never end on three equal letters.
            if bytes[count - 1] == bytes[count - 2], bytes[count - 2] == bytes[count - 3] {
                bytes[count - 1] = bytes[count - 1] == 0x61 ? 0x62 : 0x61
            }
            return String(decoding: bytes, as: UTF8.self)
        }
    }
}
