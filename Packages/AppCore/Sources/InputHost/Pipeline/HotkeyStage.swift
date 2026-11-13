// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R310 step 5 as the pipeline sees it. The recogniser itself (PRD-R14 to PRD-R18) is W1-E's
// `HotkeyRecognizer`; the pipeline is generic over this protocol so its own tests can run against a reference
// recogniser (TestSupport) independently of W1-E, with static dispatch on the hot path.

public import AppModel

/// A value-type hotkey state machine fed with the tap's events (contracts.md 10.2).
public protocol HotkeyRecognizing {
    init(toggle: HotkeyBinding, restore: HotkeyBinding?)
    mutating func handle(_ input: HotkeyInput) -> HotkeyResult
}

extension HotkeyRecognizer: HotkeyRecognizing {}
