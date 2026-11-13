// SPDX-License-Identifier: LicenseRef-App-Pending
//
// One fixture per macro import format (PRD-R32), each with valid rows and deliberately invalid ones so the
// tests can check line numbers and reasons (PRD-R70, PRD-R43). The Text Replacements shape follows the file
// System Settings writes when entries are dragged out (VERIFY on macOS 27, contracts.md 7.3).

import Foundation

enum MacroFixtures {
    /// Line 1 comment, 2 valid, 3 blank, 4 escapes, 5 no tab, 6 Vietnamese shortcut, 7 empty expansion,
    /// 8 shortcut with leading spaces (trimmed), 9 33-character shortcut.
    static let tabSeparated =
        [
            "# shortcut<TAB>expansion",
            "vn\tViệt Nam",
            "",
            "dc\tđịa chỉ:\\n123 Lê Lợi\\tQ1\\\\",
            "no tab here",
            "đc\tđược",
            "empty\t",
            "  sp\tspaced",
            String(repeating: "x", count: 33) + "\ttoo long",
        ].joined(separator: "\n") + "\n"

    /// Header row skipped; the record starting on line 3 spans two lines; line 5 escapes quotes; line 6 has an
    /// extra column; line 7 lacks the expansion; line 8 has an unterminated quote.
    static let csv = #"""
        shortcut,expansion
        vn,Việt Nam
        addr,"12 Lê Lợi,
        Quận 1"
        q,"say ""hi"""
        bad,one,two
        lonely
        open,"never closed
        """#

    static let textReplacementsXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
        \t<dict>
        \t\t<key>phrase</key>
        \t\t<string>Việt Nam</string>
        \t\t<key>shortcut</key>
        \t\t<string>vn</string>
        \t</dict>
        \t<dict>
        \t\t<key>phrase</key>
        \t\t<string>On my way!</string>
        \t\t<key>shortcut</key>
        \t\t<string>omw</string>
        \t</dict>
        \t<dict>
        \t\t<key>phrase</key>
        \t\t<string>no shortcut</string>
        \t</dict>
        \t<string>not a dictionary</string>
        </array>
        </plist>
        """

    static let appExport = #"""
        {
          "kind": "settings-export",
          "schemaVersion": 1,
          "macros": [
            { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "trigger": "vn", "expansion": "Việt Nam",
              "adaptCase": true, "enabled": true },
            { "trigger": "kg", "expansion": "không", "adaptCase": false, "enabled": false },
            { "trigger": "with space", "expansion": "x" },
            42
          ]
        }
        """#

    static let bareMacrosJSON = #"""
        { "schemaVersion": 1, "writtenBy": "0.1.0",
          "macros": [ { "trigger": "ty", "expansion": "cảm ơn" } ] }
        """#

    static func binaryPlist(_ entries: [[String: String]]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: entries, format: .binary, options: 0)
    }
}
