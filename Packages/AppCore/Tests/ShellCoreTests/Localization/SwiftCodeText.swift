// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The code of a Swift source with comments and string-literal contents blanked out, so the source scans of the
// catalog and accessibility audits (PRD-R62, PRD-R67) see what the program does, not what its text says. A raw
// value such as `case cancel = "common.cancel"` is not a use of `.cancel`; an interpolation inside a literal
// (`"\(CommonText.cancel)"`) still is.

enum SwiftCodeText {
    private enum Mode {
        case code
        case string(multiline: Bool)
        case lineComment
        case blockComment(depth: Int)
    }

    /// `text` with the same line structure, where every character of a comment or of a literal (outside
    /// interpolations) is replaced by a space and every quote is kept.
    static func strip(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(characters.count)
        var mode = Mode.code
        // One entry per open interpolation: the open parentheses inside it and whether its literal is multiline.
        var interpolations: [(depth: Int, multiline: Bool)] = []
        var index = 0
        func peek(_ offset: Int) -> Character? {
            index + offset < characters.count ? characters[index + offset] : nil
        }
        func blank(_ character: Character) { output.append(character == "\n" ? "\n" : " ") }
        while index < characters.count {
            let character = characters[index]
            switch mode {
            case .code:
                if character == "/", peek(1) == "/" {
                    mode = .lineComment
                    blank(character)
                } else if character == "/", peek(1) == "*" {
                    mode = .blockComment(depth: 1)
                    output += "  "
                    index += 1
                } else if character == "\"" {
                    let multiline = peek(1) == "\"" && peek(2) == "\""
                    mode = .string(multiline: multiline)
                    output += multiline ? "\"\"\"" : "\""
                    index += multiline ? 2 : 0
                } else if !interpolations.isEmpty, character == "(" {
                    interpolations[interpolations.count - 1].depth += 1
                    output.append(character)
                } else if !interpolations.isEmpty, character == ")" {
                    interpolations[interpolations.count - 1].depth -= 1
                    output.append(character)
                    if interpolations[interpolations.count - 1].depth == 0 {
                        mode = .string(multiline: interpolations.removeLast().multiline)
                    }
                } else {
                    output.append(character)
                }
            case .string(let multiline):
                if character == "\\", peek(1) == "(" {
                    interpolations.append((depth: 1, multiline: multiline))
                    mode = .code
                    output += " ("
                    index += 1
                } else if character == "\\" {
                    blank(character)
                    if let next = peek(1) { blank(next) }
                    index += 1
                } else if character == "\"", !multiline || (peek(1) == "\"" && peek(2) == "\"") {
                    mode = .code
                    output += multiline ? "\"\"\"" : "\""
                    index += multiline ? 2 : 0
                } else {
                    blank(character)
                }
            case .lineComment:
                if character == "\n" { mode = .code }
                blank(character)
            case .blockComment(let depth):
                if character == "*", peek(1) == "/" {
                    mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    output += "  "
                    index += 1
                } else if character == "/", peek(1) == "*" {
                    mode = .blockComment(depth: depth + 1)
                    output += "  "
                    index += 1
                } else {
                    blank(character)
                }
            }
            index += 1
        }
        return output
    }
}
