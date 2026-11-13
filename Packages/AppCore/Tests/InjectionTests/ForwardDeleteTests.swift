// SPDX-License-Identifier: LicenseRef-App-Pending
//
// PLT-R407: no strategy ever posts the forward-delete key (kVK_ForwardDelete, 0x75). Checked statically over
// the Injection sources and exhaustively over every executor, completion mode and edit shape.

import AppModel
import Foundation
import RealtimeSupport
import TestSupport
import Testing

@testable import Injection

@Suite struct ForwardDeleteTests {
    private static var injectionSources: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Injection")
    }

    /// Static: no Injection source names the forward-delete key code.
    @Test func noSourceReferencesTheForwardDeleteKeyPLTR407() throws {
        let files = try #require(
            FileManager.default.enumerator(at: Self.injectionSources, includingPropertiesForKeys: nil)
        )
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        #expect(files.count >= 10)
        let forbidden = try Regex(#"\.forwardDelete\b|0x75\b|\b117\b"#)
        for file in files {
            let source = try String(contentsOf: file, encoding: .utf8)
            #expect(source.firstMatch(of: forbidden) == nil, "\(file.lastPathComponent) references forward delete")
        }
    }

    /// Exhaustive: every executor, completion mode, AX behaviour and edit shape posts only backspace, Shift+Left,
    /// Command+V and Unicode events.
    @Test func noExecutorPostsForwardDeletePLTR407() {
        let behaviours: [FakeFocusedFieldAccess.Behaviour] = [.normal, .timeout, .unavailable, .writesIgnored]
        for strategy in InjectionStrategy.allCases {
            for mode in InlineCompletionMode.allCases {
                for behaviour in behaviours {
                    for deleteCount in 0...3 {
                        for insertion in ["", "á", "ường", String(repeating: "đ", count: 70)] {
                            let posted = post(strategy, mode, behaviour, deleteCount, insertion)
                            #expect(!posted.contains { $0.keyCode == .forwardDelete })
                        }
                    }
                }
            }
        }
    }

    private func post(
        _ strategy: InjectionStrategy, _ mode: InlineCompletionMode, _ behaviour: FakeFocusedFieldAccess.Behaviour,
        _ deleteCount: Int, _ insertion: String
    ) -> [SyntheticKeyEvent] {
        let field = SimulatedTextField(behaviour: .inlineCompletion(suggestions: ["abcdef"]), text: "abc")
        let poster = InjectionFieldWiring.poster(for: field, layout: InjectionTestLayouts.qwerty())
        let environment = FakeInjectionEnvironment(
            poster: poster, clock: ManualClock(),
            fieldAccess: FakeFocusedFieldAccess(field: field, behaviour: behaviour),
            pasteboard: FakePasteboard())
        let parameters = Fixture.parameters {
            $0.inlineCompletion = mode
            $0.pasteOptedIn = true
            $0.allowMultiCharEvents = true
        }
        let job = Fixture.job(
            deleteCount: deleteCount, insertion: insertion, plan: Fixture.plan(strategy, parameters: parameters))
        _ = StrategyCatalog.executor(for: strategy).execute(job, in: environment)
        return poster.posted.compactMap(\.synthetic)
    }
}
