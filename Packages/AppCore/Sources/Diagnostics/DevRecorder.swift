// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dev builds' continuous typing recorder (PLT-R904A, ADR 0007; Pa, 2026-11-14). Debug configuration only. It
// extends the PLT-R905 capture instead of adding a second recording path: the tap, the inject thread and the ax
// thread push into SPSC rings, `CaptureController` drains them every 2 s on the utility queue and hands the records
// to this recorder, which writes hourly JSON-lines files. Nothing is recorded while secure input is on, a secure
// field has focus or the user paused the recorder; a full ring writes a gap line instead of dropping silently.
// Nothing here uploads anything; only the offline scanner (trace-scan) reads the files.

#if DEV_RECORDER
public import AppModel
public import Foundation
public import RealtimeSupport

public final class DevRecorder: Sendable {
    /// The one string only the recorder carries; scripts/verify-release.sh fails a release that contains it. Used
    /// at run time (every file header), so the optimizer keeps it.
    public static let buildMarker = "DEV_RECORDER build: continuous typing recorder for dev builds only"

    /// Tap producer (engine steps, boundaries, the marker chord).
    public let tapRecords = SPSCRing<DevTraceRecord>(capacity: 8_192)
    /// Inject-thread producer (jobs, fallbacks).
    public let injectRecords = SPSCRing<DevTraceRecord>(capacity: 2_048)
    /// Ax-thread producer (focus snapshots).
    public let focusRecords = SPSCRing<DevTraceRecord>(capacity: 512)

    public let directory: URL
    let fileSystem: any FileSystem
    let wallClock: any WallClock
    let clock: any MonotonicClock
    let timeZone: TimeZone
    private let scheduler: any TimerScheduler
    private let active = Atomic<Bool>(false)
    private let running = Atomic<Bool>(false)
    private let dropped = Atomic<Int>(0)
    private let attentionBits = Atomic<UInt32>(0)
    // The readback's pause (PLT-R904A): the last key or click down, how many went down, the last job's end.
    private let lastInputNanos = Atomic<UInt64>(0)
    private let inputCount = Atomic<UInt64>(0)
    private let lastJobNanos = Atomic<UInt64>(DevRecorder.noJob)
    private static let noJob = UInt64.max
    private let attentionSignal: WakeSignal?
    // Closures sit in boxes: reading a bare function value through `Mutex.withLock { $0 }` re-wraps it in a
    // reabstraction thunk on every call (the inout write-back), a chain that grows until it overflows the stack.
    private let attentionListeners = Mutex<[DevRecorderCallback<Set<DevReadbackReason>>]>([])
    private let drainHook = Mutex<DevRecorderCallback<Void>?>(nil)
    private let focusSource = Mutex<DevFocusSource?>(nil)
    private let writeFailures = Atomic<Int>(0)
    private let state: Mutex<DevRecorderState>

    /// `attentionQueue` runs the marker and readback requests the tap raises (one `WakeSignal`, tap-safe); nil in
    /// tests, which read them with `takeAttention()`.
    public init(
        directory: URL, fileSystem: any FileSystem, wallClock: any WallClock, clock: any MonotonicClock,
        scheduler: any TimerScheduler, timeZone: TimeZone = .current, attentionQueue: DispatchQueue? = nil
    ) {
        self.directory = directory
        self.fileSystem = fileSystem
        self.wallClock = wallClock
        self.clock = clock
        self.scheduler = scheduler
        self.timeZone = timeZone
        state = Mutex(DevRecorderState(launch: DevRecorderState.makeLaunchID()))
        let bits = attentionBits
        let listeners = attentionListeners
        attentionSignal = attentionQueue.map { queue in
            WakeSignal(queue: queue) {
                let reasons = DevRecorder.reasons(bits.exchange(0, ordering: .acquiringAndReleasing))
                guard !reasons.isEmpty else { return }
                for listener in listeners.withLock({ $0 }) { listener.run(reasons) }
            }
        }
    }

    // MARK: Tap-safe state

    /// Started, not paused and outside a secure gap. One atomic load (PLT-R304).
    public var isActive: Bool { active.load(ordering: .acquiring) }

    /// Producer side of the three rings: a full ring is counted and becomes a gap line at the next drain.
    @inline(__always)
    public func pushTap(_ record: consuming DevTraceRecord) {
        if !tapRecords.push(record) { noteOverflow() }
    }

    /// Also notes the end of an edit job for the readback's pause (one atomic store).
    @inline(__always)
    public func pushInject(_ record: consuming DevTraceRecord) {
        if let end = record.jobEnd { lastJobNanos.store(end.nanoseconds, ordering: .relaxed) }
        if !injectRecords.push(record) { noteOverflow() }
    }

    @inline(__always)
    public func pushFocus(_ record: consuming DevTraceRecord) {
        if !focusRecords.push(record) { noteOverflow() }
    }

    /// A key or click went down (tap, every one the capture may record). The readback waits for a pause in this
    /// input (PLT-R904A): two atomic writes, no lock, no allocation (PLT-R304, PLT-R305).
    @inline(__always)
    public func noteInputDown(at instant: MonotonicInstant) {
        lastInputNanos.store(instant.nanoseconds, ordering: .relaxed)
        inputCount.wrappingAdd(1, ordering: .releasing)
    }

    /// Input and edit jobs as the readback's pause sees them (any thread).
    public var inputActivity: DevInputActivity {
        let count = inputCount.load(ordering: .acquiring)
        let input = lastInputNanos.load(ordering: .relaxed)
        let job = lastJobNanos.load(ordering: .relaxed)
        return DevInputActivity(
            count: count, lastInput: count == 0 ? nil : MonotonicInstant(nanoseconds: input),
            lastJob: job == Self.noJob ? nil : MonotonicInstant(nanoseconds: job))
    }

    /// A record could not be queued (any producer, the PLT-R905 rings included). Lock-free.
    @inline(__always)
    public func noteOverflow() { dropped.wrappingAdd(1, ordering: .relaxed) }

    /// Asks the attention queue for a readback or a marker confirmation. Lock-free and allocation-free.
    @inline(__always)
    public func requestAttention(_ reason: DevReadbackReason) {
        var current = attentionBits.load(ordering: .relaxed)
        while true {
            let (exchanged, original) = attentionBits.compareExchange(
                expected: current, desired: current | reason.bit, ordering: .acquiringAndReleasing)
            if exchanged { break }
            current = original
        }
        attentionSignal?.signal()
    }

    // MARK: Control (main thread)

    /// Started and not stopped, paused or not (one atomic load: the tap consumes the marker chord on it).
    public var isStarted: Bool { running.load(ordering: .acquiring) }
    public var pausedUntil: Date? { state.withLock { $0.pausedUntil } }
    /// Appends that failed (timer-driven drains cannot throw).
    public var failedWrites: Int { writeFailures.load(ordering: .relaxed) }

    /// Always on from launch in dev builds (PLT-R904A): no confirmation. Creates the folder, purges old files, starts
    /// the 2 s drain and the hourly purge.
    public func start(appVersion: String) throws {
        let wall = wallClock.now()
        try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
        try fileSystem.setExcludedFromBackup(true, at: directory)
        let started = state.withLock { state -> Bool in
            guard !state.started else { return false }
            state.started = true
            state.appVersion = appVersion
            state.startedAt = clock.now()
            state.append(at: state.startedAt, exempt: true, rank: .opening) { [launch = state.launch] t in
                var line = DevTraceLine(type: .start, t: t)
                line.launch = launch
                line.app = appVersion
                line.build = DevRecorder.buildMarker
                return line
            }
            state.timers = [
                scheduler.scheduleRepeating(every: CaptureFiles.drainInterval, leeway: .seconds(1)) { [weak self] in
                    self?.drain()
                },
                scheduler.scheduleRepeating(every: DevRecorderLimits.purgeInterval, leeway: .seconds(60)) {
                    [weak self] in self?.purge(now: self?.wallClock.now() ?? Date())
                },
            ]
            updateActive(state)
            return true
        }
        guard started else { return }
        purge(now: wall)
    }

    /// Quit: a final drain and a `stop` line.
    public func stop() {
        drain()  // what is queued now is still recorded
        let stopped = state.withLock { state -> Bool in
            guard state.started else { return false }
            for timer in state.timers + [state.resumeTimer].compactMap({ $0 }) { timer.cancel() }
            state.timers = []
            state.resumeTimer = nil
            state.append(at: clock.now(), exempt: true) { DevTraceLine(type: .stop, t: $0) }
            state.started = false
            updateActive(state)
            return true
        }
        if stopped { drain() }
    }

    /// "Tạm dừng ghi 30 phút": nothing is recorded until `resume()` or the end of `span`.
    public func pause(for span: TimeSpan = DevRecorderLimits.pauseDuration) {
        let until = wallClock.now().addingTimeInterval(span.inSeconds)
        let paused = state.withLock { state -> Bool in
            guard state.started else { return false }
            let now = clock.now()
            state.pausedUntil = until
            state.openWindow(.paused, at: now)
            state.append(at: now, exempt: true) { t in
                var line = DevTraceLine(type: .pause, t: t)
                line.until = DevTraceFiles.microseconds(until)
                return line
            }
            state.resumeTimer?.cancel()
            state.resumeTimer = scheduler.schedule(after: span, leeway: .seconds(1)) { [weak self] in self?.resume() }
            updateActive(state)
            return true
        }
        if paused { drain() }
    }

    /// "Tiếp tục ghi", or the end of the pause.
    public func resume() {
        let now = clock.now()
        let resumed = state.withLock { state -> Bool in
            guard state.started, state.pausedUntil != nil else { return false }
            state.pausedUntil = nil
            state.closeWindow(.paused, at: now)
            state.resumeTimer?.cancel()
            state.resumeTimer = nil
            state.append(at: now, exempt: true, rank: .opening) { DevTraceLine(type: .resume, t: $0) }
            updateActive(state)
            return true
        }
        guard resumed else { return }
        noteCurrentFocus(at: now)
        drain()
    }

    /// "Đánh dấu lỗi vừa gặp" from the menu; the chord's marker comes from the tap ring.
    public func mark(source: DevMarkerSource) {
        note(.marker(source: source, at: clock.now()))
        requestAttention(.marker)
    }

    /// Records from threads without a ring (main, readback queue). Dropped while not active.
    public func note(_ record: DevTraceRecord) {
        state.withLock { state in
            guard state.started else { return }
            state.append(record)
        }
    }

    /// The settings that change engine output, at every change and at the top of every file.
    public func noteSettings(_ snapshot: DevSettingsSnapshot) {
        note(.settings(snapshot, at: clock.now()))
    }

    /// A VI/EN change the main thread saw (menu, hotkey or per-app memory).
    public func noteMode(_ mode: TypingMode, manual: Bool, bundle: String?) {
        note(.mode(DevModeRecord(mode: mode, manual: manual, bundle: bundle, at: clock.now())))
    }

    /// The focus in effect at an instant, written when a pause or a secure gap ends: focus changes inside those
    /// windows are not recorded, so without it the lines after them would carry the focus from before (review W8-E
    /// finding 3).
    /// The engine identity for the file lines (ADR 0007 decision 13), computed off the main thread at start.
    public func setEngineIdentity(_ identity: String) {
        state.withLock { $0.engineIdentity = identity }
    }

    public func setFocusSource(_ source: @escaping @Sendable (MonotonicInstant) -> DevFocusRecord) {
        let box = DevFocusSource(source)
        focusSource.withLock { $0 = box }
    }

    private func noteCurrentFocus(at instant: MonotonicInstant) {
        guard let source = focusSource.withLock({ $0 }) else { return }
        note(.focus(source.make(instant)))
    }

    public func addAttentionListener(_ listener: @escaping @Sendable (Set<DevReadbackReason>) -> Void) {
        let box = DevRecorderCallback(listener)
        attentionListeners.withLock { $0.append(box) }
    }

    /// Reads and clears pending attention requests (tests; production uses the attention queue).
    public func takeAttention() -> Set<DevReadbackReason> {
        Self.reasons(attentionBits.exchange(0, ordering: .acquiringAndReleasing))
    }

    /// Runs a drain now (the controller pops every ring and calls `flush`).
    public func drain() {
        let hook = drainHook.withLock { $0 }
        hook?.run(())
    }

    // MARK: Capture integration (called by CaptureController)

    func attach(drain: @escaping @Sendable () -> Void) {
        let box = DevRecorderCallback<Void> { _ in drain() }
        drainHook.withLock { $0 = box }
    }

    /// PLT-R905 secure gap: secure input on or a secure field focused. `holder`: the likely holder of secure input
    /// (PLT-R396) when the gap begins, written with the gap (bundle ID and PID, never its name).
    func beginGap(_ reason: PauseCode, holder: SecureInputHolder? = nil, at instant: MonotonicInstant) {
        state.withLock { state in
            state.secureGap = reason
            state.secureGapHolder = holder.map { ($0.bundle?.rawValue, $0.pid) }
            state.openWindow(.secure(reason), at: instant)
            updateActive(state)
        }
    }

    func endGap(at instant: MonotonicInstant) {
        let ended = state.withLock { state -> Bool in
            guard let reason = state.secureGap else { return false }
            state.secureGap = nil
            let holder = state.secureGapHolder
            state.secureGapHolder = nil
            let from = state.closeWindow(.secure(reason), at: instant)
            if state.started, let from {
                state.append(at: from, exempt: true) { [start = from] t in
                    var line = DevTraceLine(type: .gap, t: t)
                    line.reason = reason.rawValue
                    let micros = instant.nanoseconds(since: start) / 1_000
                    line.end = t + Int64(micros)
                    line.durUs = micros
                    line.holder = holder?.bundle
                    line.pid = holder?.pid
                    return line
                }
            }
            updateActive(state)
            return state.started
        }
        if ended { noteCurrentFocus(at: instant) }
    }

    /// A key record popped from the shared PLT-R905 ring.
    func collect(_ record: CaptureRecord) {
        guard case .key(let key) = record else { return }  // engine, job and focus lines have richer dev records
        state.withLock { state in
            guard state.started else { return }
            state.append(at: key.at, exempt: false, rank: .key) { DevTraceLine(key: key, t: $0) }
        }
    }

    /// Pops the dev rings into the pending lines. The drain calls it before it pops the shared PLT-R905 rings
    /// (`CaptureController.drainNow`), so a key is never written after the dev records of the same key.
    func stage() {
        var popped: [DevTraceRecord] = []
        for ring in [tapRecords, injectRecords, focusRecords] {
            while let record = ring.pop() { popped.append(record) }
        }
        guard !popped.isEmpty else { return }
        state.withLock { state in
            guard state.started || !state.pending.isEmpty else { return }
            for record in popped { state.append(record) }
        }
    }

    /// Writes everything pending, oldest first, into the file of each line's hour.
    func flush() {
        let monoNow = clock.now()
        let wallNow = wallClock.now()
        let overflow = dropped.load(ordering: .relaxed)
        let batch = state.withLock { state -> [(hour: String, lines: [DevTraceLine])] in
            guard state.started || !state.pending.isEmpty else { return [] }
            if overflow != state.reportedOverflow {
                let count = overflow &- state.reportedOverflow
                state.reportedOverflow = overflow
                state.append(at: monoNow, exempt: true) { t in
                    var line = DevTraceLine(type: .gap, t: t)
                    line.reason = "overflow"
                    line.dropped = count
                    return line
                }
            }
            return state.takeLines(monoNow: monoNow, wallNow: wallNow, timeZone: timeZone)
        }
        for group in batch { write(group.lines, hour: group.hour) }
    }

    // MARK: Retention (PLT-R904A: 7 days, 200 MB, oldest first)

    /// Deletes files older than 7 days, then the oldest until the folder holds at most 200 MB; never the file in
    /// use and never a file the recorder did not name. At launch and hourly.
    public func purge(now: Date, maximumBytes: Int = DevRecorderLimits.maximumTotalBytes) {
        guard let entries = try? fileSystem.contentsOfDirectory(at: directory) else { return }
        let current = state.withLock { $0.currentHour.map { DevTraceFiles.url(forHour: $0, in: directory) } }
        var kept: [(url: URL, size: Int)] = []
        let ours = entries.compactMap { url -> (url: URL, start: Date)? in
            DevTraceFiles.hourStart(ofFileNamed: url.lastPathComponent, timeZone: timeZone).map { (url, $0) }
        }
        for entry in ours.sorted(by: { $0.start < $1.start }) {
            let isCurrent = entry.url.lastPathComponent == current?.lastPathComponent
            let end = entry.start.addingTimeInterval(3_600)
            if !isCurrent && now.timeIntervalSince(end) >= DevRecorderLimits.retention {
                try? fileSystem.removeItem(at: entry.url)
            } else {
                kept.append((entry.url, (try? fileSystem.attributes(at: entry.url).size) ?? 0))
            }
        }
        var total = kept.reduce(0) { $0 + $1.size }
        for entry in kept where total > maximumBytes {
            guard entry.url.lastPathComponent != current?.lastPathComponent else { continue }
            if (try? fileSystem.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    // MARK: Internals

    private func updateActive(_ state: DevRecorderState) {
        running.store(state.started, ordering: .releasing)
        active.store(state.started && state.pausedUntil == nil && state.secureGap == nil, ordering: .releasing)
    }

    private func write(_ lines: [DevTraceLine], hour: String) {
        let url = DevTraceFiles.url(forHour: hour, in: directory)
        do {
            if !fileSystem.fileExists(at: directory) {
                try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
                try fileSystem.setExcludedFromBackup(true, at: directory)
            }
            let isNew = !fileSystem.fileExists(at: url)
            try fileSystem.append(DevTraceFiles.encode(lines), to: url, permissions: .ownerOnlyFile)
            if isNew { try fileSystem.setExcludedFromBackup(true, at: url) }
        } catch {
            writeFailures.wrappingAdd(1, ordering: .relaxed)
        }
    }

    static func reasons(_ bits: UInt32) -> Set<DevReadbackReason> {
        Set(DevReadbackReason.allCases.filter { bits & $0.bit != 0 })
    }
}

/// A callback held by reference, so storing and reading it through a mutex never re-wraps the function.
final class DevRecorderCallback<Argument>: Sendable {
    let run: @Sendable (Argument) -> Void
    init(_ run: @escaping @Sendable (Argument) -> Void) { self.run = run }
}

/// The focus source, held by reference for the same reason as `DevRecorderCallback`.
final class DevFocusSource: Sendable {
    let make: @Sendable (MonotonicInstant) -> DevFocusRecord
    init(_ make: @escaping @Sendable (MonotonicInstant) -> DevFocusRecord) { self.make = make }
}

/// Mutable state of the recorder, guarded by its mutex.
struct DevRecorderState {
    enum Window: Equatable {
        case paused
        case secure(PauseCode)
    }

    /// Order of lines that share an instant: a start or resume line opens the recording, then the key line, then
    /// the engine steps and boundaries of that key (runbook section 3), whatever ring each was popped from.
    enum Rank: Int {
        case opening = 0
        case key = 1
        case other = 2
    }

    struct Pending {
        var at: MonotonicInstant
        var rank: Rank
        var order: Int
        /// Control lines (start, pause, gaps) are written even though they sit at the edge of a window.
        var exempt: Bool
        var make: @Sendable (Int64) -> DevTraceLine
    }

    let launch: String
    var started = false
    var appVersion = ""
    var startedAt = MonotonicInstant.zero
    var pausedUntil: Date?
    var secureGap: PauseCode?
    var secureGapHolder: (bundle: String?, pid: Int32)?
    /// `DevEngineIdentity` of the running engine, written in every file line once known.
    var engineIdentity: String?
    var timers: [any ScheduledTimer] = []
    var resumeTimer: (any ScheduledTimer)?
    var windows: [(window: Window, from: MonotonicInstant, to: MonotonicInstant?)] = []
    var pending: [Pending] = []
    var nextOrder = 0
    var reportedOverflow = 0
    var currentHour: String?
    /// The last settings and focus lines written, repeated at the top of the next file.
    var lastSettings: DevTraceLine?
    var lastFocus: DevTraceLine?

    init(launch: String) { self.launch = launch }

    static func makeLaunchID() -> String {
        String(UInt32.random(in: .min ... .max), radix: 16)
    }

    mutating func append(
        at instant: MonotonicInstant, exempt: Bool, rank: Rank = .other,
        _ make: @escaping @Sendable (Int64) -> DevTraceLine
    ) {
        pending.append(Pending(at: instant, rank: rank, order: nextOrder, exempt: exempt, make: make))
        nextOrder += 1
    }

    mutating func append(_ record: DevTraceRecord) {
        append(at: record.timestamp, exempt: false) { DevTraceLine(record, t: $0) }
    }

    mutating func openWindow(_ window: Window, at instant: MonotonicInstant) {
        guard !windows.contains(where: { $0.window == window && $0.to == nil }) else { return }
        windows.append((window, instant, nil))
    }

    @discardableResult
    mutating func closeWindow(_ window: Window, at instant: MonotonicInstant) -> MonotonicInstant? {
        guard let index = windows.lastIndex(where: { $0.window == window && $0.to == nil }) else { return nil }
        windows[index].to = instant
        return windows[index].from
    }

    /// False for records stamped before the start or inside a pause or a secure gap (the end of a window is
    /// recording again).
    func accepts(_ instant: MonotonicInstant) -> Bool {
        guard instant >= startedAt else { return false }
        return !windows.contains { instant >= $0.from && $0.to.map { instant < $0 } ?? true }
    }

    /// Lines in time order, grouped by the file (hour) they belong to; each new hour starts with its header.
    mutating func takeLines(monoNow: MonotonicInstant, wallNow: Date, timeZone: TimeZone) -> [(
        hour: String, lines: [DevTraceLine]
    )] {
        let wallMicros = DevTraceFiles.microseconds(wallNow)
        let ordered = pending.filter { $0.exempt || accepts($0.at) }.sorted {
            ($0.at, $0.rank.rawValue, $0.order) < ($1.at, $1.rank.rawValue, $1.order)
        }
        pending.removeAll()
        // Windows closed well before this drain can no longer match a queued record.
        windows.removeAll { window in window.to.map { monoNow.nanoseconds(since: $0) > 10_000_000_000 } ?? false }
        var groups: [(hour: String, lines: [DevTraceLine])] = []
        for item in ordered {
            let age = item.at > monoNow ? 0 : Int64(monoNow.nanoseconds(since: item.at) / 1_000)
            let t = wallMicros - age
            var line = item.make(t)
            if line.type == .start { line.eng = engineIdentity }  // known by the first drain (ADR 0007 decision 13)
            let hour = DevTraceFiles.hourKey(
                for: Date(timeIntervalSince1970: Double(t) / 1_000_000), timeZone: timeZone)
            if hour != currentHour {
                currentHour = hour
                groups.append((hour, header(t: t)))
            } else if groups.last?.hour != hour {
                groups.append((hour, []))
            }
            groups[groups.count - 1].lines.append(line)
            if line.type == .settings { lastSettings = line }
            if line.type == .focus { lastFocus = line }
        }
        return groups
    }

    /// `file` line, then the settings and the focus in effect, so every file can be read on its own.
    private func header(t: Int64) -> [DevTraceLine] {
        var file = DevTraceLine(type: .file, t: t)
        file.v = DevTraceFiles.formatVersion
        file.launch = launch
        file.app = appVersion
        file.build = DevRecorder.buildMarker
        file.eng = engineIdentity
        return [file]
            + [lastSettings, lastFocus].compactMap { line in
                line.map {
                    var copy = $0
                    copy.t = t
                    return copy
                }
            }
    }
}
#endif
