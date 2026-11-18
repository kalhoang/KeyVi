// SPDX-License-Identifier: GPL-3.0-or-later
//
// What a bounded read before the caret found (PLT-R342, PLT-R343) and what the PLT-R357 read-back of a revision
// did, named for the dev recorder (PLT-R904A): names only, never the text read. Since the retest of 16/11/2026 a
// revision that fell back says why, so a trace tells a caret the app reports at 0 (Warp) from a read that comes back
// short (a caret beyond the text returned, such as a cell index) and from other text before the caret (an app behind
// on its echo, or a word changed under the engine).

/// The result of one bounded read before the caret against an expected text.
enum CaretTextCheck: Sendable, Hashable {
    case matches
    /// The AX call failed or timed out.
    case unreadable
    /// A selection where a caret was required: no caret to compare at.
    case selection
    /// The caret sits less than the expected text's length from the start of the field (a caret reported at 0).
    case caretBeforeText
    /// The range read returned fewer units than asked: the caret lies beyond the text the app returns.
    case shortRead
    /// The unit before the expected text is not a separator.
    case notAtTokenStart
    /// The text before the caret is other text.
    case differs

    /// The app may still be applying keys that passed through the tap (PLT-R340, PLT-R357): the caret before the
    /// expected text, other text before it, or no answer in time. A selection, a short read or a letter before the
    /// token does not come from a field that is merely behind.
    var mayCatchUp: Bool {
        switch self {
        case .caretBeforeText, .differs, .unreadable: true
        case .matches, .selection, .shortRead, .notAtTokenStart: false
        }
    }

    /// True or false when the field answered; nil when it could not be compared (the caller decides).
    var verdict: Bool? {
        switch self {
        case .matches: true
        case .unreadable, .selection: nil
        case .caretBeforeText, .shortRead, .notAtTokenStart, .differs: false
        }
    }

    fileprivate var label: StaticString {
        switch self {
        case .matches: "matches"
        case .unreadable: "unreadable"
        case .selection: "unreadable selection"
        case .caretBeforeText: "mismatch caretBeforeText"
        case .shortRead: "mismatch shortRead"
        case .notAtTokenStart: "mismatch notAtTokenStart"
        case .differs: "mismatch differs"
        }
    }

    /// The same after the settle wait of PLT-R357 (the read that decided was the second one).
    fileprivate var labelAfterSettle: StaticString {
        switch self {
        case .matches: "matches afterSettle"
        case .unreadable: "unreadable afterSettle"
        case .selection: "unreadable selection afterSettle"
        case .caretBeforeText: "mismatch caretBeforeText afterSettle"
        case .shortRead: "mismatch shortRead afterSettle"
        case .notAtTokenStart: "mismatch notAtTokenStart afterSettle"
        case .differs: "mismatch differs afterSettle"
        }
    }
}

/// What the PLT-R357 read-back of a revision job did.
enum RevisionReadBackNote: Sendable, Hashable {
    /// The read that decided, and whether it was the one after the settle wait.
    case read(CaretTextCheck, afterSettle: Bool)
    /// The rule never verifies (`verifyReentry: never`) and no late focus change asked for a check: applied as
    /// computed (terminals since the retest of 16/11/2026).
    case skippedRule
    /// The job has no field handle to read: applied as computed, as for an unreadable field.
    case skippedNoField
    /// The pipeline did not know the previous token: only the current token's part, never a read of the previous one.
    case skippedUnknownPrevious
    /// The engine's deletion is wider than the previous token, the space and the current display: only the current
    /// token's part.
    case skippedWideDeletion

    /// The job line's `rb` value (`matches`, `mismatch differs afterSettle`, `skipped rule`); trace-scan prints it
    /// after `readback`.
    var label: StaticString {
        switch self {
        case .read(let check, false): check.label
        case .read(let check, true): check.labelAfterSettle
        case .skippedRule: "skipped rule"
        case .skippedNoField: "skipped noField"
        case .skippedUnknownPrevious: "skipped unknownPrevious"
        case .skippedWideDeletion: "skipped wideDeletion"
        }
    }
}
