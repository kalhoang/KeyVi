// SPDX-License-Identifier: GPL-3.0-or-later
//
// Toggles, per-app memory and the toggle race on the ax thread (PLT-R390-R392, PRD-R19-R21, contracts.md 10.4).

import AppModel
import Injection
import SettingsStore

/// A manual toggle for the current owner. It lasts until the owner changes: an "always English/Vietnamese"
/// app can be toggled for the moment, and its rule wins again on the next activation (PRD-R21).
struct SessionMode {
    var bundle: BundleKey?
    var mode: TypingMode
}

extension FocusCore {
    /// Tap toggles first, then one revalidation if any key asked for one (PLT-R382, PLT-R389), then the trigger
    /// settle window if a shortcut, Escape, Return, Tab or a click asked for it (PLT-R389).
    func drainInbox() {
        var toggled = false
        var revalidate = false
        var afterTrigger = false
        while let notice = services.inbox.pop() {
            switch notice {
            case .modeToggled(let sequence, let bundle, let mode):
                applyToggle(bundle: bundle, mode: mode)
                appliedToggleSequence = max(appliedToggleSequence, sequence)
                toggled = true
            case .revalidateFocus:
                revalidate = true
            case .revalidateFocusAfterTrigger:
                afterTrigger = true
            }
        }
        if toggled { republishMode() }
        if revalidate { self.revalidate(scanOverlays: false) }
        if afterTrigger { revalidateAfterTrigger() }
    }

    func setMode(_ mode: TypingMode) {
        applyToggle(bundle: current?.identity?.bundle, mode: mode)
        republishMode()
    }

    /// PRD-R20; an ignored app's toggle does nothing (PRD-R21).
    func applyToggle(bundle: BundleKey?, mode: TypingMode) {
        let isOwner = current != nil && bundle == current?.identity?.bundle
        if isOwner, current?.resolution.ignored == true { return }
        memory.recordToggle(bundle: bundle, mode: mode)
        emitMemoryIfChanged()
        if isOwner { sessionMode = SessionMode(bundle: bundle, mode: mode) }
    }

    /// Same focus context, so the same generation: only the mode, its source and the applied toggle sequence
    /// change. The tap then stops using its own override (`override.sequence <= appliedToggleSequence`).
    func republishMode() {
        guard let current else { return }
        let bundle = current.identity?.bundle
        let resolution = memory.resolve(bundle: bundle, ruleDefault: current.decision.defaultMode)
        let (mode, source) = effectiveMode(resolution, bundle: bundle)
        var snapshot = current.snapshot
        guard
            snapshot.mode != mode || snapshot.modeSource != source
                || snapshot.appliedToggleSequence != appliedToggleSequence
        else { return }
        snapshot.mode = mode
        snapshot.modeSource = source
        snapshot.appliedToggleSequence = appliedToggleSequence
        services.output.publish(snapshot)
        self.current?.snapshot = snapshot
        self.current?.resolution = resolution
    }

    func effectiveMode(_ resolution: ModeResolution, bundle: BundleKey?) -> (TypingMode, ModeSource) {
        guard let session = sessionMode, session.bundle == bundle, !resolution.ignored else {
            return (resolution.mode, resolution.source)
        }
        return (session.mode, session.mode == resolution.mode ? resolution.source : .globalMode)
    }

    /// Hands every changed document to the owner for `SettingsStore.recordAppModes` (5 s debounce there).
    func emitMemoryIfChanged() {
        let document = memory.document()
        guard document != lastEmittedDocument else { return }
        lastEmittedDocument = document
        emittedHistory.record(document)
        memoryObserver?(document)
    }
}
