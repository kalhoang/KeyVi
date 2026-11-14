// SPDX-License-Identifier: GPL-3.0-or-later
//
// PLT-R386, PLT-R387, PLT-R390, PLT-R460: rule decision -> tap decision and focus-derived pauses.

import AppModel
import CompatRules
import Injection
import Testing

@testable import InputHost
@testable import TestSupport

private func decision(
    strategy: InjectionStrategy = .backspaceReplace, fallback: [InjectionStrategy] = [.passThrough],
    requireTextFocus: RequireTextFocus = .byEngine, optIn: Bool = false, rule: String? = "test.rule"
) -> ResolvedDecision {
    var params = ResolvedParams.defaults
    params.interEventDelayUs = 1_500
    params.inlineCompletion = .axSelection
    return ResolvedDecision(
        rule: rule.map { RuleID(rawValue: $0)! }, source: .shipped, specificity: 12, strategy: strategy, params: params,
        fallback: fallback, defaultMode: .inherit, requireTextFocus: requireTextFocus, verifyReentry: .never,
        axEnable: .none, overlay: false, requiresUserOptIn: optIn, engineContext: .code,
        features: ResolvedFeatures(autoCapitalize: false, macros: false, englishRestore: false, restoreHotkey: false))
}

private func field(
    role: String?, subrole: String? = nil, editable: Bool? = nil, availability: AXAvailability = .available
)
    -> FieldContext
{
    FieldContext(
        axAvailability: availability, role: role, subrole: subrole, identifier: nil, domClasses: [], editable: editable,
        secure: subrole == "AXSecureTextField")
}

@Suite("HostDecisionMapper and text-focus gate (PLT-R386, PLT-R387)")
struct HostDecisionMapperTests {
    /// PLT-R389: the tap revalidates on every key while the focus owner's rule is an overlay rule, so the flag
    /// travels with the decision, also through the per-app "ignore" choice.
    @Test func theOverlayFlagReachesTheTapPLTR389() {
        var overlay = decision()
        #expect(!HostDecisionMapper.map(overlay, engine: .native, optedIntoPaste: false).overlay)
        overlay.overlay = true
        let mapped = HostDecisionMapper.map(overlay, engine: .native, optedIntoPaste: false)
        #expect(mapped.overlay)
        #expect(HostDecisionMapping.ignoring(mapped).overlay)
    }

    @Test func byEngineBecomesConcrete() {
        #expect(
            HostDecisionMapper.map(decision(), engine: .native, optedIntoPaste: false).requireTextFocus == .whenKnown)
        #expect(
            HostDecisionMapper.map(decision(), engine: .catalyst, optedIntoPaste: false).requireTextFocus == .whenKnown)
        #expect(HostDecisionMapper.map(decision(), engine: .electron, optedIntoPaste: false).requireTextFocus == .never)
        #expect(
            HostDecisionMapper.map(decision(requireTextFocus: .always), engine: .electron, optedIntoPaste: false)
                .requireTextFocus == .always)
    }

    @Test func copiesParametersVariantAndFeatures() {
        let mapped = HostDecisionMapper.map(decision(), engine: .native, optedIntoPaste: false)
        #expect(mapped.plan.strategy == .backspaceReplace)
        #expect(mapped.plan.fallback == [.passThrough])
        #expect(mapped.plan.parameters.interEventDelayUs == 1_500)
        #expect(mapped.plan.parameters.inlineCompletion == .axSelection)
        #expect(mapped.plan.parameters.pasteOptedIn == false)
        #expect(mapped.variant == EngineVariant(appContext: .code, englishRestore: false, macros: false))
        #expect(mapped.restoreHotkeyEnabled == false)
        #expect(mapped.verifyReentry == .never)
        #expect(mapped.rule == RuleID(rawValue: "test.rule"))
        #expect(mapped.source == .shipped)
        #expect(mapped.specificity == 12)
    }

    @Test func pasteBehindAnOptInFallsBackUntilTheUserOptsIn() {
        let offered = decision(strategy: .paste, fallback: [.paste, .selectReplace, .passThrough], optIn: true)
        let before = HostDecisionMapper.map(offered, engine: .native, optedIntoPaste: false)
        #expect(before.plan.strategy == .selectReplace)
        #expect(before.plan.fallback == [.passThrough])  // the promoted strategy is not retried as a fallback
        let after = HostDecisionMapper.map(offered, engine: .native, optedIntoPaste: true)
        #expect(after.plan.strategy == .paste)
        #expect(after.plan.parameters.pasteOptedIn)
        let noFallback = HostDecisionMapper.map(
            decision(strategy: .paste, fallback: [], optIn: true), engine: .native, optedIntoPaste: false)
        #expect(noFallback.plan.strategy == .backspaceReplace)
        #expect(noFallback.plan.fallback.isEmpty)
        // Long-text paste allowed by a rule without opt-in is kept (PLT-R460 b).
        let allowed = HostDecisionMapper.map(decision(strategy: .paste), engine: .native, optedIntoPaste: false)
        #expect(allowed.plan.strategy == .paste)
    }

    @Test func ignoringIsAUserPassThroughOverride() {
        let ignored = HostDecisionMapping.ignoring(
            HostDecisionMapper.map(decision(), engine: .native, optedIntoPaste: false))
        #expect(ignored.plan.strategy == .passThrough)
        #expect(ignored.rule == RuleID(rawValue: "user.ignore"))
        #expect(ignored.source == .user)
    }

    @Test func editableText() {
        #expect(TextFocusGate.isEditable(field(role: "AXTextField")))
        #expect(TextFocusGate.isEditable(field(role: "AXTextArea", editable: false)))
        #expect(TextFocusGate.isEditable(field(role: "AXComboBox")))
        #expect(TextFocusGate.isEditable(field(role: "AXGroup", subrole: "AXSearchField")))
        #expect(TextFocusGate.isEditable(field(role: "AXGroup", editable: true)))
        #expect(!TextFocusGate.isEditable(field(role: "AXButton")))
    }

    @Test func whenKnownPassesOnlyWhenAXPositivelyReportsANonTextElement() {
        #expect(TextFocusGate.blocks(.whenKnown, field: field(role: "AXButton")))
        #expect(!TextFocusGate.blocks(.whenKnown, field: field(role: "AXTextArea")))
        #expect(!TextFocusGate.blocks(.whenKnown, field: field(role: nil)))
        #expect(!TextFocusGate.blocks(.whenKnown, field: field(role: "AXButton", availability: .timedOut)))
        #expect(!TextFocusGate.blocks(.whenKnown, field: .unknown))
    }

    @Test func alwaysNeedsConfirmedEditableText() {
        #expect(!TextFocusGate.blocks(.always, field: field(role: "AXTextField")))
        #expect(TextFocusGate.blocks(.always, field: field(role: nil)))
        #expect(TextFocusGate.blocks(.always, field: field(role: "AXTextField", availability: .unavailable)))
        #expect(!TextFocusGate.blocks(.never, field: field(role: "AXButton")))
        #expect(!TextFocusGate.blocks(.byEngine, field: field(role: "AXButton")))
    }

    @Test func pausePrecedenceSecureFieldThenPassThroughThenTextFocus() {
        let native = HostDecisionMapper.map(decision(), engine: .native, optedIntoPaste: false)
        let passThrough = HostDecisionMapper.map(
            decision(strategy: .passThrough), engine: .native, optedIntoPaste: false)
        let secure = field(role: "AXTextField", subrole: "AXSecureTextField")
        #expect(TextFocusGate.pause(field: secure, decision: passThrough) == .secureField)  // PLT-R387
        #expect(
            TextFocusGate.pause(field: field(role: "AXTextField"), decision: passThrough)
                == .passThroughRule(RuleID(rawValue: "test.rule")!))
        #expect(TextFocusGate.pause(field: field(role: "AXButton"), decision: native) == .noTextFocus)
        #expect(TextFocusGate.pause(field: field(role: "AXTextField"), decision: native) == nil)
        let ruleless = HostDecisionMapper.map(
            decision(strategy: .passThrough, rule: nil), engine: .native, optedIntoPaste: false)
        #expect(
            TextFocusGate.pause(field: field(role: nil), decision: ruleless)
                == .passThroughRule(RuleID(rawValue: "defaults")!))
    }
}
