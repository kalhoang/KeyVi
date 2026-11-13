// SPDX-License-Identifier: GPL-3.0-or-later
//
// The tap's read of all five snapshots: one atomic load per cell, values borrowed for the duration of `body`
// (PLT-R304, PLT-R388, ADR 0303). Tap thread only, between `ReaderEpoch.enter()` and `exit()`.

extension TapSnapshots {
    @inline(__always)
    func readAll<Result>(
        _ body: (TapSettingsSnapshot, FocusSnapshot, InputSourceSnapshot, SecureInputSnapshot, LifecycleSnapshot) ->
            Result
    ) -> Result {
        settings.read { settings in
            focus.read { focus in
                inputSource.read { inputSource in
                    secureInput.read { secureInput in
                        lifecycle.read { lifecycle in body(settings, focus, inputSource, secureInput, lifecycle) }
                    }
                }
            }
        }
    }
}
