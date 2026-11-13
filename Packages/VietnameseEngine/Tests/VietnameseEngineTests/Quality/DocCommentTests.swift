// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing

/// Every public declaration of the engine and of its test-support library carries a DocC comment (`///`
/// on the line before it, attributes skipped).
@Suite("Documentation of the public API")
struct DocCommentTests {
    static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    static let declaration = try? NSRegularExpression(
        pattern:
            #"^\s*public (static |mutating |final |private\(set\) |nonmutating )*(func|var|let|init|struct|enum|class|protocol|typealias|subscript)\b"#
    )

    static func undocumented(in target: String) throws -> [String] {
        let folder = packageRoot.appendingPathComponent("Sources/\(target)")
        let names = (FileManager.default.enumerator(atPath: folder.path)?.compactMap { $0 as? String } ?? [])
            .filter { $0.hasSuffix(".swift") }.sorted()
        var missing: [String] = []
        for name in names {
            let lines = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
                .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, line) in lines.enumerated() {
                let range = NSRange(line.startIndex..., in: line)
                guard Self.declaration?.firstMatch(in: line, range: range) != nil else { continue }
                var previous = index - 1
                while previous >= 0, lines[previous].trimmingCharacters(in: .whitespaces).hasPrefix("@") {
                    previous -= 1
                }
                if previous < 0 || !lines[previous].trimmingCharacters(in: .whitespaces).hasPrefix("///") {
                    missing.append("\(target)/\(name):\(index + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        return missing
    }

    @Test(arguments: ["VietnameseEngine", "VietnameseEngineTesting"])
    func everyPublicDeclarationIsDocumented(_ target: String) throws {
        #expect(Self.declaration != nil)
        let missing = try Self.undocumented(in: target)
        #expect(missing.isEmpty, "\(missing.joined(separator: "\n"))")
    }
}
