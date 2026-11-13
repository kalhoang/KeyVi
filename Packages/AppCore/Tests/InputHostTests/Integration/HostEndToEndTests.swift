// SPDX-License-Identifier: LicenseRef-App-Pending
//
// End to end with fakes (W2-A acceptance): keys go through the real tap thread, pipeline, engine and inject
// worker of a started `InputHostController`, with keyboard layout tables built by UCKeyTranslate from the
// installed system layouts (read by ID only; no input source is selected, PLT-R360, PLT-R361, REG-16).
// Workstream W2-A.

import AppModel
import Foundation
import RealtimeSupport
import SettingsStore
import TestSupport
import Testing

@testable import InputHost

/// An installed system layout: its source info, raw `uchr` data and the table UCKeyTranslate builds from it.
struct SystemLayout {
    var info: InputSourceInfo
    var data: KeyboardLayoutData
    var table: LayoutTable

    @MainActor
    static func load(_ id: String, name: String) throws -> SystemLayout {
        let sourceID = try #require(InputSourceID(rawValue: id))
        let data = try #require(TISInputSourceProvider().layoutData(for: sourceID), "layout \(id) not installed")
        let table = try UCKeyTranslateLayoutBuilder().build(from: data, keyboardType: PipelineFixtures.keyboardType)
        let info = InputSourceInfo(
            id: sourceID, kind: .asciiLayout, localizedName: name, languages: ["en"], isBuiltInVietnamese: false)
        return SystemLayout(info: info, data: data, table: table)
    }

    /// A rig whose input-source monitor builds this layout's table with the real builder.
    @MainActor
    func rig(realResources: Bool = false) -> HostRig {
        HostRig(
            layout: table, source: info, layoutData: [info.id: data], builder: UCKeyTranslateLayoutBuilder(),
            realResources: realResources)
    }
}

@Suite("End to end with fakes and real layout tables")
@MainActor
struct HostEndToEndTests {
    nonisolated static let telexLayouts = [
        ("com.apple.keylayout.ABC", "ABC"), ("com.apple.keylayout.German", "German"),
        ("com.apple.keylayout.French", "French"), ("com.apple.keylayout.Dvorak", "Dvorak"),
    ]

    @Test(arguments: telexLayouts)
    func telexDuyetUnderEachLayout_PLT_R361(id: String, name: String) async throws {
        let layout = try SystemLayout.load(id, name: name)
        let rig = layout.rig()
        await rig.start()
        defer { rig.stop() }
        #expect(rig.controller.channels.snapshots.inputSource.load().table?.source == layout.info.id)
        rig.type("duyeetj")
        #expect(rig.field.text == "duyệt", "\(name)")
    }

    @Test(arguments: [("com.apple.keylayout.ABC", "ABC"), ("com.apple.keylayout.French", "French")])
    func vniDuyetUnderABCAndAZERTY_PLT_R361(id: String, name: String) async throws {
        let layout = try SystemLayout.load(id, name: name)
        let rig = layout.rig()
        _ = await rig.store.store.load()
        await rig.store.store.updateSettings { $0.typingMethod = .set(.vni) }
        await rig.start(preloaded: true)
        defer { rig.stop() }
        rig.type("duye65t")
        #expect(rig.field.text == "duyệt", "\(name): digits come from the layout's Shift column on AZERTY")
    }

    @Test func japaneseSourcePassesKeysAndPausesWithItsName_PLT_R371() async throws {
        let abc = try SystemLayout.load("com.apple.keylayout.ABC", name: "ABC")
        let japaneseID = try #require(InputSourceID(rawValue: "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"))
        let japanese = InputSourceInfo(
            id: japaneseID, kind: .inputMode, localizedName: "Romaji", languages: ["ja"], isBuiltInVietnamese: false)
        let rig = HostRig(
            layout: abc.table, source: japanese, layoutData: [abc.info.id: abc.data],
            builder: UCKeyTranslateLayoutBuilder())
        rig.inputSources.underlyingLayout = abc.info.id
        await rig.start()
        defer { rig.stop() }
        #expect(rig.controller.state == .paused(.nonLatinInputSource(name: "Romaji")))
        let verdicts = rig.type("duyeetj")
        #expect(verdicts.allSatisfy { $0 == .pass })
        #expect(rig.field.text == "duyeetj", "no transformation")
    }

    @Test func englishModePassesKeysThrough_QA_R7_P7() async throws {
        let abc = try SystemLayout.load("com.apple.keylayout.ABC", name: "ABC")
        let rig = abc.rig()
        await rig.start()
        defer { rig.stop() }
        rig.controller.setMode(.english, manual: true)
        rig.settle()
        #expect(rig.controller.state == .ready(.english))
        let verdicts = rig.type("duyeetj")
        #expect(verdicts.allSatisfy { $0 == .pass })
        #expect(rig.field.text == "duyeetj")
        #expect(rig.events.contains { if case .modeChanged(.english, true, _) = $0 { true } else { false } })
    }

    @Test func settingsChangeAppliesOnTheNextKeyWithoutLosingTheWord_PRD_R27() async throws {
        let abc = try SystemLayout.load("com.apple.keylayout.ABC", name: "ABC")
        let rig = abc.rig()
        await rig.start()
        defer { rig.stop() }
        rig.type("duye")
        let before = rig.controller.channels.snapshots.settings.load()
        await rig.store.store.updateSettings { $0.toggleHotkey = .set(.modifierTap(.rightOption)) }
        rig.controller.apply(settings: await rig.store.store.state)
        rig.settle()
        let after = rig.controller.channels.snapshots.settings.load()
        #expect(after.generation > before.generation, "the next key sees the new snapshot")
        #expect(after.toggleHotkey == .modifierTap(.rightOption))
        #expect(after.engines.revision == before.engines.revision, "not an engine change")
        rig.type("etj")
        #expect(rig.field.text == "duyệt", "the word survived the settings change")
    }

    @Test func engineChangeAppliesToTheNextWord_PLT_R1008() async throws {
        let abc = try SystemLayout.load("com.apple.keylayout.ABC", name: "ABC")
        let rig = abc.rig()
        await rig.start()
        defer { rig.stop() }
        rig.type("vieetj ")
        await rig.store.store.updateSettings { $0.typingMethod = .set(.vni) }
        rig.controller.apply(settings: await rig.store.store.state)
        rig.settle()
        rig.type("vie65t")
        #expect(rig.field.text == "việt việt")
    }

    @Test func bundledWordListsReachTheEngine_ENG_R1231() async throws {
        let abc = try SystemLayout.load("com.apple.keylayout.ABC", name: "ABC")
        let rig = abc.rig(realResources: true)
        await rig.start()
        defer { rig.stop() }
        rig.type("duyeetj ")
        #expect(rig.field.text == "duyệt ")
    }
}
