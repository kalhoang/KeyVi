// SPDX-License-Identifier: GPL-3.0-or-later
//
// What the scanner flags in a dev trace (PLT-R904A, ADR 0007): the moments worth reading around. Kinds a to i of
// the workstream: markers, Backspace edits, correction bursts, readback mismatches, resets with a token open,
// injection problems, restores and history re-opens, replay divergences and Command+Z after an edit; since the
// incidents of 2026-11-14 also dropped keys, extra characters and slow readbacks. A finding carries metadata only
// (time, app, rule, kind, a content-free detail); its note, which may name a typed character, and the excerpt are
// printed by `show` only.

internal import Foundation

public struct Finding: Sendable, Hashable {
    public enum Kind: String, Sendable, CaseIterable {
        case marker
        case backspaceEdit
        case correctionBurst
        case readbackMismatch
        /// A readback mismatch that is exactly one passed key's character missing from the field.
        case keyDropped
        /// A readback mismatch that is exactly one character in the field KeyVi did not type.
        case extraCharacter
        /// A readback that timed out or whose AX calls took longer than `FindingLimits.slowReadback`.
        case slowReadback
        case resetWithOpenToken
        case injectionProblem
        case restoreOrReopen
        case replayDivergence
        case undoAfterEdit
    }

    public var kind: Kind
    /// Microseconds since 1970.
    public var t: Int64
    /// The event the excerpt centres on.
    public var eventIndex: Int
    public var bundle: String?
    public var rule: String?
    /// Names and numbers only, never typed content.
    public var detail: String
    /// What `show` adds under the detail; may name a typed character (a dropped key), so never in the summary.
    public var note: String? = nil
}

/// Thresholds of the detectors.
enum FindingLimits {
    /// (c) Backspaces of one burst.
    static let burstBackspaces = 3
    /// (c) The burst fits in this window.
    static let burstWindow: Int64 = 1_500_000
    /// (c) The burst starts this soon after the engine transformed a word, and retyping follows this soon.
    static let burstAfterTransform: Int64 = 2_000_000
    static let retypeAfterBurst: Int64 = 2_000_000
    /// (f) A job slower than this.
    static let slowJob: UInt64 = 50_000
    /// (i) Command+Z this soon after an engine edit.
    static let undoAfterEdit: Int64 = 2_000_000
    /// (d) Characters of KeyVi's view compared with the field.
    static let readbackCompare = 32
    /// (d) A readback this soon after a key may not show it yet, and is not compared.
    static let readbackAfterKey: Int64 = 100_000
    /// A readback whose AX calls took longer than one AX call of the inject worker may (`axCallTimeout`, 30 ms):
    /// in that field KeyVi's own reads would time out.
    static let slowReadback: UInt64 = 30_000
    /// A key counts as still on its way to the app this long after it went down: normally a few milliseconds, tens
    /// of milliseconds under the memory pressure of 2026-11-14 (incidents 1 and 10: readbacks 27 and 71 ms after
    /// the lost key), with room to spare and below the first recorder's 300 ms readback delay.
    static let deliveryWindow: Int64 = 200_000
    /// The first recorder's readbacks have no duration; three AX calls of at most 50 ms each bound it.
    static let unmeasuredReadback: Int64 = 150_000
}

/// The focus and settings in effect at each event, for findings and replay.
struct TraceContext {
    var bundle: String?
    var rule: String?
    var focus: TraceLine?
    var settings: [String: String] = [:]

    mutating func apply(_ line: TraceLine) {
        switch line.type {
        case "focus":
            focus = line
            bundle = line.bundle
            rule = line.rule
        case "settings": settings = line.s ?? settings
        case "file", "start":
            if line.type == "start" {
                focus = nil
                bundle = nil
                rule = nil
            }
        default: break
        }
    }
}

public enum FindingDetector {
    /// Every finding in time order; replay divergences need the bundled lexicons (`replay` nil skips them).
    public static func findings(in events: [TraceEvent], replay: ReplayEngineFactory?) -> [Finding] {
        var found: [Finding] = []
        var scanner = SequentialScan()
        for event in events { scanner.feed(event, into: &found) }
        scanner.finish(into: &found)
        if let replay { found += ReplayCheck.divergences(in: events, factory: replay) }
        return found.sorted { ($0.t, $0.eventIndex, $0.kind.order) < ($1.t, $1.eventIndex, $1.kind.order) }
    }
}

extension Finding.Kind {
    var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}
