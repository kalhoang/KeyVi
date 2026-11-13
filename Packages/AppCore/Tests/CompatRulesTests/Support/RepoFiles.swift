// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Locates the repository's compat files from this source file, so tests read the real seeded data.

import AppModel
import Foundation

enum RepoFiles {
    static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Support
        .deletingLastPathComponent()  // CompatRulesTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // AppCore
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()  // repository root

    static var rules: URL { root.appending(path: "compat/rules.json") }
    static var matrix: URL { root.appending(path: "compat/matrix.json") }
    static var scenarios: URL { root.appending(path: "compat/scenarios", directoryHint: .isDirectory) }
    static var compatRulesSources: URL { root.appending(path: "Packages/AppCore/Sources/CompatRules") }
    static func schema(_ name: String) -> URL { root.appending(path: "compat/schema/" + name) }

    static func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func json(_ url: URL) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data(url)) }
}
