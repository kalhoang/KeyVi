// SPDX-License-Identifier: MPL-2.0
//
// site-demo-frames: the website's typing demos recorded from the real engine (PRD-R73; website redesign design
// of 16/11/2026, section 7.4). Every frame is engine output; the tests pin the product owner's hero sentence, the
// three behaviours of the home page and the CLI contract (exit codes, check mode, deterministic output).

import Foundation
import Testing
import VietnameseEngine
import VietnameseEngineData

@testable import site_demo_frames

@Suite struct SiteDemoFramesTests {
    /// `<repo>`, from `<repo>/Packages/VietnameseEngine/Tests/SiteDemoFramesTests/SiteDemoFramesTests.swift`.
    static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SiteDemoFramesTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // VietnameseEngine
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()

    static func recorder() throws -> FrameRecorder {
        FrameRecorder(resources: try Resources.bundled(userKeepRaw: WordSet([]), userKeepVietnamese: WordSet([])))
    }

    static func demo(
        _ keys: String, id: String = "test", expect: String = "", method: DemoScript.Method = .telex,
        toneStyle: DemoScript.ToneStyle = .traditional
    ) -> DemoScript.Demo {
        DemoScript.Demo(id: id, method: method, toneStyle: toneStyle, keys: keys, expect: expect)
    }

    // MARK: Recording through the engine

    /// The hero sentence is fixed by the product owner (design 7.3): the keys, the text and the English words the
    /// page tags as kept (online, file, slide, deadline) all come from the engine.
    @Test func heroSentenceTypesAsScripted() throws {
        let script = try DemoScript.load(from: Self.repoRoot.appendingPathComponent("site/demo/script.json"))
        let hero = try #require(script.demos.first { $0.id == "hero-chat" })
        #expect(hero.keys == "Chieeuf nay hojp online, nhows guwir file slide truwowcs deadline nha")
        let demo = try Self.recorder().record(hero)
        #expect(demo.text == "Chiều nay họp online, nhớ gửi file slide trước deadline nha")
        let commits = demo.frames.compactMap(\.commit)
        #expect(commits.filter(\.english).map(\.raw) == ["online", "file", "slide", "deadline"])
        #expect(commits.first?.raw == "Chieeuf")
        #expect(commits.first?.text == "Chiều")
        #expect(commits.first?.outcome == "kept")
        #expect(commits.first?.rule == "notEnglish")
    }

    /// D8, PRD-R18: Escape right after a word gives back the keys as typed.
    @Test func escapeGivesBackTheKeys() throws {
        let demo = try Self.recorder().record(Self.demo("Vieetj⎋"))
        #expect(demo.frames.count == 7)
        #expect(demo.frames[demo.frames.count - 2].text == "Việt")
        let last = try #require(demo.frames.last)
        #expect(last.key == "⎋")
        #expect(last.text == "Vieetj")
        #expect(last.toggle)
        #expect(demo.text == "Vieetj")
    }

    /// D29, ENG-R828: the next word revises the previous one (the sentence starts with Vietnamese, PRD-R79).
    @Test func nextWordRevisesThePreviousOne() throws {
        let demo = try Self.recorder().record(Self.demo("cais nayf tricky as hell "))
        #expect(demo.frames.contains { $0.revision })
        #expect(demo.text == "cái này tricky as hell ")
    }

    /// Every frame's text is the whole field after its key; the keys and settings are carried over.
    @Test func framesFollowTheKeysOneByOne() throws {
        let demo = try Self.recorder().record(Self.demo("hoaf", method: .telex, toneStyle: .modern))
        #expect(demo.frames.map(\.key) == ["h", "o", "a", "f"])
        #expect(demo.frames.map(\.text) == ["h", "ho", "hoa", "hoà"])
        #expect(demo.frames.allSatisfy { $0.commit == nil && !$0.revision && !$0.toggle })
        #expect(demo.keys == "hoaf")
        #expect(demo.method == .telex)
        #expect(demo.toneStyle == .modern)
        let vni = try Self.recorder().record(Self.demo("vie65t", method: .vni))
        #expect(vni.text == "việt")
    }

    /// `⏎` is Return, `⌫` is Backspace, `⎋` the restore toggle, anything else a character key.
    @Test func keyNotationMapsToEngineEvents() {
        let keys = DemoKey.parse("a ⏎⌫⎋")
        #expect(keys.map(\.notation) == ["a", " ", "⏎", "⌫", "⎋"])
        #expect(
            keys.map(\.event) == [
                .key(KeyInput("a")), .key(KeyInput(" ")), .key(KeyInput("\n")), .backspace, .restoreToggle,
            ])
    }

    @Test func returnCommitsTheLastWordAndStaysInTheText() throws {
        let demo = try Self.recorder().record(Self.demo("Minhf check email, review slide.⏎"))
        #expect(demo.text == "Mình check email, review slide.\n")
        #expect(demo.frames.last?.key == "⏎")
    }

    // MARK: The frames file

    @Test func framesFileIsDeterministic() throws {
        let recorder = try Self.recorder()
        let demos = try [Self.demo("Vieetj⎋", id: "b"), Self.demo("Minhf check email, review slide.⏎", id: "a")]
            .map(recorder.record)
        let first = renderFramesFile(demos)
        let second = renderFramesFile(demos)
        #expect(first == second)
        #expect(first.last == UInt8(ascii: "\n"))
    }

    @Test func framesFileFollowsTheSchema() throws {
        let recorder = try Self.recorder()
        let demos = try [Self.demo("Vieetj⎋", id: "escape"), Self.demo("a/b ⏎", id: "slash")].map(recorder.record)
        let data = renderFramesFile(demos)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("null"))
        #expect(!text.contains("\\/"))
        #expect(text.contains("\"generator\": \"site-demo-frames\""))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 1)
        let all = try #require(root["demos"] as? [String: [String: Any]])
        #expect(all.keys.sorted() == ["escape", "slash"])
        let escape = try #require(all["escape"])
        #expect(escape["text"] as? String == "Vieetj")
        #expect(escape["method"] as? String == "telex")
        #expect(escape["toneStyle"] as? String == "traditional")
        let frames = try #require(escape["frames"] as? [[String: Any]])
        #expect(frames.first?.keys.sorted() == ["key", "text"])
        #expect(frames.last?["toggle"] as? Bool == true)
        let slash = try #require(all["slash"])
        #expect(slash["text"] as? String == "a/b \n")
        let commit = try #require((slash["frames"] as? [[String: Any]])?.compactMap { $0["commit"] as? [String: Any] })
        #expect(commit.allSatisfy { Set($0.keys) == ["raw", "text", "outcome", "rule", "english"] })
    }

    // MARK: The command line

    @Test func expectMismatchFails() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = try directory.write("script.json", Self.script([("wrong-demo", "vieetj", "viet")]))
        let output = directory.url.appendingPathComponent("frames.json")
        var messages: [String] = []
        let status = SiteDemoFrames.run(
            arguments: ["--script", script.path, "--out", output.path], currentDirectory: directory.url,
            log: { messages.append($0) })
        #expect(status == 1)
        #expect(messages.joined(separator: "\n").contains("wrong-demo"))
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func checkModeDetectsStaleFile() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let script = try directory.write("script.json", Self.script([("card-telex", "vieetj", "việt")]))
        let output = directory.url.appendingPathComponent("frames.json")
        let arguments = ["--script", script.path, "--out", output.path]
        #expect(Self.run(["--check"] + arguments, in: directory.url) == 1)  // no file yet
        #expect(Self.run(arguments, in: directory.url) == 0)
        #expect(Self.run(["--check"] + arguments, in: directory.url) == 0)
        var bytes = try Data(contentsOf: output)
        bytes[bytes.count - 1] = UInt8(ascii: " ")
        try bytes.write(to: output)
        #expect(Self.run(["--check"] + arguments, in: directory.url) == 1)
    }

    @Test func relativePathsResolveFromTheCurrentDirectory() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        _ = try directory.write("site/demo/script.json", Self.script([("card-telex", "vieetj", "việt")]))
        var printed: [String] = []
        let status = SiteDemoFrames.run(
            arguments: [], currentDirectory: directory.url, log: { _ in }, output: { printed.append($0) })
        #expect(status == 0)
        let frames = directory.url.appendingPathComponent("site/demo/frames.json")
        #expect(FileManager.default.fileExists(atPath: frames.path))
        #expect(printed.joined().contains("site/demo/frames.json"))
    }

    @Test func unknownKeyNotationIsAUsageError() {
        #expect(Self.run(["--frobnicate"], in: Self.repoRoot) == 2)
        #expect(Self.run(["--script"], in: Self.repoRoot) == 2)
        #expect(Self.run(["--out"], in: Self.repoRoot) == 2)
        #expect(Self.run(["positional"], in: Self.repoRoot) == 2)
        #expect(Self.run(["--help"], in: Self.repoRoot) == 0)
    }

    @Test func badScriptsAreUsageErrors() throws {
        let directory = try TemporaryDirectory()
        defer { directory.remove() }
        let missing = directory.url.appendingPathComponent("missing.json")
        let cases: [String] = [
            "not json",
            #"{"schemaVersion": 2, "demos": []}"#,
            #"{"schemaVersion": 1, "demos": []}"#,
            #"{"schemaVersion": 1, "demos": [{"id": "a", "method": "qwerty", "toneStyle": "traditional", "keys": "a", "expect": "a"}]}"#,
            Self.script([("same", "a", "a"), ("same", "b", "b")]),
            Self.script([("", "a", "a")]),
            Self.script([("empty-keys", "", "")]),
        ]
        let output = directory.url.appendingPathComponent("frames.json").path
        #expect(Self.run(["--script", missing.path, "--out", output], in: directory.url) == 2)
        for (index, text) in cases.enumerated() {
            let script = try directory.write("bad-\(index).json", text)
            #expect(Self.run(["--script", script.path, "--out", output], in: directory.url) == 2, "case \(index)")
        }
    }

    /// The committed `site/demo/frames.json` matches the engine of this commit: an engine change that alters a demo
    /// regenerates the file in the same commit (design 7.4).
    @Test func committedFramesFileIsCurrent() {
        var messages: [String] = []
        let status = SiteDemoFrames.run(
            arguments: ["--check"], currentDirectory: Self.repoRoot, log: { messages.append($0) }, output: { _ in })
        #expect(status == 0, "\(messages.joined(separator: "\n"))")
    }

    // MARK: Helpers

    static func run(_ arguments: [String], in directory: URL) -> Int32 {
        SiteDemoFrames.run(arguments: arguments, currentDirectory: directory, log: { _ in }, output: { _ in })
    }

    /// A script of Telex traditional demos `(id, keys, expect)`.
    static func script(_ demos: [(String, String, String)]) -> String {
        let entries = demos.map { id, keys, expect in
            #"{"id": "\#(id)", "method": "telex", "toneStyle": "traditional", "keys": "\#(keys)", "expect": "\#(expect)"}"#
        }
        return #"{"schemaVersion": 1, "demos": [\#(entries.joined(separator: ", "))]}"#
    }
}

struct TemporaryDirectory {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("site-demo-frames-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func write(_ relativePath: String, _ text: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
        return file
    }

    func remove() { try? FileManager.default.removeItem(at: url) }
}
