// SPDX-License-Identifier: GPL-3.0-or-later
//
// Canonical match signature for duplicate detection (PLT-R521): the match encoded as JSON with sorted keys and
// every list sorted, so two rules that differ only in list order or key order have the same signature. Same
// definition as `canonical()` in scripts/check-rules.py.

import AppModel
import Foundation

enum MatchSignature {
    static func canonical(_ match: RuleMatch) -> String {
        let normalized = RuleMatch(
            bundleIds: match.bundleIds?.sorted(), bundleGroup: match.bundleGroup,
            engines: match.engines?.sorted { $0.rawValue < $1.rawValue }, appCategories: match.appCategories?.sorted(),
            appVersion: match.appVersion, macOS: match.macOS, ax: match.ax.map(sorted),
            web: match.web.map { WebMatch(urlPrefixes: $0.urlPrefixes?.sorted()) }, titlePattern: match.titlePattern)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(normalized), let text = String(data: data, encoding: .utf8) else {
            return String(describing: normalized)
        }
        return text
    }

    private static func sorted(_ ax: AXMatch) -> AXMatch {
        AXMatch(
            roles: ax.roles?.sorted(), subroles: ax.subroles?.sorted(), identifiers: ax.identifiers?.sorted(),
            domClasses: ax.domClasses?.sorted(), ancestorRoles: ax.ancestorRoles?.sorted(), editable: ax.editable)
    }
}
