// SPDX-License-Identifier: GPL-3.0-or-later
//
// Shared machinery of the key-based strategies (4.2, 4.4, 4.6): synthetic key builders, the ordered list of key
// pairs a job posts, pacing with absolute deadlines (PLT-R408, PLT-R409) and optional splitting.

internal import AppModel
internal import CoreGraphics
internal import RealtimeSupport

/// Fixed limits and parameter caps from 02-platform.md section 4.
enum InjectionTiming {
    /// PLT-R408: every timing parameter is capped at 50,000 microseconds.
    static let parameterCapMicroseconds = 50_000
    /// PLT-R420 (VERIFY value): bounded read of `AXSelectedTextRange` before deleting.
    static let axSelectionTimeout: TimeSpan = .milliseconds(15)
    /// 4.5: each AX call of `axReplace`, re-entry verification (PLT-R342) and `verifyAfterEdit` readback.
    static let axCallTimeout: TimeSpan = .milliseconds(30)
    /// PLT-R421 (VERIFY per app): U+200B ZERO WIDTH SPACE, its own grapheme cluster.
    static let placeholder = "\u{200B}"
    /// PLT-R343: AX reads never exceed 64 UTF-16 units.
    static let maximumAXReadUnits = 64
    /// PLT-R357: a revision read-back that mismatched within this long after the trigger key or the last posted
    /// event, whichever is later, is read once more when it ends (the app may not have applied the keys before the
    /// revision yet). As `verifyAfterEdit`.
    static let revisionSettle: TimeSpan = .milliseconds(50)

    static func nanoseconds(_ duration: TimeSpan) -> UInt64 { duration.unsignedNanoseconds }

    static func cappedNanoseconds(microseconds: Int) -> UInt64 {
        UInt64(min(max(0, microseconds), parameterCapMicroseconds)) * 1_000
    }
}

/// Duration caps of one job (PLT-R408, PLT-R480).
struct StrategyLimits: Sendable, Hashable {
    var maxJobDuration: TimeSpan = .milliseconds(150)
    /// Macro jobs share the 1 s macro liveness ceiling: a 150 ms cap would make that ceiling meaningless.
    var maxMacroJobDuration: TimeSpan = .seconds(1)

    init() {}

    init(_ configuration: WorkerConfiguration) {
        maxJobDuration = configuration.maxJobDuration
        maxMacroJobDuration = configuration.macroLivenessCeiling
    }

    func capNanoseconds(for kind: EditKind) -> UInt64 {
        InjectionTiming.nanoseconds(kind == .macro ? maxMacroJobDuration : maxJobDuration)
    }
}

/// Builders for the only synthetic keys any strategy posts. Forward delete deletes no text: it only clears a suggestion
/// shown after the caret, for the `forwardDelete` completion handling (PLT-R407 as amended, PLT-R423).
enum SyntheticKeys {
    static let shiftFlag = CGEventFlags.maskShift.rawValue
    static let commandFlag = CGEventFlags.maskCommand.rawValue

    /// PLT-R407: `kVK_Delete`, no Unicode string, no flags.
    static let backspace = SyntheticKeyEvent(keyCode: .delete, isKeyDown: true, flags: 0, unicode: .empty)
    /// PLT-R423: `kVK_ForwardDelete`, no Unicode string, no flags; posted only by `CompletionPrefix`, and only with the
    /// caret read at the end of the field's text, where it deletes no character.
    static let forwardDelete = SyntheticKeyEvent(keyCode: .forwardDelete, isKeyDown: true, flags: 0, unicode: .empty)
    /// 4.4: Shift+Left Arrow, layout independent (PLT-R406 allows Shift here).
    static let shiftLeft = SyntheticKeyEvent(keyCode: .leftArrow, isKeyDown: true, flags: shiftFlag, unicode: .empty)

    /// PLT-R404-R406: Unicode payload on the trigger's keycode, no modifier flags.
    static func unicode(_ chunk: InlineUTF16, keyCode: KeyCode) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: keyCode, isKeyDown: true, flags: 0, unicode: chunk)
    }

    /// PLT-R461 step 3: Command plus the key producing "v" in the current layout.
    static func paste(keyCode: KeyCode) -> SyntheticKeyEvent {
        SyntheticKeyEvent(keyCode: keyCode, isKeyDown: true, flags: commandFlag, unicode: .empty)
    }

    /// PLT-R405: the triggering keycode; restores, macros and revisions use the keycode of a character of the edit if the
    /// current layout types one on a non-action key (`JobKeyCodes.firstCharacter`). No Unicode event rides on an action key (`JobKeyCodes.isActionKey`: Backspace,
    /// Return, keypad Enter, Tab, Space, Escape): an edit they trigger (a Backspace re-composition, PLT-R352; the
    /// commit at a boundary, ENG-R532, ENG-R803, ENG-R1103; a restore on the Escape hotkey, PLT-R353) uses the
    /// keycode of a character of the edit (`JobKeyCodes.firstCharacter`, set by the pipeline) or, without one,
    /// `letterFallback`. Chromium and WebKit derive the DOM `code` (and, for a non-ASCII character, the legacy
    /// `keyCode`) from the keycode, so a Unicode event on `kVK_Return` reaches a web chat composer as Return (it
    /// sends), on `kVK_Delete` as Backspace. The trigger itself reaches the app afterwards as the replay of the
    /// physical key (ADR 0308). A first-character keycode that is itself an action key is never used either.
    static func unicodeKeyCode(for job: EditJob) -> KeyCode {
        let codes = job.keyCodes
        let triggerActs = JobKeyCodes.isActionKey(codes.trigger)
        // A revision (PLT-R357) types the previous word too, so it never rides on the boundary key's keycode.
        let typesFirstCharacter = triggerActs || job.kind == .restore || job.kind == .macro || job.kind == .revision
        if typesFirstCharacter, let first = codes.firstCharacter, !JobKeyCodes.isActionKey(first) { return first }
        return triggerActs ? letterFallback : codes.trigger
    }

    /// `kVK_ANSI_A`: a letter position for the insertion of an edit an action key triggered when the layout types
    /// no character of the edit (practically never: the token holds letters the user typed).
    static let letterFallback = KeyCode(rawValue: 0x00)

    /// PLT-R404, PLT-R480: one grapheme per event unless the rule raises `unicodeChunk`, or the insertion is
    /// long text and the rule allows multi-character events.
    static func insertionChunks(for job: EditJob) -> [InlineUTF16] {
        let parameters = job.plan.parameters
        if parameters.unicodeChunk > 1 {
            return GraphemeChunking.chunks(
                of: job.insertion, maxUTF16: parameters.unicodeChunk, oneGraphemePerEvent: false)
        }
        if parameters.allowMultiCharEvents, job.insertion.count > parameters.longTextThreshold {
            return GraphemeChunking.chunks(
                of: job.insertion, maxUTF16: GraphemeChunking.eventLimit, oneGraphemePerEvent: false)
        }
        return GraphemeChunking.chunks(of: job.insertion, maxUTF16: 1, oneGraphemePerEvent: true)
    }
}

extension SyntheticKeyEvent {
    var released: SyntheticKeyEvent {
        var copy = self
        copy.isKeyDown = false
        return copy
    }
}

/// The ordered key pairs of one job. Each step is posted as keyDown then keyUp (PLT-R407).
struct KeyScript {
    enum Phase: Equatable { case prefix, delete, insert }

    struct Step {
        var event: SyntheticKeyEvent
        var phase: Phase
    }

    private(set) var steps: [Step] = []

    mutating func append(_ event: SyntheticKeyEvent, phase: Phase, count: Int = 1) {
        guard count > 0 else { return }
        for _ in 0..<count { steps.append(Step(event: event, phase: phase)) }
    }

    mutating func appendInsertion(of job: EditJob) {
        let keyCode = SyntheticKeys.unicodeKeyCode(for: job)
        for chunk in SyntheticKeys.insertionChunks(for: job) {
            steps.append(Step(event: SyntheticKeys.unicode(chunk, keyCode: keyCode), phase: .insert))
        }
    }

    /// PLT-R408: wait before step `index`. The first step waits `firstEdit`; the first insertion after a
    /// deletion waits `interEvent + postDeleteSettle`; every other step waits `interEvent`.
    func gap(before index: Int, pacing: Pacing) -> UInt64 {
        guard index > 0 else { return pacing.firstEditNanoseconds }
        let settles = steps[index - 1].phase == .delete && steps[index].phase == .insert
        return pacing.interEventNanoseconds + (settles ? pacing.postDeleteSettleNanoseconds : 0)
    }

    func estimatedNanoseconds(pacing: Pacing) -> UInt64 {
        steps.indices.reduce(0) { $0 &+ gap(before: $1, pacing: pacing) }
    }
}

/// Timing parameters of one job after the PLT-R408 caps.
struct Pacing: Equatable {
    var interEventNanoseconds: UInt64
    var postDeleteSettleNanoseconds: UInt64
    var firstEditNanoseconds: UInt64

    init(_ job: EditJob) {
        let parameters = job.plan.parameters
        interEventNanoseconds = InjectionTiming.cappedNanoseconds(microseconds: parameters.interEventDelayUs)
        postDeleteSettleNanoseconds = InjectionTiming.cappedNanoseconds(microseconds: parameters.postDeleteSettleUs)
        // The worker clears `wordStartedNearFocusChange` when this is not the first edit of the word.
        firstEditNanoseconds =
            job.wordStartedNearFocusChange
            ? InjectionTiming.cappedNanoseconds(microseconds: parameters.firstEditDelayUs) : 0
    }
}

/// Posts a `KeyScript` through the environment with absolute-deadline pacing (PLT-R409).
enum ScriptRunner {
    enum Result: Equatable {
        case completed(lastEventSequence: UInt32)
        case failed(postedAnything: Bool)
    }

    /// PLT-R408: a job longer than its cap fails with `jobTooLong` before posting unless the rule sets
    /// `allowSplit`; then it is split at step (grapheme) boundaries and held keys are replayed between parts.
    static func run(_ script: KeyScript, job: EditJob, limits: StrategyLimits, in environment: any InjectionEnvironment)
        -> StrategyOutcome
    {
        if exceedsCap(script, job: job, limits: limits) { return .failedBeforePosting(.jobTooLong) }
        let pacing = Pacing(job)
        let cap = limits.capNanoseconds(for: job.kind)
        let allowSplit = job.plan.parameters.allowSplit
        switch post(script, pacing: pacing, splitBudget: allowSplit ? cap : nil, in: environment) {
        case .completed(let sequence): return .completed(lastEventSequence: sequence)
        case .failed(let posted):
            return posted ? .failedAfterPosting(.postingFailed) : .failedBeforePosting(.postingFailed)
        }
    }

    /// PLT-R408: the script cannot be posted within its cap and the rule does not allow splitting it.
    static func exceedsCap(_ script: KeyScript, job: EditJob, limits: StrategyLimits) -> Bool {
        !job.plan.parameters.allowSplit
            && script.estimatedNanoseconds(pacing: Pacing(job)) > limits.capNanoseconds(for: job.kind)
    }

    static func post(
        _ script: KeyScript, pacing: Pacing, splitBudget: UInt64?, in environment: any InjectionEnvironment
    )
        -> Result
    {
        var lastPairAt: MonotonicInstant?
        var partStartedAt = environment.now
        var lastSequence: UInt32?
        var postedAnything = false
        for index in script.steps.indices {
            let gap = script.gap(before: index, pacing: pacing)
            if let budget = splitBudget, index > 0, environment.now.nanoseconds(since: partStartedAt) &+ gap > budget {
                environment.releaseHeldEvents()
                partStartedAt = environment.now
            }
            if gap > 0 {
                let base = lastPairAt ?? environment.now
                environment.sleep(until: MonotonicInstant(nanoseconds: base.nanoseconds &+ gap))
            }
            let event = script.steps[index].event
            do {
                _ = try environment.post(event)
                postedAnything = true
                lastSequence = try environment.post(event.released)
            } catch {
                return .failed(postedAnything: postedAnything)
            }
            lastPairAt = environment.now
        }
        guard let lastSequence else { return .failed(postedAnything: false) }
        return .completed(lastEventSequence: lastSequence)
    }
}
