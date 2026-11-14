// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guest half of scripts/vm/tap-permission.sh (docs/runbooks/vm-test-lab.md section 11; PLT-R701, PLT-R702): which
// TCC permission the app's tap (an active key tap at the session level, the parameters of TapThread.swift) needs on
// the guest's macOS, and which checks follow a grant made while the process runs. Compiled on the host, run INSIDE
// the disposable VM only; it refuses a real Mac. It never records which key was pressed, only counts (PLT-R901).
//
// Usage:
//   tap-permission-probe probe --out FILE [--seconds N]
//       Inside an app bundle started with `open`, so TCC sees the bundle and not the shell that started it. Every
//       second it appends one JSON line to FILE: seconds since start, pid, AXIsProcessTrusted(),
//       CGPreflightPostEventAccess(), CGPreflightListenEventAccess(), whether its active key tap is installed (it
//       retries every second until the tap can be created), how many creations it tried, whether a listen-only key
//       tap can be created now, the key-downs its active tap received from other processes, the key-downs it posted
//       itself (F19, marked) and how many of those came back through its tap. Exits after N seconds (default 900).
//   tap-permission-probe type --count N
//       Posts N presses of the X key at the HID level, as a user typing would (run from the tart guest agent, which
//       the guest grants Accessibility and event posting).

import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// `kern.hv_vmm_present` is 1 only inside a virtual machine.
func insideVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(code)
}

guard insideVirtualMachine() else { fail("refusing: not inside a virtual machine", code: 3) }

let usage = "usage: tap-permission-probe probe --out FILE [--seconds N] | type --count N"

/// Event source user data of the probe's own key presses, so its tap tells them from everyone else's.
let ownMarker: Int64 = 0x4B56_5450
/// F19 has no default action anywhere; the typed key is the X key position (kVK_ANSI_X).
let ownKey: CGKeyCode = 0x50
let typedKey: CGKeyCode = 0x07

/// State shared with the tap callback, which is a C function pointer and cannot capture. Main thread only: the tap's
/// run-loop source and the timer both run on the main run loop.
final class ProbeState: @unchecked Sendable {
    var tap: CFMachPort?
    var tapCreateAttempts = 0
    var keys = 0
    var echoes = 0
    var posted = 0
    var disabledBySystem = 0
}

let probeState = ProbeState()

let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        probeState.disabledBySystem += 1
        if let tap = probeState.tap { CGEvent.tapEnable(tap: tap, enable: true) }
    case .keyDown:
        if event.getIntegerValueField(.eventSourceUserData) == ownMarker {
            probeState.echoes += 1
        } else {
            probeState.keys += 1
        }
    default:
        break
    }
    return Unmanaged.passUnretained(event)
}

let keyMask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)

/// The app's tap: active (it may change or swallow keys), session level, inserted at the head.
func installActiveTap() {
    guard probeState.tap == nil else { return }
    probeState.tapCreateAttempts += 1
    guard
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: keyMask,
            callback: tapCallback, userInfo: nil)
    else { return }
    let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    probeState.tap = tap
}

/// The app's live Input Monitoring check (SystemPermissionProbe.canListenToEventsNow): a listen-only key tap,
/// released at once.
func listenOnlyTapNow() -> Bool {
    guard
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
            eventsOfInterest: CGEventMask(1) << CGEventType.keyDown.rawValue,
            callback: { _, _, event, _ in Unmanaged.passUnretained(event) }, userInfo: nil)
    else { return false }
    CGEvent.tapEnable(tap: tap, enable: false)
    CFMachPortInvalidate(tap)
    return true
}

func postKey(_ key: CGKeyCode, marker: Int64?) {
    let source = CGEventSource(stateID: marker == nil ? .hidSystemState : .privateState)
    for down in [true, false] {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
        if let marker { event.setIntegerValueField(.eventSourceUserData, value: marker) }
        event.post(tap: .cghidEventTap)
        usleep(20_000)
    }
}

/// One JSON object per line, appended with O_APPEND so the guest script's phase markers interleave cleanly.
func append(_ line: String, to descriptor: Int32) {
    let bytes = Array((line + "\n").utf8)
    _ = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
}

func value(after flag: String, in arguments: [String]) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "type":
    guard let text = value(after: "--count", in: arguments), let count = Int(text), (1...200).contains(count) else {
        fail(usage, code: 2)
    }
    for _ in 0..<count {
        postKey(typedKey, marker: nil)
        usleep(120_000)
    }
    exit(0)
case "probe":
    guard let path = value(after: "--out", in: arguments) else { fail(usage, code: 2) }
    let seconds = value(after: "--seconds", in: arguments).flatMap(Int.init) ?? 900
    guard (5...3600).contains(seconds) else { fail(usage, code: 2) }
    let descriptor = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
    guard descriptor >= 0 else { fail("cannot open \(path)", code: 1) }
    let started = Date()
    let pid = ProcessInfo.processInfo.processIdentifier
    NSApplication.shared.setActivationPolicy(.accessory)
    let timer = Timer(timeInterval: 1, repeats: true) { _ in
        installActiveTap()
        postKey(ownKey, marker: ownMarker)
        probeState.posted += 1
        let elapsed = Int(Date().timeIntervalSince(started))
        let fields: [String] = [
            "\"t\":\(elapsed)", "\"pid\":\(pid)", "\"ax\":\(AXIsProcessTrusted())",
            "\"postPreflight\":\(CGPreflightPostEventAccess())",
            "\"listenPreflight\":\(CGPreflightListenEventAccess())", "\"activeTap\":\(probeState.tap != nil)",
            "\"tapCreateAttempts\":\(probeState.tapCreateAttempts)", "\"listenOnlyTapNow\":\(listenOnlyTapNow())",
            "\"keys\":\(probeState.keys)", "\"posted\":\(probeState.posted)", "\"echoes\":\(probeState.echoes)",
            "\"tapDisabled\":\(probeState.disabledBySystem)",
        ]
        append("{" + fields.joined(separator: ",") + "}", to: descriptor)
        if elapsed >= seconds { exit(0) }
    }
    RunLoop.main.add(timer, forMode: .common)
    NSApplication.shared.run()
default:
    fail(usage, code: 2)
}
