// SPDX-License-Identifier: LicenseRef-App-Pending
//
// Readable rendering of a typing trace, reviewed by the user before export (PLT-R905). One line per record:
// time since start, what happened, key code, modifiers, the layout character and the outcome. Control
// characters are shown as `U+XXXX` so the text stays one line per record.

internal import AppModel
internal import Foundation

enum CaptureRendering {
    private struct Labels {
        var title: String
        var startedAt: String
        var engine: String
        var deleteWord: String
        var insertWord: String
        var job: String
        var focus: String
        var gap: String
        var gapTail: String
        var end: String
    }

    private static let vietnamese = Labels(
        title: "Bản ghi thao tác gõ", startedAt: "Bắt đầu lúc", engine: "bộ gõ", deleteWord: "xoá",
        insertWord: "chèn", job: "lệnh chèn", focus: "ô nhập", gap: "khoảng trống đến",
        gapTail: "không ghi lại gì", end: "kết thúc")
    private static let english = Labels(
        title: "Typing trace", startedAt: "Started at", engine: "engine", deleteWord: "delete",
        insertWord: "insert", job: "job", focus: "focus", gap: "gap until", gapTail: "nothing recorded",
        end: "end")

    static func render(_ data: Data, language: InterfaceLanguage) -> String {
        let labels = language == .vietnamese ? vietnamese : english
        var output: [String] = []
        for line in CaptureFiles.decode(data) {
            if let text = describe(line, labels: labels) { output.append(text) }
        }
        return output.joined(separator: "\n") + "\n"
    }

    private static func describe(_ line: CaptureLine, labels: Labels) -> String? {
        let time = line.t.map(seconds) ?? String(repeating: " ", count: 9)
        switch line.type {
        case .session:
            return labels.title + " " + (line.id ?? "") + "\n" + labels.startedAt + ": "
                + (line.startedAt?.formatted(.iso8601) ?? "")
        case .key:
            let character = line.char.map { "\"" + visible($0) + "\"" } ?? "-"
            return [
                time, line.event ?? "", hex(line.keyCode ?? 0), modifiers(line.flags ?? 0), character,
                line.outcome ?? "",
            ]
            .joined(separator: "  ")
        case .engine:
            return [
                time, labels.engine, labels.deleteWord + " " + String(line.delete ?? 0),
                labels.insertWord + " \"" + visible(line.insert ?? "") + "\"",
            ].joined(separator: "  ")
        case .job:
            return [
                time, labels.job + " " + String(line.sequence ?? 0), line.strategy ?? "",
                String(line.durationUs ?? 0) + " µs", line.outcome ?? "",
            ].joined(separator: "  ")
        case .focus:
            return [time, labels.focus, line.bundle ?? "-", line.role ?? "-", line.subrole ?? "-"].joined(
                separator: "  ")
        case .gap:
            return time + "  " + labels.gap + " " + (line.to.map(seconds) ?? "?") + " (" + (line.reason ?? "") + "): "
                + labels.gapTail
        case .end:
            return time + "  " + labels.end + " (" + (line.reason ?? "") + ")"
        }
    }

    /// `+12.345 s`.
    static func seconds(_ microseconds: UInt64) -> String {
        let millis = microseconds / 1_000
        let fraction = String(millis % 1_000)
        return "+" + String(millis / 1_000) + "." + String(repeating: "0", count: 3 - fraction.count) + fraction + " s"
    }

    static func hex(_ keyCode: UInt16) -> String {
        let digits = String(keyCode, radix: 16)
        return "0x" + String(repeating: "0", count: max(0, 2 - digits.count)) + digits
    }

    /// Modifier names from the CGEventFlags device-independent bits; `-` when none is held.
    static func modifiers(_ flags: UInt64) -> String {
        let names: [(UInt64, String)] = [
            (1 << 16, "caps"), (1 << 17, "shift"), (1 << 18, "ctrl"), (1 << 19, "opt"), (1 << 20, "cmd"),
            (1 << 23, "fn"),
        ]
        let held = names.filter { flags & $0.0 != 0 }.map(\.1)
        return held.isEmpty ? "-" : held.joined(separator: "+")
    }

    /// Control characters and separators as `U+XXXX`, everything else unchanged.
    static func visible(_ text: String) -> String {
        var output = ""
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator, .format:
                let digits = String(scalar.value, radix: 16, uppercase: true)
                output += "U+" + String(repeating: "0", count: max(0, 4 - digits.count)) + digits
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        return output
    }
}
