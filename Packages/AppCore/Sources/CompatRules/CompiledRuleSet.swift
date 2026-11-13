// SPDX-License-Identifier: GPL-3.0-or-later
//
// The compiled form behind `RuleSet` (02-platform.md 5.5). Rules are kept in winning order: user overrides
// first (PLT-R522), then higher specificity (PLT-R520), then the lexicographically smaller id (PLT-R521). The
// first matching rule wins; the next matching rule of the same source and score is the runtime tie loser.

import AppModel

struct CompiledRuleSet: Sendable {
    let ordered: [CompiledRule]
    let overlayBundles: Set<BundleKey>
    let titlePatternBundles: Set<BundleKey>
    let conflictingInputApps: Set<BundleKey>
    let webkitBrowsers: Set<BundleKey>
    private let hintKeys: [BundleKey: String]

    init(document: RulesDocument, overrides: [Rule], optedIn: Set<RuleID>) throws(RulesValidationError) {
        try RulesValidator.validateRuleSet(document: document, overrides: overrides)
        var compiled: [CompiledRule] = []
        for rule in overrides {
            compiled.append(
                try CompiledRule(rule: rule, source: .user, groups: document.bundleGroups, optedIn: optedIn))
        }
        for rule in document.rules {
            compiled.append(
                try CompiledRule(rule: rule, source: .shipped, groups: document.bundleGroups, optedIn: optedIn))
        }
        let active = compiled.filter(\.isActive)
        ordered = active.sorted(by: Self.winsOver)
        overlayBundles = active.filter { $0.rule.action.overlay == true }.reduce(into: Set()) { result, rule in
            result.formUnion(rule.bundles ?? [])
            result.formUnion(rule.groupBundles ?? [])
        }
        titlePatternBundles = active.filter(\.hasTitlePattern).reduce(into: Set()) { $0.formUnion($1.bundles ?? []) }
        conflictingInputApps = Set(document.conflictingInputApps)
        webkitBrowsers = Set(document.bundleGroups[ReservedGroup.webkitBrowsers] ?? [])
        hintKeys = Dictionary(document.secureInputHints.map { ($0.bundleId, $0.hintKey) }) { first, _ in first }
    }

    func hintKey(for bundle: BundleKey) -> String? { hintKeys[bundle] }

    func resolve(_ context: MatchContext, defaults: RuleDefaults) -> ResolvedDecision {
        guard let (winner, tieLoser) = winner(for: context) else {
            return DecisionBuilder.defaultDecision(defaults, engine: context.engine)
        }
        return DecisionBuilder.decision(winner: winner, tieLoser: tieLoser, defaults: defaults, engine: context.engine)
    }

    private func winner(for context: MatchContext) -> (CompiledRule, RuleID?)? {
        var winner: CompiledRule?
        for candidate in ordered {
            if let current = winner {
                guard candidate.source == current.source, candidate.specificity == current.specificity else { break }
                if candidate.matches(context) { return (current, candidate.rule.id) }
            } else if candidate.matches(context) {
                winner = candidate
            }
        }
        return winner.map { ($0, nil) }
    }

    private static func winsOver(_ lhs: CompiledRule, _ rhs: CompiledRule) -> Bool {
        let lhsUser = lhs.source == .user
        let rhsUser = rhs.source == .user
        if lhsUser != rhsUser { return lhsUser }
        if lhs.specificity != rhs.specificity { return lhs.specificity > rhs.specificity }
        return lhs.rule.id < rhs.rule.id
    }
}

/// Applies the winning action over `defaults` (no merging across rules, PLT-R520) and resolves `byEngine`.
enum DecisionBuilder {
    static func defaultDecision(_ defaults: RuleDefaults, engine: EngineFingerprint) -> ResolvedDecision {
        ResolvedDecision(
            rule: nil, source: .default, specificity: 0, strategy: defaults.strategy,
            params: params(base: defaults.params, overlay: nil), fallback: defaults.fallback,
            defaultMode: defaults.defaultMode, requireTextFocus: concrete(defaults.requireTextFocus, engine: engine),
            verifyReentry: defaults.verifyReentry, axEnable: .none, overlay: false, requiresUserOptIn: false,
            engineContext: .general, features: .defaults)
    }

    static func decision(
        winner: CompiledRule, tieLoser: RuleID?, defaults: RuleDefaults, engine: EngineFingerprint
    ) -> ResolvedDecision {
        let action = winner.rule.action
        return ResolvedDecision(
            rule: winner.rule.id, source: winner.source, specificity: winner.specificity, strategy: action.strategy,
            params: params(base: defaults.params, overlay: action.params),
            fallback: action.fallback ?? defaults.fallback,
            defaultMode: action.defaultMode ?? defaults.defaultMode,
            requireTextFocus: concrete(action.requireTextFocus ?? defaults.requireTextFocus, engine: engine),
            verifyReentry: action.verifyReentry ?? defaults.verifyReentry, axEnable: action.axEnable ?? .none,
            overlay: action.overlay ?? false, requiresUserOptIn: action.requiresUserOptIn ?? false,
            engineContext: action.engineContext ?? .general, features: features(action.features),
            matchedTitle: winner.hasTitlePattern, matchedURL: winner.hasURLPrefixes, tieLoser: tieLoser,
            userOverride: winner.source == .user ? winner.rule : nil)
    }

    /// PLT-R386: `byEngine` is `whenKnown` for native and Catalyst apps (reliable AX), `never` otherwise.
    static func concrete(_ value: RequireTextFocus, engine: EngineFingerprint) -> RequireTextFocus {
        guard value == .byEngine else { return value }
        return engine == .native || engine == .catalyst ? .whenKnown : .never
    }

    /// Action params over the defaults block over the section 4 defaults, then capped.
    static func params(base: StrategyParams, overlay: StrategyParams?) -> ResolvedParams {
        let fallback = ResolvedParams.defaults
        return ResolvedParams(
            unicodeChunk: overlay?.unicodeChunk ?? base.unicodeChunk ?? fallback.unicodeChunk,
            interEventDelayUs: overlay?.interEventDelayUs ?? base.interEventDelayUs ?? fallback.interEventDelayUs,
            postDeleteSettleUs: overlay?.postDeleteSettleUs ?? base.postDeleteSettleUs ?? fallback.postDeleteSettleUs,
            firstEditDelayUs: overlay?.firstEditDelayUs ?? base.firstEditDelayUs ?? fallback.firstEditDelayUs,
            inlineCompletion: overlay?.inlineCompletion ?? base.inlineCompletion ?? fallback.inlineCompletion,
            allowMultiCharEvents: overlay?.allowMultiCharEvents ?? base.allowMultiCharEvents
                ?? fallback.allowMultiCharEvents,
            allowSplit: overlay?.allowSplit ?? base.allowSplit ?? fallback.allowSplit,
            longTextThreshold: overlay?.longTextThreshold ?? base.longTextThreshold ?? fallback.longTextThreshold,
            restoreDelayMs: overlay?.restoreDelayMs ?? base.restoreDelayMs ?? fallback.restoreDelayMs,
            verifyAfterEdit: overlay?.verifyAfterEdit ?? base.verifyAfterEdit ?? fallback.verifyAfterEdit
        ).capped()
    }

    /// 5.4 `action.features`: all true except `autoCapitalize`.
    static func features(_ features: RuleFeatures?) -> ResolvedFeatures {
        let fallback = ResolvedFeatures.defaults
        return ResolvedFeatures(
            autoCapitalize: features?.autoCapitalize ?? fallback.autoCapitalize,
            macros: features?.macros ?? fallback.macros,
            englishRestore: features?.englishRestore ?? fallback.englishRestore,
            restoreHotkey: features?.restoreHotkey ?? fallback.restoreHotkey)
    }
}

extension ResolvedParams {
    /// Caps of PLT-R404 (unicode chunk), PLT-R408 (delays), PLT-R480 and PLT-R461. Loading already rejects
    /// out-of-range values; capping again keeps the injection worker safe whatever builds the decision.
    func capped() -> ResolvedParams {
        var copy = self
        copy.unicodeChunk = Self.clamp(unicodeChunk, ParameterLimits.unicodeChunk)
        copy.interEventDelayUs = Self.clamp(interEventDelayUs, ParameterLimits.delayUs)
        copy.postDeleteSettleUs = Self.clamp(postDeleteSettleUs, ParameterLimits.delayUs)
        copy.firstEditDelayUs = Self.clamp(firstEditDelayUs, ParameterLimits.delayUs)
        copy.longTextThreshold = Self.clamp(longTextThreshold, ParameterLimits.longTextThreshold)
        copy.restoreDelayMs = Self.clamp(restoreDelayMs, ParameterLimits.restoreDelayMs)
        return copy
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}
