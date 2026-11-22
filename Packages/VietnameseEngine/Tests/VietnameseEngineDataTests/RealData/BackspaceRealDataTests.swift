// SPDX-License-Identifier: MPL-2.0
//
// ENG-T38 with the bundled data: Backspace only deletes (ENG-R710 to ENG-R714) for every word of the
// English lexicon and both tech lists (the words the commit restores, typed in Telex as lowercase,
// Titlecase and all capitals, and in VNI) and for every distinct word of the ENG-T20 prose corpus typed by
// the three simulated typists in Telex and VNI. Each word is typed, then Backspace is pressed until the
// field is empty, once before any boundary and once after a space (the first Backspace re-opens the word
// as the commit left it, restored or kept by the real rules of 8.1). Only the documented exceptions of
// ENG-R714 may change a character that was not deleted; the test prints how often each one occurred.

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineTesting

@Suite("ENG-T38 Backspace only deletes, with the bundled data")
struct BackspaceRealDataTests {
    /// Outcome counts and violation examples of one run.
    private struct Tally: CustomStringConvertible {
        var words = 0
        var outcomes: [BackspaceProbe.Outcome: Int] = [:]
        var violations: [String] = []
        var violationCount = 0

        mutating func probe(_ keys: String, engine: Engine) {
            words += 1
            for boundary in [nil, " "] as [Character?] {
                do {
                    for finding in try BackspaceProbe.run(keys: keys, boundary: boundary, engine: engine) {
                        outcomes[finding.outcome, default: 0] += 1
                        guard finding.outcome == .violation || finding.overDeleted else { continue }
                        violationCount += 1
                        if violations.count < 40 { violations.append(finding.description) }
                    }
                } catch {
                    violationCount += 1
                    if violations.count < 40 { violations.append("\(keys): \(error)") }
                }
            }
        }

        var description: String {
            let counts = BackspaceProbe.Outcome.allCases.filter { $0 != .deletedOnly }
                .map { "\($0.rawValue) \(outcomes[$0, default: 0])" }.joined(separator: ", ")
            return "\(words) words: \(counts)"
        }
    }

    private static func engine(_ method: CorpusMethod, _ resources: Resources) -> Engine {
        Engine(
            configuration: EngineConfiguration(inputMethod: method.inputMethod, typoCorrection: false),
            resources: resources)
    }

    @Test("ENG-T38: English lexicon and tech lists, Telex in three casings and VNI")
    func englishWords() throws {
        let resources = try RealData.resources()
        let words = try RealData.englishCorpusWords()
        let telex = Self.engine(.telex, resources)
        let vni = Self.engine(.vni, resources)
        var tally = Tally()
        for word in words {
            tally.probe(word, engine: telex)
            tally.probe(word.prefix(1).uppercased() + word.dropFirst(), engine: telex)
            tally.probe(word.uppercased(), engine: telex)
            tally.probe(word, engine: vni)
        }
        print("[ENG-T38] English corpus, \(tally)")
        #expect(words.count > 40_000)
        let examples = tally.violations.joined(separator: "\n")
        #expect(tally.violationCount == 0, "\(tally.violationCount) violations:\n\(examples)")
    }

    @Test("ENG-T38: distinct words of the prose corpus, three typists, Telex and VNI")
    func proseWords() throws {
        let resources = try RealData.resources()
        var words = Set<String>()
        var word = ""
        for character in try RealData.proseCorpus() {
            if character.isLetter {
                word.append(character)
            } else if !word.isEmpty {
                words.insert(word)
                word = ""
            }
        }
        var tally = Tally()
        for method in CorpusMethod.allCases {
            let engine = Self.engine(method, resources)
            for order in ProseCorpusCheck.typists {
                for word in words.sorted() {
                    tally.probe(ProseCorpusCheck.keys(for: word, method: method, order: order), engine: engine)
                }
            }
        }
        print("[ENG-T38] prose corpus, \(words.count) distinct words, \(tally)")
        #expect(words.count > 1_000)
        let examples = tally.violations.joined(separator: "\n")
        #expect(tally.violationCount == 0, "\(tally.violationCount) violations:\n\(examples)")
    }
}
