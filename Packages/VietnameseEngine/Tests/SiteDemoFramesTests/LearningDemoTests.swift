// SPDX-License-Identifier: MPL-2.0
//
// site-demo-frames: the learning demo of the home page (website redesign design, section 9 item 4). The generator
// teaches the engine with the corrections of the teaching passes through ReferenceCollisionMemory, the oracle of
// ENG-R863, rebuilds the engine with each new snapshot (ENG-R865) and fails unless the final pass commits the word by
// rule L9c, so the page can never claim a learning the engine did not do.

import Foundation
import Testing
import VietnameseEngine

@testable import site_demo_frames

@Suite struct LearningDemoTests {
    static let teachKeys = "Nhows reset⎋ laij mays nha"
    static let sentence = "Nhớ reset lại máy nha"

    static func learning(
        teachKeys: String = teachKeys, teach: Int = 2, teachExpect: String = sentence,
        keys: String = "Nhows reset laij mays nha", expect: String = sentence
    ) -> DemoScript.Demo {
        DemoScript.Demo(
            id: "learning-reset", method: .telex, toneStyle: .traditional, keys: keys, expect: expect,
            teachKeys: teachKeys, teach: teach, teachExpect: teachExpect)
    }

    /// Design 9 item 4: twice "rết", Escape, "reset"; from then on the engine keeps "reset" by rule L9c.
    @Test func twoCorrectionsTeachTheWord() throws {
        let demo = try SiteDemoFramesTests.recorder().record(Self.learning())
        #expect(demo.teachKeys == Self.teachKeys)
        #expect(demo.teachPasses.count == 2)
        for pass in demo.teachPasses {
            #expect(pass.text == Self.sentence)
            #expect(pass.frames.map(\.key) == DemoKey.parse(Self.teachKeys).map(\.notation))
            #expect(pass.frames.last?.text == pass.text)
            // One correction is not enough (ENG-R863: a score of 2), so the second pass still gives "rết" first.
            let toggle = try #require(pass.frames.firstIndex { $0.toggle })
            #expect(pass.frames[toggle - 1].text == "Nhớ rết")
            #expect(pass.frames[toggle].text == "Nhớ reset")
            let corrections = pass.signals.filter { $0.strength == .strong }
            #expect(
                corrections == [
                    CollisionSignal(word: "reset", context: .afterVietnamese, side: .english, strength: .strong)
                ])
        }
        #expect(demo.text == Self.sentence)
        #expect(demo.keys == "Nhows reset laij mays nha")
        #expect(!demo.frames.contains { $0.toggle })
        let learned = try #require(demo.frames.compactMap(\.commit).first { $0.rule == "learned" })
        #expect(learned.raw == "reset")
        #expect(learned.text == "reset")
        #expect(learned.outcome == "restored")
        #expect(learned.english)
        #expect(learned.plain == "rết")
    }

    /// Without the teaching the same keys give "rết": the kept word comes from the memory, not from the rules.
    @Test func theFinalKeysAloneGiveTheVietnameseDisplay() throws {
        let demo = try SiteDemoFramesTests.recorder().record(SiteDemoFramesTests.demo("Nhows reset laij mays nha"))
        #expect(demo.text == "Nhớ rết lại máy nha")
        #expect(!demo.frames.contains { $0.commit?.rule == "learned" })
    }

    /// The commit of the corrected word in a teaching pass is English and names its plain form too.
    @Test func teachingFramesCarryTheCorrectedWord() throws {
        let pass = try #require(try SiteDemoFramesTests.recorder().record(Self.learning()).teachPasses.first)
        let corrected = try #require(pass.frames.compactMap(\.commit).first { $0.raw == "reset" })
        #expect(corrected.text == "reset")
        #expect(corrected.rule == "userChoice")
        #expect(corrected.english)
        #expect(corrected.plain == "rết")
    }

    /// The generator fails, exit code 1 and no file, when a pass teaches nothing, when a pass does not give its
    /// `teachExpect`, or when the final pass has no `learned` commit (L9c).
    @Test(arguments: [
        ("Vieetj⎋ nha", 1, "Vieetj nha", "vieetj nha", "việt nha", "no strong collision signal"),
        (teachKeys, 2, "Nhớ rết lại máy nha", "Nhows reset laij mays nha", sentence, "teaching pass 1: expected"),
        (teachKeys, 1, sentence, "Nhows reset laij mays nha", "Nhớ rết lại máy nha", "rule learned"),
    ])
    func unprovenLearningFails(
        teachKeys: String, teach: Int, teachExpect: String, keys: String, expect: String, reason: String
    ) throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = try directory.write(
            "script.json",
            SiteDemoFramesTests.learningScript(
                teachKeys: teachKeys, teach: teach, teachExpect: teachExpect, keys: keys, expect: expect))
        let output = directory.url.appendingPathComponent("frames.json")
        var messages: [String] = []
        let status = SiteDemoFrames.run(
            arguments: ["--script", script.path, "--out", output.path], currentDirectory: directory.url,
            log: { messages.append($0) })
        #expect(status == 1)
        let log = messages.joined(separator: "\n")
        #expect(log.contains("learning"), "\(log)")
        #expect(log.contains(reason), "\(log)")
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    /// The frames file: `plain` on a kept English word that plain Telex changes, and for a learning demo its teaching
    /// keys and passes (`{ text, frames }`) beside the final frames.
    @Test func framesFileCarriesPlainFormsAndTeachingPasses() throws {
        let recorder = try SiteDemoFramesTests.recorder()
        let demos = try [
            SiteDemoFramesTests.demo("nhows test laij ", id: "plain"), Self.learning(),
        ].map(recorder.record)
        let data = renderFramesFile(demos)
        #expect(!String(decoding: data, as: UTF8.self).contains("null"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == DemoScript.supportedSchemaVersion)
        let all = try #require(root["demos"] as? [String: [String: Any]])
        let plain = try #require(all["plain"])
        #expect(plain.keys.sorted() == ["frames", "keys", "method", "text", "toneStyle"])
        let commits = try #require(plain["frames"] as? [[String: Any]]).compactMap { $0["commit"] as? [String: Any] }
        let test = try #require(commits.first { $0["raw"] as? String == "test" })
        #expect(Set(test.keys) == ["raw", "text", "outcome", "rule", "english", "plain"])
        #expect(test["plain"] as? String == "tét")
        #expect(commits.filter { $0["raw"] as? String != "test" }.allSatisfy { $0["plain"] == nil })
        let learning = try #require(all["learning-reset"])
        #expect(
            learning.keys.sorted() == ["frames", "keys", "method", "teachKeys", "teachPasses", "text", "toneStyle"])
        #expect(learning["teachKeys"] as? String == Self.teachKeys)
        let passes = try #require(learning["teachPasses"] as? [[String: Any]])
        #expect(passes.count == 2)
        for pass in passes {
            #expect(pass.keys.sorted() == ["frames", "text"])
            #expect(pass["text"] as? String == Self.sentence)
            let frames = try #require(pass["frames"] as? [[String: Any]])
            #expect(frames.last?["text"] as? String == Self.sentence)
            #expect(frames.contains { $0["toggle"] as? Bool == true })
        }
        let finalCommits = try #require(learning["frames"] as? [[String: Any]])
            .compactMap { $0["commit"] as? [String: Any] }
        #expect(finalCommits.contains { $0["rule"] as? String == "learned" && $0["plain"] as? String == "rết" })
    }
}
