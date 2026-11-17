// SPDX-License-Identifier: MPL-2.0
//
// The demo script, site/demo/script.json: the sentences the website types, with their keys, typing method, tone
// placement and the text they must give (website redesign design of 16/11/2026, section 7.4), and for a learning demo
// the corrections that teach the engine first (section 9 item 4).

import Foundation
import VietnameseEngine

/// `site/demo/script.json`, schema version 2. Version 2 added the learning demo (`teachKeys`, `teach`, `teachExpect`);
/// a version 1 reader would drop the teaching silently, so the version changed and an older tool refuses the script.
struct DemoScript: Decodable, Sendable {
    /// Telex or VNI (D1).
    enum Method: String, Decodable, Sendable, Hashable, CaseIterable {
        case telex
        case vni
    }

    /// Traditional or modern tone placement (D2).
    enum ToneStyle: String, Decodable, Sendable, Hashable, CaseIterable {
        case traditional
        case modern
    }

    /// One demo: the keys typed in order (in the notation of ``DemoKey``) and the field text they must give. A learning
    /// demo also names the keys of one teaching pass (a correction with the restore toggle), how many passes teach
    /// the engine before `keys` are typed, and the field text after each pass (design 9 item 4, ENG-R863).
    struct Demo: Decodable, Sendable, Hashable {
        let id: String
        let method: Method
        let toneStyle: ToneStyle
        let keys: String
        let expect: String
        /// The keys of one teaching pass; they must contain the restore toggle `⎋`.
        let teachKeys: String?
        /// The number of teaching passes, at least 1.
        let teach: Int?
        /// The field text after each teaching pass.
        let teachExpect: String?

        init(
            id: String, method: Method, toneStyle: ToneStyle, keys: String, expect: String, teachKeys: String? = nil,
            teach: Int? = nil, teachExpect: String? = nil
        ) {
            self.id = id
            self.method = method
            self.toneStyle = toneStyle
            self.keys = keys
            self.expect = expect
            self.teachKeys = teachKeys
            self.teach = teach
            self.teachExpect = teachExpect
        }

        /// The teaching of a learning demo; nil for any other demo or when its fields are incomplete.
        var teaching: Teaching? {
            guard let teachKeys, let teach, let teachExpect else { return nil }
            return Teaching(keys: teachKeys, passes: teach, expect: teachExpect)
        }
    }

    /// What teaches the engine before a learning demo's keys: `passes` times `keys` in a fresh field, each giving
    /// `expect`, their collision signals counted in the learned memory (ENG-R863, ENG-R865).
    struct Teaching: Sendable, Hashable {
        let keys: String
        let passes: Int
        let expect: String
    }

    /// Why a script cannot be used. The command line reports it as a usage error (exit code 2).
    struct Problem: Error, Sendable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static let supportedSchemaVersion = 2

    let schemaVersion: Int
    let demos: [Demo]

    /// Reads, decodes and validates the script at `url`.
    static func load(from url: URL) throws -> DemoScript {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw Problem("cannot read \(url.path)")
        }
        return try decode(data, name: url.path)
    }

    /// Decodes and validates a script; `name` labels the messages.
    static func decode(_ data: Data, name: String) throws -> DemoScript {
        let script: DemoScript
        do {
            script = try JSONDecoder().decode(DemoScript.self, from: data)
        } catch {
            throw Problem("\(name) is not a demo script: \(error)")
        }
        try script.validate(name)
        return script
    }

    private func validate(_ name: String) throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw Problem("\(name): schemaVersion \(schemaVersion), expected \(Self.supportedSchemaVersion)")
        }
        guard !demos.isEmpty else { throw Problem("\(name): no demos") }
        var seen = Set<String>()
        for demo in demos {
            guard !demo.id.isEmpty else { throw Problem("\(name): a demo has an empty id") }
            guard !demo.keys.isEmpty else { throw Problem("\(name): \(demo.id): no keys") }
            guard seen.insert(demo.id).inserted else { throw Problem("\(name): duplicate demo id \(demo.id)") }
            try validateTeaching(of: demo, name)
        }
    }

    /// A learning demo names its teaching keys, passes and text together; a pass is a correction, so its keys hold
    /// the restore toggle (ENG-R863: a correction is the toggle against the rules).
    private func validateTeaching(of demo: Demo, _ name: String) throws {
        let fields = [demo.teachKeys != nil, demo.teach != nil, demo.teachExpect != nil]
        guard fields.contains(true) else { return }
        guard let teaching = demo.teaching else {
            throw Problem("\(name): \(demo.id): teachKeys, teach and teachExpect go together")
        }
        guard teaching.passes >= 1 else { throw Problem("\(name): \(demo.id): teach must be at least 1") }
        guard DemoKey.parse(teaching.keys).contains(where: \.isToggle) else {
            throw Problem("\(name): \(demo.id): teachKeys must contain the restore toggle ⎋")
        }
    }
}

/// One key of a demo's `keys`. `⏎` is Return, `⎋` is Escape bound as the restore key, `⌫` is Backspace; every
/// other character is the key that types it (after keyboard-layout mapping, as the engine sees keys).
struct DemoKey: Sendable, Hashable {
    /// The key as written in the script; the frames file names keys this way.
    let notation: String
    /// The event the host sends the engine for this key.
    let event: EngineEvent

    init(_ character: Character) {
        notation = String(character)
        switch character {
        // The host feeds Return to the engine as the character "\n" (InputHost KeyPipeline, commitLine).
        case "⏎": event = .key(KeyInput("\n"))
        // Escape bound as the restore key asks the engine for the toggle (PLT-R353, D8, PRD-R18).
        case "⎋": event = .restoreToggle
        case "⌫": event = .backspace
        default: event = .key(KeyInput(character))
        }
    }

    /// The keys of a script's `keys` string, in order.
    static func parse(_ keys: String) -> [DemoKey] { keys.map(DemoKey.init) }

    /// The key is the restore toggle.
    var isToggle: Bool { event == .restoreToggle }
}
