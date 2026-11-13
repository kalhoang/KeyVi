// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The settings, rules and tap-log bridges of the host (PLT-R1008, PRD-R27, ENG-R1101, ENG-R1231, D10,
// PLT-R503, PLT-R540, PLT-R903, PLT-R1206, ENG-R861). Workstream W2-A.

import AppModel
import CompatRules
import Diagnostics
import Foundation
import RealtimeSupport
import SettingsStore
import Synchronization
import TestSupport
import Testing
import VietnameseEngine

@testable import InputHost

/// Counts loader calls (ENG-R1231: the bundled lists load once).
final class CountingLoader: Sendable {
    private let calls = Atomic<Int>(0)
    private let fails: Bool
    init(fails: Bool = false) { self.fails = fails }
    var count: Int { calls.load(ordering: .relaxed) }

    struct Failure: Error {}

    var loader: TapSettingsPublisher.BundledResourcesLoader {
        { [self] in
            calls.wrappingAdd(1, ordering: .relaxed)
            if fails { throw Failure() }
            return .empty
        }
    }
}

private func publisher(_ loader: CountingLoader, logger: RecordingLogger = RecordingLogger())
    -> (TapSettingsPublisher, SnapshotCell<TapSettingsSnapshot>)
{
    let cell = SnapshotCell(InputHostController.placeholderSettings, epoch: ReaderEpoch())
    return (TapSettingsPublisher(cell: cell, logger: logger, loadBundled: loader.loader), cell)
}

private func state(_ change: (inout UserSettings) -> Void = { _ in }, macros: [StoredMacro] = []) -> SettingsState {
    var user = UserSettings()
    change(&user)
    return SettingsState(user: user, macros: macros)
}

@Suite("Settings to tap snapshot (PLT-R1008, PRD-R27)")
struct TapSettingsPublisherTests {
    @Test func publishesEveryChangeButRebuildsEnginesOnlyForEngineInputs() {
        let loader = CountingLoader()
        let (publisher, cell) = publisher(loader)
        let first = publisher.publish(state())
        #expect(first.rebuiltEngines)
        #expect(cell.load().generation == first.snapshot.generation)
        let hotkey = publisher.publish(state { $0.toggleHotkey = .set(.modifierTap(.rightCommand)) })
        #expect(!hotkey.rebuiltEngines, "PRD-R27: a hotkey change keeps the word")
        #expect(hotkey.snapshot.generation > first.snapshot.generation)
        #expect(hotkey.snapshot.engines.revision == first.snapshot.engines.revision)
        #expect(hotkey.snapshot.toggleHotkey == .modifierTap(.rightCommand))
        let language = publisher.publish(state { $0.interfaceLanguage = .set(.english) })
        #expect(language.snapshot.engines.revision == first.snapshot.engines.revision)
        for change in Self.engineChanges {
            let before = cell.load().engines.revision
            let changed = publisher.publish(state(change))
            #expect(changed.rebuiltEngines)
            #expect(changed.snapshot.engines.revision != before)
            publisher.publish(state())  // back to defaults: another engine change
        }
        #expect(loader.count == 1, "ENG-R1231: bundled lists load once")
    }

    /// D1, D2, D4, D5, D6, D9 and the two user lists (the W1-F1 revision contract).
    static let engineChanges: [@Sendable (inout UserSettings) -> Void] = [
        { $0.typingMethod = .set(.vni) }, { $0.tonePlacement = .set(.modern) }, { $0.englishRestore = .set(false) },
        { $0.telexStandaloneW = .set(false) }, { $0.telexBracketKeys = .set(true) },
        { $0.macrosEnabled = .set(false) }, { $0.keepAsTyped = ["xyz"] }, { $0.keepVietnamese = ["ddi"] },
    ]

    @Test func macroChangesRebuildAndExpansionsAreComposed_ENG_R1101() {
        let (publisher, _) = publisher(CountingLoader())
        publisher.publish(state())
        let decomposed = "Vie\u{0302}\u{0323}t Nam"
        let macro = StoredMacro(trigger: "vn", expansion: decomposed)
        let result = publisher.publish(state(macros: [macro]))
        #expect(result.rebuiltEngines)
        #expect(result.macroIssues.isEmpty)
        let normalized = MacroNormalization.normalized([macro])
        #expect(normalized[0].expansion.unicodeScalars.count == "Việt Nam".unicodeScalars.count)
        #expect(normalized[0].expansion.unicodeScalars.elementsEqual("Việt Nam".unicodeScalars))
    }

    @Test func rejectedMacrosAreReportedByIDAndLogged() {
        let logger = RecordingLogger()
        let (publisher, _) = publisher(CountingLoader(), logger: logger)
        let bad = StoredMacro(trigger: "", expansion: "x")
        let result = publisher.publish(state(macros: [bad, StoredMacro(trigger: "ok", expansion: "fine")]))
        #expect(result.macroIssues.count == 1)
        #expect(logger.entries.count == 1)
    }

    @Test func failingBundledListsFallBackToEmptyOnceAndLog() {
        let loader = CountingLoader(fails: true)
        let logger = RecordingLogger()
        let (publisher, _) = publisher(loader, logger: logger)
        publisher.preloadResources()
        publisher.preloadResources()
        publisher.publish(state())
        #expect(loader.count == 1)
        #expect(logger.entries.count == 1)
    }

    @Test func englishModeMacrosStayOffUntilTheEngineHasALiteralMode_D10() {
        let (publisher, _) = publisher(CountingLoader())
        let result = publisher.publish(state { $0.macrosInEnglishMode = .set(true) })
        #expect(!result.snapshot.macrosInEnglishMode, "ADR 0306: hidden and off")
        #expect(!EnglishModeMacros.isSettingVisible)
        #expect(EnglishModeMacros.engineSupportsLiteralMode == false)
    }

    @Test func rememberPerAppAndRestoreHotkeyFollowSettings() {
        let (publisher, _) = publisher(CountingLoader())
        let result = publisher.publish(
            state {
                $0.rememberPerApp = .set(false)
                $0.restoreHotkey = .set(.key(KeyCode(rawValue: 0x35)))
            })
        #expect(!result.snapshot.rememberPerApp)
        #expect(result.snapshot.restoreHotkey == .key(KeyCode(rawValue: 0x35)))
    }
}

@Suite("Rule set assembly (PLT-R503, PLT-R540)")
struct RuleSetAssemblyTests {
    @Test func shippedRulesWithAValidOverrideCompile() throws {
        let rules = HostRig.shippedRules
        #expect(!rules.usedEmbeddedDefaults, "compat/rules.json is valid")
        let override = StoredRuleOverride(
            createdAt: Date(timeIntervalSince1970: 0), rule: Self.override(id: "user.editor"))
        let settings = SettingsState(ruleOverrides: [override])
        let assembly = RuleSetAssembly.build(rules: rules, inputs: RuleSetInputs(settings: settings))
        #expect(assembly.rejectedOverrides.isEmpty)
        #expect(assembly.error == nil)
        #expect(!assembly.needsHealthEvent)
        let context = MatchContext(
            bundle: BundleKey(rawValue: "com.example.editor"), appVersion: nil, macOS: LooseVersion("15.0")!,
            engine: .native)
        #expect(assembly.ruleSet.resolve(context).source == .user, "PLT-R522: the override wins")
    }

    @Test func invalidOverridesAreRejectedOneByOne() {
        let settings = SettingsState(ruleOverrides: [
            StoredRuleOverride(createdAt: Date(timeIntervalSince1970: 0), rule: .object(["id": .string("bad")])),
            StoredRuleOverride(createdAt: Date(timeIntervalSince1970: 0), rule: Self.override(id: "user.editor")),
        ])
        let assembly = RuleSetAssembly.build(rules: HostRig.shippedRules, inputs: RuleSetInputs(settings: settings))
        #expect(assembly.rejectedOverrides.count == 1)
        #expect(assembly.needsHealthEvent)
    }

    @Test func aMissingShippedFileUsesTheEmbeddedRules() {
        let rules = RulesLoader.load(contentsOf: URL(fileURLWithPath: "/nonexistent/compat-rules.json"))
        let assembly = RuleSetAssembly.build(rules: rules, inputs: RuleSetInputs(settings: SettingsState()))
        #expect(rules.usedEmbeddedDefaults)
        #expect(assembly.needsHealthEvent)
    }

    /// A `rule-overrides.json` entry as the Apps pane writes it (encoded from the schema types).
    static func override(id: String) -> JSONValue {
        let rule = Rule(
            id: RuleID(rawValue: id)!, summary: "Set by the user",
            match: RuleMatch(bundleIds: [BundleKey(rawValue: "com.example.editor")!]),
            action: RuleAction(strategy: .selectReplace),
            provenance: .userSuggestion(UserProvenance(source: "user-suggestion", date: "2026-11-13")))
        return try! JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(rule))
    }
}

@Suite("Tap log drain (PLT-R903, PLT-R1206)")
struct TapLogDrainerTests {
    @Test func recordsBecomeHealthEventsDatedByTheirAge() throws {
        let ring = TapLogRing(capacity: 8)
        let clock = ManualClock(start: MonotonicInstant(nanoseconds: 10_000_000_000))
        let wall = FixedWallClock(Date(timeIntervalSince1970: 1_000))
        let health = HealthEventLog()
        let logger = RecordingLogger()
        let drainer = TapLogDrainer(ring: ring, health: health, logger: logger, clock: clock, wallClock: wall)
        ring.push(TapLogRecord(code: .echoMissing, at: MonotonicInstant(nanoseconds: 8_000_000_000), a: 2))
        ring.push(TapLogRecord(code: .flushRequested, at: MonotonicInstant(nanoseconds: 9_500_000_000)))
        ring.push(TapLogRecord(code: .jobQueueFull, at: MonotonicInstant(nanoseconds: 9_000_000_000)))
        ring.push(TapLogRecord(code: .tapDisabledByTimeout, at: MonotonicInstant(nanoseconds: 9_000_000_000)))
        let result = drainer.drain()
        #expect(result.records == 4)
        #expect(result.healthEvents == 2)
        let events = health.recent(limit: 10)
        let echo = try #require(events.first)
        #expect(echo.kind == .echoLoss)
        #expect(echo.at == Date(timeIntervalSince1970: 998), "2 s before the drain")
        #expect(echo.detail == .count(2))
        #expect(events.last?.kind == .flush)
        #expect(logger.entries.count == 2, "queue full and tap disabled are log lines, not health events")
    }

    @Test func droppedRecordsAreReportedOncePerDrain() {
        let ring = TapLogRing(capacity: 1)
        let logger = RecordingLogger()
        let drainer = TapLogDrainer(
            ring: ring, health: HealthEventLog(), logger: logger, clock: ManualClock(), wallClock: FixedWallClock())
        for _ in 0..<3 { ring.push(TapLogRecord(code: .layoutMismatch, at: .zero)) }
        #expect(drainer.drain().newlyDropped == 2)
        #expect(drainer.drain().newlyDropped == 0)
    }

    @Test(arguments: TapLogCode.allKnown)
    func everyCodeIsEitherAHealthEventOrALogLine(code: TapLogCode) {
        let anchor = MonotonicToWallClock(monotonicNow: .zero, wallNow: Date(timeIntervalSince1970: 0))
        let health = TapLogDrainer.healthEvent(for: TapLogRecord(code: code, at: .zero), anchor: anchor)
        #expect((health != nil) != (TapLogDrainer.logLine(for: code) != nil))
    }

    @Test func aRecordFromTheFutureIsDatedNow() {
        let anchor = MonotonicToWallClock(monotonicNow: .zero, wallNow: Date(timeIntervalSince1970: 50))
        #expect(anchor.date(of: MonotonicInstant(nanoseconds: 5)) == Date(timeIntervalSince1970: 50))
    }
}

extension TapLogCode {
    static let allKnown: [TapLogCode] = [
        .tapDisabledByTimeout, .tapDisabledByUserInput, .tapReenabled, .jobQueueFull, .flushRequested, .echoMissing,
        .secureInputResumedByKey, .layoutMismatch, .unknownEventType, .callbackOverBudget,
    ]
}

@Suite("Learning from restore toggles (ENG-R861, open decision 8)")
struct LearningTrackerTests {
    @Test func theSecondIdenticalSignalProposesAndTheCountStartsOver() {
        var tracker = LearningTracker()
        #expect(tracker.note(.preferredRaw(raw: "tar")) == nil)
        #expect(tracker.note(.preferredVietnamese(raw: "tar")) == nil, "a different list is a different signal")
        #expect(tracker.note(.preferredRaw(raw: "tar")) == LearningProposal(list: .keepAsTyped, rawKeys: "tar"))
        #expect(tracker.note(.preferredRaw(raw: "tar")) == nil)
        #expect(tracker.note(.preferredRaw(raw: "")) == nil)
    }

    @Test func pendingSignalsAreBounded() {
        var tracker = LearningTracker()
        for index in 0...LearningTracker.capacity { _ = tracker.note(.preferredRaw(raw: "w\(index)")) }
        #expect(tracker.note(.preferredRaw(raw: "w0")) == nil, "the oldest pending signal was forgotten")
        #expect(tracker.note(.preferredRaw(raw: "w\(LearningTracker.capacity)")) != nil)
    }

    @Test func applyingMovesTheWordBetweenLists() {
        var settings = UserSettings()
        settings.keepVietnamese = ["tar"]
        LearningProposal(list: .keepAsTyped, rawKeys: "tar").apply(to: &settings)
        #expect(settings.keepAsTyped == ["tar"])
        #expect(settings.keepVietnamese.isEmpty)
        LearningProposal(list: .keepVietnamese, rawKeys: "tar").apply(to: &settings)
        #expect(settings.keepVietnamese == ["tar"])
        #expect(settings.keepAsTyped.isEmpty)
    }
}
