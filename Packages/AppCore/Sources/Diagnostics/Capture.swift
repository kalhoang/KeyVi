// SPDX-License-Identifier: GPL-3.0-or-later
//
// Time-boxed typing trace (PLT-R905, PRD-R46, D26): the only artefact that ever contains typed characters.

public import AppModel
public import Foundation
public import RealtimeSupport

public enum CaptureLimits {
    public static let defaultDuration: TimeSpan = .seconds(60)
    public static let maximumDuration: TimeSpan = .seconds(180)
    public static let retention: TimeInterval = 24 * 3_600
}

public struct CaptureSessionID: RawRepresentable, Sendable, Hashable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// What the tap records while a capture is active. Characters come from the layout table (what the user's
/// layout produced), never from field contents.
public struct KeyCaptureRecord: Sendable, BitwiseCopyable {
    public enum Kind: UInt8, Sendable, BitwiseCopyable { case keyDown, keyUp, flagsChanged, mouseDown }
    public enum Outcome: UInt8, Sendable, BitwiseCopyable {
        case passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp
    }
    public var kind: Kind
    public var keyCode: UInt16
    public var flags: UInt64
    public var character: InlineUTF16
    public var outcome: Outcome
    public var at: MonotonicInstant
    public init(
        kind: Kind, keyCode: UInt16, flags: UInt64, character: InlineUTF16, outcome: Outcome,
        at: MonotonicInstant
    ) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.character = character
        self.outcome = outcome
        self.at = at
    }
}

public enum CaptureRecord: Sendable {
    case key(KeyCaptureRecord)
    /// Engine decision for the last key: delete count and inserted text (content, capture only).
    case engine(deleteCount: Int, insert: String, at: MonotonicInstant)
    case job(sequence: UInt64, strategy: InjectionStrategy, durationMicroseconds: UInt64, outcome: StaticString)
    /// Roles and bundle IDs only, never titles or URLs (PLT-R905).
    case focus(bundle: BundleKey?, role: String?, subrole: String?, at: MonotonicInstant)
    /// Nothing is recorded while secure input is on or a secure field is focused; the gap is marked.
    case gap(reason: PauseCode, from: MonotonicInstant, to: MonotonicInstant)
}

public struct CaptureSessionInfo: Sendable, Hashable, Codable {
    public var id: CaptureSessionID
    public var startedAt: Date
    public var endsAt: Date
    public var file: URL
}

/// Why a capture could not start or a session could not be read (PLT-R905).
public enum CaptureError: Error, Sendable, Hashable {
    /// Zero, negative or longer than `CaptureLimits.maximumDuration`.
    case invalidDuration
    case alreadyRecording
    /// No capture file with this ID exists (expired, exported, discarded or never created).
    case unknownSession
    case storage(FileSystemError)
}

/// Owns capture state. `isRecording` is an atomic flag the tap reads once per callback; records flow through
/// SPSC rings (tap, inject, ax producers) drained by the utility queue into
/// `~/Library/Logs/<folder>/captures/<id>.jsonl` (0600, excluded from backup).
///
/// The session stops by itself when its duration is over (a one-shot timer on `scheduler`); while it runs a
/// repeating 2 s timer drains the rings (PLT-R803). `beginGap`/`endGap` bracket secure input and secure fields:
/// `isRecording` is false in between, records stamped inside the gap are dropped and a gap line is written.
public final class CaptureController: Sendable {
    public let tapRecords = SPSCRing<CaptureRecord>(capacity: 8_192)
    public let injectRecords = SPSCRing<CaptureRecord>(capacity: 2_048)
    public let focusRecords = SPSCRing<CaptureRecord>(capacity: 512)

    let directory: URL
    let fileSystem: any FileSystem
    let wallClock: any WallClock
    let clock: any MonotonicClock
    private let scheduler: any TimerScheduler
    private let recording = Atomic<Bool>(false)
    private let session = Mutex<CaptureSession?>(nil)
    private let writeFailures = Atomic<Int>(0)

    public init(
        directory: URL, fileSystem: any FileSystem, wallClock: any WallClock, clock: any MonotonicClock,
        scheduler: any TimerScheduler
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.wallClock = wallClock
        self.clock = clock
        self.scheduler = scheduler
    }

    /// Tap-safe (one atomic load).
    public var isRecording: Bool { recording.load(ordering: .acquiring) }

    /// Appends that failed while a session ran (timer-driven drains cannot throw).
    public var failedWrites: Int { writeFailures.load(ordering: .relaxed) }

    /// Explicit user action only, after a confirmation that explains what is recorded (PLT-R905).
    public func start(duration: TimeSpan) throws -> CaptureSessionInfo {
        guard duration > .zero, duration <= CaptureLimits.maximumDuration else { throw CaptureError.invalidDuration }
        return try session.withLock { (active: inout CaptureSession?) throws -> CaptureSessionInfo in
            guard active == nil else { throw CaptureError.alreadyRecording }
            discardPendingRecords()
            let startedAt = wallClock.now()
            let id = CaptureFiles.makeID(at: startedAt)
            let info = CaptureSessionInfo(
                id: id, startedAt: startedAt, endsAt: startedAt.addingTimeInterval(duration.inSeconds),
                file: CaptureFiles.url(for: id, in: directory))
            try storage { try prepareFile(for: info) }
            let stopTimer = scheduler.schedule(after: duration, leeway: .milliseconds(100)) { [weak self] in
                self?.finish(reason: .timeLimit)
            }
            let drainTimer = scheduler.scheduleRepeating(every: CaptureFiles.drainInterval, leeway: .milliseconds(200))
            {
                [weak self] in self?.drainNow()
            }
            active = CaptureSession(info: info, start: clock.now(), timers: [stopTimer, drainTimer])
            recording.store(true, ordering: .releasing)
            return info
        }
    }

    public func stop() -> CaptureSessionInfo? { finish(reason: .stopped) }

    public func remaining(now: Date) -> TimeSpan? {
        session.withLock { active in
            active.map { .seconds(max(0, $0.info.endsAt.timeIntervalSince(now))) }
        }
    }

    /// Secure input turned on or a secure field got focus: record nothing until `endGap` (PLT-R905).
    public func beginGap(_ reason: PauseCode) {
        session.withLock { active in
            guard active != nil, active?.openGap == nil else { return }
            recording.store(false, ordering: .releasing)
            active?.openGap = CaptureSession.OpenGap(reason: reason, from: clock.now())
        }
    }

    public func endGap() {
        session.withLock { active in
            guard active?.openGap != nil else { return }
            active?.closeGap(at: clock.now())
            recording.store(true, ordering: .releasing)
        }
    }

    /// Readable rendering the user reviews before export (PLT-R905).
    public func render(_ id: CaptureSessionID, language: InterfaceLanguage) throws -> String {
        let url = try existingFile(for: id)
        drainNow()
        let data = try storage { try fileSystem.readData(at: url, maxBytes: CaptureFiles.maximumFileBytes) }
        return CaptureRendering.render(data, language: language)
    }

    /// Writes the export and deletes the capture immediately afterwards.
    public func export(_ id: CaptureSessionID, to destination: URL) throws {
        let url = try existingFile(for: id)
        finishIfActive(id)
        let data = try storage { try fileSystem.readData(at: url, maxBytes: CaptureFiles.maximumFileBytes) }
        try storage { try fileSystem.writeAtomically(data, to: destination, permissions: .ownerOnlyFile) }
        try storage { try fileSystem.removeItem(at: url) }
    }

    public func discard(_ id: CaptureSessionID) {
        guard let url = try? existingFile(for: id) else { return }
        finishIfActive(id)
        try? fileSystem.removeItem(at: url)
    }

    /// Deletes captures older than 24 hours; run at launch and hourly on the utility queue.
    public func purgeExpired(now: Date) {
        // Compared by name: directory listings may spell the folder differently (symlinks, trailing slash).
        let activeName = session.withLock { $0?.info.file.lastPathComponent }
        guard let entries = try? fileSystem.contentsOfDirectory(at: directory) else { return }
        for url in entries where url.pathExtension == CaptureFiles.fileExtension && url.lastPathComponent != activeName
        {
            guard let created = try? fileSystem.attributes(at: url).creationDate else { continue }
            if now.timeIntervalSince(created) >= CaptureLimits.retention { try? fileSystem.removeItem(at: url) }
        }
    }

    // MARK: Session internals

    @discardableResult
    private func finish(reason: CaptureFiles.EndReason) -> CaptureSessionInfo? {
        session.withLock { active in
            recording.store(false, ordering: .releasing)
            guard var current = active else { return nil }
            for timer in current.timers { timer.cancel() }
            let now = clock.now()
            current.closeGap(at: now)
            var lines = drainedLines(&current, now: now)
            lines.append(CaptureLine(type: .end, t: now.microseconds(since: current.start), reason: reason.rawValue))
            append(lines, to: current.info.file)
            active = nil
            return current.info
        }
    }

    private func finishIfActive(_ id: CaptureSessionID) {
        if session.withLock({ $0?.info.id == id }) { finish(reason: .stopped) }
    }

    private func drainNow() {
        session.withLock { active in
            guard var current = active else { return }
            append(drainedLines(&current, now: clock.now()), to: current.info.file)
            active = current
        }
    }

    /// Pops every ring and returns the lines to write, oldest first. Records stamped before the session or
    /// inside a gap are dropped (PLT-R905 "nothing is recorded while secure input is on").
    private func drainedLines(_ session: inout CaptureSession, now: MonotonicInstant) -> [CaptureLine] {
        var timed: [(at: MonotonicInstant, line: CaptureLine)] = session.takeUnwrittenGaps()
        for ring in [tapRecords, injectRecords, focusRecords] {
            while let record = ring.pop() {
                let at = record.timestamp ?? now
                guard session.accepts(at) else { continue }
                timed.append((at, CaptureLine(record, start: session.start)))
            }
        }
        return timed.enumerated().sorted { ($0.element.at, $0.offset) < ($1.element.at, $1.offset) }.map(\.element.line)
    }

    private func discardPendingRecords() {
        for ring in [tapRecords, injectRecords, focusRecords] { while ring.pop() != nil {} }
    }

    private func append(_ lines: [CaptureLine], to file: URL) {
        guard !lines.isEmpty else { return }
        do {
            try fileSystem.append(CaptureFiles.encode(lines), to: file, permissions: .ownerOnlyFile)
        } catch {
            writeFailures.wrappingAdd(1, ordering: .relaxed)
        }
    }

    /// Directory 0700, file 0600 with the session header, both excluded from backups (PLT-R905).
    private func prepareFile(for info: CaptureSessionInfo) throws {
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
        try fileSystem.setExcludedFromBackup(true, at: directory)
        let header = CaptureLine(
            type: .session, id: info.id.rawValue, startedAt: info.startedAt, endsAt: info.endsAt,
            formatVersion: CaptureFiles.formatVersion)
        try fileSystem.append(CaptureFiles.encode([header]), to: info.file, permissions: .ownerOnlyFile)
        try fileSystem.setExcludedFromBackup(true, at: info.file)
    }

    private func existingFile(for id: CaptureSessionID) throws -> URL {
        guard CaptureFiles.isValid(id) else { throw CaptureError.unknownSession }
        let url = CaptureFiles.url(for: id, in: directory)
        guard fileSystem.fileExists(at: url) else { throw CaptureError.unknownSession }
        return url
    }

    private func storage<T>(_ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch let error as FileSystemError {
            throw CaptureError.storage(error)
        }
    }
}
