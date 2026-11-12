// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Reads the corpus files bundled with this test target (`Corpus/`, QA-R4).
enum CorpusFiles {
    struct Missing: Error, CustomStringConvertible {
        let name: String
        var description: String { "corpus file not found: \(name)" }
    }

    static func text(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Corpus") else {
            throw Missing(name: name)
        }
        return try String(contentsOf: url, encoding: .utf8)
    }
}
