// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R380-R393, PLT-R523, PRD-R19-R22: focus tracking on a real ax RunLoopThread with fake AX, processes and
// rules (`FocusTrackerHarness.swift`). Every test waits for the ax thread with `waitUntilIdle()`; time comes from
// a ManualClock.

import AppModel
import CompatRules
import Diagnostics
import Foundation
import Injection
import RealtimeSupport
import SettingsStore
import Synchronization
import Testing

@testable import InputHost
@testable import TestSupport

private let terminalPID = FocusFixtures.terminalPID
private let spotlightPID = FocusFixtures.spotlightPID
private let zaloPID = FocusFixtures.zaloPID
private let codePID = FocusFixtures.codePID
private let browserPID = FocusFixtures.browserPID
private let terminal = FocusFixtures.terminal
private let spotlight = FocusFixtures.spotlight
private let zalo = FocusFixtures.zalo
private let code = FocusFixtures.code
private let browser = FocusFixtures.browser
private typealias Harness = FocusHarness
private typealias CountingResolver = CountingFocusResolver

private func attributes(
    role: String? = "AXTextArea", subrole: String? = nil, identifier: String? = nil, title: String? = nil,
    url: String? = nil
) -> FocusAttributes {
    // A URL only exists inside a web area (02-platform.md 5.5), so URL fixtures carry an `AXWebArea` ancestor.
    let ancestors = url == nil ? FocusFixtures.nativeAncestors : ["AXGroup", "AXWebArea", "AXScrollArea", "AXWindow"]
    return FocusFixtures.attributes(
        role: role, subrole: subrole, identifier: identifier, title: title, url: url, ancestors: ancestors)
}

private func decision(
    _ rule: String?, strategy: InjectionStrategy = .backspaceReplace, axEnable: AXEnableMode = .none,
    tieLoser: String? = nil, defaultMode: FirstSeenMode = .inherit, engine: EngineFingerprint = .native
) -> ResolvedDecision {
    FocusFixtures.decision(
        rule, strategy: strategy, axEnable: axEnable, tieLoser: tieLoser, defaultMode: defaultMode, engine: engine)
}

private func resolver(
    _ decisions: [BundleKey: ResolvedDecision] = [:], overlays: Set<BundleKey> = [spotlight]
) -> FakeDecisionResolver {
    FocusFixtures.resolver(decisions, overlays: overlays)
}

@Suite("FocusTracker (PLT-R380-R393, PRD-R19-R22)", .serialized)
struct FocusTrackerTests {
    @Test func publishesTheFocusOwnerFieldAndGeneration() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = resolver()
        harness.ax.focus(pid: terminalPID, attributes: attributes(identifier: "shell"), notify: nil)
        harness.start(rules)
        let snapshot = harness.snapshot
        #expect(
            snapshot.app
                == FocusedApp(pid: terminalPID, bundle: terminal, appVersion: LooseVersion("1.0"), engine: .native))
        #expect(snapshot.field.role == "AXTextArea")
        #expect(snapshot.field.identifier == "shell")
        #expect(snapshot.field.axAvailability == .available)
        #expect(snapshot.generation == FocusGeneration(rawValue: 1))
        #expect(harness.generation.load() == snapshot.generation)
        #expect(snapshot.fieldHandle?.pid == terminalPID)
        #expect(snapshot.pause == nil)
        #expect(harness.tracker.currentDecision() == decision(nil))
        #expect(harness.metrics.focusRefresh.snapshot().count == 1)  // T6 recorded
        #expect(rules.resolvedContexts.last?.ancestorRoles.count == 6)
        #expect(rules.resolvedContexts.last?.macOS == LooseVersion("27.2"))
        #expect(rules.resolvedContexts.last?.appVersion == LooseVersion("1.0"))
    }

    /// PRD-R22 acceptance: Spotlight over Terminal (remembered EN) uses Spotlight's own memory (inherit -> VI).
    @Test func nonActivatingOverlayOwnsFocusSoItsRuleAndMemoryApply() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = resolver([spotlight: decision("spotlight.overlay")])
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start(rules, memory: [AppModeEntry(bundle: terminal, mode: .english)])
        #expect(harness.snapshot.mode == .english)
        harness.ax.focus(pid: spotlightPID, attributes: attributes(role: "AXTextField"), notify: .focusedElementChanged)
        harness.sync()
        #expect(harness.snapshot.app?.bundle == spotlight)
        #expect(harness.snapshot.mode == .vietnamese)
        #expect(harness.snapshot.decision.rule == RuleID(rawValue: "spotlight.overlay"))
        #expect(harness.generation.load() == FocusGeneration(rawValue: 2))
    }

    @Test func activationWithoutAnObserverIsPickedUpByRevalidation() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: .applicationActivated)  // not observed
        harness.sync()
        #expect(harness.snapshot.app?.bundle == terminal)
        harness.tracker.revalidate()
        harness.sync()
        #expect(harness.snapshot.app?.bundle == zalo)
    }

    @Test func idleRevalidationThroughTheInbox() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        _ = harness.inbox.push(.revalidateFocus)  // PLT-R382
        harness.tracker.drainInbox()
        harness.sync()
        #expect(harness.snapshot.app?.bundle == zalo)
    }

    /// PLT-R382 + T6: the first key after a typing pause revalidates focus without a full scan of running
    /// applications and without re-reading the owner's identity; NSWorkspace activation still rescans overlays.
    @Test func idleRevalidationSkipsTheRunningApplicationScanPLTR382() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        let scans = harness.processes.runningApplicationScans
        let lookups = harness.processes.identityLookups(of: terminalPID)
        for _ in 0..<5 {
            _ = harness.inbox.push(.revalidateFocus)
            harness.tracker.drainInbox()
        }
        harness.sync()
        #expect(harness.processes.runningApplicationScans == scans)
        #expect(harness.processes.identityLookups(of: terminalPID) == lookups)
        harness.tracker.revalidate()  // NSWorkspace activation or wake
        harness.sync()
        #expect(harness.processes.runningApplicationScans == scans + 1)
    }

    @Test func resolutionHappensOncePerFocusChange() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = resolver()
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start(rules)
        for kind in [AXNotificationKind.focusedElementChanged, .focusedWindowChanged, .applicationActivated] {
            harness.ax.post(kind, from: terminalPID)
        }
        harness.tracker.revalidate()
        harness.sync()
        #expect(rules.resolvedContexts.count == 1)
        #expect(harness.generation.load() == FocusGeneration(rawValue: 1))
        harness.activate(zaloPID)
        #expect(rules.resolvedContexts.count == 2)
    }

    @Test func threeTimeoutsInTenSecondsOpenTheBreakerForSixtySeconds() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = resolver()
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start(rules)
        harness.ax.setTimingOut(pid: terminalPID, true)
        for _ in 0..<3 {
            harness.clock.advance(byMicroseconds: 1_000_000)
            harness.tracker.revalidate()
        }
        harness.sync()
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == 4)
        #expect(
            harness.health.recent(limit: 10).filter { $0.kind == .axCircuitBreakerTrip }.map(\.bundle) == [terminal])
        #expect(harness.snapshot.field.axAvailability == .timedOut)
        #expect(rules.resolvedContexts.last?.role == nil)  // bundle- and engine-level rules only
        harness.clock.advance(byMicroseconds: 30_000_000)
        harness.tracker.revalidate()
        harness.sync()
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == 4)  // no AX query while open
        harness.ax.setTimingOut(pid: terminalPID, false)
        harness.clock.advance(byMicroseconds: 31_000_000)
        harness.tracker.revalidate()
        harness.sync()
        #expect(harness.ax.elementQueryCount(pid: terminalPID) == 5)
        #expect(harness.snapshot.field.axAvailability == .available)
    }

    @Test func secureTextFieldYieldsSecureField() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(
            pid: zaloPID, attributes: attributes(role: "AXTextField", subrole: "AXSecureTextField"), notify: nil)
        harness.start()
        #expect(harness.snapshot.field.secure)
        #expect(harness.snapshot.pause == .secureField)
    }

    @Test func titleAndURLAreUsedForMatchingButNeverPublished() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = resolver()
        let title = "Secret window title 4711"
        let url = "https://example.test/private/path-4711"
        harness.ax.focus(pid: browserPID, attributes: attributes(title: title, url: url), notify: nil)
        harness.start(rules)
        #expect(
            harness.ax.lastAttributeRequest == AXAttributeRequest(includeDocumentURL: true, includeWindowTitle: true))
        #expect(rules.resolvedContexts.last?.windowTitle == title)
        #expect(rules.resolvedContexts.last?.documentURL == url)
        let published = String(describing: harness.snapshot)
        #expect(!published.contains("4711"))
        #expect(harness.snapshot.app?.engine == .chromium)
        harness.activate(terminalPID, attributes(title: title, url: url))
        #expect(
            harness.ax.lastAttributeRequest == AXAttributeRequest(includeDocumentURL: false, includeWindowTitle: false))
        #expect(rules.resolvedContexts.last?.windowTitle == nil)
    }

    @Test func titleChangeForATitlePatternBundleReResolvesWithoutANewFocusGeneration() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = resolver()
        harness.ax.focus(pid: browserPID, attributes: attributes(title: "One"), notify: nil)
        harness.start(rules)
        #expect(harness.ax.observedNotifications[browserPID]?.contains(.titleChanged) == true)
        harness.ax.focus(pid: browserPID, attributes: attributes(title: "Two"), notify: .titleChanged)
        harness.sync()
        #expect(rules.resolvedContexts.count == 2)
        #expect(harness.generation.load() == FocusGeneration(rawValue: 1))  // same decision: no hard boundary
    }

    /// contracts.md 10.4: the ax thread applies the tap's toggle and stamps the sequence.
    @Test func tapToggleIsAppliedWithItsSequenceInTheSameGeneration() throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        let before = harness.snapshot.generation
        harness.toggle(7, terminal, .english)
        #expect(harness.snapshot.mode == .english)
        #expect(harness.snapshot.appliedToggleSequence == 7)
        #expect(harness.snapshot.generation == before)
        let document = try #require(harness.documents.last)
        #expect(document.globalMode == .english)
        #expect(document.apps.first == AppModeEntry(bundle: terminal, mode: .english))
        harness.toggle(3, zalo, .vietnamese)  // an older toggle for another app: sequence stays the highest
        #expect(harness.snapshot.appliedToggleSequence == 7)
        #expect(harness.snapshot.mode == .english)
    }

    /// PRD-R19 / PRD-R23 acceptance: Terminal EN, Zalo VI, back to Terminal: English at once.
    @Test func rememberedModeAppliesOnTheNextActivation() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start(memory: [AppModeEntry(bundle: zalo, mode: .vietnamese)])
        harness.toggle(1, terminal, .english)
        harness.activate(zaloPID)
        #expect(harness.snapshot.mode == .vietnamese)
        #expect(harness.snapshot.modeSource == .remembered)
        harness.activate(terminalPID)
        #expect(harness.snapshot.mode == .english)
        #expect(harness.snapshot.modeSource == .remembered)
    }

    @Test func ignoredAppPassesThroughAndItsToggleDoesNothing() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: codePID, attributes: attributes(), notify: nil)
        harness.start(memory: [AppModeEntry(bundle: code, rule: .ignore)])
        let userIgnore = RuleID(rawValue: "user.ignore")!
        #expect(harness.snapshot.decision.plan.strategy == .passThrough)
        #expect(harness.snapshot.pause == .passThroughRule(userIgnore))
        #expect(harness.snapshot.modeSource == .ignoreRule)
        harness.toggle(1, code, .english)
        harness.tracker.setMode(.english)
        harness.sync()
        #expect(harness.documents.values.allSatisfy { $0.globalMode == .vietnamese })
        #expect(harness.snapshot.pause == .passThroughRule(userIgnore))
    }

    /// PRD-R21: a rule wins on every activation; a toggle under it lasts until the app is left.
    @Test func alwaysEnglishWinsOnEveryActivation() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start(memory: [AppModeEntry(bundle: terminal, rule: .alwaysEnglish, mode: .vietnamese)])
        #expect(harness.snapshot.mode == .english)
        harness.toggle(1, terminal, .vietnamese)
        #expect(harness.snapshot.mode == .vietnamese)
        harness.ax.focus(
            pid: terminalPID, attributes: attributes(identifier: "other-field"), notify: .focusedElementChanged)
        harness.sync()
        #expect(harness.snapshot.mode == .vietnamese)  // same app, another field: the toggle holds
        harness.activate(zaloPID)
        harness.activate(terminalPID)
        #expect(harness.snapshot.mode == .english)
        #expect(harness.snapshot.modeSource == .alwaysEnglish)
    }

    @Test func menuModeChangeUpdatesMemoryAndTheSnapshot() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.start()
        harness.tracker.setMode(.english)
        harness.sync()
        #expect(harness.snapshot.mode == .english)
        #expect(harness.snapshot.appliedToggleSequence == 0)
        #expect(harness.documents.last?.apps.first == AppModeEntry(bundle: zalo, mode: .english))
    }

    @Test func requireTextFocusFollowsTheEngine() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(role: "AXButton"), notify: nil)
        harness.start(resolver([code: decision(nil, engine: .electron)]))
        #expect(harness.snapshot.decision.requireTextFocus == .whenKnown)
        #expect(harness.snapshot.pause == .noTextFocus)  // PLT-R386: native app, AX says not text
        harness.activate(codePID, attributes(role: "AXButton"))
        #expect(harness.snapshot.decision.requireTextFocus == .never)
        #expect(harness.snapshot.pause == nil)
        harness.activate(terminalPID)
        #expect(harness.snapshot.pause == nil)
    }

    @Test func rulesChangeReResolvesAndPublishesOnlyOnChange() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        harness.tracker.update(rules: resolver())
        harness.sync()
        #expect(harness.generation.load() == FocusGeneration(rawValue: 1))
        harness.tracker.update(rules: resolver([terminal: decision("terminal.pass", strategy: .passThrough)]))
        harness.sync()
        #expect(harness.generation.load() == FocusGeneration(rawValue: 2))
        #expect(harness.snapshot.pause == .passThroughRule(RuleID(rawValue: "terminal.pass")!))
    }

    @Test func settingsAndAppModesChangeAppliesOnTheCurrentFocus() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: codePID, attributes: attributes(), notify: nil)
        harness.start()
        let emitted = harness.documents.last ?? AppModesDocument()
        var incoming = emitted
        incoming.apps.insert(AppModeEntry(bundle: code, rule: .ignore), at: 0)
        incoming.apps = incoming.apps.filter { $0.bundle != code || $0.rule == .ignore }
        harness.tracker.update(settings: DefaultSettings.v1, appModes: incoming)
        harness.sync()
        #expect(harness.snapshot.decision.plan.strategy == .passThrough)
    }

    /// PRD-R20, contracts.md 10.4: SettingsStore republishes `appModes` on every settings change and debounces
    /// `recordAppModes`, so it can hand back any document emitted before the latest toggle. Such an echo must
    /// not roll the toggle back.
    @Test func anOlderEchoFromTheStoreDoesNotRollBackAToggle() throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        let preToggle = try #require(harness.documents.last)
        harness.toggle(1, terminal, .english)
        let middle = try #require(harness.documents.last)
        harness.toggle(2, terminal, .vietnamese)
        harness.toggle(3, terminal, .english)
        for echo in [preToggle, middle] {
            harness.tracker.update(settings: DefaultSettings.v1, appModes: echo)
            harness.sync()
            #expect(harness.snapshot.mode == .english)
            #expect(harness.documents.last?.globalMode == .english)
            #expect(harness.documents.last?.apps.first == AppModeEntry(bundle: terminal, mode: .english))
        }
    }

    /// PRD-R26: an Apps-pane reset clears the live memory even when the session started with no remembered
    /// modes. Once the store returned a newer document, the empty launch state is no echo any more.
    @Test func aResetToTheLaunchStateClearsTheMemory() throws {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.start()  // fresh install: global VI, nothing remembered
        harness.toggle(1, terminal, .english)
        harness.toggle(2, zalo, .vietnamese)  // the global mode is back to VI
        let latest = try #require(harness.documents.last)
        harness.tracker.update(settings: DefaultSettings.v1, appModes: latest)  // the store's echo
        harness.sync()
        harness.tracker.update(settings: DefaultSettings.v1, appModes: AppModesDocument(globalMode: .vietnamese))
        harness.sync()
        harness.activate(terminalPID)
        #expect(harness.snapshot.mode == .vietnamese, "Terminal's remembered EN was reset")
        #expect(harness.documents.last?.apps.contains { $0.bundle == terminal && $0.mode == .english } == false)
    }

    /// An import or reset (a document this memory never emitted) replaces the remembered modes.
    @Test func anImportedDocumentReplacesTheRememberedModes() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        harness.toggle(1, terminal, .english)
        let imported = AppModesDocument(globalMode: .vietnamese, apps: [AppModeEntry(bundle: zalo, mode: .english)])
        harness.tracker.update(settings: DefaultSettings.v1, appModes: imported)
        harness.sync()
        harness.activate(zaloPID)
        #expect(harness.snapshot.mode == .english)
        #expect(harness.snapshot.modeSource == .remembered)
    }

    @Test func pasteOptInComesFromSettingsOrAUserOverride() {
        let harness = Harness()
        defer { harness.finish() }
        var offered = decision("chat.paste", strategy: .paste)
        offered.requiresUserOptIn = true
        offered.fallback = [.backspaceReplace]
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.start(resolver([zalo: offered]))
        #expect(harness.snapshot.decision.plan.strategy == .backspaceReplace)
        var settings = DefaultSettings.v1
        settings.optedInRules = [RuleID(rawValue: "chat.paste")!]
        harness.tracker.update(settings: settings, appModes: harness.documents.last ?? AppModesDocument())
        harness.sync()
        #expect(harness.snapshot.decision.plan.strategy == .paste)
    }

    @Test func manualAccessibilityOnlyWhenTheRuleAsksAndOncePerProcess() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.start(resolver([zalo: decision("electron.manual", axEnable: .manual)]))
        harness.activate(terminalPID)
        harness.activate(zaloPID)
        #expect(harness.ax.manualAccessibilityRequests == [zaloPID])
        #expect(harness.tracker.manualAccessibilityBundles() == [zalo])
    }

    @Test func runtimeTieRecordsAHealthEvent() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.start(resolver([zalo: decision("rule.a", tieLoser: "rule.b")]))
        let ties = harness.health.recent(limit: 10).filter { $0.kind == .ruleTie }
        #expect(ties.map(\.rule) == [RuleID(rawValue: "rule.a")])
    }

    @Test func observersFollowTheOwnerAndKeepOverlays() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        let base: Set<AXNotificationKind> = [.focusedElementChanged, .focusedWindowChanged, .applicationActivated]
        #expect(harness.ax.observedNotifications == [terminalPID: base, spotlightPID: base])
        harness.activate(zaloPID)
        #expect(Set(harness.ax.observedNotifications.keys) == [zaloPID, spotlightPID])
        harness.activate(browserPID)
        #expect(harness.ax.observedNotifications[browserPID] == base.union([.titleChanged]))
        harness.processes.terminate(pid: spotlightPID)
        harness.tracker.revalidate()
        harness.sync()
        #expect(Set(harness.ax.observedNotifications.keys) == [browserPID])
        harness.tracker.stop()
        harness.sync()
        #expect(harness.ax.observedNotifications.isEmpty)
    }

    @Test func overlayRulesAddedLaterAreObserved() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start(resolver(overlays: []))
        #expect(Set(harness.ax.observedNotifications.keys) == [terminalPID])
        harness.tracker.update(rules: resolver(overlays: [spotlight, zalo]))
        harness.sync()
        #expect(Set(harness.ax.observedNotifications.keys) == [terminalPID, spotlightPID, zaloPID])
    }

    @Test func noFocusedAppAndNoFocusedElement() {
        let harness = Harness()
        defer { harness.finish() }
        harness.start()
        #expect(harness.snapshot.app == nil)
        #expect(harness.snapshot.fieldHandle == nil)
        harness.ax.focusWithoutElement(pid: terminalPID, notify: nil)
        harness.tracker.revalidate()
        harness.sync()
        #expect(harness.snapshot.app?.bundle == terminal)
        #expect(harness.snapshot.field.role == nil)
        #expect(harness.snapshot.field.axAvailability == .available)
        #expect(harness.snapshot.pause == nil)  // unknown is not "definitely not text"
        harness.activate(zaloPID, attributes(role: "AXApplication"))
        #expect(harness.snapshot.field.role == nil)
        #expect(harness.snapshot.fieldHandle == nil)
    }

    @Test func unavailableAccessibilityIsReported() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.setUnavailable(pid: zaloPID, true)
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.start()
        #expect(harness.snapshot.field.axAvailability == .unavailable)
    }

    @Test func fingerprintIsCachedPerBundleVersion() {
        let harness = Harness()
        defer { harness.finish() }
        let rules = CountingResolver(resolver())
        harness.ax.focus(pid: browserPID, attributes: attributes(), notify: nil)
        harness.start(rules)
        harness.activate(terminalPID)
        harness.activate(browserPID)
        #expect(rules.fingerprintCalls.filter { $0 == browser }.count == 1)
        harness.tracker.update(rules: rules)  // rules changed: the webkitBrowsers group may differ
        harness.sync()
        #expect(rules.fingerprintCalls.filter { $0 == browser }.count == 2)
    }

    @Test func stoppedTrackerIgnoresEverything() {
        let harness = Harness()
        defer { harness.finish() }
        harness.ax.focus(pid: terminalPID, attributes: attributes(), notify: nil)
        harness.start()
        harness.tracker.stop()
        harness.sync()
        harness.ax.focus(pid: zaloPID, attributes: attributes(), notify: nil)
        harness.tracker.revalidate()
        harness.tracker.update(rules: resolver())
        harness.toggle(1, zalo, .english)
        #expect(harness.snapshot.app?.bundle == terminal)
        #expect(harness.documents.last?.globalMode == .english)  // memory still learns the toggle
    }
}
