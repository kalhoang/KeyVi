// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Strategy catalogue (02-platform.md section 4) and the pure helpers every strategy shares.

public import AppModel
public import RealtimeSupport

public enum StrategyOutcome: Sendable, Hashable {
    /// Final synthetic event posted; its sequence goes to the echo tracker.
    case completed(lastEventSequence: UInt32)
    /// Detectable failure before anything was posted (AX error, pasteboard unreadable): try `fallback`.
    case failedBeforePosting(FallbackReason)
    /// Failure after partial output (readback mismatch for `axReplace`): fallback for the rest of the focus
    /// session, health event (4.5).
    case failedAfterPosting(FallbackReason)
}

public enum FallbackReason: UInt8, Sendable, Hashable {
    case axUnavailable, axTimedOut, axWriteFailed, readbackMismatch, pasteboardUnsafe, postingFailed, jobTooLong
}

/// The inject-thread environment a strategy runs in. Implemented by the worker; faked in strategy tests.
public protocol InjectionEnvironment: AnyObject {
    var now: MonotonicInstant { get }
    /// Absolute-deadline pacing on the inject thread (PLT-R409).
    func sleep(until deadline: MonotonicInstant)
    /// Posts one event with a fresh marker sequence and returns that sequence.
    func post(_ event: SyntheticKeyEvent) throws(PostError) -> UInt32
    /// Replays every held event queued behind the current job (paste step 4, PLT-R461).
    func releaseHeldEvents()
    var fieldAccess: any FocusedFieldAccess { get }
    var pasteboard: any PasteboardAccess { get }
}

public protocol StrategyExecutor: Sendable {
    var strategy: InjectionStrategy { get }
    func execute(_ job: EditJob, in environment: any InjectionEnvironment) -> StrategyOutcome
}

/// `backspaceReplace` (4.2, with 4.3 inline completion), `selectReplace` (4.4), `axReplace` (4.5),
/// `paste` (4.6 with `PasteboardPreserver`). `passThrough` jobs are never built.
public enum StrategyCatalog {
    public static func executor(for strategy: InjectionStrategy) -> any StrategyExecutor { unimplemented() }
}

/// PLT-R402: trims the common grapheme prefix of the replaced text and the insertion. With unknown replaced
/// text, the edit is returned unchanged (the engine's edits are already minimal, ENG-R611).
public enum EditMinimizer {
    public static func minimize(deleteCount: Int, replaced: String?, insertion: String)
        -> (deleteCount: Int, insertion: String)
    { unimplemented() }
}

/// PLT-R404/PLT-R480: one grapheme per event by default; up to `maxUTF16` units per event when allowed;
/// never splits a grapheme cluster.
public enum UnicodeChunker {
    public static func chunks(of text: String, maxUTF16: Int, oneGraphemePerEvent: Bool) -> [InlineUTF16] {
        unimplemented()
    }
}

/// Full clipboard preservation for `paste` (PLT-R461): snapshot every item and type (abort on file promises,
/// unmaterialisable lazy data, > 10 MB or > 100 ms), write the transient item, paste, restore after
/// `restoreDelayMs` only if `changeCount` is unchanged, coalesce consecutive pastes within the window.
public final class PasteboardPreserver {
    public init(pasteboard: any PasteboardAccess, limits: PasteboardLimits = PasteboardLimits()) { unimplemented() }
    /// Step 1-2. Throws when the clipboard cannot be fully preserved: never destroy what cannot be restored.
    public func beginPaste(_ text: String) throws(PasteboardError) { unimplemented() }
    /// Steps 4-6, driven by the worker's deadlines.
    public func restoreIfDue(now: MonotonicInstant, restoreDelay: Duration) -> RestoreResult { unimplemented() }

    public enum RestoreResult: Sendable, Hashable { case notDue, restored, skippedUserCopied, nothingPending }
}
