// SPDX-License-Identifier: GPL-3.0-or-later
//
// One rule prepared for matching (02-platform.md 5.5): lists become sets, the bundle group is expanded, the
// title pattern is compiled once at load (PLT-R502) and the specificity score is computed (PLT-R520).
// Matching is pure and allocation-light; it runs on the ax thread on focus change only (PLT-R523).

import AppModel
import Foundation

/// PLT-R520 specificity terms. Each term counts once, however many of its fields are present.
enum Specificity {
    static let axIdentity = 16  // ax.identifiers or ax.domClasses
    static let axStructure = 8  // ax.roles, ax.subroles or ax.ancestorRoles
    static let urlPrefix = 8  // web.urlPrefixes
    static let titlePattern = 4
    static let bundle = 4  // bundleIds or bundleGroup (a named list of bundle IDs)
    static let engine = 2
    static let appCategory = 1

    static func score(of match: RuleMatch) -> Int {
        var score = 0
        if present(match.ax?.identifiers) || present(match.ax?.domClasses) { score += axIdentity }
        if present(match.ax?.roles) || present(match.ax?.subroles) || present(match.ax?.ancestorRoles) {
            score += axStructure
        }
        if present(match.web?.urlPrefixes) { score += urlPrefix }
        if match.titlePattern != nil { score += titlePattern }
        if present(match.bundleIds) || match.bundleGroup != nil { score += bundle }
        if present(match.engines) { score += engine }
        if present(match.appCategories) { score += appCategory }
        return score
    }

    private static func present<T>(_ list: [T]?) -> Bool { !(list?.isEmpty ?? true) }
}

struct CompiledRule: Sendable {
    let rule: Rule
    let source: DecisionSource
    let specificity: Int
    /// Inactive rules (opt-in not given) are never candidates.
    let isActive: Bool
    let bundles: Set<BundleKey>?
    let groupBundles: Set<BundleKey>?
    private let engines: Set<EngineFingerprint>?
    private let categories: Set<String>?
    private let roles: Set<String>?
    private let subroles: Set<String>?
    private let identifiers: Set<String>?
    private let domClasses: Set<String>?
    private let ancestorRoles: Set<String>?
    private let urlPrefixes: [String]?
    private let title: NSRegularExpression?

    init(
        rule: Rule, source: DecisionSource, groups: [String: [BundleKey]], optedIn: Set<RuleID>
    ) throws(RulesValidationError) {
        let match = rule.match
        self.rule = rule
        self.source = source
        specificity = Specificity.score(of: match)
        isActive = Self.isActive(rule, source: source, optedIn: optedIn)
        bundles = match.bundleIds.map(Set.init)
        groupBundles = try match.bundleGroup.map { name throws(RulesValidationError) in
            guard let members = groups[name] else { throw .unknownBundleGroup(rule: rule.id, group: name) }
            return Set(members)
        }
        engines = match.engines.map(Set.init)
        categories = match.appCategories.map(Set.init)
        roles = match.ax?.roles.map(Set.init)
        subroles = match.ax?.subroles.map(Set.init)
        identifiers = match.ax?.identifiers.map(Set.init)
        domClasses = match.ax?.domClasses.map(Set.init)
        ancestorRoles = match.ax?.ancestorRoles.map(Set.init)
        urlPrefixes = match.web?.urlPrefixes
        title = try match.titlePattern.map { pattern throws(RulesValidationError) in
            guard let regex = try? NSRegularExpression(pattern: pattern) else { throw .invalidTitlePattern(rule.id) }
            return regex
        }
    }

    /// PLT-R460, `requiresUserOptIn`: a shipped rule that asks for opt-in, or uses `paste`, stays inactive until
    /// the user opts in. User overrides are the user's own choice and are always active.
    private static func isActive(_ rule: Rule, source: DecisionSource, optedIn: Set<RuleID>) -> Bool {
        guard source == .shipped else { return true }
        let needsOptIn = rule.action.requiresUserOptIn == true || rule.action.strategy == .paste
        return !needsOptIn || optedIn.contains(rule.id)
    }

    var hasTitlePattern: Bool { title != nil }
    var hasURLPrefixes: Bool { urlPrefixes != nil }

    /// Every present match field must match (all-of across fields, any-of within a field).
    func matches(_ context: MatchContext) -> Bool {
        matchesIdentity(context) && matchesVersions(context) && matchesAX(context) && matchesWeb(context)
            && matchesTitle(context)
    }

    private func matchesIdentity(_ context: MatchContext) -> Bool {
        Self.contains(bundles, context.bundle) && Self.contains(groupBundles, context.bundle)
            && Self.contains(engines, context.engine) && Self.contains(categories, context.appCategory)
    }

    private func matchesVersions(_ context: MatchContext) -> Bool {
        if let range = rule.match.appVersion {
            guard let version = context.appVersion, range.contains(version) else { return false }
        }
        if let range = rule.match.macOS, !range.contains(context.macOS) { return false }
        return true
    }

    private func matchesAX(_ context: MatchContext) -> Bool {
        guard Self.contains(roles, context.role), Self.contains(subroles, context.subrole),
            Self.contains(identifiers, context.identifier), Self.intersects(domClasses, context.domClasses),
            Self.intersects(ancestorRoles, context.ancestorRoles)
        else { return false }
        if let editable = rule.match.ax?.editable { return context.editable == editable }
        return true
    }

    /// The document URL is used here only, in memory, and never stored or logged (PLT-R383).
    private func matchesWeb(_ context: MatchContext) -> Bool {
        guard let urlPrefixes else { return true }
        guard let url = context.documentURL else { return false }
        return urlPrefixes.contains { url.hasPrefix($0) }
    }

    /// The window title is used here only, in memory, and never stored or logged (PLT-R383, PLT-R502).
    private func matchesTitle(_ context: MatchContext) -> Bool {
        guard let title else { return true }
        guard let windowTitle = context.windowTitle else { return false }
        let range = NSRange(windowTitle.startIndex..<windowTitle.endIndex, in: windowTitle)
        return title.firstMatch(in: windowTitle, range: range) != nil
    }

    private static func contains<T: Hashable>(_ set: Set<T>?, _ value: T?) -> Bool {
        guard let set else { return true }
        guard let value else { return false }
        return set.contains(value)
    }

    private static func intersects(_ set: Set<String>?, _ values: [String]) -> Bool {
        guard let set else { return true }
        return values.contains { set.contains($0) }
    }
}
