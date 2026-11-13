// SPDX-License-Identifier: GPL-3.0-or-later
//
// Candidate list, candidate <-> injection plan mapping and the choice of the best candidate for the guided
// test of the "This app misbehaves" flow (PLT-R1205 step 3).

public import AppModel
internal import CompatRules
public import Injection

extension GuidedTestCandidate {
    /// The candidate that reproduces `plan` (strategy, inline-completion handling, pacing).
    public init(plan: InjectionPlan) {
        self.init(
            strategy: plan.strategy, inlineCompletion: plan.parameters.inlineCompletion,
            interEventDelayUs: plan.parameters.interEventDelayUs)
    }

    /// The plan the candidate runs with: default parameters plus its own handling and pacing, and no fallback,
    /// so a failure of the candidate itself stays visible.
    public var plan: InjectionPlan {
        var parameters = InjectionParameters.defaults
        parameters.inlineCompletion = inlineCompletion
        parameters.interEventDelayUs = interEventDelayUs
        return InjectionPlan(strategy: strategy, parameters: parameters, fallback: [])
    }

    /// Only these strategies can type the canary: `passThrough` types nothing and `paste` needs the user's
    /// clipboard opt-in (PLT-R460).
    var canType: Bool { strategy != .passThrough && strategy != .paste }
}

extension GuidedTestCandidateResult {
    /// Passed by AX readback or by the user's "Yes".
    public var passed: Bool { self == .passedByReadback || self == .humanSaidYes }
}

extension GuidedTestRunner {
    /// The first passing candidate in list order, which runs from the least to the most invasive change.
    public static func best(
        of candidates: [GuidedTestCandidate], results: [GuidedTestCandidateResult?]
    ) -> GuidedTestCandidate? {
        zip(candidates, results).first { $0.1?.passed == true }?.0
    }

    /// PLT-R386 treats native and Catalyst apps as AX-reliable; `axReplace` is offered for them only.
    public static func isNativeApp(_ engine: EngineFingerprint?) -> Bool {
        engine == .native || engine == .catalyst
    }
}

enum GuidedTestPlans {
    static let pacingSteps = [2_000, 5_000]  // PLT-R1205: pacing 0, 2 and 5 ms

    static func candidates(current: InjectionPlan?, isNativeApp: Bool) -> [GuidedTestCandidate] {
        let fromPlan = current.map(GuidedTestCandidate.init(plan:))
        let first =
            fromPlan.flatMap { $0.canType ? $0 : nil } ?? GuidedTestCandidate(plan: InjectionPlan.default)
        var list = [first]
        list.append(
            GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .axSelection, interEventDelayUs: 0))
        list.append(
            GuidedTestCandidate(strategy: .backspaceReplace, inlineCompletion: .placeholder, interEventDelayUs: 0))
        list.append(GuidedTestCandidate(strategy: .selectReplace, inlineCompletion: .none, interEventDelayUs: 0))
        if isNativeApp {
            list.append(GuidedTestCandidate(strategy: .axReplace, inlineCompletion: .none, interEventDelayUs: 0))
        }
        for delay in pacingSteps where delay > first.interEventDelayUs {
            var paced = first
            paced.interEventDelayUs = delay
            list.append(paced)
        }
        var seen: Set<GuidedTestCandidate> = []
        return list.filter { seen.insert($0).inserted }
    }
}
