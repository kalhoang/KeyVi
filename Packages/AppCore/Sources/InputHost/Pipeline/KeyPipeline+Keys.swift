// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R310 steps 6 to 10 for keyDown and keyUp: classification, the engine call, outcomes and jobs, the keyUp
// pairing of ADR 0308, hold while busy (PLT-R311) and hard boundaries (PLT-R340).

internal import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport
internal import VietnameseEngine

extension KeyPipeline {
    func handleKeyDown(
        _ event: RawKeyEvent, now: MonotonicInstant, probe: Bool, state: HostState, restore: Bool,
        focus: FocusSnapshot, inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        if event.autorepeat, consumedKeys.entry(event.keyCode) == .hotkey { return consumeAsHotkey(event) }
        consumedKeys.set(event.keyCode, .none)  // a new keyDown ends any stale pairing for this key
        let afterDeadKey = keyState.deadKeyPending
        keyState.deadKeyPending = false
        // Step 6: paused, EN mode or a passThrough strategy: do not feed the engine.
        guard case .ready(.vietnamese) = state, focus.decision.plan.strategy != .passThrough else {
            return passOrHold(event, now: now, probe: probe)
        }
        if afterDeadKey {  // PLT-R354, before any hotkey use: the key after a dead key passes untouched
            hardBoundary(.unknown, job: .navigation, generation: focus.generation)
            return passOrHold(event, now: now, probe: probe)
        }
        let key = KeyInputContext(event: event, now: now, probe: probe)
        if restore { return restoreLastWord(key, focus: focus, inputSource: inputSource) }
        let keyClass = KeyClassification.classify(event, table: inputSource.table)  // step 7
        observeLayout(event, keyClass: keyClass, inputSource: inputSource, now: now)
        return feed(keyClass, key, focus: focus, inputSource: inputSource)
    }

    /// Steps 8 to 10 by key class (PLT-R340, PLT-R341, PLT-R350 to PLT-R356).
    private func feed(
        _ keyClass: KeyClass, _ key: KeyInputContext, focus: FocusSnapshot, inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        let generation = focus.generation
        switch keyClass {
        case .character(let character, let fromKeypad):
            if key.event.autorepeat {  // PLT-R351: untransformed, ends the composition
                hardBoundary(.unknown, job: .navigation, generation: generation)
                return passOrHold(key.event, now: key.now, probe: key.probe)
            }
            // PLT-R355: `fromKeypad` lets the engine keep keypad digits out of VNI tone handling.
            let input = EngineEvent.key(KeyInput(character, fromKeypad: fromKeypad))
            return compose(input, kind: .compose, key, focus: focus, inputSource: inputSource)
        case .backspace:  // PLT-R351, PLT-R352: reported one by one, autorepeat included
            return compose(.backspace, kind: .backspaceRecompose, key, focus: focus, inputSource: inputSource)
        case .returnKey: return commitLine("\n", key, focus: focus, inputSource: inputSource)
        case .tab: return commitLine("\t", key, focus: focus, inputSource: inputSource)
        case .escape: hardBoundary(.shortcut, job: .escape, generation: generation)
        case .navigation: hardBoundary(.cursorMoved, job: .navigation, generation: generation)  // PLT-R356
        case .forwardDelete: hardBoundary(.forwardDelete, job: .navigation, generation: generation)
        case .commandOrControlChord, .optionChord: hardBoundary(.shortcut, job: .commandChord, generation: generation)
        case .deadKey:
            hardBoundary(.unknown, job: .navigation, generation: generation)
            keyState.deadKeyPending = true
        case .functionKey, .unmapped, .modifierOnly: hardBoundary(.unknown, job: nil, generation: generation)
        }
        return passOrHold(key.event, now: key.now, probe: key.probe)
    }

    /// Return and Tab are fed to the engine first (commit and restore, ENG-R912, P0-3), then they are a hard
    /// boundary (ADR 0306 decision 3), so a chat app never receives Return before the correction.
    private func commitLine(
        _ character: Character, _ key: KeyInputContext, focus: FocusSnapshot, inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        let verdict = compose(
            .key(KeyInput(character)), kind: .compose, key, focus: focus, inputSource: inputSource)
        hardBoundary(.cursorMoved, job: .returnOrTab, generation: focus.generation)
        return verdict
    }

    /// PLT-R353: the restore binding asks the engine; an edit consumes the key, otherwise the key passes and
    /// Escape is a hard boundary (an Escape consumed as restore is not, so the engine keeps the token).
    private func restoreLastWord(
        _ key: KeyInputContext, focus: FocusSnapshot, inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        let replaced = engine.activeDisplay
        let output = engine.handle(.restoreToggle)
        engineDirty = true
        if case .edit(let edit, _) = output.action, edit.deleteCount > 0 || !edit.insert.isEmpty {
            return apply(output, kind: .restore, replaced: replaced, key, focus: focus, inputSource: inputSource)
        }
        if key.event.keyCode == .escape { hardBoundary(.shortcut, job: .escape, generation: focus.generation) }
        return passOrHold(key.event, now: key.now, probe: key.probe)
    }

    /// Step 8: the one engine call for this key.
    private func compose(
        _ input: EngineEvent, kind: EditKind, _ key: KeyInputContext, focus: FocusSnapshot,
        inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        let replaced = engine.activeDisplay
        if case .key = input, replaced.isEmpty {  // a new word (or a separator after a committed one)
            keyState.wordStartedAt = key.now
            keyState.reopenedWord = false
        }
        let output = engine.handle(input)
        engineDirty = true
        keyState.engineFedByThisKey = true  // PLT-R398B: the first key after a secure-input release reached the engine
        if case .backspace = input, replaced.isEmpty { noteReentry(output) }
        if let learning = output.learning { notifyMain(.learning(learning)) }  // ENG-R861, memory only
        return apply(output, kind: kind, replaced: replaced, key, focus: focus, inputSource: inputSource)
    }

    /// ENG-R1002: a Backspace with no active word that edits or leaves a word active walked back into the
    /// committed history, so what follows edits text the engine did not see being typed (PLT-R342). The extra
    /// display read happens only on this rare path.
    private func noteReentry(_ output: EngineOutput) {
        if case .edit = output.action {
            keyState.reopenedWord = true
        } else if !engine.activeDisplay.isEmpty {
            keyState.reopenedWord = true
        }
    }

    /// Steps 9 and 10 (ADR 0306 decision 4).
    private func apply(
        _ output: EngineOutput, kind: EditKind, replaced: String, _ key: KeyInputContext, focus: FocusSnapshot,
        inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        guard case .edit(let edit, let thenPassThrough) = output.action else {
            return passOrHold(key.event, now: key.now, probe: key.probe)
        }
        if edit.deleteCount == 0 && edit.insert.isEmpty {
            if thenPassThrough { return passOrHold(key.event, now: key.now, probe: key.probe) }
            consumedKeys.set(key.event.keyCode, .withoutJob)  // swallowed without a job; its keyUp too
            outcome = .consumedForEdit
            return .swallow
        }
        if kind == .restore {
            return applyRestore(edit, replaced: replaced, key, focus: focus, inputSource: inputSource)
        }
        let record = Self.record(key.event, probe: key.probe)
        let job = makeEditJob(
            edit, kind: editKind(kind, decision: output.decision), replaced: replaced,
            trigger: thenPassThrough ? nil : record, key, focus: focus, inputSource: inputSource)
        guard push(.edit(job)) else { return queueFull(now: key.now) }
        if thenPassThrough {
            // P0-3: punctuation and Return reach the app after the correction, as a replay of the original key.
            guard push(.replay(context.queue.nextSequence(), record)) else { return queueFull(now: key.now) }
            outcome = .held
            return .swallow
        }
        consumedKeys.set(key.event.keyCode, .job(job.sequence))  // PLT-R313
        outcome = .consumedForEdit
        return .swallow
    }

    /// Macros keep their kind; any other edit of a re-opened word is a re-entry (PLT-R342).
    private func editKind(_ kind: EditKind, decision: CommitDecision?) -> EditKind {
        if decision == .macro { return .macro }
        return keyState.reopenedWord ? .reentry : kind
    }

    /// PLT-R353, ADR 0308: the restore key is a hotkey. Its edit carries no trigger, so an abandoned or
    /// discarded restore replays nothing (an Escape would close Spotlight or a dialog), and its keyUp is
    /// consumed whatever the job's outcome.
    private func applyRestore(
        _ edit: TextEdit, replaced: String, _ key: KeyInputContext, focus: FocusSnapshot,
        inputSource: InputSourceSnapshot
    ) -> TapVerdict {
        let job = makeEditJob(
            edit, kind: .restore, replaced: replaced, trigger: nil, key, focus: focus, inputSource: inputSource)
        guard push(.edit(job)) else { return queueFull(now: key.now) }
        return consumeAsHotkey(key.event)
    }

    private func makeEditJob(
        _ edit: TextEdit, kind: EditKind, replaced: String, trigger: KeyEventRecord?, _ key: KeyInputContext,
        focus: FocusSnapshot, inputSource: InputSourceSnapshot
    ) -> EditJob {
        // PLT-R405: restores and macros type with the keycode producing their first character, if any.
        let firstCharacter =
            kind == .restore || kind == .macro
            ? edit.insert.first.flatMap { inputSource.table?.keyCode(producing: $0) } : nil
        return EditJob(
            sequence: context.queue.nextSequence(), generation: focus.generation, plan: focus.decision.plan,
            field: focus.fieldHandle, kind: kind, deleteCount: edit.deleteCount,
            deleteUTF16Count: edit.deleteUTF16Count, replacedText: replaced.isEmpty ? nil : replaced,
            insertion: edit.insert,
            keyCodes: JobKeyCodes(trigger: key.event.keyCode, firstCharacter: firstCharacter, paste: seen.pasteKeyCode),
            trigger: trigger,
            verifyBeforeApply: keyState.reopenedWord && focus.decision.verifyReentry != .never,
            wordStartedNearFocusChange: wordStartedNearFocusChange(focus), createdAt: key.now, isProbe: key.probe)
    }

    /// PLT-R408: the word began within 300 ms of a focus change or click.
    private func wordStartedNearFocusChange(_ focus: FocusSnapshot) -> Bool {
        guard let start = keyState.wordStartedAt else { return false }
        var anchor = focus.changedAt
        if let click = keyState.lastPointerDownAt, click > anchor { anchor = click }
        return start >= anchor && start.nanoseconds(since: anchor) <= 300_000_000
    }

    // MARK: keyUp (PLT-R313, ADR 0308)

    func handleKeyUp(_ event: RawKeyEvent, now: MonotonicInstant, probe: Bool) -> TapVerdict {
        switch consumedKeys.take(event.keyCode) {
        case .none:
            return passOrHold(event, now: now, probe: probe)
        case .hotkey, .withoutJob:
            outcome = .consumedPairedKeyUp
            return .swallow
        case .job(let job):
            switch context.feedback.outcome(of: job) {
            case .executed?, .executedWithFallback?:
                outcome = .consumedPairedKeyUp
                return .swallow
            case .abandoned?, .discardedForGeneration?, .passedThroughByFallback?:
                return passOrHold(event, now: now, probe: probe)  // its keyDown was replayed
            case nil:  // still queued: the worker drops it if the job executes, replays it otherwise
                let paired = InjectionJob.pairedKeyUp(
                    context.queue.nextSequence(), Self.record(event, probe: probe), forJob: job)
                guard push(paired) else { return queueFull(now: now) }
                outcome = .consumedPairedKeyUp
                return .swallow
            }
        }
    }

    // MARK: Outcomes

    /// Step 10: pass, unless jobs are in flight (until their echo, ADR 0311): then hold as a replay (PLT-R311).
    func passOrHold(_ event: RawKeyEvent, now: MonotonicInstant, probe: Bool) -> TapVerdict {
        guard context.queue.inFlight > 0 else {
            outcome = .passed
            return .pass
        }
        guard push(.replay(context.queue.nextSequence(), Self.record(event, probe: probe))) else {
            return queueFull(now: now)
        }
        outcome = .held
        return .swallow
    }

    /// PLT-R730: fail-open passes everything in this very callback; a keyUp also forgets its pairing.
    func failOpenPass(_ event: RawKeyEvent) -> TapVerdict {
        if event.kind != .flagsChanged { consumedKeys.set(event.keyCode, .none) }
        outcome = .passed
        return .pass
    }

    func consumeAsHotkey(_ event: RawKeyEvent) -> TapVerdict {
        consumedKeys.set(event.keyCode, .hotkey)
        outcome = .consumedAsHotkey
        return .swallow
    }

    /// The ring is full (the worker is far behind, PLT-R314): pass rather than block, and drop the composition
    /// because the engine's view no longer matches the field.
    private func queueFull(now: MonotonicInstant) -> TapVerdict {
        context.tapLog.push(TapLogRecord(code: .jobQueueFull, at: now))
        resetEngineIfDirty(.unknown)
        outcome = .passed
        return .pass
    }

    @inline(__always)
    private func push(_ job: InjectionJob) -> Bool {
        guard context.queue.push(job) else { return false }
        lastPushWasBoundary = false
        return true
    }

    // MARK: Boundaries

    /// PLT-R340: reset the composition and, while jobs are in flight, mark the boundary in FIFO order.
    func hardBoundary(_ reason: ResetReason, job: BoundaryReason?, generation: FocusGeneration) {
        resetEngineIfDirty(reason)
        keyState.wordStartedAt = nil
        keyState.reopenedWord = false
        guard let job, !lastPushWasBoundary, context.queue.inFlight > 0 else { return }
        let boundary = BoundaryJob(sequence: context.queue.nextSequence(), reason: job, generation: generation)
        if context.queue.push(.boundary(boundary)) { lastPushWasBoundary = true }
    }

    /// A clean engine is in its initial state, so its reset is skipped (no observable difference).
    func resetEngineIfDirty(_ reason: ResetReason) {
        guard engineDirty else { return }
        _ = engine.handle(.reset(reason))
        engineDirty = false
    }

    func notifyMain(_ notice: MainNotice) {
        if context.outbox.toMain.push(notice) { context.outbox.mainSignal.signal() }
    }

    /// PLT-R363 (debug builds) and the keyboard-type notice for `InputSourceMonitor.keyboardTypeSeen`.
    private func observeLayout(
        _ event: RawKeyEvent, keyClass: KeyClass, inputSource: InputSourceSnapshot, now: MonotonicInstant
    ) {
        guard let table = inputSource.table else { return }
        if event.keyboardType != table.keyboardType && keyState.reportedKeyboardType != event.keyboardType {
            keyState.reportedKeyboardType = event.keyboardType
            notifyMain(.keyboardTypeSeen(event.keyboardType))
        }
        #if DEBUG
        if case .character(let character, _) = keyClass,
            !KeyClassification.layoutAgrees(with: event, character: character)
        {
            // Keycode plus the input-source generation only (the drain maps it to the layout ID).
            let record = TapLogRecord(
                code: .layoutMismatch, at: now, a: UInt64(event.keyCode.rawValue), b: inputSource.generation)
            context.tapLog.push(record)
        }
        #endif
    }

    /// A bitwise copy of the physical event for a replay (PLT-R324).
    @inline(__always)
    static func record(_ event: RawKeyEvent, probe: Bool) -> KeyEventRecord {
        let kind: KeyEventRecord.Kind =
            switch event.kind {
            case .keyUp: .keyUp
            case .flagsChanged: .flagsChanged
            default: .keyDown
            }
        return KeyEventRecord(
            kind: kind, keyCode: event.keyCode, flags: event.flags, autorepeat: event.autorepeat,
            keyboardType: event.keyboardType, unicode: event.unicode, receivedAt: event.receivedAt, isProbe: probe)
    }
}

/// The physical key being processed.
struct KeyInputContext {
    var event: RawKeyEvent
    var now: MonotonicInstant
    var probe: Bool
}

/// Reset and boundary-job reasons for a host-state transition (PLT-R210). No collections: transitions run on
/// the tap thread too.
enum BoundaryReasons {
    static func transition(from old: HostStateCode, to new: HostStateCode) -> (reset: ResetReason, job: BoundaryReason)
    {
        func either(_ test: (HostStateCode) -> Bool) -> Bool { test(old) || test(new) }
        if either({ $0 == .paused(.secureInput) || $0 == .paused(.secureField) }) {
            return (.secureInputChanged, .secureInputChanged)
        }
        if either({ $0 == .paused(.nonLatinInputSource) || $0 == .paused(.builtInVietnameseSource) }) {
            return (.inputSourceChanged, .inputSourceChanged)
        }
        if either({ $0 == .paused(.passThroughRule) || $0 == .paused(.noTextFocus) }) {
            return (.configurationChanged, .ruleChanged)
        }
        if either({ $0 == .paused(.userDisabled) }) { return (.configurationChanged, .settingsChanged) }
        let isReady: (HostStateCode) -> Bool = { $0 == .readyVietnamese || $0 == .readyEnglish }
        if isReady(old) && isReady(new) { return (.modeToggled, .modeToggled) }
        return (.unknown, .sessionChanged)
    }
}
