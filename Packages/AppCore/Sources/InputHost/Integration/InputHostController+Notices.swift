// SPDX-License-Identifier: GPL-3.0-or-later
//
// Tap -> main notices and the main thread's view of host state (PRD-R10, PRD-R11, PLT-R323, PLT-R330,
// PLT-R398B, PLT-R905, ENG-R861). Workstream W2-A.

internal import AppModel
internal import Diagnostics
internal import Foundation
internal import Injection
internal import SettingsStore
internal import VietnameseEngine

extension InputHostController {
    /// Main actor, single consumer of the tap's main outbox.
    func drainMainOutbox() {
        while let notice = channels.outbox.toMain.pop() { handle(notice) }
        let drainer = tapLogDrainer
        dependencies.utilityQueue.async { drainer.drain() }
    }

    func handle(_ notice: MainNotice) {
        switch notice {
        case .modeToggled(let sequence, let bundle, let mode):
            latestToggle = (sequence, bundle, mode)
            refreshState()
            onEvent?(.modeChanged(mode, manual: true, bundle: bundle))
        case .secureInputResumedByKey(let generation):
            // PLT-R398B: the tap already resumed; the monitor ends the episode, the menu follows at once.
            secureResumedGeneration = generation
            secureInputMonitor?.keyEvidence(generation: generation)
            refreshState()
        case .tapDisabled(let byTimeout):
            feedFreshPermissions()  // PLT-R330 step 1 re-enables only with valid permissions
            feed(.tapDisabledBySystem(byTimeout: byTimeout))
            if byTimeout, session?.thread.isEnabled == true { counters.tapRecoveries.increment() }
        case .learning(let signal):
            noteLearning(signal)
        case .echoMissed:
            checkPostAccessAfterEchoMiss()
        case .postingBroken:
            feed(.postingBroken)
        case .keyboardTypeSeen(let keyboardType):
            inputSourceMonitor.keyboardTypeSeen(keyboardType)
        }
    }

    /// ADR 0311: the first miss of a run asks the utility queue for `CGPreflightPostEventAccess()`; a revoked
    /// post permission breaks posting at once instead of after three timeouts (PLT-R730).
    func checkPostAccessAfterEchoMiss() {
        let probe = dependencies.permissions
        let feedback = channels.feedback
        let hop = self.hop
        dependencies.utilityQueue.async { [weak self] in
            guard !probe.canPostEvents() else { return }
            feedback.markPostingBroken()
            hop.hop { self?.feed(.postingBroken) }
        }
    }

    /// ENG-R862: the second identical signal in the focused app adds the word for that app (visible, removable and
    /// promotable in Settings). The word is content: it goes to the settings store only, never to a log.
    func noteLearning(_ signal: LearningSignal) {
        guard let proposal = learning.note(signal, in: currentFocus().app?.bundle) else { return }
        let store = settingsStore
        Task { await store.updateSettings { proposal.apply(to: &$0) } }
        onEvent?(.learningProposal(proposal))
    }

    // MARK: State shown by the shell

    /// The same pure function the tap uses (`HostStateResolver`), over the current snapshots, so what the user
    /// sees is what the tap does (PRD-R10, PRD-R11). Emits state and focus changes and keeps the typing-trace
    /// gaps in step with secure input (PLT-R905).
    func refreshState() {
        let snapshots = channels.snapshots
        let focus = snapshots.focus.load()
        let secureInput = snapshots.secureInput.load()
        let inputSource = snapshots.inputSource.load()
        let resolved = HostStateResolver.resolve(
            lifecycle: snapshots.lifecycle.load(), secureInput: secureInput,
            secureResumedGeneration: secureResumedGeneration, inputSource: inputSource,
            focus: focus, effectiveMode: effectiveMode(focus, inputSource: inputSource))
        updateCaptureGap(secureInput: secureInput, focus: focus)
        let key = FocusKey(bundle: focus.app?.bundle, rule: focus.decision.rule)
        if key != lastFocusKey {
            lastFocusKey = key
            publishWordLists(for: key.bundle)  // ENG-R862: the focused app's learned words
            onEvent?(.focusChanged(bundle: key.bundle, rule: key.rule))
        }
        guard resolved != state else { return }
        let previous = state
        state = resolved
        dependencies.logger.log(.hostState(from: previous.code, to: resolved.code), level: .info)
        onEvent?(.stateChanged(resolved))
    }

    /// A bound layout decides (PLT-R373, as in the tap); otherwise the tap's own toggle wins until the ax thread
    /// applied it (contracts.md 10.4); the main thread knows the toggle's bundle from the notice.
    func effectiveMode(_ focus: FocusSnapshot, inputSource: InputSourceSnapshot) -> TypingMode {
        if let bound = inputSource.boundMode { return bound }
        if let toggle = latestToggle, toggle.sequence > focus.appliedToggleSequence, toggle.bundle == focus.app?.bundle
        {
            return toggle.mode
        }
        return focus.mode
    }

    /// PLT-R905: nothing is recorded while secure input is on or a secure field has focus; the capture marks the
    /// gap. One gap at a time: secure input outranks the secure field.
    func updateCaptureGap(secureInput: SecureInputSnapshot, focus: FocusSnapshot) {
        guard let capture = dependencies.capture else { return }
        let resumed = secureResumedGeneration == secureInput.generation
        let wanted: PauseCode? =
            secureInput.enabled && !resumed ? .secureInput : (focus.field.secure ? .secureField : nil)
        guard wanted != captureGap else { return }
        if captureGap != nil { capture.endGap() }
        if let wanted { capture.beginGap(wanted) }
        captureGap = wanted
    }
}
