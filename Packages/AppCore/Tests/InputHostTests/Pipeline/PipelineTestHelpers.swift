// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Shared helpers for the pipeline suites: ANSI virtual key codes, flag bits and job inspection.

import AppModel
import Injection
import InputHost
import TestSupport
import VietnameseEngine

enum Key {
    static let a: UInt16 = 0x00
    static let s: UInt16 = 0x01
    static let d: UInt16 = 0x02
    static let x: UInt16 = 0x07
    static let w: UInt16 = 0x0D
    static let e: UInt16 = 0x0E
    static let u: UInt16 = 0x20
    static let space: UInt16 = 0x31
    static let comma: UInt16 = 0x2B
    static let backspace: UInt16 = 0x33
    static let returnKey: UInt16 = 0x24
    static let keypadEnter: UInt16 = 0x4C
    static let tab: UInt16 = 0x30
    static let escape: UInt16 = 0x35
    static let left: UInt16 = 0x7B
    static let up: UInt16 = 0x7E
    static let down: UInt16 = 0x7D
    static let forwardDelete: UInt16 = 0x75
    static let keypad1: UInt16 = 0x53
    static let f5: UInt16 = 0x60
    static let control: UInt16 = 0x3B
    static let shift: UInt16 = 0x38
    static let command: UInt16 = 0x37
    static let rightCommand: UInt16 = 0x36
    static let azertyDeadKey: UInt16 = 0x21
}

enum Flag {
    static let capsLock: UInt64 = 0x0001_0000
    static let shift: UInt64 = 0x0002_0000
    static let control: UInt64 = 0x0004_0000
    static let option: UInt64 = 0x0008_0000
    static let command: UInt64 = 0x0010_0000
    static let rightCommandDevice: UInt64 = 0x10
}

enum JobKind: Equatable {
    case edit, replay, paired, boundary
}

extension InjectionJob {
    var kind: JobKind {
        switch self {
        case .edit: .edit
        case .replay: .replay
        case .pairedKeyUp: .paired
        case .boundary: .boundary
        }
    }

    var edit: EditJob? {
        if case .edit(let job) = self { return job }
        return nil
    }

    var replayed: KeyEventRecord? {
        if case .replay(_, let record) = self { return record }
        return nil
    }

    var boundaryReason: BoundaryReason? {
        if case .boundary(let job) = self { return job.reason }
        return nil
    }
}

extension EngineEventLog {
    /// Engine inputs (no resets, no creations).
    var feeds: [EngineEvent] {
        events.filter {
            if case .reset = $0 { return false }
            return true
        }
    }

    var resets: [ResetReason] {
        events.compactMap {
            if case .reset(let reason) = $0 { return reason }
            return nil
        }
    }

    var madeVariants: [EngineVariant] {
        entries.compactMap {
            if case .made(let variant) = $0 { return variant }
            return nil
        }
    }
}

extension MainNotice {
    var toggledMode: TypingMode? {
        if case .modeToggled(_, _, let mode) = self { return mode }
        return nil
    }
}

/// Typing with the fixture: each character is a keyDown then keyUp of its ANSI key.
extension PipelineFixture {
    @discardableResult
    func typeKeys(_ codes: [UInt16]) -> [TapVerdict] { codes.map { press($0) } }
}
