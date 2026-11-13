// SPDX-License-Identifier: GPL-3.0-or-later
//
// Keyboard focus of the "This app misbehaves" panel (PLT-R1205 step 6, decision Q43 in
// docs/decisions/0005-pa-decisions-2026-11-13.md). The panel takes keyboard focus while the user describes the
// symptom (step 2) and during the final offers (step 5), so Tab and Full Keyboard Access reach its controls
// (PRD-R67), and it gives keyboard focus back to the problem field before each guided-test candidate (step 3),
// because the runner types into that field. The App's panel applies this policy with AppKit.

public import InputHost

/// Who holds keyboard focus in one phase of the misbehaves flow.
public enum MisbehavesPanelFocus: Sendable, Hashable {
    /// Steps 2 and 5 (and a stop or a non-empty field, after which nothing is typed): the panel takes keyboard
    /// focus.
    case panel
    /// Step 3 (the empty-and-safe gate, every candidate and the "Do you see 'đá â'?" question): the problem field
    /// keeps keyboard focus and the panel never becomes key, so clicking its buttons does not take the focus.
    case problemField
    /// The user moved focus to another app during the test: the panel does not take the focus back from that
    /// app, but still becomes key when the user types into one of its fields.
    case leftAlone

    public init(step: MisbehavesFlow.Step?) {
        switch step {
        case nil, .describe?, .finished?: self = .panel
        case .confirmField?, .testing?, .askHuman?: self = .problemField
        case .interrupted(.focusChanged)?: self = .leftAlone
        case .interrupted(.cancelled)?, .interrupted(.fieldNotEmpty)?: self = .panel
        }
    }

    /// `NSWindow.canBecomeKey` of the panel in this phase.
    public var panelCanBecomeKey: Bool { self != .problemField }

    /// `NSPanel.becomesKeyOnlyIfNeeded`: while the panel holds the focus a click on any control keeps it key;
    /// while the focus is left alone only a field that needs typing makes it key.
    public var panelBecomesKeyOnlyIfNeeded: Bool { self != .panel }

    /// What the panel does when the flow enters this phase.
    public var actionOnEntry: MisbehavesFocusAction? {
        switch self {
        case .panel: .takeFocus
        case .problemField: .returnFocusToProblemField
        case .leftAlone: nil
        }
    }

    /// PLT-R1205 step 6: keyboard focus goes back to the problem field before each guided-test candidate, also
    /// before the test text is removed, so the runner never types into the panel.
    public static let actionBeforeEachCandidate = MisbehavesFocusAction.returnFocusToProblemField
}

/// A keyboard focus move the panel performs.
public enum MisbehavesFocusAction: Sendable, Hashable {
    /// The panel becomes key without activating the app (a non-activating panel).
    case takeFocus
    /// The panel stops being key, so keyboard focus returns to the app the user was typing in and its field.
    case returnFocusToProblemField
}

/// Follows the flow's steps and reports a focus move only when the phase changes, so choosing a symptom or
/// editing the page address never moves the focus again.
public struct MisbehavesFocusTracker: Sendable, Hashable {
    public private(set) var phase: MisbehavesPanelFocus?

    public init() {}

    /// The phase for `step` becomes current; returns the move due on entering it, or nil when the phase is
    /// unchanged.
    public mutating func update(step: MisbehavesFlow.Step?) -> MisbehavesFocusAction? {
        let next = MisbehavesPanelFocus(step: step)
        guard next != phase else { return nil }
        phase = next
        return next.actionOnEntry
    }
}
