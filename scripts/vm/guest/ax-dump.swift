// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guest half of the pane-name check (scripts/vm/pane-names.sh, docs/runbooks/vm-test-lab.md section 10): reads the
// visible labels of System Settings (macOS 13 and later) or System Preferences (macOS 12), and the menus of an app,
// through the Accessibility API, so App/Resources/SystemPanes.json can quote them as the user sees them (PLT-R704,
// PRD-R64, ADR 0315). pane-names.sh compiles it on the host for arm64 macOS 12 and later (the macOS 12 lab image
// has no compiler) and never runs it there; it runs INSIDE a disposable VM only and refuses a real Mac: the process
// that starts it needs the Accessibility grant, which only a VM may receive from a script.
//
// One line per element: role, subrole, title, description, string value, identifier and selection. It reads labels
// of system panes and menus, never typed content.
//
// Usage: ax-dump --trusted
//        ax-dump --bundle ID [--wait SECONDS] [--depth N] (--windows | --menus | --open-menu INDEX | --close-menus)
// Exit status: 0 done, 1 app or window not found, 2 usage error, 3 not a VM, 4 not trusted for Accessibility.

import AppKit
import ApplicationServices
import Foundation

/// `kern.hv_vmm_present` is 1 only inside a virtual machine.
func insideVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

func fail(_ code: Int32, _ message: String) -> Never {
    FileHandle.standardError.write(Data(("ax-dump: " + message + "\n").utf8))
    exit(code)
}

enum Mode: Equatable {
    case trusted
    case windows
    case menus
    case openMenu(Int)
    case closeMenus
}

struct Options {
    var mode: Mode?
    var bundle = ""
    var wait = 0.0
    var depth = 40
}

let usage =
    "usage: ax-dump --trusted | --bundle ID [--wait SECONDS] [--depth N] "
    + "(--windows | --menus | --open-menu INDEX | --close-menus)"

func parse(_ arguments: [String]) -> Options {
    var options = Options()
    var rest = arguments[...]
    func value() -> String {
        guard let next = rest.popFirst() else { fail(2, usage) }
        return next
    }
    while let argument = rest.popFirst() {
        switch argument {
        case "--trusted": options.mode = .trusted
        case "--windows": options.mode = .windows
        case "--menus": options.mode = .menus
        case "--close-menus": options.mode = .closeMenus
        case "--open-menu":
            guard let index = Int(value()), index >= 0 else { fail(2, usage) }
            options.mode = .openMenu(index)
        case "--bundle": options.bundle = value()
        case "--wait":
            guard let seconds = Double(value()), (0...120).contains(seconds) else { fail(2, usage) }
            options.wait = seconds
        case "--depth":
            guard let depth = Int(value()), (1...80).contains(depth) else { fail(2, usage) }
            options.depth = depth
        default: fail(2, usage)
        }
    }
    guard options.mode != nil, options.mode == .trusted || !options.bundle.isEmpty else { fail(2, usage) }
    return options
}

func copy(_ element: AXUIElement, _ attribute: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value
}

func text(_ element: AXUIElement, _ attribute: String) -> String? {
    guard let value = copy(element, attribute) as? String, !value.isEmpty else { return nil }
    return value
}

/// The app's menu bar (a CF type: checked by type ID, not by a cast that always succeeds).
func menuBar(of app: AXUIElement) -> AXUIElement {
    guard let value = copy(app, kAXMenuBarAttribute), CFGetTypeID(value) == AXUIElementGetTypeID() else {
        fail(1, "no menu bar")
    }
    return unsafeDowncast(value, to: AXUIElement.self)
}

func children(_ element: AXUIElement) -> [AXUIElement] {
    (copy(element, kAXChildrenAttribute) as? [AXUIElement]) ?? []
}

/// A label on one line, quoted, at most 300 characters.
func quoted(_ value: String) -> String {
    let flat = value.replacingOccurrences(of: "\n", with: "\\n")
    return "\"" + String(flat.prefix(300)) + "\""
}

func describe(_ element: AXUIElement) -> String {
    let role = text(element, kAXRoleAttribute) ?? "?"
    var parts = [role]
    if let subrole = text(element, kAXSubroleAttribute) { parts.append("[" + subrole + "]") }
    if let title = text(element, kAXTitleAttribute) { parts.append("title=" + quoted(title)) }
    if let description = text(element, kAXDescriptionAttribute) { parts.append("desc=" + quoted(description)) }
    let value = copy(element, kAXValueAttribute)
    if let string = value as? String, !string.isEmpty {
        parts.append("value=" + quoted(string))
    } else if let number = value as? NSNumber, role == kAXRadioButtonRole || role == kAXCheckBoxRole {
        parts.append("value=" + number.stringValue)
    }
    if let identifier = text(element, kAXIdentifierAttribute) { parts.append("id=" + quoted(identifier)) }
    if (copy(element, kAXSelectedAttribute) as? Bool) == true { parts.append("selected") }
    return parts.joined(separator: " ")
}

/// Depth-first, at most `maxDepth` levels and 8000 elements per call.
func dump(_ element: AXUIElement, depth: Int, maxDepth: Int, budget: inout Int) {
    guard budget > 0 else { return }
    budget -= 1
    print(String(repeating: "  ", count: depth) + describe(element))
    guard depth < maxDepth else { return }
    for child in children(element) { dump(child, depth: depth + 1, maxDepth: maxDepth, budget: &budget) }
}

/// The running app with `bundle`, waiting up to `seconds` for it (and for a window when `needsWindow`).
func application(_ bundle: String, wait seconds: Double, needsWindow: Bool) -> (AXUIElement, String)? {
    let deadline = Date().addingTimeInterval(seconds)
    repeat {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first {
            let app = AXUIElementCreateApplication(running.processIdentifier)
            AXUIElementSetMessagingTimeout(app, 5)
            let windows = (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
            if !needsWindow || !windows.isEmpty {
                return (app, (running.localizedName ?? "?") + " pid " + String(running.processIdentifier))
            }
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    } while Date() < deadline
    return nil
}

guard insideVirtualMachine() else { fail(3, "refusing: not inside a virtual machine") }
let options = parse(Array(CommandLine.arguments.dropFirst()))
if options.mode == .trusted {
    let trusted = AXIsProcessTrusted()
    print(trusted ? "trusted: yes" : "trusted: no")
    exit(trusted ? 0 : 4)
}
guard AXIsProcessTrusted() else { fail(4, "this process is not trusted for Accessibility") }
guard let (app, name) = application(options.bundle, wait: options.wait, needsWindow: options.mode == .windows)
else { fail(1, "no running app (or no window) for " + options.bundle) }
print("app: " + name)
var budget = 8000
switch options.mode {
case .windows:
    for window in (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? [] {
        dump(window, depth: 0, maxDepth: options.depth, budget: &budget)
    }
case .menus:
    dump(menuBar(of: app), depth: 0, maxDepth: min(options.depth, 4), budget: &budget)
case .openMenu(let index):
    let items = children(menuBar(of: app))
    guard items.indices.contains(index) else { fail(1, "no menu bar item " + String(index)) }
    let result = AXUIElementPerformAction(items[index], kAXPressAction as CFString)
    print("press: " + describe(items[index]) + " -> AXError " + String(result.rawValue))
case .closeMenus:
    for item in children(menuBar(of: app)) {
        for menu in children(item) { _ = AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
    }
case .trusted, .none:
    break
}
