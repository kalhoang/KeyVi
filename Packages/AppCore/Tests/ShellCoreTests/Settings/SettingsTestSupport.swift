// SPDX-License-Identifier: GPL-3.0-or-later
//
// Helpers for the Settings window tests (W2-B): localizers over the shipped catalogs and test doubles for the
// login item service and the Sparkle wrapper.

import AppModel
import Foundation
import RealtimeSupport

@testable import ShellCore

/// The four W2-B tables plus Menu (hotkey names are in the Menu table).
enum SettingsCatalogs {
    static let owned: [StringTable] = [.settings, .macros, .apps, .support]

    static func bundle() throws -> TemporaryAppBundle {
        try TemporaryAppBundle(catalogs: owned + [.menu])
    }
}

struct Localizers {
    let bundle: TemporaryAppBundle
    let vi: Localizer
    let en: Localizer

    init() throws {
        bundle = try SettingsCatalogs.bundle()
        vi = Localizer(language: .vietnamese, appBundle: bundle.bundle)
        en = Localizer(language: .english, appBundle: bundle.bundle)
    }
}

/// `LoginItemService` double: records calls and can fail.
final class FakeLoginItem: LoginItemService, Sendable {
    struct State {
        var status: LoginItemStatus
        var calls: [String] = []
        var failNext = false
        var statusAfterRegister = LoginItemStatus.enabled
    }

    struct Failure: Error {}

    let state: Mutex<State>

    init(status: LoginItemStatus = .notRegistered) { state = Mutex(State(status: status)) }

    var status: LoginItemStatus { state.withLock { $0.status } }
    var calls: [String] { state.withLock { $0.calls } }
    func failNextCall() { state.withLock { $0.failNext = true } }
    func setStatusAfterRegister(_ status: LoginItemStatus) { state.withLock { $0.statusAfterRegister = status } }
    func setStatus(_ status: LoginItemStatus) { state.withLock { $0.status = status } }

    func register() throws {
        try state.withLock { state in
            state.calls.append("register")
            if state.failNext {
                state.failNext = false
                throw Failure()
            }
            state.status = state.statusAfterRegister
        }
    }

    func unregister() throws {
        try state.withLock { state in
            state.calls.append("unregister")
            if state.failNext {
                state.failNext = false
                throw Failure()
            }
            state.status = .notRegistered
        }
    }

    func openSystemSettings() { state.withLock { $0.calls.append("openSystemSettings") } }
}
