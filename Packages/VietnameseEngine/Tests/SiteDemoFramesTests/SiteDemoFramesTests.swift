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

    /// The hero sentences are fixed by the product owner (design section 9 item 1): English words that plain Telex
    /// turns into something else. The keys, the text, the words the page tags as kept and what plain Telex would
    /// have typed (`plain`, ENG-R802) all come from the engine. The keys are inlined so that the package tests stand
    /// alone; `committedFramesFileIsCurrent` pins the script.
    @Test(arguments: [
        (
            "hero-chat", "Chieeuf nay meeting treen Zoom, nhows test laij banr mowis nha",
            "Chiều nay meeting trên Zoom, nhớ test lại bản mới nha",
            [["meeting", "mêting"], ["Zoom", "Zôm"], ["test", "tét"]]
        ),
        (
            "hero-email", "Em gwir anh list task tuaanf nayf, anh sort laij giusp em nhes",
            "Em gửi anh list task tuần này, anh sort lại giúp em nhé",
            [["list", "lít"], ["task", "ták"], ["sort", "sỏt"]]
        ),
        (
            "hero-note", "Best case thif thuws Saus choots, boss duyeetj xong laf post luoon",
            "Best case thì thứ Sáu chốt, boss duyệt xong là post luôn",
            [["Best", "Bét"], ["case", "cáe"], ["boss", "bos"], ["post", "pót"]]
        ),
    ])
    func heroSentenceTypesAsScripted(id: String, keys: String, expect: String, english: [[String]]) throws {
        let demo = try Self.recorder().record(Self.demo(keys, id: id, expect: expect))
        #expect(demo.text == expect)
        let commits = demo.frames.compactMap(\.commit)
        #expect(commits.filter(\.english).map { [$0.raw, $0.plain ?? ""] } == english)
        // Only a kept English word names its plain form.
        #expect(commits.filter { !$0.english }.allSatisfy { $0.plain == nil })
        #expect(demo.frames.allSatisfy { $0.revised == nil })
        #expect(demo.teachKeys == nil)
        #expect(demo.teachPasses.isEmpty)
    }

    /// ENG-R802: a kept English word that plain Telex types the same (`online`, `file`) carries no plain form.
    @Test func englishWordsThatTypeThemselvesHaveNoPlainForm() throws {
        let demo = try Self.recorder().record(
            Self.demo("Chieeuf nay hojp online, nhows guwir file slide truwowcs deadline nha"))
        #expect(demo.text == "Chiều nay họp online, nhớ gửi file slide trước deadline nha")
        let commits = demo.frames.compactMap(\.commit)
        #expect(commits.filter(\.english).map(\.raw) == ["online", "file", "slide", "deadline"])
        #expect(commits.allSatisfy { $0.plain == nil })
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
        #expect(demo.text == "cái này tricky as hell ")
        let earlier = try #require(demo.frames.compactMap(\.commit).first { $0.raw == "as" })
        #expect(earlier.text == "á")
        #expect(!earlier.english)
        let revising = demo.frames.filter { $0.revision }
        #expect(revising.count == 1)
        let frame = try #require(revising.first)
        #expect(frame.commit?.raw == "hell")
        // The frame names the word it changed, what that word became and what plain Telex would have typed, so the
        // page can tag "as" (ENG-R828, ENG-R802).
        #expect(frame.revised == RecordedDemo.Revised(raw: "as", text: "as", english: true, plain: "á"))
        #expect(demo.frames.filter { $0.revised != nil }.count == 1)
    }

    /// RV4 (ENG-R828): a Vietnamese word after an English run gives the previous word, restored by that run, its
    /// Vietnamese display back; the revised entry is then not English although its commit was.
    @Test func revisionToVietnameseIsNotEnglish() throws {
        let demo = try Self.recorder().record(Self.demo("Happy new year car nhaf "))
        #expect(demo.text == "Happy new year cả nhà ")
        let earlier = try #require(demo.frames.compactMap(\.commit).first { $0.raw == "car" })
        #expect(earlier.text == "car")
        #expect(earlier.english)
        let frame = try #require(demo.frames.first { $0.revision })
        #expect(frame.commit?.raw == "nhaf")
        #expect(frame.revised == RecordedDemo.Revised(raw: "car", text: "cả", english: false, plain: nil))
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

    /// Design 7.3: English words stay as typed at a comma, a period and Return; each boundary commits one of them.
    @Test func returnCommitsTheLastWordAndStaysInTheText() throws {
        let demo = try Self.recorder().record(Self.demo("Minhf check email, review slide. Gwir file⏎"))
        #expect(demo.text == "Mình check email, review slide. Gửi file\n")
        let kept = demo.frames.filter { $0.commit?.english == true && $0.key != " " }.map { [$0.key, $0.commit?.raw] }
        #expect(kept == [[",", "email"], [".", "slide"], ["⏎", "file"]])
        #expect(demo.frames.last?.key == "⏎")
        #expect(demo.frames.last?.commit?.text == "file")
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
        let demos = try [
            Self.demo("Vieetj⎋", id: "escape"), Self.demo("a/b ⏎", id: "slash"),
            Self.demo("cais nayf tricky as hell ", id: "revision"),
        ].map(recorder.record)
        let data = renderFramesFile(demos)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("null"))
        #expect(!text.contains("\\/"))
        #expect(text.contains("\"generator\": \"site-demo-frames\""))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schemaVersion"] as? Int == 2)
        let all = try #require(root["demos"] as? [String: [String: Any]])
        #expect(all.keys.sorted() == ["escape", "revision", "slash"])
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
        let revisionFrames = try #require(all["revision"]?["frames"] as? [[String: Any]])
        let revising = try #require(revisionFrames.first { $0["revision"] as? Bool == true })
        let revised = try #require(revising["revised"] as? [String: Any])
        #expect(Set(revised.keys) == ["raw", "text", "english", "plain"])
        #expect(revised["raw"] as? String == "as")
        #expect(revised["plain"] as? String == "á")
        #expect(revised["text"] as? String == "as")
        #expect(revised["english"] as? Bool == true)
        #expect(revisionFrames.filter { $0["revised"] != nil }.count == 1)
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
            #"{"schemaVersion": 1, "demos": []}"#,
            #"{"schemaVersion": 2, "demos": []}"#,
            #"{"schemaVersion": 2, "demos": [{"id": "a", "method": "qwerty", "toneStyle": "traditional", "keys": "a", "expect": "a"}]}"#,
            Self.script([("same", "a", "a"), ("same", "b", "b")]),
            Self.script([("", "a", "a")]),
            Self.script([("empty-keys", "", "")]),
            // A learning demo names its teaching keys, its number of passes and their text together.
            Self.learningScript(teachKeys: "a⎋", teach: nil, teachExpect: "a"),
            Self.learningScript(teachKeys: nil, teach: 2, teachExpect: "a"),
            Self.learningScript(teachKeys: "a⎋", teach: 2, teachExpect: nil),
            Self.learningScript(teachKeys: "a⎋", teach: 0, teachExpect: "a"),
            Self.learningScript(teachKeys: "", teach: 1, teachExpect: ""),
            // A teaching pass is a correction: without the restore toggle it teaches nothing (ENG-R863).
            Self.learningScript(teachKeys: "reset ", teach: 2, teachExpect: "reset "),
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
    @Test func committedFramesFileIsCurrent() throws {
        let script = Self.repoRoot.appendingPathComponent(SiteDemoFrames.defaultScript)
        try #require(
            FileManager.default.fileExists(atPath: script.path),
            """
            \(script.path) is missing: this test needs the repository layout, with the engine package at \
            <repo>/Packages/VietnameseEngine and the website at <repo>/site
            """)
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
        return #"{"schemaVersion": 2, "demos": [\#(entries.joined(separator: ", "))]}"#
    }

    /// A script of one Telex traditional learning demo; a nil field is left out.
    static func learningScript(
        id: String = "learning", teachKeys: String?, teach: Int?, teachExpect: String?,
        keys: String = "Nhows reset laij mays nha", expect: String = "Nhớ reset lại máy nha"
    ) -> String {
        let teaching = [
            teachKeys.map { #""teachKeys": "\#($0)""# }, teach.map { #""teach": \#($0)"# },
            teachExpect.map { #""teachExpect": "\#($0)""# },
        ].compactMap { $0 }
        let required = [
            #""id": "\#(id)""#, #""method": "telex""#, #""toneStyle": "traditional""#, #""keys": "\#(keys)""#,
            #""expect": "\#(expect)""#,
        ]
        let fields = (required + teaching).joined(separator: ", ")
        return #"{"schemaVersion": 2, "demos": [{\#(fields)}]}"#
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
