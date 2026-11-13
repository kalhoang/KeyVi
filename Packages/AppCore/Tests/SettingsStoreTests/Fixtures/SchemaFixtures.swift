// SPDX-License-Identifier: GPL-3.0-or-later
//
// One fixture per released schema version of every settings file (PLT-R1005, QA-R41). Kept as Swift literals
// because the frozen test target declares no resources. When a schema version ships, its files are copied here
// verbatim and never edited again; the load-migrate-compare test walks `SchemaFixtures.released`.
// Bundle IDs below are test fixtures (PLT-R501 allows them only in fixtures and compat/*.json).

import Foundation

enum SchemaFixtures {
    struct Release {
        var schemaVersion: Int
        var settings: String
        var appModes: String
        var ruleOverrides: String
        var macros: String
    }

    static let released: [Release] = [v1]

    static let v1 = Release(
        schemaVersion: 1,
        settings: #"""
            {
              "schemaVersion": 1,
              "writtenBy": "0.1.0",
              "settings": {
                "typingMethod": "vni",
                "tonePlacement": "traditional",
                "restoreHotkey": null,
                "toggleHotkey": { "type": "keyCombo", "modifiers": 9, "keyCode": 49, "futureHotkeyField": 7 },
                "layoutBinding": { "enabled": true, "vietnamese": ["com.apple.keylayout.ABC"], "english": [] },
                "futureSettingFromNewerBuild": "kept"
              },
              "englishRestoreLists": { "keepAsTyped": ["tex"], "keepVietnamese": ["mas"], "futureList": [1] },
              "optedInRules": ["chromium.ax-enable"],
              "onboarding": { "completedVersion": "0.1.0", "futureStep": 3 },
              "futureKeyFromNewerBuild": { "kept": true }
            }
            """#,
        appModes: #"""
            {
              "schemaVersion": 1,
              "writtenBy": "0.1.0",
              "globalMode": "en",
              "apps": [
                { "bundle": "com.example.Terminal", "mode": "en", "futureEntryKey": "x" },
                { "bundle": "com.example.Chat", "rule": "alwaysVietnamese" },
                { "bundle": "com.example.Editor", "rule": "ignore", "mode": "vi" },
                { "bundle": "sha256:4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c4f1c", "mode": "en" }
              ],
              "futureTopLevel": 1
            }
            """#,
        ruleOverrides: #"""
            {
              "schemaVersion": 1,
              "writtenBy": "0.1.0",
              "overrides": [
                {
                  "createdAt": "2026-11-13T09:00:00Z",
                  "rule": { "id": "user.paste.1", "match": { "bundle": "com.example.Editor" }, "strategy": "paste" },
                  "futureOverrideKey": true
                }
              ]
            }
            """#,
        macros: #"""
            {
              "schemaVersion": 1,
              "writtenBy": "0.1.0",
              "macros": [
                { "id": "6F9619FF-8B86-D011-B42D-00C04FC964FF", "trigger": "vn", "expansion": "Việt Nam",
                  "adaptCase": true, "enabled": true, "futureMacroKey": "x" },
                { "id": "7F9619FF-8B86-D011-B42D-00C04FC964FF", "trigger": "@@", "expansion": "pa@example.com",
                  "adaptCase": false, "enabled": false }
              ]
            }
            """#)

    /// A synthetic pre-release version 0 used only to exercise the migration machinery while every file is
    /// at version 1: `TestMigrations.zeroToOne` renames `prefs` to `settings` and `method` to `typingMethod`.
    static let v0Settings = #"""
        {
          "schemaVersion": 0,
          "writtenBy": "0.0.1",
          "prefs": { "method": "vni", "englishRestore": false },
          "unknownFromV0": [1, 2]
        }
        """#
}
