// SPDX-License-Identifier: GPL-3.0-or-later
//
// The dev recorder's line format as the scanner reads it (PLT-R904A, ADR 0007; writer: Diagnostics
// `DevTraceLine`, documented in docs/runbooks/dev-recorder.md). Every field but `type` and `t` is optional, so lines
// of a newer format version still decode; unknown types are kept and shown as they are. A round-trip test writes
// with the recorder and reads with this type, so the two cannot drift apart.

internal import Foundation

public struct TraceLine: Decodable, Sendable, Hashable {
    public var type: String
    /// Microseconds since 1970, wall clock.
    public var t: Int64
    public var v: Int?
    public var launch: String?
    public var app: String?
    /// Engine identity (`DevEngineIdentity`), file and start lines of format version 3.
    public var eng: String?
    public var ev: String?
    public var kc: UInt16?
    public var fl: UInt64?
    public var ch: String?
    public var out: String?
    public var act: String?
    public var del: Int?
    public var ins: String?
    public var comp: String?
    public var dec: String?
    public var reason: String?
    public var job: String?
    public var end: Int64?
    public var dropped: Int?
    public var until: Int64?
    public var src: String?
    public var seq: UInt64?
    public var gen: UInt64?
    public var kind: String?
    public var strat: String?
    public var posted: Int?
    public var delN: Int?
    public var insN: Int?
    public var totalUs: UInt64?
    public var runUs: UInt64?
    public var from: String?
    public var to: String?
    public var bundle: String?
    public var role: String?
    public var subrole: String?
    public var rule: String?
    public var rtf: String?
    public var ax: String?
    public var secure: Bool?
    public var mode: String?
    public var modeSrc: String?
    public var ctx: String?
    public var er: Bool?
    public var mac: Bool?
    public var pause: String?
    public var manual: Bool?
    /// Focus lines without an app: NSWorkspace's frontmost application (format version 3).
    public var front: String?
    /// Secure gap lines: the likely holder's bundle ID and process ID (format version 3).
    public var holder: String?
    public var pid: Int32?
    public var status: String?
    public var text: String?
    public var selLoc: Int?
    public var selLen: Int?
    /// Readback timing, format version 2: AX calls' duration and the longest single call, wait since the trigger,
    /// input idle time, and a key down while the read was in flight.
    public var durUs: UInt64?
    public var maxCallUs: UInt64?
    public var waitUs: UInt64?
    public var idleUs: UInt64?
    public var overlap: Bool?
    public var s: [String: String]?

    public init(type: String, t: Int64) {
        self.type = type
        self.t = t
    }
}

/// One line with where it came from, in scan order.
public struct TraceEvent: Sendable, Hashable {
    public var index: Int
    public var line: TraceLine
    public var file: String

    public var t: Int64 { line.t }
}

/// Virtual key codes and flag bits the scanner needs (public macOS values, Carbon `Events.h`, CGEventFlags).
enum TraceKeys {
    static let backspace: UInt16 = 0x33
    static let returnKey: UInt16 = 0x24
    static let keypadEnter: UInt16 = 0x4C
    static let tab: UInt16 = 0x30
    static let zKey: UInt16 = 0x06
    static let capsLock: UInt64 = 0x0001_0000
    static let control: UInt64 = 0x0004_0000
    static let option: UInt64 = 0x0008_0000
    static let command: UInt64 = 0x0010_0000

    /// Modifier keys report flagsChanged, never keyUp (kVK_RightCommand to kVK_Function).
    static func isModifier(_ keyCode: UInt16) -> Bool { (0x36...0x3F).contains(keyCode) }

    /// Keypad keys that produce characters (kVK_ANSI_Keypad0...9, Decimal, Multiply, Plus, Clear, Divide, Minus,
    /// Equals), as the pipeline flags them for the engine (PLT-R355).
    static func isKeypadCharacter(_ keyCode: UInt16) -> Bool {
        switch keyCode {
        case 0x52...0x59, 0x5B, 0x5C, 0x41, 0x43, 0x45, 0x47, 0x4B, 0x4E, 0x51: true
        default: false
        }
    }
}

extension TraceLine {
    var isKeyDown: Bool { type == "key" && ev == "keyDown" }
    var isBackspaceDown: Bool { isKeyDown && kc == TraceKeys.backspace }
    var isKeyUp: Bool { type == "key" && ev == "keyUp" }
    /// A Backspace the pipeline reports to the engine: plain or with Shift. Option+Backspace deletes a word and
    /// Command+Backspace the line (PLT-R352): not one Backspace.
    var isPlainBackspaceDown: Bool {
        isBackspaceDown && flags & (TraceKeys.command | TraceKeys.control | TraceKeys.option) == 0
    }
    var flags: UInt64 { fl ?? 0 }
    var hasCommandOrControl: Bool { flags & (TraceKeys.command | TraceKeys.control) != 0 }
    /// An engine step that changed the text.
    var isEdit: Bool { type == "engine" && (act == "edit" || act == "editThenPassThrough") }
    var changesText: Bool { isEdit && ((del ?? 0) > 0 || !(ins ?? "").isEmpty) }
}
