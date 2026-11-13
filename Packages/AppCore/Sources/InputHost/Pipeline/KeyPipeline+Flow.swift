// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R310 steps 1 to 6: tap-disabled events, echo settlement and fail-open, marker check, pointer and scroll,
// snapshot reconciliation, secure-input resume, host state and hotkeys.

internal import AppModel
internal import Diagnostics
internal import Injection
internal import RealtimeSupport
internal import VietnameseEngine

/// PLT-R382: a keyDown after this much keyboard silence asks the ax thread to revalidate focus.
private let idleRevalidationNanoseconds: UInt64 = 500_000_000

extension KeyPipeline {
    /// Returns the verdict and whether the event was a latency-probe event.
    func process(_ event: RawKeyEvent, now: MonotonicInstant) -> (TapVerdict, Bool) {
        if event.kind == .tapDisabledByTimeout || event.kind == .tapDisabledByUserInput {
            outcome = nil
            handleTapDisabled(event, now: now)  // step 1
            return (.pass, false)
        }
        settleEchoes(now: now)
        let probe: Bool
        switch context.marker.classify(event.userData) {  // step 2 (PLT-R321, PLT-R323)
        case .echo(let sequence):
            context.echo.observed(sequence, at: now)
            outcome = nil
            return (.pass, false)
        case .probe: probe = true  // processed as physical (PLT-R810)
        case .foreign: probe = false
        }
        switch event.kind {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:  // step 3: never held (PLT-R317)
            outcome = nil
            handlePointerDown(now: now)
            return (.pass, probe)
        case .scrollWheel:  // PLT-R301: cancels a modifier tap in progress, nothing else
            outcome = nil
            _ = hotkeys.handle(.scroll(at: now))
            return (.pass, probe)
        case .keyDown, .keyUp, .flagsChanged:
            let verdict = context.snapshots.readAll { settings, focus, inputSource, secureInput, lifecycle in
                processKeyboard(
                    event, now: now, probe: probe, settings: settings, focus: focus, inputSource: inputSource,
                    secureInput: secureInput, lifecycle: lifecycle)
            }
            return (verdict, probe)
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            return (.pass, probe)
        }
    }

    /// Steps 4 to 10 for a keyboard event. Snapshots are passed as borrowed parameters, never copied into a
    /// struct, so reading them costs no retain.
    func processKeyboard(
        _ event: RawKeyEvent, now: MonotonicInstant, probe: Bool, settings: TapSettingsSnapshot,
        focus: FocusSnapshot, inputSource: InputSourceSnapshot, secureInput: SecureInputSnapshot,
        lifecycle: LifecycleSnapshot
    ) -> TapVerdict {
        noteKeyboardActivity(event, now: now)
        reconcile(
            settings: settings, focus: focus, inputSource: inputSource, secureInput: secureInput, lifecycle: lifecycle)
        resumeSecureInputIfNeeded(event, secureInput: secureInput, generation: focus.generation, now: now)
        let mode = HostStateResolution.effectiveMode(focus: focus, override: toggleOverride)
        let state = HostStateResolution.resolve(
            lifecycle: lifecycle, secureInput: secureInput, secureResumedGeneration: seen.secureResumedGeneration,
            inputSource: inputSource, focus: focus, effectiveMode: mode)
        noteStateTransition(state, generation: focus.generation)
        let hotkey = feedHotkeys(event, now: now)
        if seen.postingBroken || !state.allowsSwallowing { return failOpenPass(event) }  // PLT-R730
        let hotkeysActive = !lifecycle.recorderActive  // PRD-R15: the recorder is capturing keys
        if hotkeysActive && (hotkey == .toggleTap || hotkey == .toggleCombo) {
            toggleMode(from: mode, state: state, focus: focus)
            if hotkey == .toggleCombo { return consumeAsHotkey(event) }
        }
        switch event.kind {
        case .keyUp: return handleKeyUp(event, now: now, probe: probe)
        case .keyDown:
            let restore = hotkeysActive && hotkey == .restoreCandidate && focus.decision.restoreHotkeyEnabled
            return handleKeyDown(
                event, now: now, probe: probe, state: state, restore: restore, focus: focus, inputSource: inputSource)
        default: return passOrHold(event, now: now, probe: probe)
        }
    }

    // MARK: Step 1 and echo liveness

    func handleTapDisabled(_ event: RawKeyEvent, now: MonotonicInstant) {
        // PLT-R330: the lifecycle owner re-enables the tap and flushes held events; the tap resets, logs, counts.
        let byTimeout = event.kind == .tapDisabledByTimeout
        if byTimeout { context.metrics.tapTimeouts.increment() }
        context.tapLog.push(TapLogRecord(code: byTimeout ? .tapDisabledByTimeout : .tapDisabledByUserInput, at: now))
        notifyMain(.tapDisabled(byTimeout: byTimeout))
        let generation = context.snapshots.focus.read { $0.generation }
        hardBoundary(.eventTapReenabled, job: .tapReenabled, generation: generation)
    }

    /// ADR 0311: settle echoed and timed-out jobs; three consecutive misses fail open in this callback.
    func settleEchoes(now: MonotonicInstant) {
        _ = context.echo.settle(now: now)
        let misses = context.echo.consecutiveMisses
        if misses > seen.echoMisses {
            context.metrics.echoLosses.increment(by: UInt64(misses - seen.echoMisses))
            context.tapLog.push(TapLogRecord(code: .echoMissing, at: now, a: UInt64(misses)))
            if seen.echoMisses == 0 { notifyMain(.echoMissed) }  // first miss of a run (PLT-R323)
        }
        seen.echoMisses = misses
        if misses < seen.missBaseline { seen.missBaseline = 0 }  // an echo ended the run of misses
        // The lifecycle owner cleared posting broken since the last callback (PLT-R731): misses counted before
        // the recovery do not count again; only a new run of three breaks posting.
        if seen.postingBroken && !context.feedback.isPostingBroken { seen.missBaseline = misses }
        if misses - seen.missBaseline >= context.echo.missesForBroken && !context.feedback.isPostingBroken {
            context.feedback.markPostingBroken()
            notifyMain(.postingBroken)
        }
        let broken = context.feedback.isPostingBroken
        if broken != seen.postingBroken {
            seen.postingBroken = broken
            resetEngineIfDirty(.unknown)  // PLT-R210: into or out of fail-open
        }
    }

    // MARK: Step 3

    func handlePointerDown(now: MonotonicInstant) {
        _ = hotkeys.handle(.pointerDown(at: now))
        keyState.lastPointerDownAt = now
        let generation = context.snapshots.focus.read { $0.generation }
        hardBoundary(.pointerClicked, job: .mouseDown, generation: generation)
    }

    // MARK: Steps 4 to 6

    func noteKeyboardActivity(_ event: RawKeyEvent, now: MonotonicInstant) {
        if event.kind == .keyDown, let last = keyState.lastKeyboardEventAt,
            now.nanoseconds(since: last) >= idleRevalidationNanoseconds
        {
            if context.outbox.toAX.push(.revalidateFocus) { context.outbox.axSignal.signal() }
        }
        keyState.lastKeyboardEventAt = now
    }

    /// PLT-R398B: a keyDown that reaches the tap while the OS flag is on proves secure input no longer blocks
    /// it: leave the pause for this generation, start a fresh composition, tell main. Never waits for a poll.
    func resumeSecureInputIfNeeded(
        _ event: RawKeyEvent, secureInput: SecureInputSnapshot, generation: FocusGeneration, now: MonotonicInstant
    ) {
        guard event.kind == .keyDown, secureInput.enabled, seen.secureResumedGeneration != secureInput.generation
        else { return }
        seen.secureResumedGeneration = secureInput.generation
        notifyMain(.secureInputResumedByKey(generation: secureInput.generation))
        context.tapLog.push(TapLogRecord(code: .secureInputResumedByKey, at: now, a: secureInput.generation))
        hardBoundary(.secureInputChanged, job: .secureInputChanged, generation: generation)
    }

    /// PLT-R210: every transition into or out of paused or fail-open (and VI/EN changes) resets.
    func noteStateTransition(_ state: HostState, generation: FocusGeneration) {
        let code = state.code
        guard let previous = seen.stateCode else {
            seen.stateCode = code
            return
        }
        guard code != previous else { return }
        seen.stateCode = code
        let reasons = BoundaryReasons.transition(from: previous, to: code)
        hardBoundary(reasons.reset, job: reasons.job, generation: generation)
    }

    func feedHotkeys(_ event: RawKeyEvent, now: MonotonicInstant) -> HotkeyResult {
        switch event.kind {
        case .flagsChanged:
            hotkeys.handle(
                .flagsChanged(keyCode: event.keyCode, modifiers: EventFlags.modifierKeys(event.flags), at: now))
        case .keyDown:
            hotkeys.handle(
                .keyDown(
                    keyCode: event.keyCode, modifiers: EventFlags.modifierKeys(event.flags),
                    autorepeat: event.autorepeat, at: now))
        case .keyUp:
            hotkeys.handle(.keyUp(keyCode: event.keyCode, at: now))
        default:
            .none
        }
    }

    /// PRD-R14, PRD-R20, contracts.md 10.4: flip at once, tag with a sequence, tell main and ax, reset.
    func toggleMode(from mode: TypingMode, state: HostState, focus: FocusSnapshot) {
        if case .paused(.passThroughRule) = state { return }  // PRD-R21: an ignored app's toggle does nothing
        toggleSequence &+= 1
        let newMode = mode.toggled
        toggleOverride = ToggleOverride(
            sequence: toggleSequence, pid: focus.app?.pid ?? ToggleOverride.noProcess, mode: newMode)
        let bundle = focus.app?.bundle
        notifyMain(.modeToggled(sequence: toggleSequence, bundle: bundle, mode: newMode))
        if context.outbox.toAX.push(.modeToggled(sequence: toggleSequence, bundle: bundle, mode: newMode)) {
            context.outbox.axSignal.signal()
        }
        hardBoundary(.modeToggled, job: .modeToggled, generation: focus.generation)
        if case .ready = state { seen.stateCode = HostState.ready(newMode).code }
    }

    // MARK: Reconciliation (PLT-R340, PLT-R1008, ADR 0306 decision 2)

    /// Compares the snapshots with what the pipeline last saw: settings and variant changes build a fresh
    /// engine (a hard boundary by itself); focus, input-source, secure-input and lifecycle changes reset.
    func reconcile(
        settings: TapSettingsSnapshot, focus: FocusSnapshot, inputSource: InputSourceSnapshot,
        secureInput: SecureInputSnapshot, lifecycle: LifecycleSnapshot
    ) {
        var change = BoundaryAccumulator()
        let resetCount = context.feedback.compositionResetCount
        if resetCount != seen.resetCount {  // the worker flushed or discarded (ADR 0308)
            seen.resetCount = resetCount
            change.note(.unknown, job: nil)
        }
        var rebuild = false
        if settings.generation != seen.settingsGeneration {
            seen.settingsGeneration = settings.generation
            hotkeys = Factory.Hotkeys(toggle: settings.toggleHotkey, restore: settings.restoreHotkey)
            rebuild = true
            change.note(.configurationChanged, job: .settingsChanged)
        }
        reconcileFocus(focus, into: &change, rebuild: &rebuild)
        if inputSource.generation != seen.inputSourceGeneration {
            seen.inputSourceGeneration = inputSource.generation
            seen.pasteKeyCode = inputSource.table?.keyCode(producing: "v")
            change.note(.inputSourceChanged, job: .inputSourceChanged)
        }
        if secureInput.generation != seen.secureGeneration {
            seen.secureGeneration = secureInput.generation
            change.note(.secureInputChanged, job: .secureInputChanged)
        }
        if lifecycle.generation != seen.lifecycleGeneration {
            seen.lifecycleGeneration = lifecycle.generation
            change.note(.unknown, job: .sessionChanged)
        }
        if rebuild {
            engine = factory.makeEngine(for: focus.decision.variant, settings: settings)
            engineDirty = false
            seen.engineVariant = focus.decision.variant
        }
        if let reset = change.reset { hardBoundary(reset, job: change.job, generation: focus.generation) }
    }

    private func reconcileFocus(_ focus: FocusSnapshot, into change: inout BoundaryAccumulator, rebuild: inout Bool) {
        guard focus.generation != seen.focus.generation else { return }
        let identity = FocusIdentity(focus)
        if !identity.sameOwner(as: seen.focus) {
            change.note(identity.pid != seen.focus.pid ? .applicationChanged : .focusChanged, job: .focusChanged)
        } else if identity.decision != seen.focus.decision {
            change.note(.configurationChanged, job: .ruleChanged)
        }
        if focus.decision.variant != seen.engineVariant { rebuild = true }
        seen.focus = identity
    }

}

/// Collects the boundaries one reconciliation found: the last reset reason, the first job reason.
struct BoundaryAccumulator {
    var reset: ResetReason?
    var job: BoundaryReason?

    mutating func note(_ reason: ResetReason, job jobReason: BoundaryReason?) {
        reset = reason
        if job == nil { job = jobReason }
    }
}

extension HostState {
    /// Keys may be swallowed (for edits, holds or hotkeys) only while the tap is running; every other lifecycle
    /// phase passes everything (PLT-R730). Pauses still hold while jobs are in flight (PLT-R311).
    var allowsSwallowing: Bool {
        switch self {
        case .noPermission, .starting, .failOpen: false
        case .ready, .paused: true
        }
    }
}
