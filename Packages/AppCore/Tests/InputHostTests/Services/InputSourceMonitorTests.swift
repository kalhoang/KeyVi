// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R370-R373, PLT-R360: snapshots on source changes, table reuse, keyboard types and the layout binding.

import AppModel
import Foundation
import RealtimeSupport
import Testing

@testable import InputHost
@testable import TestSupport

/// Synthetic tables; counts builds and can fail.
private final class CountingBuilder: LayoutTableBuilding {
    private let builds = Mutex<[LayoutTableKey]>([])
    private let failing: Set<InputSourceID>

    init(failing: Set<InputSourceID> = []) { self.failing = failing }

    func build(from data: KeyboardLayoutData, keyboardType: UInt32) throws -> LayoutTable {
        builds.withLock { $0.append(LayoutTableKey(source: data.source, keyboardType: keyboardType)) }
        if failing.contains(data.source) { throw LayoutTableError.invalidLayoutData }
        return LayoutTable(
            source: data.source, keyboardType: keyboardType,
            entries: [LayoutEntry](repeating: .none, count: LayoutTable.keyCodeCount * 4))
    }

    var buildKeys: [LayoutTableKey] { builds.withLock { $0 } }
}

private let abc = InputSourceInfo.layout("com.apple.keylayout.ABC", name: "ABC")
private let usLayout = InputSourceInfo.layout("com.apple.keylayout.US", name: "U.S.")
private let german = InputSourceInfo.layout("com.apple.keylayout.German", name: "German", languages: ["de"])
private let kana = InputSourceInfo(
    id: sourceID("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"), kind: .inputMode, localizedName: "Romaji",
    languages: ["ja"], isBuiltInVietnamese: false)
private let vietnameseTelex = InputSourceInfo(
    id: sourceID("com.apple.inputmethod.VietnameseIM.VietnameseTelex"), kind: .inputMode, localizedName: "Telex",
    languages: ["vi"], isBuiltInVietnamese: true)

private func layoutData(_ info: InputSourceInfo) -> KeyboardLayoutData {
    KeyboardLayoutData(source: info.id, uchr: Data([1, 2, 3]))
}

@MainActor
private struct Harness {
    let provider = FakeInputSourceProvider(
        current: abc,
        layouts: Dictionary(uniqueKeysWithValues: [abc, usLayout, german].map { ($0.id, layoutData($0)) }))
    let builder: CountingBuilder
    let published = Recorder<InputSourceSnapshot>()
    let monitor: InputSourceMonitor

    init(builder: CountingBuilder = CountingBuilder()) {
        self.builder = builder
        let published = self.published
        monitor = InputSourceMonitor(provider: provider, builder: builder) { published.append($0) }
    }
}

@Suite("InputSourceMonitor (PLT-R370-R373)")
@MainActor
struct InputSourceMonitorTests {
    @Test func startPublishesTheCurrentLayoutWithItsTable() throws {
        let harness = Harness()
        harness.monitor.start()
        let snapshot = try #require(harness.published.last)
        #expect(snapshot.generation == 1)
        #expect(snapshot.source == abc)
        #expect(snapshot.table?.source == abc.id)
        #expect(snapshot.table?.keyboardType == 40)
        #expect(snapshot.boundMode == nil)
    }

    @Test func everySelectionChangePublishesANewGeneration() throws {
        let harness = Harness()
        harness.monitor.start()
        harness.provider.select(kana)
        let paused = try #require(harness.published.last)
        #expect(paused.generation == 2)
        #expect(paused.source.kind == .inputMode)
        #expect(paused.table == nil)  // PLT-R371: input modes are never transformed
        harness.provider.select(vietnameseTelex)
        #expect(harness.published.last?.source.isBuiltInVietnamese == true)  // PLT-R372
        #expect(harness.published.last?.generation == 3)
    }

    @Test func aNotificationWithoutChangePublishesNothing() {
        let harness = Harness()
        harness.monitor.start()
        harness.provider.notifyChange()
        harness.provider.select(abc)
        #expect(harness.published.count == 1)
    }

    @Test func tablesAreBuiltOncePerLayoutAndKeyboardType() {
        let harness = Harness()
        harness.monitor.start()
        harness.provider.select(german)
        harness.provider.select(abc)
        harness.provider.select(german)
        #expect(harness.builder.buildKeys.map(\.source) == [abc.id, german.id])
        #expect(harness.published.count == 4)
    }

    @Test func anInputMethodNeverGetsATableEvenWithAnUnderlyingLayout() {
        let harness = Harness()
        harness.provider.underlyingLayout = abc.id
        harness.monitor.start()
        harness.provider.select(kana)
        #expect(harness.published.last?.table == nil)
    }

    @Test func aNewKeyboardTypeRebuildsTheTable() {
        let harness = Harness()
        harness.monitor.start()
        harness.monitor.keyboardTypeSeen(40)
        #expect(harness.published.count == 1)
        harness.monitor.keyboardTypeSeen(41)  // ISO
        #expect(harness.published.last?.table?.keyboardType == 41)
        #expect(harness.published.last?.generation == 2)
        #expect(harness.builder.buildKeys.count == 2)
    }

    @Test func layoutBindingDecidesTheModeOnlyWhenEnabled() {
        let harness = Harness()
        harness.monitor.start()
        harness.monitor.apply(
            binding: LayoutBindingConfiguration(enabled: true, vietnamese: [abc.id], english: [usLayout.id]))
        #expect(harness.published.last?.boundMode == .vietnamese)
        harness.provider.select(usLayout)
        #expect(harness.published.last?.boundMode == .english)
        harness.provider.select(german)
        #expect(harness.published.last?.boundMode == nil)
        harness.monitor.apply(binding: LayoutBindingConfiguration(enabled: false, vietnamese: [german.id], english: []))
        #expect(harness.published.last?.boundMode == nil)
    }

    @Test func nonAsciiSourcesAreNeverBound() {
        let harness = Harness()
        harness.monitor.start()
        harness.monitor.apply(binding: LayoutBindingConfiguration(enabled: true, vietnamese: [kana.id], english: []))
        harness.provider.select(kana)
        #expect(harness.published.last?.boundMode == nil)
    }

    @Test func aFailedBuildStillPublishesTheSource() {
        let harness = Harness(builder: CountingBuilder(failing: [abc.id]))
        harness.monitor.start()
        #expect(harness.published.last?.source == abc)
        #expect(harness.published.last?.table == nil)
    }

    @Test func missingLayoutDataGivesNoTable() {
        let harness = Harness()
        harness.monitor.start()
        harness.provider.select(InputSourceInfo.layout("com.apple.keylayout.Missing"))
        #expect(harness.published.last?.table == nil)
    }

    @Test func stopRemovesTheObserverAndStartIsIdempotent() {
        let harness = Harness()
        harness.monitor.start()
        harness.monitor.start()
        #expect(harness.provider.observerCount == 1)
        harness.monitor.stop()
        #expect(harness.provider.observerCount == 0)
        harness.provider.select(german)
        #expect(harness.published.count == 1)
    }
}
