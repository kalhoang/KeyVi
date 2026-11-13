// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R310 step 7 (KeyClassifier) and step 6 (HostStateResolver, 02-platform.md 2.1).

import AppModel
import CoreGraphics
import RealtimeSupport
import TestSupport
import Testing

@testable import InputHost

@Suite struct KeyClassifierTests {
    private let table = PipelineFixtures.qwertyTable()

    private func classify(_ code: UInt16, flags: UInt64 = 0, kind: RawKeyEvent.Kind = .keyDown) -> KeyClass {
        KeyClassifier.classify(PipelineFixtures.keyEvent(kind, code, flags: flags), table: table)
    }

    @Test func characterKeysUseTheTable() {
        #expect(classify(Key.a) == .character("a", fromKeypad: false))
        #expect(classify(Key.a, flags: Flag.shift) == .character("A", fromKeypad: false))
        #expect(classify(Key.a, flags: Flag.capsLock) == .character("A", fromKeypad: false))
        #expect(classify(Key.a, flags: Flag.capsLock | Flag.shift) == .character("a", fromKeypad: false))
        #expect(classify(0x12, flags: Flag.capsLock) == .character("1", fromKeypad: false))
        #expect(classify(Key.a, kind: .keyUp) == .character("a", fromKeypad: false))
    }

    /// PLT-R355.
    @Test func keypadCharactersAreFlagged() {
        for code: UInt16 in [0x52, 0x53, 0x5B, 0x5C, 0x41] {
            guard case .character(_, let fromKeypad) = classify(code) else {
                Issue.record("keypad key \(code) not a character")
                continue
            }
            #expect(fromKeypad)
        }
        #expect(classify(Key.keypadEnter) == .returnKey)
    }

    @Test func editingAndNavigationKeys() {
        #expect(classify(Key.backspace) == .backspace)
        #expect(classify(Key.backspace, flags: Flag.option) == .navigation)
        #expect(classify(Key.forwardDelete) == .forwardDelete)
        #expect(classify(Key.escape) == .escape)
        #expect(classify(Key.returnKey) == .returnKey)
        #expect(classify(Key.tab) == .tab)
        #expect(classify(Key.tab, flags: Flag.shift) == .tab)
        for code: UInt16 in [0x7B, 0x7C, 0x7D, 0x7E, 0x73, 0x77, 0x74, 0x79] { #expect(classify(code) == .navigation) }
        #expect(classify(Key.left, flags: Flag.option) == .navigation)
    }

    @Test func functionKeys() {
        for code: UInt16 in [0x7A, 0x78, 0x63, 0x76, 0x60, 0x6F, 0x5A, 0x72, 0x48, 0x4A] {
            #expect(classify(code) == .functionKey)
        }
    }

    /// PLT-R350.
    @Test func chordsAreClassifiedNotTranslated() {
        #expect(classify(Key.a, flags: Flag.command) == .commandOrControlChord)
        #expect(classify(Key.backspace, flags: Flag.control) == .commandOrControlChord)
        #expect(classify(Key.left, flags: Flag.command) == .commandOrControlChord)
        #expect(classify(Key.a, flags: Flag.option) == .optionChord)
    }

    /// PLT-R354.
    @Test func deadKeysAndUnmappedKeys() {
        let azerty = PipelineFixtures.azertyTable()
        let event = PipelineFixtures.keyEvent(.keyDown, Key.azertyDeadKey)
        #expect(KeyClassifier.classify(event, table: azerty) == .deadKey)
        #expect(KeyClassifier.classify(PipelineFixtures.keyEvent(.keyDown, 0x03), table: azerty) == .unmapped)
        #expect(KeyClassifier.classify(PipelineFixtures.keyEvent(.keyDown, Key.a), table: nil) == .unmapped)
        #expect(KeyClassifier.classify(PipelineFixtures.keyEvent(.keyDown, 200), table: azerty) == .unmapped)
    }

    @Test func nonKeyEvents() {
        #expect(classify(Key.shift, kind: .flagsChanged) == .modifierOnly)
        #expect(classify(0, kind: .leftMouseDown) == .unmapped)
        #expect(classify(0, kind: .scrollWheel) == .unmapped)
    }

    /// PLT-R363: an empty Unicode string is not a mismatch; a different one is.
    @Test func layoutCrossCheck() throws {
        let b = try #require(InlineUTF16("b"))
        let a = try #require(InlineUTF16("a"))
        #expect(KeyClassification.layoutAgrees(with: PipelineFixtures.keyEvent(.keyDown, Key.a), character: "a"))
        #expect(
            KeyClassification.layoutAgrees(with: PipelineFixtures.keyEvent(.keyDown, Key.a, unicode: a), character: "a")
        )
        #expect(
            !KeyClassification.layoutAgrees(
                with: PipelineFixtures.keyEvent(.keyDown, Key.a, unicode: b), character: "a"))
    }

    @Test func flagConstantsMatchCoreGraphics() {
        #expect(EventFlags.capsLock == CGEventFlags.maskAlphaShift.rawValue)
        #expect(EventFlags.shift == CGEventFlags.maskShift.rawValue)
        #expect(EventFlags.control == CGEventFlags.maskControl.rawValue)
        #expect(EventFlags.option == CGEventFlags.maskAlternate.rawValue)
        #expect(EventFlags.command == CGEventFlags.maskCommand.rawValue)
        #expect(EventFlags.numericPad == CGEventFlags.maskNumericPad.rawValue)
    }

    @Test func sideSpecificModifiers() {
        #expect(EventFlags.modifierKeys(Flag.command | 0x10) == [.command, .rightCommand])
        #expect(EventFlags.modifierKeys(Flag.command | 0x18) == [.command])
        #expect(EventFlags.modifierKeys(Flag.option | 0x40) == [.option, .rightOption])
        #expect(EventFlags.modifierKeys(Flag.option | 0x20) == [.option])
        #expect(EventFlags.modifierKeys(Flag.control | Flag.shift) == [.control, .shift])
        #expect(EventFlags.modifierKeys(Flag.capsLock).isEmpty)
    }
}

@Suite struct HostStateResolverTests {
    private func resolve(
        lifecycle: LifecycleSnapshot = PipelineFixtures.lifecycle(), secure: SecureInputSnapshot = .initial,
        resumed: UInt64? = nil, source: InputSourceSnapshot = PipelineFixtures.inputSource(),
        focus: FocusSnapshot = PipelineFixtures.focus(), mode: TypingMode = .vietnamese
    ) -> HostState {
        HostStateResolver.resolve(
            lifecycle: lifecycle, secureInput: secure, secureResumedGeneration: resumed, inputSource: source,
            focus: focus, effectiveMode: mode)
    }

    @Test func readyInTheEffectiveMode() {
        #expect(resolve() == .ready(.vietnamese))
        #expect(resolve(mode: .english) == .ready(.english))
    }

    @Test func lifecyclePhasesComeFirst() {
        let secure = SecureInputSnapshot(generation: 1, enabled: true, holder: nil)
        #expect(resolve(lifecycle: PipelineFixtures.lifecycle(phase: .noPermission), secure: secure) == .noPermission)
        #expect(resolve(lifecycle: PipelineFixtures.lifecycle(phase: .starting), secure: secure) == .starting)
        #expect(
            resolve(lifecycle: PipelineFixtures.lifecycle(phase: .failOpen(.watchdog)), secure: secure)
                == .failOpen(.watchdog))
        #expect(
            resolve(lifecycle: PipelineFixtures.lifecycle(phase: .sessionInactive, userDisabled: true))
                == .paused(.sessionInactive))
        #expect(
            resolve(lifecycle: PipelineFixtures.lifecycle(userDisabled: true), secure: secure) == .paused(.userDisabled)
        )
    }

    /// PLT-R398A, PLT-R398B.
    @Test func secureInputPausesUnlessResumedForThisGeneration() {
        let secure = SecureInputSnapshot(generation: 4, enabled: true, holder: nil)
        #expect(resolve(secure: secure) == .paused(.secureInput(nil)))
        #expect(resolve(secure: secure, resumed: 4) == .ready(.vietnamese))
        #expect(resolve(secure: secure, resumed: 3) == .paused(.secureInput(nil)))
    }

    /// PLT-R398A: nothing but the OS flag and a secure field pauses for security; no heuristics.
    @Test func onlyTheOSStateAndASecureFieldPauseForSecurity() {
        let passwordLooking = FieldContext(
            axAvailability: .available, role: "AXTextField", subrole: nil, identifier: "password",
            domClasses: ["password", "login"], editable: true, secure: false)
        #expect(resolve(focus: PipelineFixtures.focus(field: passwordLooking)) == .ready(.vietnamese))
        #expect(
            resolve(focus: PipelineFixtures.focus(field: PipelineFixtures.field(secure: true))) == .paused(.secureField)
        )
        #expect(resolve(focus: PipelineFixtures.focus(pause: .secureField)) == .paused(.secureField))
    }

    /// PLT-R371, PLT-R372.
    @Test func inputSources() {
        #expect(
            resolve(source: PipelineFixtures.inputSource(kind: .inputMethod))
                == .paused(.nonLatinInputSource(name: "ABC")))
        #expect(
            resolve(source: PipelineFixtures.inputSource(kind: .nonASCIILayout)).code == .paused(.nonLatinInputSource))
        #expect(
            resolve(source: PipelineFixtures.inputSource(kind: .inputMode, builtInVietnamese: true))
                == .paused(.builtInVietnameseSource))
    }

    @Test func focusPausesAndTextGating() throws {
        let rule = try #require(RuleID(rawValue: "games.default"))
        #expect(
            resolve(focus: PipelineFixtures.focus(pause: .passThroughRule(rule))) == .paused(.passThroughRule(rule)))
        #expect(resolve(focus: PipelineFixtures.focus(pause: .noTextFocus)) == .paused(.noTextFocus))
        // PLT-R386 gating from the field context.
        let notEditable = PipelineFixtures.field(editable: false)
        let unknown = FieldContext.unknown
        func gated(_ require: RequireTextFocus, _ field: FieldContext) -> HostState {
            resolve(
                focus: PipelineFixtures.focus(
                    decision: PipelineFixtures.decision(requireTextFocus: require), field: field))
        }
        #expect(gated(.whenKnown, notEditable) == .paused(.noTextFocus))
        #expect(gated(.whenKnown, unknown) == .ready(.vietnamese))
        #expect(gated(.always, unknown) == .paused(.noTextFocus))
        #expect(gated(.always, PipelineFixtures.field()) == .ready(.vietnamese))
        #expect(gated(.never, notEditable) == .ready(.vietnamese))
        #expect(gated(.byEngine, notEditable) == .ready(.vietnamese))
    }

    @Test func pauseReasonsKeepTheirPrecedence() {
        let secureOn = SecureInputSnapshot(generation: 1, enabled: true, holder: nil)
        let secureField = PipelineFixtures.focus(field: PipelineFixtures.field(secure: true), pause: .noTextFocus)
        let japanese = PipelineFixtures.inputSource(kind: .inputMethod)
        #expect(resolve(secure: secureOn, source: japanese, focus: secureField) == .paused(.secureInput(nil)))
        #expect(resolve(source: japanese, focus: secureField) == .paused(.secureField))
        #expect(
            resolve(source: japanese, focus: PipelineFixtures.focus(pause: .noTextFocus)).code
                == .paused(.nonLatinInputSource))
    }

    @Test func swallowingIsAllowedOnlyWhileRunning() {
        #expect(HostState.ready(.vietnamese).allowsSwallowing)
        #expect(HostState.paused(.noTextFocus).allowsSwallowing)
        #expect(!HostState.failOpen(.postingBroken).allowsSwallowing)
        #expect(!HostState.noPermission.allowsSwallowing)
        #expect(!HostState.starting.allowsSwallowing)
    }

    @Test func boundaryReasonsForTransitions() {
        #expect(
            BoundaryReasons.transition(from: .readyVietnamese, to: .paused(.secureInput)) == (
                .secureInputChanged, .secureInputChanged
            ))
        #expect(
            BoundaryReasons.transition(from: .paused(.secureField), to: .readyEnglish) == (
                .secureInputChanged, .secureInputChanged
            ))
        #expect(
            BoundaryReasons.transition(from: .readyVietnamese, to: .paused(.builtInVietnameseSource)) == (
                .inputSourceChanged, .inputSourceChanged
            ))
        #expect(
            BoundaryReasons.transition(from: .paused(.noTextFocus), to: .readyVietnamese) == (
                .configurationChanged, .ruleChanged
            ))
        #expect(
            BoundaryReasons.transition(from: .paused(.userDisabled), to: .readyVietnamese) == (
                .configurationChanged, .settingsChanged
            ))
        #expect(BoundaryReasons.transition(from: .readyVietnamese, to: .readyEnglish) == (.modeToggled, .modeToggled))
        #expect(
            BoundaryReasons.transition(from: .readyVietnamese, to: .failOpen(.postingBroken)) == (
                .unknown, .sessionChanged
            ))
    }
}

@Suite struct TapSnapshotsTests {
    /// ADR 0303: the watchdog's 5 s reclamation frees retired boxes of every cell; readers keep seeing the
    /// latest value and the tap's borrowed read sees all five cells.
    @Test func reclaimAllKeepsTheLatestValues() {
        let fixture = PipelineFixture()
        fixture.publish(settings: PipelineFixtures.settings(generation: 2))
        fixture.publish(focus: PipelineFixtures.focus(generation: 3))
        fixture.publish(inputSource: PipelineFixtures.inputSource(generation: 4))
        fixture.publish(secureInput: SecureInputSnapshot(generation: 5, enabled: false, holder: nil))
        fixture.publish(lifecycle: PipelineFixtures.lifecycle(generation: 6))
        fixture.snapshots.reclaimAll()
        fixture.snapshots.epoch.enter()
        let generations = fixture.snapshots.readAll { settings, focus, inputSource, secureInput, lifecycle in
            [
                settings.generation, focus.generation.rawValue, inputSource.generation, secureInput.generation,
                lifecycle.generation,
            ]
        }
        fixture.snapshots.epoch.exit()
        #expect(generations == [2, 3, 4, 5, 6])
    }
}
