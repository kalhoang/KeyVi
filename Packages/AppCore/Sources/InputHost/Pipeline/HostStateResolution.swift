// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Host state per key (02-platform.md 2.1, PLT-R310 step 6). The same pure function serves the tap and the
// main thread's icon and menu (PRD-R10, PRD-R11), so what the user sees is what the tap does.

internal import AppModel

enum HostStateResolution {
    static func resolve(
        lifecycle: LifecycleSnapshot, secureInput: SecureInputSnapshot, secureResumedGeneration: UInt64?,
        inputSource: InputSourceSnapshot, focus: FocusSnapshot, effectiveMode: TypingMode
    ) -> HostState {
        switch lifecycle.phase {
        case .noPermission: return .noPermission
        case .starting: return .starting
        case .failOpen(let reason): return .failOpen(reason)
        case .sessionInactive: return .paused(.sessionInactive)
        case .running: break
        }
        if lifecycle.diagnosticsPassThrough { return .paused(.diagnosticsTest) }  // PLT-R1205 guided test
        if lifecycle.userDisabled { return .paused(.userDisabled) }
        // PLT-R398A: only two signals pause for security, the OS secure-input state and a secure field.
        // PLT-R398B: key evidence for this generation means the OS flag no longer blocks the tap.
        if secureInput.enabled && secureResumedGeneration != secureInput.generation {
            return .paused(.secureInput(secureInput.holder))
        }
        if focus.field.secure || focus.pause == .secureField { return .paused(.secureField) }  // PLT-R387
        // PLT-R372 before PLT-R371: the built-in Vietnamese sources are input modes, so the more specific
        // reason must be tested first or it could never be shown.
        if inputSource.source.isBuiltInVietnamese { return .paused(.builtInVietnameseSource) }
        if inputSource.source.kind != .asciiLayout {
            return .paused(.nonLatinInputSource(name: inputSource.source.localizedName))
        }
        if let pause = focus.pause, case .passThroughRule = pause { return .paused(pause) }
        if focus.pause == .noTextFocus || lacksTextFocus(focus) { return .paused(.noTextFocus) }
        return .ready(effectiveMode)
    }

    /// PLT-R386 gating from the focus snapshot, with the ax thread's own definition (`TextFocusGate`): a text
    /// role or the search-field subrole is editable text whatever the settable flag says, so the tap and the
    /// menu never pause a field the ax thread published as ready (PLT-R523: one resolution, not two).
    /// `byEngine` is resolved to a concrete value on the ax thread; if it ever arrives here it gates like `never`.
    static func lacksTextFocus(_ focus: FocusSnapshot) -> Bool {
        TextFocusGate.blocks(focus.decision.requireTextFocus, field: focus.field)
    }

    /// PLT-R373: with the layout binding on, a layout designated VI or EN decides the mode, ahead of the toggle
    /// hotkey, per-app memory and the global mode (the toggle does nothing on a bound layout, `KeyPipeline`).
    /// Otherwise the tap's own toggle wins until the ax thread has applied it to memory (contracts.md 10.4,
    /// PLT-R391); the focus owner is matched by pid, which identifies the same process the toggle was made in.
    static func effectiveMode(
        focus: FocusSnapshot, inputSource: InputSourceSnapshot, override: ToggleOverride?
    ) -> TypingMode {
        if let bound = inputSource.boundMode { return bound }
        if let override, override.sequence > focus.appliedToggleSequence,
            override.pid == (focus.app?.pid ?? ToggleOverride.noProcess)
        {
            return override.mode
        }
        return focus.mode
    }
}

/// The tap's latest VI/EN toggle (contracts.md 10.4).
struct ToggleOverride: Equatable {
    static let noProcess: Int32 = -1
    var sequence: UInt64
    var pid: Int32
    var mode: TypingMode
}
