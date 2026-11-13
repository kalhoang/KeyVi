// SPDX-License-Identifier: GPL-3.0-or-later
//
// Focus check of the guided test (PLT-R1205 step 3, PLT-R387): the runner types only while the field the user
// confirmed still has keyboard focus. Runs on the guided-test thread through bounded AX reads (100 ms messaging
// timeout, PLT-R342, PLT-R384); any doubt (timeout, AX unavailable, no focused element) counts as "focus moved",
// so the runner stops rather than type into an unknown field.

public import Injection

public enum GuidedTestFocus {
    /// A check for `ProbeStopSignal`: the system-wide focused application must be `pid` and, when the handle
    /// carries an AX element, that application's focused element must be this element. A handle without an
    /// element (fakes, apps without AX) is checked at the application level only.
    public static func check(ax: any AXProvider, pid: Int32, field: FieldHandle?) -> @Sendable () -> Bool {
        let element = field?.element
        return {
            guard case .success(let focusedPID?) = ax.focusedApplication(), focusedPID == pid else { return false }
            guard let element else { return true }
            guard case .success(let focused?) = ax.focusedElement(pid: pid) else { return false }
            return focused.element == element
        }
    }
}
