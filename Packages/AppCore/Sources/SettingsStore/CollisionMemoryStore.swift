// SPDX-License-Identifier: GPL-3.0-or-later
//
// The collision memory on disk (PLT-R914, ENG-R863 to ENG-R866): `collision-memory.json` in the app's Application
// Support folder, mode 0600, schema version 1, written off the tap thread two seconds after the first change, every
// word checked against the bundled collision list at load (unknown words are dropped, so the file only ever holds
// bundled vocabulary). The store never sees the tap: InputHost drains the engine's signals on the main thread and
// applies them on the utility queue; the store publishes the votes, and InputHost turns them into the engine's
// snapshot (ENG-R865). Callers are the utility queue (signals, import, reset) and the settings actor (which runs on
// the same queue); state is behind a lock so any thread may read it. Never logged (PLT-R901): the words are
// bundled vocabulary, but which ones a person types and corrects is still theirs.

public import AppModel
public import Foundation
public import RealtimeSupport

public final class CollisionMemoryStore: Sendable {
    public static let fileName = "collision-memory.json"
    /// PLT-R914: written with a 2 s debounce.
    public static let writeDelay = TimeSpan.seconds(2)
    /// 2,048 entries take about 400 KB; a larger file is not one this build wrote.
    static let maxFileBytes = 4 * 1024 * 1024

    /// Receives the votes after every change that alters them (load, signal, removal, import, clear).
    public typealias Observer = @Sendable ([CollisionMemoryVote]) -> Void

    private struct State {
        var memory = CollisionMemory.empty
        /// The bundled collision list; nil until `load`: nothing is recorded or written before it.
        var vocabulary: CollisionVocabulary?
        /// Imported before `load` (validated then).
        var pendingImport = CollisionMemory.empty
        /// The day the whole memory was last aged.
        var agedDay: Int?
        var dirty = false
        /// Bumped on every change, so a write that raced a change leaves the memory dirty.
        var revision: UInt64 = 0
        var timer: (any DebounceTimer)?
        var timerToken: UInt64 = 0
        /// A newer schema is on disk: its known entries are used, the file is never rewritten (as PLT-R1007).
        var readOnly = false
        var published: [CollisionMemoryVote]?
        var observer: Observer?

        mutating func changed() {
            dirty = true
            revision &+= 1
        }
    }

    private struct FileContents {
        var memory = CollisionMemory.empty
        var readOnly = false
    }

    public let url: URL
    private let directory: URL
    private let fileSystem: any FileSystem
    private let wallClock: any WallClock
    private let scheduler: any DebounceScheduler
    private let writtenBy: String
    private let state = Mutex(State())

    public init(
        location: StorageLocation, fileSystem: any FileSystem, wallClock: any WallClock,
        scheduler: any DebounceScheduler, writtenBy: String
    ) {
        directory = location.directory
        url = location.directory.appendingPathComponent(Self.fileName)
        self.fileSystem = fileSystem
        self.wallClock = wallClock
        self.scheduler = scheduler
        self.writtenBy = writtenBy
    }

    // MARK: Reading

    /// The memory has been loaded with the bundled list.
    public var isLoaded: Bool { state.withLock { $0.vocabulary != nil } }
    /// Diagnostics report this number only (PLT-R901, PLT-R914).
    public var entryCount: Int { state.withLock { $0.memory.count } }
    /// Every vote, conflicts included (the engine's snapshot).
    public var votes: [CollisionMemoryVote] { state.withLock { $0.memory.votes } }
    /// The rows of the learned-words sheet (PRD-R78): entries that vote for a side.
    public var learnedChoices: [CollisionMemoryVote] { state.withLock { $0.memory.learnedChoices } }
    /// A copy of the counters (tests, export).
    public var memory: CollisionMemory { state.withLock { $0.memory } }

    /// Replaces the observer; a loaded store calls it at once with the current votes.
    public func setObserver(_ observer: Observer?) {
        let current: [CollisionMemoryVote]? = state.withLock { state in
            state.observer = observer
            guard state.vocabulary != nil else { return nil }
            state.published = state.memory.votes
            return state.published
        }
        if let current { observer?(current) }
    }

    // MARK: Loading

    /// Reads the file, keeps only words of `vocabulary` (the bundled collision list: the ambiguity table's words and
    /// the collision supplement), ages it to today and publishes the votes. A corrupt file is renamed aside (never
    /// deleted) and the memory starts empty.
    public func load(vocabulary: CollisionVocabulary) {
        let today = currentDay()
        let contents = readFile()
        let changed: Bool = state.withLock { state in
            state.vocabulary = vocabulary
            state.readOnly = contents.readOnly
            let loaded = contents.memory.merging(state.pendingImport).validated(against: vocabulary)
                .aged(to: today).capped()
            state.agedDay = today
            let differs = loaded != contents.memory || !state.pendingImport.isEmpty
            state.pendingImport = .empty
            state.memory = loaded
            if differs { state.changed() }
            return differs
        }
        if changed { scheduleWrite() }
        publish()
    }

    private func readFile() -> FileContents {
        guard fileSystem.fileExists(at: url) else { return FileContents() }
        guard let data = try? fileSystem.readData(at: url, maxBytes: Self.maxFileBytes),
            let object = try? JSONSupport.parseObject(data),
            let version = object[EnvelopeKey.schemaVersion]?.intValue, version >= 1
        else {
            quarantine()
            return FileContents()
        }
        return FileContents(
            memory: CollisionMemoryCodec.decode(object), readOnly: version > CollisionMemoryCodec.schemaVersion)
    }

    /// `collision-memory.json.corrupt-<timestamp>` next to it (PLT-R1006 "never wipe").
    private func quarantine() {
        let stamp = StorageTimestamp.compact(wallClock.now())
        let target = directory.appendingPathComponent(Self.fileName + ".corrupt-" + stamp)
        try? fileSystem.moveItem(at: url, to: target)
    }

    // MARK: Changes

    /// ENG-R864 signals for words of the bundled list; other words and signals before `load` are dropped. The
    /// caller has already dropped what must not be recorded (secure input, secure fields, `englishRestore: false`,
    /// D28 off: PLT-R914).
    public func apply(_ signals: [CollisionMemorySignal]) {
        guard !signals.isEmpty else { return }
        let today = currentDay()
        let changed: Bool = state.withLock { state in
            guard let vocabulary = state.vocabulary else { return false }
            let accepted = signals.filter { vocabulary.contains($0.word) }
            guard !accepted.isEmpty else { return false }
            Self.age(&state, to: today)
            state.memory = state.memory.applying(accepted, day: today)
            state.changed()
            return true
        }
        guard changed else { return }
        scheduleWrite()
        publish()
    }

    /// Removes one entry (one row of the learned-words sheet; `context` nil is the any-context entry).
    public func forget(word: String, context: CollisionMemoryContext?) {
        edit { $0.removing(CollisionMemoryKey(word: word, context: context)) }
    }

    /// Removes every entry of `word`.
    public func forget(word: String) {
        edit { $0.removing(word: word) }
    }

    /// "Xóa tất cả" and the Typing pane reset (PRD-R26, PRD-R78): the memory empties and the file is deleted.
    public func clearAll() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
            state.memory = .empty
            state.pendingImport = .empty
            state.dirty = false
            state.revision &+= 1
        }
        if fileSystem.fileExists(at: url) { try? fileSystem.removeItem(at: url) }
        publish()
    }

    /// Import (PRD-R72): counters are added to the current ones; words not on the bundled list are dropped.
    public func merge(_ imported: CollisionMemory) {
        guard !imported.isEmpty else { return }
        let today = currentDay()
        let changed: Bool = state.withLock { state in
            guard let vocabulary = state.vocabulary else {
                state.pendingImport = state.pendingImport.merging(imported)
                return false
            }
            let valid = imported.validated(against: vocabulary)
            guard !valid.isEmpty else { return false }
            Self.age(&state, to: today)
            state.memory = state.memory.merging(valid).aged(to: today)
            state.changed()
            return true
        }
        guard changed else { return }
        scheduleWrite()
        publish()
    }

    /// Writes a pending change now (quit, update install).
    public func flush() {
        state.withLock { state in
            state.timer?.cancel()
            state.timer = nil
        }
        writeNow()
    }

    private func edit(_ change: (CollisionMemory) -> CollisionMemory) {
        let changed: Bool = state.withLock { state in
            guard state.vocabulary != nil else { return false }
            let next = change(state.memory)
            guard next != state.memory else { return false }
            state.memory = next
            state.changed()
            return true
        }
        guard changed else { return }
        scheduleWrite()
        publish()
    }

    private static func age(_ state: inout State, to day: Int) {
        guard state.agedDay != day else { return }
        state.agedDay = day
        state.memory = state.memory.aged(to: day)
    }

    // MARK: Export

    /// The `collisionMemory` section of a settings export: the entries, without the envelope.
    public func exportSection() -> JSONValue { .array(CollisionMemoryCodec.encodeEntries(memory)) }

    /// Entries of an export section; invalid entries are left out (PLT-R912). Words are checked at merge.
    public static func importedEntries(_ section: [JSONValue]) -> CollisionMemory {
        CollisionMemoryCodec.decodeEntries(section)
    }

    // MARK: Writing

    private func scheduleWrite() {
        state.withLock { state in
            guard state.timer == nil, !state.readOnly else { return }
            state.timerToken &+= 1
            let token = state.timerToken
            state.timer = scheduler.schedule(after: Self.writeDelay) { [weak self] in self?.timerFired(token) }
        }
    }

    private func timerFired(_ token: UInt64) {
        let current: Bool = state.withLock { state in
            guard state.timerToken == token, state.timer != nil else { return false }
            state.timer = nil
            return true
        }
        if current { writeNow() }
    }

    /// Atomic write, 0600 in a 0700 folder. A failed write keeps the change for the next one.
    private func writeNow() {
        let pending: (CollisionMemory, UInt64)? = state.withLock { state in
            guard state.dirty, !state.readOnly, state.vocabulary != nil else { return nil }
            return (state.memory, state.revision)
        }
        guard let (memory, revision) = pending else { return }
        do {
            if !fileSystem.fileExists(at: directory) {
                try fileSystem.createDirectory(at: directory, permissions: .ownerOnlyDirectory)
            }
            let data = try JSONSupport.serialize(.object(CollisionMemoryCodec.encodeFile(memory, writtenBy: writtenBy)))
            try fileSystem.writeAtomically(data, to: url, permissions: .ownerOnlyFile)
        } catch {
            return
        }
        state.withLock { state in
            if state.revision == revision { state.dirty = false }
        }
    }

    // MARK: Publication

    private func publish() {
        let delivery: (Observer, [CollisionMemoryVote])? = state.withLock { state in
            let votes = state.memory.votes
            guard state.published != votes else { return nil }
            state.published = votes
            return state.observer.map { ($0, votes) }
        }
        if let (observer, votes) = delivery { observer(votes) }
    }

    private func currentDay() -> Int { CollisionMemory.day(of: wallClock.now()) }
}
