// SPDX-License-Identifier: LicenseRef-App-Pending
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
        Rule(
            id: ruleID(for: context.bundle), summary: summary, match: match(context, urlPrefix: includeURLPrefix),
            action: action(best),
            provenance: .userSuggestion(
                UserProvenance(source: source, appVersion: appVersion, macOS: macOS, date: date)))
    }

    /// `user.guided.<bundle ID>` (rule ID grammar: dot-separated `[A-Za-z0-9_-]` segments, at most 128 bytes).
    static func ruleID(for bundle: BundleKey?) -> RuleID {
        let segments = (bundle?.rawValue ?? "app").split(separator: ".").map { segment in
            String(
                segment.unicodeScalars.map { scalar in
                    scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
                        ? Character(scalar) : "_"
                })
        }
        var raw = String(([idPrefix] + segments).joined(separator: ".").prefix(128))
        while raw.hasSuffix(".") { raw.removeLast() }
        return RuleID(rawValue: raw) ?? RuleID(rawValue: idPrefix + ".app")!
    }

    /// "This app" plus "only this kind of field" (PLT-R540): role and subrole, then the identifier when AX
    /// exposes one, else the DOM classes. No bundle group (one app only) and no title pattern.
    static func match(_ context: MatchContext, urlPrefix: String?) -> RuleMatch {
        let ax = AXMatch(
            roles: list(context.role), subroles: list(context.subrole), identifiers: list(context.identifier),
            domClasses: context.identifier == nil && !context.domClasses.isEmpty ? context.domClasses : nil)
        let hasAX = ax.roles != nil || ax.subroles != nil || ax.identifiers != nil || ax.domClasses != nil
        let prefix = urlPrefix.flatMap(hostLevelPrefix)
        return RuleMatch(
            bundleIds: context.bundle.map { [$0] }, engines: context.bundle == nil ? [context.engine] : nil,
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
