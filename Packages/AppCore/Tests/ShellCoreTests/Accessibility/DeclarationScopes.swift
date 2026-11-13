// SPDX-License-Identifier: LicenseRef-App-Pending
//
// The function-like declarations (`func`, `init`, computed `var`) of a Swift source and the brace-delimited range
// of each, so a source audit can ask what the innermost declaration around a call site contains (PRD-R67: every
// animation call site checks Reduce Motion). Works on code stripped by `SwiftCodeText`, so braces in literals and
// comments do not count.

struct DeclarationScopes {
    struct Scope {
        var name: String
        var range: Range<Int>  // character offsets of the block, braces included
    }

    let code: [Character]
    let scopes: [Scope]

    init(code text: String) {
        code = Array(text)
        var found: [Scope] = []
        var open: [(name: String?, start: Int)] = []
        var header = ""
        for (offset, character) in code.enumerated() {
            switch character {
            case "{":
                open.append((Self.declarationName(header), offset))
                header = ""
            case "}":
                if let last = open.popLast(), let name = last.name {
                    found.append(Scope(name: name, range: last.start..<(offset + 1)))
                }
                header = ""
            case ";":
                header = ""
            default:
                header.append(character)
            }
        }
        scopes = found
    }

    /// The name a block header declares when the block is a function body, an initialiser or a computed property.
    static func declarationName(_ header: String) -> String? {
        // The header is everything since the previous brace, so stored properties may precede the declaration.
        if let match = header.matches(of: /\bfunc\s+(\w+)/).last { return String(match.output.1) }
        if header.contains(/\b(init|deinit)\b/) { return "init" }
        if let match = header.matches(of: /\bvar\s+(\w+)\s*:[^=]*$/).last { return String(match.output.1) }
        return nil
    }

    /// The innermost declaration whose block contains `offset`.
    func enclosing(_ offset: Int) -> Scope? {
        scopes.filter { $0.range.contains(offset) }.min { $0.range.count < $1.range.count }
    }

    func text(of scope: Scope) -> String { String(code[scope.range]) }

    /// 1-based line number of `offset`.
    func line(of offset: Int) -> Int { code[..<offset].filter { $0 == "\n" }.count + 1 }
}
