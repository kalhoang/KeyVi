// SPDX-License-Identifier: GPL-3.0-or-later
//
// File layout of the dev recorder (PLT-R904A, ADR 0007): `<logs folder>/dev-traces/YYYYMMDD-HH.jsonl` in local
// time, one JSON object per line, folder 0700, files 0600, both excluded from backup; 7 days and 200 MB at most,
// oldest first. Every line has `type` and `t` (microseconds since 1970, wall clock); each file the process opens
// starts with a `file` line, the settings and the current focus. docs/runbooks/dev-recorder.md documents the
// fields; TraceScanCore reads them.

#if DEV_RECORDER
internal import AppModel
public import Foundation
public import RealtimeSupport

public enum DevRecorderLimits {
    public static let retention: TimeInterval = 7 * 24 * 3_600
    public static let maximumTotalBytes = 200 * 1_024 * 1_024
    public static let purgeInterval: TimeSpan = .seconds(3_600)
    public static let pauseDuration: TimeSpan = .seconds(30 * 60)
}

enum DevTraceFiles {
    static let folderName = "dev-traces"
    static let fileExtension = "jsonl"
    /// 2: readback lines carry `durUs`, `maxCallUs`, `waitUs`, `idleUs` and `overlap` (2026-11-14 incidents).
    /// 3: file lines carry the engine identity `eng`, secure gap lines the likely holder (`holder`, `pid`) and
    /// `durUs`, focus lines without an app the frontmost application `front` (2026-11-15).
    static let formatVersion = 3

    /// `YYYYMMDD-HH` of `date` in `timeZone`.
    static func hourKey(for date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return pad(parts.year, 4) + pad(parts.month, 2) + pad(parts.day, 2) + "-" + pad(parts.hour, 2)
    }

    /// Start of the hour a file name stands for; nil for names the recorder did not write.
    static func hourStart(ofFileNamed name: String, timeZone: TimeZone) -> Date? {
        guard name.hasSuffix("." + fileExtension) else { return nil }
        let stem = name.dropLast(fileExtension.count + 1)
        let digits = stem.filter { $0 != "-" }
        guard stem.count == 11, stem[stem.index(stem.startIndex, offsetBy: 8)] == "-", digits.count == 10,
            digits.allSatisfy({ ("0"..."9").contains($0) })
        else { return nil }
        let number = { (from: Int, length: Int) -> Int? in
            Int(String(digits.dropFirst(from).prefix(length)))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = DateComponents(
            year: number(0, 4), month: number(4, 2), day: number(6, 2), hour: number(8, 2))
        guard let date = calendar.date(from: parts) else { return nil }
        return hourKey(for: date, timeZone: timeZone) == String(stem) ? date : nil
    }

    static func url(forHour key: String, in directory: URL) -> URL {
        directory.appendingPathComponent(key + "." + fileExtension)
    }

    static func microseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1_000_000).rounded()) }

    static func encode(_ lines: [DevTraceLine]) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for line in lines {
            guard let encoded = try? encoder.encode(line) else { continue }
            data.append(encoded)
            data.append(0x0A)
        }
        return data
    }

    private static func pad(_ value: Int?, _ width: Int) -> String {
        let text = String(value ?? 0)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// One line of a dev trace file. Absent fields are omitted from the JSON.
struct DevTraceLine: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable {
        case file, start, pause, resume, stop, settings, focus, key, engine, boundary, job, fallback, readback
        case marker, mode, gap
    }

    var type: Kind
    var t: Int64
    // file, start
    var v: Int?
    var launch: String?
    var build: String?
    var app: String?
    /// Engine identity (`DevEngineIdentity`), file lines (format version 3).
    var eng: String?
    // key
    var ev: String?
    var kc: UInt16?
    var fl: UInt64?
    var ch: String?
    var out: String?
    // engine
    var act: String?
    var del: Int?
    var ins: String?
    var comp: String?
    var dec: String?
    // boundary, gap, fallback, readback, pause
    var reason: String?
    var job: String?
    var end: Int64?
    var dropped: Int?
    var until: Int64?
    // marker
    var src: String?
    // job, fallback
    var seq: UInt64?
    var gen: UInt64?
    var kind: String?
    var strat: String?
    var posted: Int?
    var delN: Int?
    var insN: Int?
    var totalUs: UInt64?
    var runUs: UInt64?
    var from: String?
    var to: String?
    // focus, readback, mode
    var bundle: String?
    var role: String?
    var subrole: String?
    var rule: String?
    var rtf: String?
    var ax: String?
    var secure: Bool?
    var mode: String?
    var modeSrc: String?
    var ctx: String?
    var er: Bool?
    var mac: Bool?
    var pause: String?
    var manual: Bool?
    /// Focus lines without an app: the frontmost application's bundle ID (format version 3).
    var front: String?
    /// Secure gap lines: the likely holder's bundle ID and process ID (PLT-R396, format version 3).
    var holder: String?
    var pid: Int32?
    var status: String?
    var text: String?
    var selLoc: Int?
    var selLen: Int?
    // readback timing (format version 2)
    var durUs: UInt64?
    var maxCallUs: UInt64?
    var waitUs: UInt64?
    var idleUs: UInt64?
    var overlap: Bool?
    // settings
    var s: [String: String]?

    init(type: Kind, t: Int64) {
        self.type = type
        self.t = t
    }
}

extension DevTraceLine {
    /// PLT-R905 key record (shared ring) as a dev trace line.
    init(key: KeyCaptureRecord, t: Int64) {
        self.init(type: .key, t: t)
        ev = String(describing: key.kind)
        kc = key.keyCode
        fl = key.flags
        ch = key.character.count == 0 ? nil : key.character.string
        out = String(describing: key.outcome)
    }

    init(_ record: DevTraceRecord, t: Int64) {
        switch record {
        case .engine(let step):
            self.init(type: .engine, t: t)
            act = String(describing: step.action)
            del = step.deleteCount
            ins = step.insert
            comp = step.composing
            dec = step.decision.map(DevTraceNames.describe)
        case .boundary(let reason, let job, _):
            self.init(type: .boundary, t: t)
            self.reason = DevTraceNames.describe(reason)
            self.job = job.map(DevTraceNames.describe)
        case .marker(let source, _):
            self.init(type: .marker, t: t)
            src = source.rawValue
        case .job(let job):
            self.init(job: job, t: t)
        case .fallback(let sequence, let from, let to, let reason, _):
            self.init(type: .fallback, t: t)
            seq = sequence
            self.from = from.rawValue
            self.to = to.rawValue
            self.reason = DevTraceNames.describe(reason)
        case .focus(let focus):
            self.init(focus: focus, t: t)
        case .readback(let readback):
            self.init(type: .readback, t: t)
            reason = readback.reason.rawValue
            status = readback.status.rawValue
            text = readback.textBeforeCaret
            selLoc = readback.selectionLocation
            selLen = readback.selectionLength
            bundle = readback.bundle
            rule = readback.rule
            durUs = readback.durationMicroseconds
            maxCallUs = readback.longestCallMicroseconds
            waitUs = readback.waitMicroseconds
            idleUs = readback.idleMicroseconds
            overlap = readback.overlap ? true : nil
        case .mode(let change):
            self.init(type: .mode, t: t)
            mode = change.mode.rawValue
            manual = change.manual
            bundle = change.bundle
        case .settings(let snapshot, _):
            self.init(type: .settings, t: t)
            s = snapshot.values
        }
    }

    private init(job: DevJobRecord, t: Int64) {
        self.init(type: .job, t: t)
        seq = job.sequence
        gen = job.generation
        kind = DevTraceNames.describe(job.kind)
        strat = job.strategy.rawValue
        out = job.outcome.description
        delN = job.deleteCount
        insN = job.insertCount
        posted = job.eventsPosted
        totalUs = job.totalMicroseconds
        runUs = job.runMicroseconds
    }

    private init(focus: DevFocusRecord, t: Int64) {
        self.init(type: .focus, t: t)
        gen = focus.generation
        bundle = focus.bundle
        role = focus.role
        subrole = focus.subrole
        rule = focus.rule
        strat = focus.strategy
        rtf = focus.requireTextFocus
        ax = focus.axAvailability
        secure = focus.secure
        mode = focus.mode
        modeSrc = focus.modeSource
        ctx = focus.engineContext
        er = focus.englishRestore
        mac = focus.macros
        pause = focus.pause
        front = focus.bundle == nil ? focus.frontmost : nil
    }
}

/// Names of enum values boxed by producers that Diagnostics cannot see (engine and injection types). Called on the
/// drain, never on the tap.
enum DevTraceNames {
    /// `String(describing:)` without module and type qualifiers: `kept(VietnameseEngine.CommitRule.notEnglish)`
    /// becomes `kept(notEnglish)`.
    static func describe(_ value: any Sendable) -> String {
        let text = String(describing: value)
        var output = ""
        var word = ""
        func flush(_ terminator: Character?) {
            output += word
            if let terminator { output.append(terminator) }
            word = ""
        }
        for character in text {
            if character == "." {
                word = ""  // a qualifier: drop what came before the dot
            } else if character.isLetter || character.isNumber || character == "_" {
                word.append(character)
            } else {
                flush(character)
            }
        }
        flush(nil)
        return output
    }
}
#endif
