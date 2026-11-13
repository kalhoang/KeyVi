// SPDX-License-Identifier: GPL-3.0-or-later
//
// Rule suggestion of the guided test (PLT-R1205 step 4, PLT-R540): a `userOverrideRule` of
// compat/schema/rules.schema.json. Match from the focus snapshot (bundle ID plus the field kind), action from the
// best passing candidate, provenance `{source: "user-suggestion", appVersion, macOS, date}`. A page address is
// included only when the user opted in, and only as a host-level prefix (ADR 0312); the window title is never
// used (PLT-R502).

internal import AppModel
internal import CompatRules
internal import Foundation

enum GuidedTestSuggestion {
    static let idPrefix = "user.guided"
    static let summary = "Suggested by the guided test"
    static let source = "user-suggestion"

    static func rule(
        context: MatchContext, best: GuidedTestCandidate, appVersion: String?, macOS: String, date: String,
        includeURLPrefix: String?
    ) -> Rule {
        let match = match(context, urlPrefix: includeURLPrefix)
        let id = isAppScope(match) ? context.bundle.map(appSlotID) : nil
        return Rule(
            id: id ?? ruleID(for: context.bundle, match: match), summary: summary, match: match, action: action(best),
            provenance: .userSuggestion(
                UserProvenance(source: source, appVersion: appVersion, macOS: macOS, date: date)))
    }

    /// `user.guided.<bundle ID>.<match hash>` (rule ID grammar: dot-separated `[A-Za-z0-9_-]` segments, at most
    /// 128 bytes). PLT-R540 "only this kind of field": the hash of the match signature keeps one override per
    /// field kind, so a second guided test in another kind of field of the same app adds an override instead of
    /// replacing the first one, and a repeated test in the same kind of field replaces its own.
    static func ruleID(for bundle: BundleKey?, match: RuleMatch) -> RuleID {
        let segments = (bundle?.rawValue ?? "app").split(separator: ".").map { segment in
            String(
                segment.unicodeScalars.map { scalar in
                    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
                        ? Character(scalar) : "_"
                })
        }
        let suffix = "." + signatureHash(RuleSet.signature(of: match))
        var base = String(([idPrefix] + segments).joined(separator: ".").prefix(maximumIDBytes - suffix.utf8.count))
        while base.hasSuffix(".") { base.removeLast() }
        return RuleID(rawValue: base + suffix) ?? RuleID(rawValue: idPrefix + ".app" + suffix)!
    }

    /// The app's one "this app" override slot, `user.compat.<bundle>`: the id the Apps pane writes, shows,
    /// replaces and removes with "reset to automatic" (PRD-R36, PLT-R540; `CompatibilityModeChoice.ruleID` in
    /// ShellCore, kept equal by ShellCoreTests/Settings/GuidedOverrideSlotTests.swift). Characters outside the
    /// rule ID alphabet become `-` (`sha256:` keys become `sha256-`).
    static func appSlotID(for bundle: BundleKey) -> RuleID {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let cleaned = String(bundle.rawValue.map { allowed.contains($0) ? $0 : "-" })
        let segments = cleaned.split(separator: ".", omittingEmptySubsequences: true).joined(separator: ".")
        let candidate = String((appSlotIDPrefix + segments).prefix(maximumIDBytes))
        let trimmed = candidate.hasSuffix(".") ? String(candidate.dropLast()) : candidate
        return RuleID(rawValue: trimmed) ?? RuleID(rawValue: appSlotIDPrefix + "app")!
    }

    static let appSlotIDPrefix = "user.compat."

    /// Bundle-only: no field terms, no page address, no engine.
    static func isAppScope(_ match: RuleMatch) -> Bool {
        match.bundleIds != nil && match.ax == nil && match.web == nil && match.engines == nil
    }

    /// Rule ID grammar limit.
    static let maximumIDBytes = 128

    /// 32-bit FNV-1a of the signature as 8 lowercase hex digits: stable across launches (unlike `Hasher`).
    static func signatureHash(_ signature: String) -> String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in signature.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }

    /// "This app" plus "only this kind of field" (PLT-R540): role and subrole, then the identifier when AX
    /// exposes one, else the DOM classes. No bundle group (one app only) and no title pattern.
    ///
    /// Without AX field terms or a page address the suggestion is a "this app" override and takes the app's
    /// override slot (`appSlotID`): a second bundle-only rule for the app would tie with the Apps pane's rule
    /// (score 4, smaller id wins, a tie recorded on every focus change, PLT-R521), and a rule outranking it would
    /// leave the Apps pane's choice and "reset to automatic" without effect (PLT-R540). Without a bundle ID the
    /// engine fingerprint the test ran on is the only identity.
    static func match(_ context: MatchContext, urlPrefix: String?) -> RuleMatch {
        let ax = AXMatch(
            roles: list(context.role), subroles: list(context.subrole), identifiers: list(context.identifier),
            domClasses: context.identifier == nil && !context.domClasses.isEmpty ? context.domClasses : nil)
        let hasAX = ax.roles != nil || ax.subroles != nil || ax.identifiers != nil || ax.domClasses != nil
        let prefix = urlPrefix.flatMap(hostLevelPrefix)
        return RuleMatch(
            bundleIds: context.bundle.map { [$0] },
            engines: context.bundle == nil ? [context.engine] : nil,
            ax: hasAX ? ax : nil, web: prefix.map { WebMatch(urlPrefixes: [$0]) })
    }

    static func action(_ best: GuidedTestCandidate) -> RuleAction {
        let params = StrategyParams(
            interEventDelayUs: best.interEventDelayUs > 0 ? best.interEventDelayUs : nil,
            inlineCompletion: best.inlineCompletion == .none ? nil : best.inlineCompletion)
        return RuleAction(strategy: best.strategy, params: params == StrategyParams() ? nil : params)
    }

    /// `scheme://host[:port]/` for an http(s) address, nil otherwise. Path, query, fragment and user info are
    /// dropped whatever the user left in the field (PLT-R1205 step 4 "host-level prefix").
    static func hostLevelPrefix(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https", let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)/"
    }

    private static func list(_ value: String?) -> [String]? {
        guard let value, !value.isEmpty else { return nil }
        return [value]
    }
}
