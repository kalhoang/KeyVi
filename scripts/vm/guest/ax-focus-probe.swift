// SPDX-License-Identifier: GPL-3.0-or-later
//
// Triage aid of the VM integration runs (docs/runbooks/integration-suite.md section 10.5): logs, with a timestamp,
// every focus, window, selection and value notification an app posts, with the role, AX identifier, DOM classes,
// pid and hash of the element and of the app's focused element at that moment, plus every general pasteboard
// change (change count and types). This is how W7-A found that WebKit posts the focus notification of a page's
// textarea before the textarea is the app's focused element, and that a just launched app refuses observers.
// Never a value: no text of a field is read and the pasteboard's data is never read at all (PLT-R901; reading it
// could also raise macOS's paste consent prompt over the windows of the following scenarios). Compiled and run
// INSIDE the disposable VM only, in the logged-in session (tart exec); it refuses a real Mac.
//
// Usage: ax-focus-probe <bundle ID>   Runs until killed; needs Accessibility (scripts/vm/grant-tcc.sh --binary).
// scripts/vm/integration-dev.sh --probe compiles, grants and runs it beside the suite (integration-suite.md 10.5).

import AppKit
import ApplicationServices

/// `kern.hv_vmm_present` is 1 only inside a virtual machine.
func insideVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

guard insideVirtualMachine() else {
    FileHandle.standardError.write(Data("refusing: not inside a virtual machine\n".utf8))
    exit(3)
}
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: ax-focus-probe <bundle ID>\n".utf8))
    exit(2)
}

@MainActor
final class FocusProbe {
    static let notifications = [
        kAXFocusedUIElementChangedNotification, kAXFocusedWindowChangedNotification,
        kAXApplicationActivatedNotification, kAXSelectedTextChangedNotification, kAXValueChangedNotification,
    ]

    let bundle: String
    let started = Date()
    var pid: pid_t = 0
    var application: AXUIElement?
    var observer: AXObserver?
    /// Notifications the app refused so far (it answers kAXErrorCannotComplete while it is still launching).
    var pending: [String] = []
    var lastFocused: AXUIElement?
    var pasteboardChange = NSPasteboard.general.changeCount

    init(bundle: String) { self.bundle = bundle }

    func log(_ line: String) {
        let stamp = String(format: "%9.3f", Date().timeIntervalSince(started))
        FileHandle.standardOutput.write(Data((stamp + " " + line + "\n").utf8))
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    /// Role, identifier, classes, pid, hash, selection and length; never the value itself.
    func describe(_ element: AXUIElement?) -> String {
        guard let element else { return "none" }
        let role = attribute(element, kAXRoleAttribute) as? String ?? "?"
        let identifier = attribute(element, "AXIdentifier") as? String ?? "-"
        let classes = (attribute(element, "AXDOMClassList") as? [String])?.joined(separator: ".") ?? "-"
        var owner: pid_t = 0
        AXUIElementGetPid(element, &owner)
        var text = "\(role) id=\(identifier) classes=\(classes) pid=\(owner) hash=\(CFHash(element))"
        if let range = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(range) == AXValueGetTypeID() {
            var selection = CFRange()
            if AXValueGetValue(range as! AXValue, .cfRange, &selection) {  // type checked above
                text += " selection=\(selection.location),\(selection.length)"
            }
        }
        if let count = attribute(element, kAXNumberOfCharactersAttribute) as? Int { text += " characters=\(count)" }
        return text
    }

    func focusedElement() -> AXUIElement? {
        guard let application, let value = attribute(application, kAXFocusedUIElementAttribute),
            CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)  // type checked above
    }

    func received(_ name: String, element: AXUIElement) {
        let focused = focusedElement()
        let change =
            switch (focused, lastFocused) {
            case (let now?, let before?): CFEqual(now, before) ? "same" : "changed"
            default: "unknown"
            }
        log("\(name) element=[\(describe(element))] focused=[\(describe(focused))] focus=\(change)")
        if name == kAXFocusedUIElementChangedNotification { lastFocused = focused }
    }

    func attach(_ target: pid_t) {
        let callback: AXObserverCallback = { _, element, name, refcon in
            guard let refcon else { return }
            let probe = Unmanaged<FocusProbe>.fromOpaque(refcon).takeUnretainedValue()
            MainActor.assumeIsolated { probe.received(name as String, element: element) }
        }
        var created: AXObserver?
        guard AXObserverCreate(target, callback, &created) == .success, let created else {
            log("observer for pid \(target) could not be created")
            return
        }
        pid = target
        application = AXUIElementCreateApplication(target)
        observer = created
        pending = Self.notifications
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(created), .defaultMode)
        log("attached to pid \(target)")
        register()
        lastFocused = focusedElement()
    }

    /// Adds the notifications still missing; logs each answer, so a refusal after launch shows.
    func register() {
        guard let observer, let application else { return }
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        pending = pending.filter { name in
            let result = AXObserverAddNotification(observer, application, name as CFString, refcon)
            log("add \(name): \(result.rawValue)")
            return result != .success && result != .notificationAlreadyRegistered
        }
    }

    /// Every 10 ms: the target's pid (it may launch or quit), refused notifications, the pasteboard.
    func tick() {
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first
        let target = running?.processIdentifier ?? 0
        if target != pid {
            if let observer {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
            }
            observer = nil
            application = nil
            pid = 0
            if target == 0 { log("\(bundle) is not running") } else { attach(target) }
        } else if !pending.isEmpty {
            register()
        }
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != pasteboardChange else { return }
        pasteboardChange = pasteboard.changeCount
        let types = pasteboard.types?.map(\.rawValue).joined(separator: ",") ?? "-"
        log("pasteboard change=\(pasteboardChange) types=\(types)")
    }
}

// Top-level code runs on the main thread; the probe and its timer live on the main run loop.
MainActor.assumeIsolated {
    let probe = FocusProbe(bundle: CommandLine.arguments[1])
    probe.log("probe for \(probe.bundle), accessibility trusted: \(AXIsProcessTrusted())")
    let timer = Timer(timeInterval: 0.01, repeats: true) { _ in MainActor.assumeIsolated { probe.tick() } }
    RunLoop.main.add(timer, forMode: .default)
    RunLoop.main.run()
}
