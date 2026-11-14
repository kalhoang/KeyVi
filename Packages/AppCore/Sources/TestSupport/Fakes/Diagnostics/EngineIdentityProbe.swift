// SPDX-License-Identifier: GPL-3.0-or-later
//
// The app's engine identity for test targets that cannot import InputHost (the scanner's tests): the recorder and the
// scanner must compute the same `DevEngineIdentity` for the same engine (ADR 0007 decision 13).

public import Diagnostics
internal import InputHost

public enum EngineIdentityProbe {
    /// What the running app writes in its trace file lines.
    public static func appIdentity() -> String? { DevEngineIdentity.ofLinkedEngine() }
}
