// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R390-R393, PRD-R19-R23: precedence, LRU, toggles, document round-trip and merging published documents.

import AppModel
import SettingsStore
import Testing

@testable import InputHost

private let terminal = bundle("com.apple.Terminal")
private let zalo = bundle("com.example.zalo")
private let code = bundle("com.example.code")

private func memory(
    _ apps: [AppModeEntry], global: TypingMode = .vietnamese, remember: Bool = true, firstSeen: FirstSeenMode = .inherit
) -> AppModeMemory {
    AppModeMemory(
        document: AppModesDocument(globalMode: global, apps: apps), rememberPerApp: remember, firstSeen: firstSeen)
}

private struct PrecedenceCase: Sendable, CustomStringConvertible {
    var rule: PerAppRule?
    var remembered: TypingMode?
    var ruleDefault: FirstSeenMode
    var firstSeen: FirstSeenMode
    var expected: ModeResolution
    var description: String { "\(String(describing: rule)) \(String(describing: remembered)) \(ruleDefault)" }
}

/// PRD-R21: ignore > always English > always Vietnamese > remembered > rule defaultMode / D13 > global (VI).
private let precedence: [PrecedenceCase] = [
    .init(
        rule: .ignore, remembered: .vietnamese, ruleDefault: .vi, firstSeen: .vi,
        expected: .init(mode: .vietnamese, source: .ignoreRule, ignored: true)),
    .init(
        rule: .alwaysEnglish, remembered: .vietnamese, ruleDefault: .vi, firstSeen: .vi,
        expected: .init(mode: .english, source: .alwaysEnglish, ignored: false)),
    .init(
        rule: .alwaysVietnamese, remembered: .english, ruleDefault: .en, firstSeen: .en,
        expected: .init(mode: .vietnamese, source: .alwaysVietnamese, ignored: false)),
    .init(
        rule: .remember, remembered: .english, ruleDefault: .vi, firstSeen: .vi,
        expected: .init(mode: .english, source: .remembered, ignored: false)),
    .init(
        rule: nil, remembered: .english, ruleDefault: .vi, firstSeen: .vi,
        expected: .init(mode: .english, source: .remembered, ignored: false)),
    .init(
        rule: nil, remembered: nil, ruleDefault: .en, firstSeen: .vi,
        expected: .init(mode: .english, source: .ruleDefault, ignored: false)),
    .init(
        rule: nil, remembered: nil, ruleDefault: .inherit, firstSeen: .en,
        expected: .init(mode: .english, source: .ruleDefault, ignored: false)),
    .init(
        rule: nil, remembered: nil, ruleDefault: .inherit, firstSeen: .inherit,
        expected: .init(mode: .vietnamese, source: .globalMode, ignored: false)),
]

@Suite("AppModeMemory (PRD-R19-R23, PLT-R390-R392)")
struct AppModeMemoryTests {
    @Test(arguments: precedence)
    fileprivate func precedenceTable(_ testCase: PrecedenceCase) {
        let entries =
            testCase.rule == nil && testCase.remembered == nil
            ? [] : [AppModeEntry(bundle: terminal, rule: testCase.rule, mode: testCase.remembered)]
        let resolved = memory(entries, firstSeen: testCase.firstSeen)
            .resolve(bundle: terminal, ruleDefault: testCase.ruleDefault)
        #expect(resolved == testCase.expected)
    }

    @Test func withoutPerAppMemoryOnlyExplicitRulesApply() {
        let state = memory(
            [AppModeEntry(bundle: terminal, mode: .english), AppModeEntry(bundle: code, rule: .alwaysEnglish)],
            remember: false)
        #expect(
            state.resolve(bundle: terminal, ruleDefault: .en)
                == .init(mode: .vietnamese, source: .globalMode, ignored: false))
        #expect(state.resolve(bundle: code, ruleDefault: .inherit).mode == .english)
        #expect(state.resolve(bundle: nil, ruleDefault: .en).source == .globalMode)
    }

    @Test func toggleUpdatesMemoryAndTheGlobalMode() {
        var state = memory([])
        state.recordToggle(bundle: terminal, mode: .english)
        #expect(state.globalMode == .english)
        #expect(
            state.resolve(bundle: terminal, ruleDefault: .inherit)
                == .init(mode: .english, source: .remembered, ignored: false))
        state.recordToggle(bundle: zalo, mode: .vietnamese)
        #expect(state.document().apps.map(\.bundle) == [zalo, terminal])
        // PRD-R19 acceptance: Terminal stays English after Zalo.
        #expect(state.resolve(bundle: terminal, ruleDefault: .inherit).mode == .english)
        state.recordToggle(bundle: nil, mode: .english)
        #expect(state.globalMode == .english)
    }

    @Test func ignoredAppToggleDoesNothing() {
        var state = memory([AppModeEntry(bundle: code, rule: .ignore)])
        state.recordToggle(bundle: code, mode: .english)
        #expect(state.globalMode == .vietnamese)
        #expect(state.document().apps == [AppModeEntry(bundle: code, rule: .ignore)])
    }

    @Test func toggleUnderAnAlwaysRuleIsTemporary() {
        var state = memory([AppModeEntry(bundle: terminal, rule: .alwaysEnglish)])
        state.recordToggle(bundle: terminal, mode: .vietnamese)
        #expect(state.globalMode == .vietnamese)
        #expect(state.document().apps == [AppModeEntry(bundle: terminal, rule: .alwaysEnglish)])
    }

    @Test func toggleWithMemoryOffChangesOnlyTheGlobalMode() {
        var state = memory([], remember: false)
        state.recordToggle(bundle: terminal, mode: .english)
        #expect(state.globalMode == .english)
        #expect(state.document().apps.isEmpty)
    }

    @Test func lruEvictsRememberedEntriesAtOneThousandButNeverExplicitRules() {
        let rules = (0..<5).map { AppModeEntry(bundle: bundle("test.rule.\($0)"), rule: .alwaysEnglish) }
        let remembered = (0..<1_000).map { AppModeEntry(bundle: bundle("test.app.\($0)"), mode: .english) }
        var state = memory(rules + remembered)
        #expect(state.document().apps.count == 1_005)
        state.recordToggle(bundle: bundle("test.app.new"), mode: .vietnamese)
        let apps = state.document().apps
        #expect(apps.count == 1_005)
        #expect(apps.first?.bundle == bundle("test.app.new"))
        #expect(!apps.contains { $0.bundle == bundle("test.app.999") })  // least recently used
        #expect(apps.filter { $0.rule == .alwaysEnglish }.count == 5)
        state.touch(bundle("test.app.0"))
        state.recordToggle(bundle: bundle("test.app.newer"), mode: .english)
        #expect(state.document().apps.contains { $0.bundle == bundle("test.app.0") })
        #expect(!state.document().apps.contains { $0.bundle == bundle("test.app.998") })
    }

    @Test func documentRoundTripsAndDropsDuplicates() {
        let document = AppModesDocument(
            globalMode: .english,
            apps: [
                AppModeEntry(bundle: terminal, mode: .english), AppModeEntry(bundle: code, rule: .ignore),
                AppModeEntry(bundle: zalo, rule: .remember, mode: nil),
            ])
        #expect(AppModeMemory(document: document, rememberPerApp: true, firstSeen: .inherit).document() == document)
        let duplicated = AppModesDocument(
            globalMode: .english,
            apps: [AppModeEntry(bundle: terminal, mode: .english), AppModeEntry(bundle: terminal, mode: .vietnamese)])
        #expect(memory(duplicated.apps).document().apps == [AppModeEntry(bundle: terminal, mode: .english)])
    }

    @Test func setRuleAddsClearsAndKeepsRememberedModes() {
        var state = memory([AppModeEntry(bundle: terminal, mode: .english)])
        state.setRule(.ignore, for: code)
        #expect(state.document().apps.first == AppModeEntry(bundle: code, rule: .ignore))
        state.setRule(nil, for: code)
        #expect(!state.document().apps.contains { $0.bundle == code })
        state.setRule(.alwaysVietnamese, for: terminal)
        #expect(state.resolve(bundle: terminal, ruleDefault: .inherit).mode == .vietnamese)
        state.setRule(.remember, for: terminal)
        #expect(state.document().apps == [AppModeEntry(bundle: terminal, rule: nil, mode: .english)])
        state.setRule(nil, for: zalo)
        #expect(state.document().apps.count == 1)
    }

    @Test func touchMovesAnEntryToTheFront() {
        var state = memory([
            AppModeEntry(bundle: terminal, mode: .english), AppModeEntry(bundle: zalo, mode: .vietnamese),
        ])
        state.touch(zalo)
        state.touch(code)  // unknown: no entry is created
        #expect(state.document().apps.map(\.bundle) == [zalo, terminal])
    }

    @Test func activationRecordsTheFirstSeenMode() {
        var state = memory([], global: .english)
        #expect(state.activate(bundle: zalo, ruleDefault: .vi).source == .ruleDefault)
        #expect(state.activate(bundle: terminal, ruleDefault: .inherit).mode == .english)
        state.recordToggle(bundle: code, mode: .vietnamese)  // global is now VI
        // Terminal keeps the mode it had when first seen (D13).
        #expect(
            state.activate(bundle: terminal, ruleDefault: .inherit)
                == .init(mode: .english, source: .remembered, ignored: false))
        #expect(state.document().apps.first?.bundle == terminal)
        var off = memory([], remember: false)
        _ = off.activate(bundle: terminal, ruleDefault: .inherit)
        #expect(off.document().apps.isEmpty)
        _ = off.activate(bundle: nil, ruleDefault: .inherit)
    }

    @Test func mergeKeepsNewerTogglesWhenTheStoreEchoesAnOlderDocument() {
        var live = memory([AppModeEntry(bundle: terminal, mode: .vietnamese)])
        let emitted = live.document()
        live.recordToggle(bundle: terminal, mode: .english)  // newer than what the store has
        // FocusCore records the post-toggle document too, as it emits it before the store echoes the old one.
        let merged = AppModeMemory.merged(
            current: live, incoming: emitted, recentlyEmitted: history(emitted, live.document()),
            rememberPerApp: true, firstSeen: .inherit)
        #expect(merged.resolve(bundle: terminal, ruleDefault: .inherit).mode == .english)
    }

    @Test func mergeAppliesRuleChangesFromTheStore() {
        let live = memory([AppModeEntry(bundle: terminal, mode: .english), AppModeEntry(bundle: code, rule: .ignore)])
        let emitted = live.document()
        var incoming = emitted
        incoming.apps = [
            AppModeEntry(bundle: terminal, rule: .alwaysVietnamese, mode: .english),
            AppModeEntry(bundle: zalo, rule: .ignore),
        ]
        let merged = AppModeMemory.merged(
            current: live, incoming: incoming, recentlyEmitted: history(emitted), rememberPerApp: true,
            firstSeen: .inherit)
        #expect(merged.resolve(bundle: terminal, ruleDefault: .inherit).source == .alwaysVietnamese)
        #expect(merged.resolve(bundle: zalo, ruleDefault: .inherit).ignored)
        #expect(!merged.resolve(bundle: code, ruleDefault: .inherit).ignored)  // rule removed in the Apps pane
        #expect(!merged.document().apps.contains { $0.bundle == code })
    }

    @Test func mergeReplacesModesChangedOutsideImportOrReset() {
        let live = memory([AppModeEntry(bundle: terminal, mode: .english)])
        let imported = AppModesDocument(globalMode: .english, apps: [AppModeEntry(bundle: zalo, mode: .english)])
        let merged = AppModeMemory.merged(
            current: live, incoming: imported, recentlyEmitted: history(live.document()), rememberPerApp: false,
            firstSeen: .vi)
        #expect(merged.document() == imported)
        #expect(merged.rememberPerApp == false)
        let first = AppModeMemory.merged(
            current: live, incoming: imported, recentlyEmitted: EmittedModeHistory(), rememberPerApp: true,
            firstSeen: .inherit)
        #expect(first.document() == imported)
    }

    @Test func historyKeepsTheLastSixteenDistinctModeStates() {
        var history = EmittedModeHistory()
        let documents = (0..<20).map { index in
            AppModesDocument(
                globalMode: index.isMultiple(of: 2) ? .english : .vietnamese,
                apps: [AppModeEntry(bundle: bundle("com.example.app\(index)"), mode: .english)])
        }
        for document in documents {
            history.record(document)
            history.record(document)  // consecutive duplicates are stored once
        }
        #expect(history.states.count == EmittedModeHistory.capacity)
        #expect(!history.contains(documents[3]))
        #expect(history.contains(documents[4]))
        #expect(history.contains(documents[19]))
        // Rules and order are not part of the mode state.
        var reordered = documents[19]
        reordered.apps.append(AppModeEntry(bundle: zalo, rule: .ignore))
        #expect(history.contains(reordered))
    }
}

private func history(_ documents: AppModesDocument...) -> EmittedModeHistory {
    var history = EmittedModeHistory()
    for document in documents { history.record(document) }
    return history
}
