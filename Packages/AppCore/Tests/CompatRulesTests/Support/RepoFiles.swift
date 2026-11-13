// SPDX-License-Identifier: GPL-3.0-or-later
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

    static var rules: URL { root.appendingPathComponent("compat/rules.json") }
    static var matrix: URL { root.appendingPathComponent("compat/matrix.json") }
    static var scenarios: URL { root.appendingPathComponent("compat/scenarios", isDirectory: true) }
    static var compatRulesSources: URL { root.appendingPathComponent("Packages/AppCore/Sources/CompatRules") }
    static func schema(_ name: String) -> URL { root.appendingPathComponent("compat/schema/" + name) }

    static func data(_ url: URL) throws -> Data { try Data(contentsOf: url) }
    static func json(_ url: URL) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data(url)) }
}
