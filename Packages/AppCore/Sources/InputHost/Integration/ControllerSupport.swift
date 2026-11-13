// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Small Sendable helpers of `InputHostController`: the rule set shared with the utility-queue secure-input
// monitor, the coalesced main-thread refresh, and the constants the controller starts from. Workstream W2-A.

public import AppModel
internal import CompatRules
internal import Foundation
internal import Injection
internal import RealtimeSupport
internal import Synchronization
internal import VietnameseEngine

/// The current compiled rule set, readable from the utility queue (secure-input hint keys, PLT-R397).
final class RuleSetBox: Sendable {
    private let current = Mutex<RuleSet?>(nil)

    func set(_ ruleSet: RuleSet) { current.withLock { $0 = ruleSet } }
    var ruleSet: RuleSet? { current.withLock { $0 } }
    func hintKey(for bundle: BundleKey) -> String? { ruleSet?.secureInputHintKey(for: bundle) }
}

/// Coalesces "the snapshots changed, recompute what the menu shows" requests from any thread into one main-actor
/// call (PRD-R10, PRD-R11). A request made while one is pending is merged into it.
final class RefreshRequests: Sendable {
    private let hop: any MainThreadHop
    private let pending = Atomic<Bool>(false)
    private let action = Mutex<(@MainActor @Sendable () -> Void)?>(nil)

    init(hop: any MainThreadHop) { self.hop = hop }

    func connect(_ body: (@MainActor @Sendable () -> Void)?) { action.withLock { $0 = body } }

    func request() {
        guard !pending.exchange(true, ordering: .sequentiallyConsistent) else { return }
        hop.hop { [self] in
            clear()
            action.withLock { $0 }?()
        }
    }

    private func clear() { pending.store(false, ordering: .sequentiallyConsistent) }
}

/// What `HostEvent.focusChanged` compares.
struct FocusKey: Hashable {
    var bundle: BundleKey?
    var rule: RuleID?
}

extension InputHostController {
    /// The tap is never created before `start` published the real settings; until then the cell holds this
    /// placeholder (one neutral engine, empty lists).
    nonisolated static var placeholderSettings: TapSettingsSnapshot {
        TapSettingsSnapshot(
            generation: 0, engines: EngineCatalog(engines: [:]), toggleHotkey: .defaultToggle, restoreHotkey: nil,
            macrosInEnglishMode: false, rememberPerApp: true)
    }

    /// The running macOS as a `LooseVersion` (pane names and deep links, PRD-R64; focus matching, PLT-R520).
    public nonisolated static var macOSVersion: LooseVersion {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return LooseVersion("\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
            ?? LooseVersion("15.0")!
    }

    /// Before the first check (nothing is claimed granted).
    nonisolated static let unknownPermissions = PermissionStatus(
        accessibility: .unknown, postEvent: .unknown, listenEvent: .unknown, listenEventRequired: false,
        health: .noPermission)
}
