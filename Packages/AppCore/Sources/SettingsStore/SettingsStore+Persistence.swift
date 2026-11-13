// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Debounced atomic writes (PLT-R1003: temp file, fsync, rename, 1 s; PLT-R392: app modes 5 s) and change
// publication (PLT-R1008). A change marks its file dirty and arms one timer per file; further changes before it
// fires join the same write, so a write happens at most one delay after the first change. Timer callbacks hop
// onto the store's serial queue, which keeps them ordered with every other call into the actor.

internal import AppModel
internal import Foundation
internal import RealtimeSupport

/// Per-file bookkeeping of the store.
struct FileStatus: Sendable {
    /// The object as last read or written; unknown keys live here (PLT-R1002).
    var raw: [String: JSONValue] = [:]
    /// Newer schema on disk: used for known fields, never rewritten automatically (PLT-R1007).
    var readOnly = false
    /// Corrupt file without a usable backup: defaults are not written until the user confirms (PLT-R1006).
    var awaitingConfirmation = false
    /// The original must stay untouched this launch: its pre-migration backup failed (PLT-R1005), or it is
    /// corrupt and could not be renamed (PLT-R1006).
    var writeBlocked = false
    var dirty = false
    var pending: PendingWrite?
}

struct PendingWrite: Sendable {
    var token: UInt64
    var delay: TimeSpan
    var timer: any DebounceTimer
}

enum WriteDelay {
    static let standard = TimeSpan.seconds(1)  // PLT-R1003
    static let appModes = TimeSpan.seconds(5)  // PLT-R392
}

extension SettingsStore {
    func status(_ file: SettingsFile) -> FileStatus { files[file] ?? FileStatus() }

    func updateStatus(_ file: SettingsFile, _ body: (inout FileStatus) -> Void) {
        var status = status(file)
        body(&status)
        files[file] = status
    }

    func canWrite(_ file: SettingsFile) -> Bool {
        let status = status(file)
        return loaded && !safeMode && !status.readOnly && !status.awaitingConfirmation && !status.writeBlocked
    }

    /// A document changed in memory: publish now, write after `delay`.
    func changed(_ file: SettingsFile, after delay: TimeSpan) {
        updateStatus(file) { $0.dirty = true }
        scheduleWrite(file, after: delay)
        publish()
    }

    func publish() {
        generation &+= 1
        onChange(state)
    }

    // MARK: Debounce

    /// Keeps an armed timer unless the new delay is shorter (an explicit rule change while a 5 s memory write
    /// is pending is written after 1 s).
    private func scheduleWrite(_ file: SettingsFile, after delay: TimeSpan) {
        guard canWrite(file) else { return }
        if let pending = status(file).pending, pending.delay <= delay { return }
        cancelPendingWrite(file)
        nextTimerToken &+= 1
        let token = nextTimerToken
        let timer = scheduler.schedule(after: delay) { [weak self] in
            self?.debounceTimerFired(file: file, token: token)
        }
        updateStatus(file) { $0.pending = PendingWrite(token: token, delay: delay, timer: timer) }
    }

    func cancelPendingWrite(_ file: SettingsFile) {
        status(file).pending?.timer.cancel()
        updateStatus(file) { $0.pending = nil }
    }

    /// Timer handlers may run on any thread (the manual scheduler fires on the test's thread). Enqueueing on the
    /// store's own serial queue orders the write after every call that was already queued.
    nonisolated func debounceTimerFired(file: SettingsFile, token: UInt64) {
        queue.async { [weak self] in
            self?.withQueueIsolation { store in store.debounceElapsed(file: file, token: token) }
        }
    }

    /// `assumeIsolated` for a block already running on `queue`. Sound because the store's executor runs every
    /// job on that serial queue, so no job of the store runs meanwhile. `assumeIsolated` itself cannot check a
    /// custom executor before macOS 15 (ADR 0315); this checks the queue instead.
    nonisolated func withQueueIsolation(_ body: (isolated SettingsStore) -> Void) {
        dispatchPrecondition(condition: .onQueue(queue))
        withoutActuallyEscaping(body) { isolatedBody in
            let unchecked = unsafeBitCast(isolatedBody, to: ((SettingsStore) -> Void).self)
            unchecked(self)
        }
    }

    private func debounceElapsed(file: SettingsFile, token: UInt64) {
        guard status(file).pending?.token == token else { return }
        updateStatus(file) { $0.pending = nil }
        if writeNow(file) { publish() }
    }

    // MARK: Writing

    /// Writes `file` when it is dirty and writable. Returns true when the notices changed (the caller publishes).
    ///
    /// Every complete write also leaves its bytes as the newest backup, so a later corruption recovers the last
    /// written state and loses at most the changes still waiting for the debounce (PLT-R1006, section 10
    /// acceptance "no data loss beyond the last 1 s debounce window"). Pruning keeps five per schema version,
    /// so these rotation copies never push out the pre-migration `v<N>` copies (PLT-R1005).
    @discardableResult
    func writeNow(_ file: SettingsFile) -> Bool {
        guard status(file).dirty, canWrite(file) else { return false }
        var object = encodedPayload(file, over: status(file).raw)
        object[EnvelopeKey.schemaVersion] = .number(Double(file.currentSchemaVersion))
        object[EnvelopeKey.writtenBy] = .string(writtenBy)
        let written: Data
        do {
            written = try storage.write(object, to: file)
        } catch {
            return addNotice(.writeFailed(file))
        }
        // Best effort: the user's change is already saved; a failed backup only narrows what recovery can offer.
        try? storage.writeBackup(written, of: file, schemaVersion: file.currentSchemaVersion)
        updateStatus(file) {
            $0.raw = object
            $0.dirty = false
        }
        return removeNotice(.writeFailed(file))
    }

    func encodedPayload(_ file: SettingsFile, over raw: [String: JSONValue]) -> [String: JSONValue] {
        switch file {
        case .settings: SettingsCodec.encode(user, over: raw)
        case .appModes: AppModesCodec.encode(appModes, over: raw)
        case .ruleOverrides: RuleOverridesCodec.encode(ruleOverrides, over: raw)
        case .macros: MacrosCodec.encode(macros, over: raw)
        }
    }

    // MARK: Notices

    @discardableResult
    func addNotice(_ notice: StoreNotice) -> Bool {
        guard !notices.contains(notice) else { return false }
        notices.append(notice)
        return true
    }

    @discardableResult
    func removeNotice(_ notice: StoreNotice) -> Bool {
        let before = notices.count
        notices.removeAll { $0 == notice }
        return notices.count != before
    }
}

extension StoreNotice {
    /// Corruption notices of `file` (cleared when the user confirms).
    func isRecovery(of file: SettingsFile) -> Bool {
        switch self {
        case .recoveredFromBackup(let other, _), .corruptFileUsingDefaults(let other): other == file
        default: false
        }
    }

    /// Any notice about `file`.
    func concerns(_ file: SettingsFile) -> Bool {
        switch self {
        case .recoveredFromBackup(let other, _), .corruptFileUsingDefaults(let other),
            .newerSchemaReadOnly(let other, _),
            .writeFailed(let other):
            other == file
        case .safeMode: false
        }
    }
}
