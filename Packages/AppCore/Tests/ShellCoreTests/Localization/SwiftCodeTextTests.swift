// SPDX-License-Identifier: GPL-3.0-or-later
//
// The literal and comment stripper the source audits rely on (PRD-R62, PRD-R67).

import Testing

@Suite struct SwiftCodeTextTests {
    @Test func blanksLiteralsAndCommentsButKeepsCode() {
        let source = "case cancel = \"common.cancel\" // .close\nlet x = a.b /* .c /* .d */ */ + e.f"
        let code = SwiftCodeText.strip(source)
        #expect(!code.contains("common") && !code.contains(".close") && !code.contains(".c") && !code.contains(".d"))
        #expect(code.contains("case cancel = \"") && code.contains("a.b") && code.contains("e.f"))
        #expect(code.split(separator: "\n", omittingEmptySubsequences: false).count == 2)
    }

    @Test func keepsInterpolatedCode() {
        let code = SwiftCodeText.strip("let s = \"left \\(t(CommonText.cancel)) right\" + z.w")
        #expect(code.contains("CommonText.cancel") && code.contains("z.w"))
        #expect(!code.contains("left") && !code.contains("right"))
    }

    @Test func handlesEscapesAndMultilineLiterals() {
        let code = SwiftCodeText.strip("let a = \"q\\\"uote.x\"\nlet b = \"\"\"\n  \"line.one\"\n  \"\"\"\nc.d")
        #expect(!code.contains("uote") && !code.contains("line") && code.contains("c.d"))
    }
}
