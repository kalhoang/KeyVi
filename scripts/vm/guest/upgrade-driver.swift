// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guest tool of scripts/vm/upgrade-test.sh (QA-R40, PLT-R1108, spec/02-platform.md 13.5 and 13.7,
// docs/runbooks/vm-test-lab.md section 12): drives the release build and Sparkle's windows through accessibility,
// posts synthetic key events into TestHost and measures the relaunch after the update. Compiled and run INSIDE the
// disposable VM only (it refuses a real Mac); upgrade-guest.sh grants it Accessibility and event posting with
// grant-tcc.sh. It prints JSON on standard output and never judges: the host's scripts/vm/upgrade-report.py decides.
// Typed text is TestHost fixture text; the app's settings and macros are never read here (PLT-R901).
//
// Usage:
//   upgrade-driver menu BUNDLE --title T [--title T...] [--timeout S]
//       Opens the status item menu of BUNDLE and presses the first item whose title is one of T.
//   upgrade-driver press BUNDLE --title T [--title T...] [--timeout S] [--dump FILE] [--find-only|--close-window]
//       Waits for an enabled button titled T in a window of BUNDLE (Sparkle's windows run in the app), writes the
//       window to FILE and presses the button (not with --find-only; --close-window closes that window instead).
//   upgrade-driver windows BUNDLE                      windows of BUNDLE: titles, texts, buttons
//   upgrade-driver activate BUNDLE                     brings BUNDLE to the front
//   upgrade-driver frontmost                           the frontmost application
//   upgrade-driver type BUNDLE --field ID --keys K --expect E [--reset ID] [--seconds S]
//       Types K (a-z and space) into the field with accessibility identifier ID until it reads E, at most S seconds.
//   upgrade-driver relaunch --executable PATH --old-pid P --typing-bundle B --field ID --keys K --expect E
//                           [--reset ID] [--snapshot-src DIR --snapshot-dst DIR [--loaded-snapshot-dst DIR]]
//                           [--defaults-domain D --defaults-dst FILE] [--timeout S] [--watch S]
//       Waits for P to exit, copies DIR at once (the files as the old version left them) and exports D, waits for
//       the new process of PATH, then records when its event tap is enabled (CGGetEventTapList) and when typing into
//       the TestHost field first works, measured from the new process's start time. With --loaded-snapshot-dst it
//       copies DIR again once the new version has loaded it (0.5 s after its tap, at the latest 4 s after start).
//   upgrade-driver quit BUNDLE [--timeout S]            asks BUNDLE to quit (as Quit in its menu) and waits
//   upgrade-driver taps                                 every event tap with its process and state
//   upgrade-driver processes --executable PATH          running processes of PATH with their start times
// Exit status: 0 done, 1 not found or timed out, 2 usage error, 3 refused (not a VM), 4 not trusted for AX.

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin
import Foundation

func insideVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data(("upgrade-driver: " + message + "\n").utf8))
    exit(code)
}

guard insideVirtualMachine() else { fail("refusing: not inside a virtual machine", code: 3) }

// MARK: - Output and time

func jsonData(_ object: Any) -> Data {
    (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted])) ?? Data("{}".utf8)
}

func emit(_ object: Any) {
    FileHandle.standardOutput.write(jsonData(object))
    FileHandle.standardOutput.write(Data("\n".utf8))
}

/// Wall-clock seconds since 1970 with microseconds, the clock of `pbi_start_tvsec` and of the host's analysis.
func now() -> Double {
    var tv = timeval()
    gettimeofday(&tv, nil)
    return Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
}

func pause(_ seconds: Double) { usleep(useconds_t(max(0, seconds) * 1_000_000)) }

// MARK: - Arguments

struct Arguments {
    var positional: [String] = []
    var values: [String: [String]] = [:]
    var flags: Set<String> = []
    static let flagNames: Set<String> = ["find-only", "close-window"]

    init(_ raw: [String]) {
        var index = 0
        while index < raw.count {
            let word = raw[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if Self.flagNames.contains(name) {
                    flags.insert(name)
                    index += 1
                    continue
                }
                guard index + 1 < raw.count else { fail("\(word) needs a value", code: 2) }
                values[name, default: []].append(raw[index + 1])
                index += 2
            } else {
                positional.append(word)
                index += 1
            }
        }
    }

    func one(_ name: String) -> String? { values[name]?.last }
    func required(_ name: String) -> String {
        guard let value = one(name), !value.isEmpty else { fail("--\(name) is required", code: 2) }
        return value
    }
    func number(_ name: String, default fallback: Double) -> Double {
        guard let text = one(name) else { return fallback }
        guard let value = Double(text), value >= 0 else { fail("--\(name) must be a number", code: 2) }
        return value
    }
    func all(_ name: String) -> [String] { values[name] ?? [] }
}

// MARK: - Processes

func processIdentifiers(executable: String) -> [pid_t] {
    let capacity = Int(proc_listallpids(nil, 0)) + 64
    var pids = [pid_t](repeating: 0, count: max(capacity, 64))
    let count = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
    var found: [pid_t] = []
    var buffer = [CChar](repeating: 0, count: 4096)
    for pid in pids.prefix(max(0, count)) where pid > 0 {
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0, String(cString: buffer) == executable {
            found.append(pid)
        }
    }
    return found.sorted()
}

/// Start time of a process with microseconds (`proc_bsdinfo.pbi_start_tvsec/usec`).
func startTime(_ pid: pid_t) -> Double? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return Double(info.pbi_start_tvsec) + Double(info.pbi_start_tvusec) / 1_000_000
}

func isAlive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 || errno == EPERM }

func runningApplication(_ bundle: String) -> NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first { !$0.isTerminated }
}

// MARK: - Event taps

struct TapInfo {
    var pid: pid_t
    var enabled: Bool
    var options: UInt32
    var location: UInt32
    var json: [String: Any] {
        ["pid": Int(pid), "enabled": enabled, "listenOnly": options == 1, "location": Int(location)]
    }
}

func eventTaps() -> [TapInfo] {
    var count: UInt32 = 0
    guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return [] }
    var list = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
    guard CGGetEventTapList(count, &list, &count) == .success else { return [] }
    return list.prefix(Int(count)).map {
        TapInfo(
            pid: $0.tappingProcess, enabled: $0.enabled, options: $0.options.rawValue, location: $0.tapPoint.rawValue)
    }
}

// MARK: - Accessibility

func axApplication(_ pid: pid_t) -> AXUIElement {
    let element = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(element, 2)
    return element
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func element(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
    return (value as! AXUIElement)  // type ID checked above
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (attribute(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

func string(_ element: AXUIElement, _ name: String) -> String? { attribute(element, name) as? String }

func role(_ element: AXUIElement) -> String { string(element, kAXRoleAttribute) ?? "" }

func title(_ element: AXUIElement) -> String { string(element, kAXTitleAttribute) ?? "" }

/// Titles compared without case, with the typographic ellipsis and apostrophe of localized strings folded.
func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{2026}", with: "...").replacingOccurrences(of: "\u{2019}", with: "'")
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

func walk(_ root: AXUIElement, depth: Int = 0, maximum: Int = 30, _ visit: (AXUIElement) -> Bool) -> Bool {
    if visit(root) { return true }
    guard depth < maximum else { return false }
    for child in children(root) where walk(child, depth: depth + 1, maximum: maximum, visit) { return true }
    return false
}

func windows(of pid: pid_t) -> [AXUIElement] {
    (attribute(axApplication(pid), kAXWindowsAttribute) as? [AXUIElement]) ?? []
}

/// Texts, buttons and the default button of one window; long texts (release notes) are cut.
func describeWindow(_ window: AXUIElement) -> [String: Any] {
    var texts: [String] = []
    var buttons: [[String: Any]] = []
    _ = walk(window, maximum: 25) { item in
        switch role(item) {
        case kAXStaticTextRole:
            if let value = string(item, kAXValueAttribute), !value.isEmpty { texts.append(String(value.prefix(400))) }
        case kAXButtonRole:
            let enabled = (attribute(item, kAXEnabledAttribute) as? Bool) ?? false
            buttons.append(["title": title(item), "enabled": enabled])
        default: break
        }
        return false
    }
    let defaultButton = element(attribute(window, kAXDefaultButtonAttribute)).map(title) ?? ""
    return [
        "title": title(window), "subrole": string(window, kAXSubroleAttribute) ?? "", "texts": texts,
        "buttons": buttons, "defaultButton": defaultButton,
    ]
}

func pid(of bundle: String, timeout: Double) -> pid_t? {
    let deadline = now() + timeout
    repeat {
        if let app = runningApplication(bundle) { return app.processIdentifier }
        pause(0.1)
    } while now() < deadline
    return nil
}

func findButton(in pid: pid_t, titles: [String]) -> (button: AXUIElement, window: AXUIElement)? {
    let wanted = Set(titles.map(normalized))
    for window in windows(of: pid) {
        var found: AXUIElement?
        _ = walk(window, maximum: 25) { item in
            guard role(item) == kAXButtonRole, wanted.contains(normalized(title(item))),
                (attribute(item, kAXEnabledAttribute) as? Bool) ?? false
            else { return false }
            found = item
            return true
        }
        if let found { return (found, window) }
    }
    return nil
}

func element(identifier: String, in pid: pid_t) -> AXUIElement? {
    var found: AXUIElement?
    _ = walk(axApplication(pid)) { item in
        guard string(item, kAXIdentifierAttribute) == identifier else { return false }
        found = item
        return true
    }
    return found
}

func frontmost() -> [String: Any] {
    let system = AXUIElementCreateSystemWide()
    AXUIElementSetMessagingTimeout(system, 2)
    var pid: pid_t = 0
    if let app = element(attribute(system, kAXFocusedApplicationAttribute)) { AXUIElementGetPid(app, &pid) }
    let bundle = pid > 0 ? NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "" : ""
    return ["pid": Int(pid), "bundle": bundle]
}

func activate(_ bundle: String) {
    if (frontmost()["bundle"] as? String) == bundle { return }
    let open = Process()
    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-b", bundle]
    try? open.run()
    open.waitUntilExit()
    let deadline = now() + 1  // the system-wide focus can read empty for a moment; do not wait on it longer
    while now() < deadline, (frontmost()["bundle"] as? String) != bundle { pause(0.05) }
}

// MARK: - Keys

/// ANSI virtual key codes of the ABC layout (the input source upgrade-guest.sh selects).
let keyCodes: [Character: CGKeyCode] = [
    "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09,
    "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22,
    "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28, "n": 0x2D, "m": 0x2E, " ": 0x31,
]

/// Posted at the HID level from a HID-state source without the app's marker, so the app sees physical keys (PLT-R321).
func type(_ keys: String) {
    guard let source = CGEventSource(stateID: .hidSystemState) else { fail("no event source", code: 1) }
    for character in keys {
        guard let code = keyCodes[character] else { fail("no key code for \(character)", code: 2) }
        for down in [true, false] {
            CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap)
            pause(down ? 0.03 : 0.06)
        }
    }
}

struct TypingAttempt {
    var startedAt: Double
    var endedAt: Double
    var value: String
    var matched: Bool
    /// When the first and the last key of the attempt were posted (0 when no key was posted).
    var keysStartedAt: Double = 0
    var keysEndedAt: Double = 0
    var json: [String: Any] {
        [
            "startedAt": startedAt, "endedAt": endedAt, "value": value, "matched": matched,
            "keysStartedAt": keysStartedAt, "keysEndedAt": keysEndedAt,
        ]
    }
}

func typeOnce(bundle: String, field: String, keys: String, expect: String, reset: String?) -> TypingAttempt {
    let started = now()
    activate(bundle)
    guard let target = pid(of: bundle, timeout: 2) else {
        return TypingAttempt(startedAt: started, endedAt: now(), value: "<no process>", matched: false)
    }
    if let reset, let button = element(identifier: reset, in: target) {
        AXUIElementPerformAction(button, kAXPressAction as CFString)
    }
    guard let input = element(identifier: field, in: target) else {
        return TypingAttempt(startedAt: started, endedAt: now(), value: "<no field>", matched: false)
    }
    AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    pause(0.15)
    type(keys)
    pause(0.4)
    let value = string(input, kAXValueAttribute) ?? "<unreadable>"
    return TypingAttempt(startedAt: started, endedAt: now(), value: value, matched: value == expect)
}

/// The TestHost field of the relaunch measurement, looked up once. An attempt re-activates TestHost only when it is
/// not the frontmost app, then presses Reset fields, focuses the field, types the keys and reads the field.
final class TypingTarget {
    let bundle: String
    let field: String
    let reset: String?
    private var pid: pid_t = 0
    private var input: AXUIElement?
    private var resetButton: AXUIElement?
    private var attempts = 0

    init(bundle: String, field: String, reset: String?) {
        self.bundle = bundle
        self.field = field
        self.reset = reset
    }

    /// Finds and focuses the field; false when TestHost or the field is missing.
    func prepare() -> Bool {
        activate(bundle)
        guard let found = runningApplication(bundle)?.processIdentifier else { return false }
        pid = found
        input = element(identifier: field, in: found)
        resetButton = reset.flatMap { element(identifier: $0, in: found) }
        guard let input else { return false }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    func attempt(keys: String, expect: String) -> TypingAttempt {
        let started = now()
        if input == nil, !prepare() {
            pause(0.2)
            return TypingAttempt(startedAt: started, endedAt: now(), value: "<no field>", matched: false)
        }
        guard let input else { return TypingAttempt(startedAt: started, endedAt: now(), value: "", matched: false) }
        // The system-wide focus often reads empty while the relaunched app starts; the first attempt trusts the focus
        // prepare() set, a later one activates TestHost again.
        attempts += 1
        if attempts > 1, (frontmost()["pid"] as? Int) != Int(pid) { activate(bundle) }
        if let resetButton { AXUIElementPerformAction(resetButton, kAXPressAction as CFString) }
        AXUIElementSetAttributeValue(input, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        let keysStarted = now()
        type(keys)
        let keysEnded = now()
        pause(0.3)
        let value = string(input, kAXValueAttribute) ?? "<unreadable>"
        return TypingAttempt(
            startedAt: started, endedAt: now(), value: value, matched: value == expect, keysStartedAt: keysStarted,
            keysEndedAt: keysEnded)
    }
}

// MARK: - Commands

func menuCommand(_ arguments: Arguments, bundle: String) {
    let titles = arguments.all("title")
    guard !titles.isEmpty else { fail("--title is required", code: 2) }
    guard let target = pid(of: bundle, timeout: arguments.number("timeout", default: 10)) else {
        fail("\(bundle) is not running", code: 1)
    }
    let app = axApplication(target)
    guard let extras = element(attribute(app, "AXExtrasMenuBar")), let item = children(extras).first else {
        fail("\(bundle) has no status item", code: 1)
    }
    // The press may time out while the menu is open (AppKit tracks it in a nested loop); the menu is there all the
    // same, so the result is ignored and AXShowMenu is tried only when no menu appeared.
    AXUIElementPerformAction(item, kAXPressAction as CFString)
    func menuOpen() -> Bool { children(item).contains { role($0) == kAXMenuRole } }
    var waited = now() + 2
    while !menuOpen(), now() < waited { pause(0.1) }
    if !menuOpen() {
        AXUIElementPerformAction(item, "AXShowMenu" as CFString)
        waited = now() + 3
        while !menuOpen(), now() < waited { pause(0.1) }
    }
    let wanted = Set(titles.map(normalized))
    let deadline = now() + 3
    var seen: [String] = []
    while now() < deadline {
        for menu in children(item) where role(menu) == kAXMenuRole {
            let entries = children(menu)
            seen = entries.map(title)
            if let entry = entries.first(where: { wanted.contains(normalized(title($0))) }) {
                let pressed = title(entry)
                AXUIElementPerformAction(entry, kAXPressAction as CFString)
                emit(["pressed": pressed, "at": now(), "items": seen.filter { !$0.isEmpty }])
                return
            }
            AXUIElementPerformAction(menu, kAXCancelAction as CFString)
            emit(["pressed": NSNull(), "items": seen.filter { !$0.isEmpty }])
            exit(1)
        }
        pause(0.1)
    }
    emit(["pressed": NSNull(), "items": seen])
    exit(1)
}

func pressCommand(_ arguments: Arguments, bundle: String) {
    let titles = arguments.all("title")
    guard !titles.isEmpty else { fail("--title is required", code: 2) }
    let deadline = now() + arguments.number("timeout", default: 60)
    repeat {
        if let target = runningApplication(bundle)?.processIdentifier,
            let (button, window) = findButton(in: target, titles: titles)
        {
            let described = describeWindow(window)
            if let file = arguments.one("dump") { try? jsonData(described).write(to: URL(fileURLWithPath: file)) }
            // Read before the press: Install and Relaunch ends the app, and its elements read empty afterwards.
            let label = title(button)
            var pressed: Any = NSNull()
            if arguments.flags.contains("close-window") {
                // Sparkle 2.10's update window has no Remind Me Later button: closing it dismisses the offer without
                // the SUSkippedVersion that Skip This Version would store.
                if let close = element(attribute(window, kAXCloseButtonAttribute)) {
                    AXUIElementPerformAction(close, kAXPressAction as CFString)
                    pressed = "<close window>"
                }
            } else if !arguments.flags.contains("find-only") {
                AXUIElementPerformAction(button, kAXPressAction as CFString)
                pressed = label
            }
            emit(["pressed": pressed, "found": label, "at": now(), "window": described])
            return
        }
        pause(0.25)
    } while now() < deadline
    let current = runningApplication(bundle).map { windows(of: $0.processIdentifier).map(describeWindow) } ?? []
    if let file = arguments.one("dump") { try? jsonData(current).write(to: URL(fileURLWithPath: file)) }
    emit(["pressed": NSNull(), "windows": current])
    exit(1)
}

func copySnapshot(from source: String, to destination: String) -> String? {
    do {
        try FileManager.default.copyItem(atPath: source, toPath: destination)
        return nil
    } catch {
        return "\(error)"
    }
}

/// Modification times of the files a snapshot copied (APFS clones keep them): a file the new version wrote would be
/// newer than its start.
func modificationTimes(in folder: String) -> [String: Double] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
    var times: [String: Double] = [:]
    for name in names {
        let path = (folder as NSString).appendingPathComponent(name)
        if let date = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date {
            times[name] = date.timeIntervalSince1970
        }
    }
    return times
}

func exportDefaults(domain: String, to file: String) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    process.arguments = ["export", domain, file]
    do { try process.run() } catch { return -1 }
    process.waitUntilExit()
    return process.terminationStatus
}

final class TapWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var enabledAt: Double?
    private var seenTaps: [[String: Any]] = []

    func record(_ at: Double, _ taps: [TapInfo]) {
        lock.lock()
        defer { lock.unlock() }
        if enabledAt == nil {
            enabledAt = at
            seenTaps = taps.map(\.json)
        }
    }

    var result: (Double?, [[String: Any]]) {
        lock.lock()
        defer { lock.unlock() }
        return (enabledAt, seenTaps)
    }
}

/// When the "loaded" snapshot was taken, and its error.
final class SnapshotStamp: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (Double, String?)?

    func record(_ at: Double, _ error: String?) {
        lock.lock()
        defer { lock.unlock() }
        value = (at, error)
    }

    var result: (Double, String?)? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

func relaunchCommand(_ arguments: Arguments) {
    let executable = arguments.required("executable")
    guard let oldPid = pid_t(arguments.required("old-pid")) else { fail("--old-pid must be a process id", code: 2) }
    let timeout = arguments.number("timeout", default: 300)
    let watch = arguments.number("watch", default: 30)
    var report: [String: Any] = ["oldPid": Int(oldPid), "executable": executable, "armedAt": now()]

    // The TestHost field is found and focused before the update relaunches the app, so each timed attempt below
    // costs only the keys and one read (a tree walk on a loaded guest took seconds on 2026-11-23).
    let target = TypingTarget(
        bundle: arguments.required("typing-bundle"), field: arguments.required("field"), reset: arguments.one("reset"))
    report["typingPrepared"] = target.prepare()

    let exitDeadline = now() + timeout
    while isAlive(oldPid) {
        guard now() < exitDeadline else {
            report["error"] = "the old process did not exit"
            emit(report)
            exit(1)
        }
        pause(0.01)
    }
    report["oldExitedAt"] = now()
    // Snapshot "as the old version left it": taken before the new version can load or write anything.
    if let source = arguments.one("snapshot-src"), let destination = arguments.one("snapshot-dst") {
        report["snapshotError"] = copySnapshot(from: source, to: destination) ?? NSNull()
        report["snapshotAt"] = now()
        report["newProcessBeforeSnapshot"] = !processIdentifiers(executable: executable).filter { $0 != oldPid }
            .isEmpty
        report["snapshotModified"] = modificationTimes(in: destination)
    }
    if let domain = arguments.one("defaults-domain"), let file = arguments.one("defaults-dst") {
        report["defaultsExportStatus"] = Int(exportDefaults(domain: domain, to: file))
        report["defaultsAt"] = now()
    }

    var newPid: pid_t = 0
    let startDeadline = now() + timeout
    while newPid == 0 {
        if let found = processIdentifiers(executable: executable).first(where: { $0 != oldPid }) {
            newPid = found
            break
        }
        guard now() < startDeadline else {
            report["error"] = "no new process of the executable"
            emit(report)
            exit(1)
        }
        pause(0.01)
    }
    let seenAt = now()
    let started = startTime(newPid) ?? seenAt
    report["newPid"] = Int(newPid)
    report["newSeenAt"] = seenAt
    report["newStartedAt"] = started
    report["frontmostAtStart"] = frontmost()

    let tapWatch = TapWatch()
    let tapThread = Thread {
        let end = started + watch
        while now() < end {
            let taps = eventTaps()
            if taps.contains(where: { $0.pid == newPid && $0.enabled }) {
                tapWatch.record(now(), taps.filter { $0.pid == newPid })
                return
            }
            pause(0.01)
        }
    }
    tapThread.start()
    // The "loaded" snapshot: the settings as the new version has them once it loaded them and created its tap
    // (a migration writes at load), but before a 5 s debounced app-modes write of its own session can land
    // (PLT-R392). Taken 0.5 s after the tap is enabled, at the latest 4 s after the start.
    let loadedStamp = SnapshotStamp()
    let loadedThread = Thread {
        guard let source = arguments.one("snapshot-src"), let destination = arguments.one("loaded-snapshot-dst") else {
            return
        }
        while now() < started + 4 {
            if let tapAt = tapWatch.result.0, now() >= tapAt + 0.5 { break }
            pause(0.02)
        }
        loadedStamp.record(now(), copySnapshot(from: source, to: destination))
    }
    loadedThread.start()

    let keys = arguments.required("keys")
    let expect = arguments.required("expect")
    var attempts: [TypingAttempt] = []
    while now() < started + watch {
        let attempt = target.attempt(keys: keys, expect: expect)
        attempts.append(attempt)
        if attempt.matched { break }
    }
    while !tapThread.isFinished || !loadedThread.isFinished { pause(0.05) }
    if let (at, error) = loadedStamp.result {
        report["loadedSnapshotAt"] = at
        report["loadedSnapshotError"] = error ?? NSNull()
    }
    let (tapAt, taps) = tapWatch.result
    report["tapEnabledAt"] = tapAt ?? NSNull()
    report["tapLatencySeconds"] = tapAt.map { $0 - started } ?? NSNull()
    report["taps"] = taps
    report["attempts"] = attempts.map(\.json)
    // Typing works from the moment the keys of the first attempt that read back right were typed: those keystrokes
    // were composed correctly. The read-back itself comes 0.3 s after the last key.
    let worked = attempts.first(where: \.matched)
    report["typingWorkedAt"] = worked?.keysStartedAt ?? NSNull()
    report["typingLatencySeconds"] = worked.map { $0.keysStartedAt - started } ?? NSNull()
    report["typingVerifiedLatencySeconds"] = worked.map { $0.endedAt - started } ?? NSNull()
    report["frontmostAtEnd"] = frontmost()
    emit(report)
}

func quitCommand(_ arguments: Arguments, bundle: String) {
    guard let app = runningApplication(bundle) else {
        emit(["quit": bundle, "wasRunning": false])
        return
    }
    let target = app.processIdentifier
    app.terminate()
    let deadline = now() + arguments.number("timeout", default: 20)
    while isAlive(target), now() < deadline { pause(0.05) }
    let exited = !isAlive(target)
    emit(["quit": bundle, "pid": Int(target), "wasRunning": true, "exited": exited, "at": now()])
    if !exited { exit(1) }
}

let arguments = Arguments(Array(CommandLine.arguments.dropFirst()))
guard let command = arguments.positional.first else {
    fail("usage: upgrade-driver menu|press|windows|activate|frontmost|type|relaunch|quit|taps|processes ...", code: 2)
}
let needsAccessibility: Set<String> = ["menu", "press", "windows", "type", "relaunch", "frontmost", "activate"]
if needsAccessibility.contains(command), !AXIsProcessTrusted() {
    fail(
        "not trusted for accessibility (grant-tcc.sh --binary for this tool and for the process that starts it)",
        code: 4)
}
func bundleArgument() -> String {
    guard arguments.positional.count >= 2 else { fail("\(command) needs a bundle identifier", code: 2) }
    return arguments.positional[1]
}

switch command {
case "menu": menuCommand(arguments, bundle: bundleArgument())
case "press": pressCommand(arguments, bundle: bundleArgument())
case "windows":
    let bundle = bundleArgument()
    emit(runningApplication(bundle).map { windows(of: $0.processIdentifier).map(describeWindow) } ?? [])
case "activate":
    let bundle = bundleArgument()
    activate(bundle)
    emit(["frontmost": frontmost()])
case "frontmost": emit(frontmost())
case "type":
    let bundle = bundleArgument()
    let deadline = now() + arguments.number("seconds", default: 10)
    var attempts: [TypingAttempt] = []
    repeat {
        let attempt = typeOnce(
            bundle: bundle, field: arguments.required("field"), keys: arguments.required("keys"),
            expect: arguments.required("expect"), reset: arguments.one("reset"))
        attempts.append(attempt)
        if attempt.matched { break }
    } while now() < deadline
    emit(["attempts": attempts.map(\.json), "matched": attempts.last?.matched ?? false])
    if attempts.last?.matched != true { exit(1) }
case "relaunch": relaunchCommand(arguments)
case "quit": quitCommand(arguments, bundle: bundleArgument())
case "taps":
    emit(
        eventTaps().map { tap -> [String: Any] in
            var json = tap.json
            json["process"] = NSRunningApplication(processIdentifier: tap.pid)?.bundleIdentifier ?? ""
            return json
        })
case "processes":
    let executable = arguments.required("executable")
    emit(processIdentifiers(executable: executable).map { ["pid": Int($0), "startedAt": startTime($0) ?? 0] })
default: fail("unknown command \(command)", code: 2)
}
