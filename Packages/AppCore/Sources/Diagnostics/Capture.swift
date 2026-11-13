// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Time-boxed typing trace (PLT-R905, PRD-R46, D26): the only artefact that ever contains typed characters.

public import AppModel
public import Foundation
public import RealtimeSupport

public enum CaptureLimits {
    public static let defaultDuration: Duration = .seconds(60)
    public static let maximumDuration: Duration = .seconds(180)
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
    public enum Outcome: UInt8, Sendable, BitwiseCopyable { case passed, held, consumedForEdit, consumedAsHotkey, consumedPairedKeyUp }
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

/// Owns capture state. `isRecording` is an atomic flag the tap reads once per callback; records flow through
/// SPSC rings (tap, inject, ax producers) drained by the utility queue into
/// `~/Library/Logs/<folder>/captures/<id>.jsonl` (0600, excluded from backup).
public final class CaptureController: Sendable {
    public init(directory: URL, fileSystem: any FileSystem, wallClock: any WallClock, clock: any MonotonicClock) {
        unimplemented()
    }

    /// Tap-safe (one atomic load).
    public var isRecording: Bool { unimplemented() }
    public var tapRecords: SPSCRing<CaptureRecord> { unimplemented() }
    public var injectRecords: SPSCRing<CaptureRecord> { unimplemented() }
    public var focusRecords: SPSCRing<CaptureRecord> { unimplemented() }

    /// Explicit user action only, after a confirmation that explains what is recorded (PLT-R905).
    public func start(duration: Duration) throws -> CaptureSessionInfo { unimplemented() }
    public func stop() -> CaptureSessionInfo? { unimplemented() }
    public func remaining(now: Date) -> Duration? { unimplemented() }
    /// Readable rendering the user reviews before export (PLT-R905).
    public func render(_ id: CaptureSessionID, language: InterfaceLanguage) throws -> String { unimplemented() }
    /// Writes the export and deletes the capture immediately afterwards.
    public func export(_ id: CaptureSessionID, to destination: URL) throws { unimplemented() }
    public func discard(_ id: CaptureSessionID) { unimplemented() }
    /// Deletes captures older than 24 hours; run at launch and hourly on the utility queue.
    public func purgeExpired(now: Date) { unimplemented() }
}
