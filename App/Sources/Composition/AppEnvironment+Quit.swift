// SPDX-License-Identifier: GPL-3.0-or-later
//
// Quit (PLT-R1003, PLT-R1009, D20): stop the host (tap removed) and the integration hooks on the main thread, then
// flush settings and logs off the main actor and let AppKit end the process. `QuitCoordinator` (SettingsStore,
// tested there) sends the reply once, when the flush finished or after its deadline.
//
// The reply is performed by the main run loop, never through the main dispatch queue: when the quit request comes
// from inside a main-queue job (`NSApp.terminate` from a main-actor task, the relaunch after a stuck callback, the
// launch sequence's quit), or arrives while a modal alert opened from `DispatchQueue.main.async` runs (safe mode,
// the conflict notice), that queue is busy until the job returns, and a reply queued on it never ran: the app did
// not quit until the alert closed, or never (reproduced in the tart VM, integration-suite.md section 10).

import AppKit
import SettingsStore

extension AppEnvironment {
    /// Starts the quit once; a second request (AppKit asks again while the first one runs) changes nothing.
    func terminate() {
        guard quit == nil else { return }
        diagnostics.logger.log(.lifecycle(.terminating), level: .notice)
        launch?.terminate()
        #if INTEGRATION_HOOKS
        integrationHooks.stop()
        #endif
        host.stop()
        let store = settingsStore
        let flushLogs = diagnostics.flushOperation()
        let coordinator = QuitCoordinator(
            scheduler: DispatchDebounceScheduler(queue: .global(qos: .userInitiated)),
            flush: {
                await store.flush()
                flushLogs()
            },
            reply: MainRunLoopReply.terminate)
        quit = coordinator
        coordinator.request()
    }
}

enum MainRunLoopReply {
    /// `reply(toApplicationShouldTerminate: true)` from the main run loop in its common modes, which include the
    /// modal-panel mode AppKit runs while it waits for this reply. Callable from any thread.
    static func terminate() {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        CFRunLoopWakeUp(main)
    }
}
