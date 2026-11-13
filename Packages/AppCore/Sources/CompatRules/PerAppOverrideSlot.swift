// SPDX-License-Identifier: GPL-3.0-or-later
//
// The ids of the per-app user overrides (PLT-R540): one "this app" override per writer and app,
// `<prefix><bundle>`. The Apps pane's compatibility mode and the guided test's "this app" result share
// `user.compat.<bundle>` (PRD-R36, PLT-R1205 step 5); the status line's "type here anyway" without a mode writes
// `user.textfocus.<bundle>`. One algorithm builds all of them, so each writer finds the rule another one wrote and
// replaces it instead of adding a second bundle-only rule that would tie (PLT-R520, PLT-R521).

package import AppModel

/// A per-app user override slot: the id prefix of one writer.
package enum PerAppOverrideSlot: String, Sendable, CaseIterable {
    /// The Apps pane's compatibility mode and the guided test's "this app" result (PRD-R36, PLT-R1205).
    case compat = "user.compat."
    /// "Type here anyway" while no compatibility mode is chosen (PLT-R540, 02-platform.md section 6).
    case textFocus = "user.textfocus."

    /// Rule ID grammar limit (02-platform.md 5.4 `id`).
    static let maximumIDBytes = 128
    static let alphabet = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")

    package var prefix: String { rawValue }

    /// `<prefix><bundle>` within the rule ID grammar (dot-separated `[A-Za-z0-9_-]` segments, at most 128 bytes):
    /// characters outside the alphabet become `-` (`sha256:` keys become `sha256-`), empty segments are dropped
    /// and a long id is cut without leaving a trailing dot.
    package func ruleID(for bundle: BundleKey) -> RuleID {
        let cleaned = String(bundle.rawValue.map { Self.alphabet.contains($0) ? $0 : "-" })
        let segments = cleaned.split(separator: ".", omittingEmptySubsequences: true).joined(separator: ".")
        var candidate = String((prefix + segments).prefix(Self.maximumIDBytes))
        while candidate.hasSuffix(".") { candidate.removeLast() }
        return RuleID(rawValue: candidate) ?? RuleID(rawValue: prefix + "app")!
    }
}
