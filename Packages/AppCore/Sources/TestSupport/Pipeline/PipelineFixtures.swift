// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Snapshot values, synthetic layout tables and a directly driven pipeline for step tests (W1-F1, reused by
// W2-A). Key codes are the public ANSI virtual key codes (Carbon `Events.h`).

public import AppModel
internal import Dispatch
internal import Injection
public import InputHost
public import RealtimeSupport

public enum PipelineFixtures {
    public static let editorBundle = BundleKey(rawValue: "com.example.editor")!
    public static let otherBundle = BundleKey(rawValue: "com.example.chat")!
    public static let layoutID = InputSourceID(rawValue: "com.apple.keylayout.ABC")!
    /// ANSI keyboard type reported by `LMGetKbdType` on most Macs.
    public static let keyboardType: UInt32 = 40

    /// One wake-up pair shared by every fixture: nobody needs the wake-ups in tests, the rings are drained
    /// directly.
    public static let wakeSignal = WakeSignal(queue: DispatchQueue(label: "test.pipeline.wake"), handler: {})

    // MARK: Layout tables

    /// US ANSI (QWERTY) letters, digits, punctuation and keypad, with Shift and Caps Lock columns.
    public static func qwertyTable(keyboardType: UInt32 = keyboardType) -> LayoutTable {
        var characters: [UInt16: (Character, Character)] = [:]
        let letters: [(UInt16, Character)] = [
            (0x00, "a"), (0x01, "s"), (0x02, "d"), (0x03, "f"), (0x04, "h"), (0x05, "g"), (0x06, "z"), (0x07, "x"),
            (0x08, "c"), (0x09, "v"), (0x0B, "b"), (0x0C, "q"), (0x0D, "w"), (0x0E, "e"), (0x0F, "r"), (0x10, "y"),
            (0x11, "t"), (0x1F, "o"), (0x20, "u"), (0x22, "i"), (0x23, "p"), (0x25, "l"), (0x26, "j"), (0x28, "k"),
            (0x2D, "n"), (0x2E, "m"),
        ]
        for (code, letter) in letters { characters[code] = (letter, Character(letter.uppercased())) }
        let symbols: [(UInt16, Character, Character)] = [
            (0x12, "1", "!"), (0x13, "2", "@"), (0x14, "3", "#"), (0x15, "4", "$"), (0x17, "5", "%"),
            (0x16, "6", "^"), (0x1A, "7", "&"), (0x1C, "8", "*"), (0x19, "9", "("), (0x1D, "0", ")"),
            (0x1B, "-", "_"), (0x18, "=", "+"), (0x21, "[", "{"), (0x1E, "]", "}"), (0x29, ";", ":"),
            (0x27, "'", "\""), (0x2B, ",", "<"), (0x2F, ".", ">"), (0x2C, "/", "?"), (0x32, "`", "~"),
            (0x2A, "\\", "|"), (0x31, " ", " "),
        ]
        for (code, plain, shifted) in symbols { characters[code] = (plain, shifted) }
        let keypad: [(UInt16, Character)] = [
            (0x52, "0"), (0x53, "1"), (0x54, "2"), (0x55, "3"), (0x56, "4"), (0x57, "5"), (0x58, "6"), (0x59, "7"),
            (0x5B, "8"), (0x5C, "9"), (0x41, "."),
        ]
        for (code, digit) in keypad { characters[code] = (digit, digit) }
        return table(characters: characters, deadKeys: [], keyboardType: keyboardType)
    }

    /// A French (AZERTY) subset: `a` and `q`, `z` and `w` swapped, digits on Shift (PLT-R361), and a dead key
    /// (circumflex) on the `[` position.
    public static func azertyTable() -> LayoutTable {
        var characters: [UInt16: (Character, Character)] = [
            0x0C: ("a", "A"), 0x00: ("q", "Q"), 0x06: ("w", "W"), 0x0D: ("z", "Z"), 0x01: ("s", "S"),
            0x0E: ("e", "E"), 0x2D: ("n", "N"), 0x20: ("u", "U"), 0x1F: ("o", "O"), 0x10: ("y", "Y"),
            0x07: ("x", "X"), 0x02: ("d", "D"), 0x31: (" ", " "),
        ]
        let digits: [(UInt16, Character, Character)] = [
            (0x12, "&", "1"), (0x13, "é", "2"), (0x14, "\"", "3"), (0x15, "'", "4"), (0x17, "(", "5"),
            (0x16, "§", "6"),
        ]
        for (code, plain, shifted) in digits { characters[code] = (plain, shifted) }
        return table(characters: characters, deadKeys: [0x21], keyboardType: keyboardType)
    }

    /// Builds a 128 x 4 table: Caps Lock upper-cases letters only, like the system layouts.
    public static func table(
        characters: [UInt16: (Character, Character)], deadKeys: Set<UInt16>, keyboardType: UInt32,
        source: InputSourceID = layoutID
    ) -> LayoutTable {
        var entries = [LayoutEntry](repeating: .none, count: LayoutTable.keyCodeCount * 4)
        for (code, pair) in characters {
            let base = Int(code) * 4
            let capsLocked = pair.0.isLetter ? pair.1 : pair.0
            entries[base + LayoutModifierState.none.rawValue] = .character(pair.0)
            entries[base + LayoutModifierState.shift.rawValue] = .character(pair.1)
            entries[base + LayoutModifierState.capsLock.rawValue] = .character(capsLocked)
            entries[base + LayoutModifierState.shiftCapsLock.rawValue] = .character(pair.0.isLetter ? pair.0 : pair.1)
        }
        for code in deadKeys {
            for state in LayoutModifierState.allCases { entries[Int(code) * 4 + state.rawValue] = .deadKey }
        }
        return LayoutTable(source: source, keyboardType: keyboardType, entries: entries)
    }

    // MARK: Snapshots

    public static func settings(
        generation: UInt64 = 1, toggle: HotkeyBinding = .defaultToggle, restore: HotkeyBinding? = nil
    ) -> TapSettingsSnapshot {
        TapSettingsSnapshot(
            generation: generation, engines: EngineCatalog(engines: [:]), toggleHotkey: toggle,
            restoreHotkey: restore, macrosInEnglishMode: false, rememberPerApp: true)
    }

    public static func decision(
        strategy: InjectionStrategy = .backspaceReplace, variant: EngineVariant = .default,
        requireTextFocus: RequireTextFocus = .never, restoreHotkeyEnabled: Bool = true
    ) -> HostDecision {
        HostDecision(
            plan: InjectionPlan(strategy: strategy, parameters: .defaults, fallback: [.passThrough]), variant: variant,
            requireTextFocus: requireTextFocus, verifyReentry: .whenReadable,
            restoreHotkeyEnabled: restoreHotkeyEnabled, rule: nil, source: .default, specificity: 0)
    }

    public static func field(editable: Bool? = true, secure: Bool = false) -> FieldContext {
        FieldContext(
            axAvailability: .available, role: "AXTextField", subrole: secure ? "AXSecureTextField" : nil,
            identifier: nil, domClasses: [], editable: editable, secure: secure)
    }

    public static func focus(
        generation: UInt64 = 1, pid: Int32 = 100, bundle: BundleKey = editorBundle, mode: TypingMode = .vietnamese,
        decision: HostDecision = decision(), field: FieldContext = field(), appliedToggleSequence: UInt64 = 0,
        pause: PauseReason? = nil, changedAt: MonotonicInstant = .zero
    ) -> FocusSnapshot {
        FocusSnapshot(
            generation: FocusGeneration(rawValue: generation),
            app: FocusedApp(pid: pid, bundle: bundle, appVersion: nil, engine: .native), field: field,
            decision: decision, mode: mode, modeSource: .remembered, appliedToggleSequence: appliedToggleSequence,
            fieldHandle: FieldHandle(pid: pid, token: generation, element: nil), changedAt: changedAt, pause: pause)
    }

    public static func inputSource(
        generation: UInt64 = 1, kind: InputSourceKind = .asciiLayout, table: LayoutTable? = qwertyTable(),
        builtInVietnamese: Bool = false
    ) -> InputSourceSnapshot {
        let info = InputSourceInfo(
            id: layoutID, kind: kind, localizedName: "ABC", languages: ["en"], isBuiltInVietnamese: builtInVietnamese)
        return InputSourceSnapshot(generation: generation, source: info, table: table, boundMode: nil)
    }

    public static func lifecycle(
        generation: UInt64 = 1, phase: LifecycleSnapshot.Phase = .running, userDisabled: Bool = false,
        recorderActive: Bool = false
    ) -> LifecycleSnapshot {
        LifecycleSnapshot(
            generation: generation, phase: phase, userDisabled: userDisabled, recorderActive: recorderActive,
            globalMode: .vietnamese)
    }

    public static func keyEvent(
        _ kind: RawKeyEvent.Kind, _ keyCode: UInt16, flags: UInt64 = 0, autorepeat: Bool = false,
        unicode: InlineUTF16 = .empty, userData: Int64 = 0, at: MonotonicInstant = .zero
    ) -> RawKeyEvent {
        RawKeyEvent(
            kind: kind, keyCode: KeyCode(rawValue: keyCode), flags: flags, autorepeat: autorepeat,
            keyboardType: keyboardType, unicode: unicode, userData: userData, receivedAt: at)
    }
}
