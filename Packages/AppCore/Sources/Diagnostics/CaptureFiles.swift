// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Session state and file format of the typing trace (PLT-R905). One JSON object per line: a `session` header,
// then `key`, `engine`, `job`, `focus` and `gap` lines with `t` in microseconds since the start, and an `end`
// line. Characters appear only in `char` (layout output) and `insert` (engine output); this file is the only
// artefact that ever holds them (PRD-R46).

internal import AppModel
internal import Foundation
internal import RealtimeSupport

enum CaptureFiles {
    static let formatVersion = 1
    static let fileExtension = "jsonl"
    /// Ring drain period while recording. Capture is a short user-started session; 2 s keeps to PLT-R803 and
    /// the rings hold far more than 2 s of typing.
    static let drainInterval: Duration = .seconds(2)
    /// 180 s of fast typing is well under 1 MB; the cap only guards against a corrupted file.
    static let maximumFileBytes = 16 * 1_024 * 1_024

    enum EndReason: String {
        case timeLimit, stopped
    }

    static func url(for id: CaptureSessionID, in directory: URL) -> URL {
        directory.appendingPathComponent(id.rawValue + "." + fileExtension)
    }

    /// `trace-YYYYMMDD-HHMMSS-xxxx` in UTC with a random suffix, so two sessions never share a file.
    static func makeID(at date: Date) -> CaptureSessionID {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? calendar.timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        let stamp =
            pad(parts.year, 4) + pad(parts.month, 2) + pad(parts.day, 2) + "-" + pad(parts.hour, 2)
            + pad(parts.minute, 2) + pad(parts.second, 2)
        let suffix = HexEncoding.lowercase(
            withUnsafeBytes(of: UInt16.random(in: .min ... .max).bigEndian) { Array($0) })
        return CaptureSessionID(rawValue: "trace-" + stamp + "-" + suffix)
    }

    /// IDs are file names inside the captures folder: letters, digits and `-` only, so a crafted ID can never
    /// point outside it.
    static func isValid(_ id: CaptureSessionID) -> Bool {
        !id.rawValue.isEmpty && id.rawValue.utf8.count <= 64
            && id.rawValue.unicodeScalars.allSatisfy {
                $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || $0 == "-")
            }
    }

    static func encode(_ lines: [CaptureLine]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        var data = Data()
        for line in lines {
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        return data
    }

    static func decode(_ data: Data) -> [CaptureLine] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return data.split(separator: 0x0A).compactMap { try? decoder.decode(CaptureLine.self, from: Data($0)) }
    }
}

/// The running session, guarded by the controller's mutex.
struct CaptureSession: Sendable {
    struct OpenGap: Sendable {
        var reason: PauseCode
        var from: MonotonicInstant
    }

    struct ClosedGap: Sendable {
        var reason: PauseCode
        var from: MonotonicInstant
        var to: MonotonicInstant
        var written = false
    }

    var info: CaptureSessionInfo
    var start: MonotonicInstant
    var timers: [any ScheduledTimer]
    var openGap: OpenGap?
    var gaps: [ClosedGap] = []

    init(info: CaptureSessionInfo, start: MonotonicInstant, timers: [any ScheduledTimer]) {
        self.info = info
        self.start = start
        self.timers = timers
    }

    mutating func closeGap(at now: MonotonicInstant) {
        guard let open = openGap else { return }
        gaps.append(ClosedGap(reason: open.reason, from: open.from, to: now))
        openGap = nil
    }

    /// False for records stamped before the session or inside a gap.
    func accepts(_ instant: MonotonicInstant) -> Bool {
        guard instant >= start else { return false }
        if let open = openGap, instant >= open.from { return false }
        return !gaps.contains { instant >= $0.from && instant <= $0.to }
    }

    mutating func takeUnwrittenGaps() -> [(at: MonotonicInstant, line: CaptureLine)] {
        var lines: [(at: MonotonicInstant, line: CaptureLine)] = []
        for index in gaps.indices where !gaps[index].written {
            let gap = gaps[index]
            lines.append(
                (
                    gap.from,
                    CaptureLine(
                        type: .gap, t: gap.from.microseconds(since: start), reason: gap.reason.rawValue,
                        to: gap.to.microseconds(since: start))
                ))
            gaps[index].written = true
        }
        return lines
    }
}

/// One line of the capture file. Absent fields are omitted from the JSON.
struct CaptureLine: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case session, key, engine, job, focus, gap, end }

    var type: Kind
    var t: UInt64?
    var id: String?
    var startedAt: Date?
    var endsAt: Date?
    var formatVersion: Int?
    var event: String?
    var keyCode: UInt16?
    var flags: UInt64?
    var char: String?
    var outcome: String?
    var delete: Int?
    var insert: String?
    var sequence: UInt64?
    var strategy: String?
    var durationUs: UInt64?
    var bundle: String?
    var role: String?
    var subrole: String?
    var reason: String?
    var to: UInt64?

    init(
        type: Kind, t: UInt64? = nil, id: String? = nil, startedAt: Date? = nil, endsAt: Date? = nil,
        formatVersion: Int? = nil, reason: String? = nil, to: UInt64? = nil
    ) {
        self.type = type
        self.t = t
        self.id = id
        self.startedAt = startedAt
        self.endsAt = endsAt
        self.formatVersion = formatVersion
        self.reason = reason
        self.to = to
    }

    init(_ record: CaptureRecord, start: MonotonicInstant) {
        switch record {
        case .key(let key):
            self.init(type: .key, t: key.at.microseconds(since: start))
            event = String(describing: key.kind)
            keyCode = key.keyCode
            flags = key.flags
            char = key.character.count == 0 ? nil : key.character.string
            outcome = String(describing: key.outcome)
        case .engine(let deleteCount, let insert, let at):
            self.init(type: .engine, t: at.microseconds(since: start))
            delete = deleteCount
            self.insert = insert
        case .job(let sequence, let strategy, let duration, let outcome):
            self.init(type: .job)
            self.sequence = sequence
            self.strategy = strategy.rawValue
            durationUs = duration
            self.outcome = outcome.description
        case .focus(let bundle, let role, let subrole, let at):
            // Roles and bundle IDs only (PLT-R905); the record type has no title or URL.
            self.init(type: .focus, t: at.microseconds(since: start))
            self.bundle = bundle?.rawValue
            self.role = role
            self.subrole = subrole
        case .gap(let reason, let from, let to):
            self.init(
                type: .gap, t: from.microseconds(since: start), reason: reason.rawValue,
                to: to.microseconds(since: start))
        }
    }
}

extension CaptureRecord {
    /// When the record happened; jobs carry no timestamp and are ordered at drain time.
    var timestamp: MonotonicInstant? {
        switch self {
        case .key(let key): key.at
        case .engine(_, _, let at): at
        case .job: nil
        case .focus(_, _, _, let at): at
        case .gap(_, let from, _): from
        }
    }
}

extension MonotonicInstant {
    func microseconds(since start: MonotonicInstant) -> UInt64 { nanoseconds(since: start) / 1_000 }
}

extension Duration {
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
