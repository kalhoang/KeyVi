// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guest tool of scripts/vm/upgrade-test.sh (QA-R40, PLT-R1108, docs/runbooks/vm-test-lab.md section 12): writes and
// reads the settings folder through the app's own `SettingsStore`, so the files on disk are the ones a user of that
// version has. scripts/vm/guest/upgrade-guest.sh builds it twice inside the VM: against the AppCore package of the
// previous stable (the commit in its build-info.json) to seed the settings before the update, and against this
// commit's AppCore to read them back as the candidate does. It uses only API that both versions have.
//
// Usage (inside the VM only; it refuses a real Mac):
//   upgrade-store seed --dir DIR --written-by VERSION --plan PLAN.json --channel stable|beta
//       Loads DIR (the app's Application Support folder), applies the plan (settings, word lists, learned words,
//       per-app memory and rules, compatibility overrides, macros, onboarding finished) through the store's own
//       update calls and flushes. The app must not be running.
//   upgrade-store set-channel --dir DIR --written-by VERSION --channel stable|beta
//       D21 only (the channel switch check of release.md section 5 item 3). The app must not be running.
//   upgrade-store dump --dir DIR
//       Prints what the store reads from DIR as canonical JSON (sorted keys and sets). Run it on a COPY of a
//       snapshot: a load writes when it migrates or recovers a file (SettingsStore+Load.swift).
// Exit status: 0 done, 1 failure, 2 usage error, 3 refused (not a VM).
// The plan's macro bodies are fixture text (scripts/vm/fixtures/upgrade-plan.json), never a user's content.

import AppModel
import Darwin
import Dispatch
import Foundation
import SettingsStore

func insideVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("upgrade-store: " + message + "\n").utf8))
    exit(code)
}

/// The guard's key-value store lives in memory: the tool must never touch the app's user defaults domain.
final class MemoryKeyValues: KeyValueStore, @unchecked Sendable {
    private let lock = NSLock()
    private var integers: [String: Int] = [:]
    private var doubles: [String: Double] = [:]
    func integer(forKey key: String) -> Int { locked { integers[key] ?? 0 } }
    func set(_ value: Int, forKey key: String) { locked { integers[key] = value } }
    func double(forKey key: String) -> Double { locked { doubles[key] ?? 0 } }
    func set(_ value: Double, forKey key: String) { locked { doubles[key] = value } }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

struct Arguments {
    var command = ""
    var values: [String: String] = [:]

    init(_ raw: [String]) {
        guard let first = raw.first else { return }
        command = first
        var index = 1
        while index < raw.count {
            let key = raw[index]
            guard key.hasPrefix("--"), index + 1 < raw.count else { fail("bad argument: \(key)", code: 2) }
            values[String(key.dropFirst(2))] = raw[index + 1]
            index += 2
        }
    }

    func required(_ key: String) -> String {
        guard let value = values[key], !value.isEmpty else { fail("--\(key) is required", code: 2) }
        return value
    }
}

func makeStore(directory: String, writtenBy: String) -> SettingsStore {
    let queue = DispatchQueue(label: "upgrade-store.utility", qos: .utility)
    return SettingsStore(
        location: StorageLocation(directory: URL(fileURLWithPath: directory, isDirectory: true)),
        fileSystem: LocalFileSystem(), wallClock: SystemWallClock(), writtenBy: writtenBy, queue: queue,
        launchGuard: LaunchGuard(store: MemoryKeyValues()), onChange: { _ in })
}

// MARK: - Plan

func typed<T: Decodable>(_ value: JSONValue, as type: T.Type, key: String) -> T {
    do {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(T.self, from: data)
    } catch {
        fail("plan value of \(key) is not a \(T.self): \(error)", code: 2)
    }
}

func bundleKey(_ raw: String) -> BundleKey {
    guard let key = BundleKey(rawValue: raw) else { fail("invalid bundle key in the plan: \(raw)", code: 2) }
    return key
}

/// One explicit choice of the plan, written through the typed `UserSettings` field (PRD-R6: `set`, never `unset`).
func apply(setting key: String, value: JSONValue, to user: inout UserSettings) {
    switch key {
    case "typingMethod": user.typingMethod = .set(typed(value, as: TypingMethod.self, key: key))
    case "tonePlacement": user.tonePlacement = .set(typed(value, as: TonePlacement.self, key: key))
    case "englishRestore": user.englishRestore = .set(typed(value, as: Bool.self, key: key))
    case "telexStandaloneW": user.telexStandaloneW = .set(typed(value, as: Bool.self, key: key))
    case "telexBracketKeys": user.telexBracketKeys = .set(typed(value, as: Bool.self, key: key))
    case "restoreHotkey":
        if case .null = value {
            user.restoreHotkey = .set(nil)
        } else {
            user.restoreHotkey = .set(typed(value, as: HotkeyBinding.self, key: key))
        }
    case "macrosEnabled": user.macrosEnabled = .set(typed(value, as: Bool.self, key: key))
    case "macrosInEnglishMode": user.macrosInEnglishMode = .set(typed(value, as: Bool.self, key: key))
    case "toggleHotkey": user.toggleHotkey = .set(typed(value, as: HotkeyBinding.self, key: key))
    case "rememberPerApp": user.rememberPerApp = .set(typed(value, as: Bool.self, key: key))
    case "firstSeenAppMode": user.firstSeenAppMode = .set(typed(value, as: FirstSeenMode.self, key: key))
    case "showSwitchIndicator": user.showSwitchIndicator = .set(typed(value, as: Bool.self, key: key))
    case "soundOnSwitch": user.soundOnSwitch = .set(typed(value, as: Bool.self, key: key))
    case "clickIconToToggle": user.clickIconToToggle = .set(typed(value, as: Bool.self, key: key))
    case "interfaceLanguage": user.interfaceLanguage = .set(typed(value, as: InterfaceLanguage.self, key: key))
    case "automaticallyCheckForUpdates":
        user.automaticallyCheckForUpdates = .set(typed(value, as: Bool.self, key: key))
    case "automaticallyInstallUpdates":
        user.automaticallyInstallUpdates = .set(typed(value, as: Bool.self, key: key))
    case "updateChannel": user.updateChannel = .set(typed(value, as: UpdateChannel.self, key: key))
    case "learnCollisionChoices": user.learnCollisionChoices = .set(typed(value, as: Bool.self, key: key))
    case "lookaheadRevision": user.lookaheadRevision = .set(typed(value, as: Bool.self, key: key))
    default: fail("the plan names a setting this tool does not know: \(key)", code: 2)
    }
}

struct Plan {
    var object: [String: JSONValue]

    init(path: String) {
        guard let data = FileManager.default.contents(atPath: path),
            let value = try? JSONDecoder().decode(JSONValue.self, from: data), let object = value.objectValue
        else { fail("cannot read the plan \(path)", code: 2) }
        self.object = object
    }

    func array(_ key: String) -> [JSONValue] {
        guard case .array(let items)? = object[key] else { return [] }
        return items
    }

    func strings(_ key: String) -> Set<String> { Set(array(key).compactMap(\.stringValue)) }
}

func channel(_ raw: String) -> UpdateChannel {
    guard let value = UpdateChannel(rawValue: raw) else { fail("--channel must be stable or beta", code: 2) }
    return value
}

func seed(_ arguments: Arguments) async {
    let directory = arguments.required("dir")
    let plan = Plan(path: arguments.required("plan"))
    let writtenBy = arguments.required("written-by")
    let chosenChannel = channel(arguments.required("channel"))
    let store = makeStore(directory: directory, writtenBy: writtenBy)
    let loaded = await store.load()
    guard !loaded.safeMode, loaded.readOnlyFiles.isEmpty else { fail("the store loaded in safe or read-only mode") }

    var user = loaded.user
    for (key, value) in plan.object["settings"]?.objectValue ?? [:] { apply(setting: key, value: value, to: &user) }
    user.updateChannel = .set(chosenChannel)
    user.keepAsTyped = plan.strings("keepAsTyped")
    user.keepVietnamese = plan.strings("keepVietnamese")
    user.learnedWords = Set(
        plan.array("learnedWords").map { item in
            let list = RestoreList(rawValue: item["list"]?.stringValue ?? "") ?? .keepAsTyped
            return LearnedWord(
                list: list, raw: item["raw"]?.stringValue ?? "", app: bundleKey(item["app"]?.stringValue ?? ""))
        })
    // Onboarding finished in the previous version, as on a Mac that used it (PRD-R42).
    user.onboarding.completedVersion = writtenBy
    let finalUser = user
    await store.updateSettings { $0 = finalUser }

    // Per-app memory first (recordAppModes keeps explicit rules), then the explicit rules (PRD-R21, PLT-R392).
    let global = TypingMode(rawValue: plan.object["globalMode"]?.stringValue ?? "vi") ?? .vietnamese
    let remembered = plan.array("rememberedModes").map { item in
        AppModeEntry(
            bundle: bundleKey(item["bundle"]?.stringValue ?? ""),
            mode: TypingMode(rawValue: item["mode"]?.stringValue ?? ""))
    }
    await store.recordAppModes(AppModesDocument(globalMode: global, apps: remembered))
    for item in plan.array("appRules") {
        guard let rule = PerAppRule(rawValue: item["rule"]?.stringValue ?? "") else {
            fail("bad per-app rule", code: 2)
        }
        await store.setAppRule(rule, for: bundleKey(item["bundle"]?.stringValue ?? ""))
    }

    let formatter = ISO8601DateFormatter()
    for item in plan.array("ruleOverrides") {
        guard let created = formatter.date(from: item["createdAt"]?.stringValue ?? ""), let rule = item["rule"] else {
            fail("bad rule override in the plan", code: 2)
        }
        await store.addRuleOverride(StoredRuleOverride(createdAt: created, rule: rule))
    }

    let macros = plan.array("macros").map { item -> StoredMacro in
        guard let id = UUID(uuidString: item["id"]?.stringValue ?? "") else { fail("bad macro id", code: 2) }
        return StoredMacro(
            id: id, trigger: item["trigger"]?.stringValue ?? "", expansion: item["expansion"]?.stringValue ?? "",
            adaptCase: item["adaptCase"] == .bool(true), enabled: item["enabled"] == .bool(true))
    }
    await store.replaceMacros(macros)
    await store.flush()
    let state = await store.state
    let summary: [String: Any] = [
        "explicitSettings": state.user.explicitlySetKeys, "appEntries": state.appModes.apps.count,
        "ruleOverrides": state.ruleOverrides.count, "macros": state.macros.count,
    ]
    print(String(data: try! JSONSerialization.data(withJSONObject: summary, options: [.sortedKeys]), encoding: .utf8)!)
}

func setChannel(_ arguments: Arguments) async {
    let store = makeStore(directory: arguments.required("dir"), writtenBy: arguments.required("written-by"))
    let loaded = await store.load()
    guard !loaded.safeMode, loaded.readOnlyFiles.isEmpty else { fail("the store loaded in safe or read-only mode") }
    let chosen = channel(arguments.required("channel"))
    await store.updateSettings { $0.updateChannel = .set(chosen) }
    await store.flush()
    print("updateChannel=" + chosen.rawValue)
}

// MARK: - Dump

/// A value as stable text: sets sorted, everything else by its description (the same type names in both builds).
func describe(_ value: Any) -> Any {
    if let set = value as? Set<String> { return set.sorted() }
    if let set = value as? Set<LearnedWord> {
        return set.sorted().map { "\($0.list.rawValue):\($0.raw)@\($0.app.rawValue)" }
    }
    if let set = value as? Set<RuleID> { return set.map(\.rawValue).sorted() }
    return String(describing: value)
}

func jsonText(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(data: (try? encoder.encode(value)) ?? Data(), encoding: .utf8) ?? ""
}

func dumpStore(_ arguments: Arguments) async {
    let store = makeStore(directory: arguments.required("dir"), writtenBy: "upgrade-store-dump")
    let state = await store.load()
    var user: [String: Any] = [:]
    for child in Mirror(reflecting: state.user).children {
        guard let label = child.label else { continue }
        user[label] = describe(child.value)
    }
    let apps = state.appModes.apps.map { entry -> [String: Any] in
        [
            "bundle": entry.bundle.rawValue, "rule": entry.rule?.rawValue ?? NSNull(),
            "mode": entry.mode?.rawValue ?? NSNull(),
        ]
    }
    let overrides = state.ruleOverrides.map { override -> [String: Any] in
        ["createdAt": ISO8601DateFormatter().string(from: override.createdAt), "rule": jsonText(override.rule)]
    }
    let macros = state.macros.map { macro -> [String: Any] in
        [
            "id": macro.id.uuidString, "trigger": macro.trigger, "expansion": macro.expansion,
            "adaptCase": macro.adaptCase, "enabled": macro.enabled,
        ]
    }
    let output: [String: Any] = [
        "user": user, "explicitSettings": state.user.explicitlySetKeys,
        "appModes": ["globalMode": state.appModes.globalMode.rawValue, "apps": apps],
        "ruleOverrides": overrides, "macros": macros, "safeMode": state.safeMode,
        "readOnlyFiles": state.readOnlyFiles.map(\.rawValue).sorted(),
        "notices": state.notices.map { String(describing: $0) }.sorted(),
    ]
    let data = try! JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
    print(String(data: data, encoding: .utf8)!)
}

guard insideVirtualMachine() else { fail("refusing: not inside a virtual machine", code: 3) }
let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
switch arguments.command {
case "seed": await seed(arguments)
case "set-channel": await setChannel(arguments)
case "dump": await dumpStore(arguments)
default: fail("usage: upgrade-store seed|set-channel|dump --dir DIR ... (see the header)", code: 2)
}
