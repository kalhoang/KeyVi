// SPDX-License-Identifier: MPL-2.0
import EngineFuzzTarget
import Foundation
import Testing
import VietnameseEngine

/// QA-R9: the committed seed corpus replays with no broken invariant, and the header byte reaches every
/// option.
@Suite("Fuzz seed corpus (QA-R9)")
struct SeedCorpusTests {
    static let corpus = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Corpus")

    @Test func seedsReplay() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: Self.corpus.path).filter { !$0.hasPrefix(".") }
        #expect(names.count >= 10)
        for name in names {
            let bytes = [UInt8](try Data(contentsOf: Self.corpus.appendingPathComponent(name)))
            let violation = FuzzTarget.run(bytes)
            #expect(violation == nil, "\(name): \(String(describing: violation))")
        }
    }

    @Test func headerByteCoversEveryOption() {
        let configurations = (0..<256).map(FuzzTarget.configuration)
        #expect(configurations.contains { $0.inputMethod == .vni })
        #expect(
            configurations.contains { $0.inputMethod == .telex(TelexOptions(standaloneW: false, bracketKeys: true)) })
        #expect(configurations.contains { $0.toneStyle == .modern && !$0.autoRestore && $0.appContext == .code })
        #expect(configurations.contains { $0.historyLimit == 1 })
        #expect(FuzzTarget.run([]) == nil && FuzzTarget.run([0x40]) == nil)
    }
}
