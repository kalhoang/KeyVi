// SPDX-License-Identifier: LicenseRef-App-Pending
//
// "This app misbehaves" flow (PLT-R1205) as a value: what the panel shows, the symptom, the gate before any
// typing, candidate progress with the human fallback question, the rule suggestion and the offers. The App's
// panel drives `GuidedTestRunner` from `pendingCandidate` and feeds the results back; no strings live here.

public import AppModel
public import CompatRules
public import Diagnostics
public import Injection

/// Step 2: the detected app, field, rule and strategy at the moment the user chose the menu item.
public struct MisbehavesTarget: Sendable, Hashable {
    public var app: FocusedApp?
    public var field: FieldContext
    public var fieldHandle: FieldHandle?
    public var focusGeneration: FocusGeneration
    public var rule: RuleID?
    public var source: DecisionSource
    public var plan: InjectionPlan

    public init(
        app: FocusedApp?, field: FieldContext, fieldHandle: FieldHandle?, focusGeneration: FocusGeneration,
        rule: RuleID?, source: DecisionSource, plan: InjectionPlan
    ) {
        self.app = app
        self.field = field
        self.fieldHandle = fieldHandle
        self.focusGeneration = focusGeneration
        self.rule = rule
        self.source = source
        self.plan = plan
    }

    public init(focus: FocusSnapshot) {
        self.init(
            app: focus.app, field: focus.field, fieldHandle: focus.fieldHandle, focusGeneration: focus.generation,
            rule: focus.decision.rule, source: focus.decision.source, plan: focus.decision.plan)
    }

    public var isNativeApp: Bool { GuidedTestRunner.isNativeApp(app?.engine) }

    private static let unknownMacOS = LooseVersion("0")!

    /// The guided test needs a known app and a text field that is not secure (PLT-R387: nothing is typed into a
    /// password field).
    public var canRunGuidedTest: Bool { app != nil && !field.secure }

    /// Whether the panel may offer the guided test. The runner's events must reach the field unchanged, so the
    /// test needs the host's diagnostics pass-through (no engine, no per-app memory write, no manual mode
    /// change, composition reset on entry and exit, PLT-R210); without that hook it is never offered and the
    /// runner never types (PLT-R1205 step 3).
    public func offersGuidedTest(hostPassThroughAvailable: Bool) -> Bool {
        hostPassThroughAvailable && canRunGuidedTest
    }

    /// Match context for the suggestion: snapshot metadata only; the page address comes from the user.
    public func matchContext(macOS: String) -> MatchContext {
        MatchContext(
            bundle: app?.bundle, appVersion: app?.appVersion, macOS: LooseVersion(macOS) ?? Self.unknownMacOS,
            engine: app?.engine ?? .native,
            role: field.role, subrole: field.subrole, identifier: field.identifier, domClasses: field.domClasses,
            editable: field.editable)
    }
}

/// Step 5 offers.
public enum MisbehavesOffer: String, Sendable, Hashable, CaseIterable {
    /// "Use this for me now": creates the user override (PLT-R540, PLT-R1205).
    case useForMe
    /// Copies the suggestion JSON on its own (ADR 0312: never part of the report).
    case copySuggestion
    case copyReport
    case openGitHubIssue
}

public struct MisbehavesFlow: Sendable, Hashable {
    public enum Step: Sendable, Hashable {
        /// Step 2: detected target, symptom chips, "Copy report", optional guided test.
        case describe
        /// Step 3 gate: the user confirms the focused field is empty and safe to type in.
        case confirmField
        case testing(Int)
        /// "Do you see 'đá â'?" for the candidate at this index.
        case askHuman(Int)
        /// Steps 4 and 5.
        case finished
        case interrupted(Interruption)
    }

    public enum Interruption: Sendable, Hashable {
        /// Focus moved away from the target field: typing stops at once.
        case focusChanged
        /// The readable field held text before a candidate ran.
        case fieldNotEmpty
        case cancelled
    }

    public let target: MisbehavesTarget
    public let candidates: [GuidedTestCandidate]
    public private(set) var step: Step = .describe
    public private(set) var results: [GuidedTestCandidateResult?]
    public var symptom: DiagnosticsReport.Symptom?
    /// "Include page address" (PLT-R1205 step 4): off by default; the address is cut to its host.
    public var includePageAddress = false
    public var pageAddress = ""

    public init(target: MisbehavesTarget) {
        self.target = target
        candidates = GuidedTestRunner.candidates(current: target.plan, isNativeApp: target.isNativeApp)
        results = Array(repeating: nil, count: candidates.count)
    }

    public mutating func requestGuidedTest() {
        guard step == .describe, target.canRunGuidedTest else { return }
        step = .confirmField
    }

    /// Nothing is typed before this confirmation (PLT-R1205 step 3).
    public mutating func confirmFieldIsEmptyAndSafe() {
        guard step == .confirmField else { return }
        step = .testing(0)
    }

    /// The candidate the App runs next, if a run is due.
    public var pendingCandidate: (index: Int, candidate: GuidedTestCandidate)? {
        guard case .testing(let index) = step else { return nil }
        return (index, candidates[index])
    }

    /// The candidate waiting for the human answer.
    public var questionCandidate: GuidedTestCandidate? {
        guard case .askHuman(let index) = step else { return nil }
        return candidates[index]
    }

    public mutating func record(_ result: GuidedTestCandidateResult) {
        guard case .testing(let index) = step else { return }
        results[index] = result
        switch result {
        case .needsHumanAnswer: step = .askHuman(index)
        case .fieldNotEmpty: step = .interrupted(.fieldNotEmpty)
        // A user stop interrupts the flow before the result arrives, so a stop seen here is a focus change.
        case .stopped: step = .interrupted(.focusChanged)
        default: advance(after: index, passed: result.passed)
        }
    }

    public mutating func answer(seesCanary: Bool) {
        guard case .askHuman(let index) = step else { return }
        results[index] = seesCanary ? .humanSaidYes : .humanSaidNo
        advance(after: index, passed: seesCanary)
    }

    public mutating func interrupt(_ reason: Interruption) {
        switch step {
        case .finished, .interrupted: return
        default: step = .interrupted(reason)
        }
    }

    /// Stops at the first passing candidate: the list runs from the least to the most invasive change, so
    /// later candidates could not be better, and the user's field sees as little typing as possible.
    private mutating func advance(after index: Int, passed: Bool) {
        step = passed || index + 1 >= candidates.count ? .finished : .testing(index + 1)
    }

    public var best: GuidedTestCandidate? { GuidedTestRunner.best(of: candidates, results: results) }

    /// The current plan itself passed: the symptom did not reproduce, so there is nothing to fix. A user
    /// override equal to the shipped decision would only shadow later shipped improvements (PLT-R540), so the
    /// panel offers the report instead of "Use this for me now".
    public var couldNotReproduce: Bool {
        step == .finished && results.first??.passed == true
            && candidates.first == GuidedTestCandidate(plan: target.plan)
    }

    /// The host-level prefix that the suggestion will carry, for the panel to show before applying.
    public var pageAddressPrefix: String? {
        includePageAddress ? GuidedTestSuggestion.hostLevelPrefix(pageAddress) : nil
    }

    public func suggestion(macOS: String, date: String) -> Rule? {
        guard let best else { return nil }
        return GuidedTestRunner.suggestion(
            context: target.matchContext(macOS: macOS), best: best, appVersion: target.app?.appVersion?.original,
            macOS: macOS, date: date, includeURLPrefix: pageAddressPrefix)
    }

    public func offers(hasRepository: Bool) -> [MisbehavesOffer] {
        MisbehavesOffer.allCases.filter { offer in
            switch offer {
            case .useForMe, .copySuggestion: step == .finished && best != nil && !couldNotReproduce
            case .copyReport: true
            case .openGitHubIssue: hasRepository
            }
        }
    }
}
