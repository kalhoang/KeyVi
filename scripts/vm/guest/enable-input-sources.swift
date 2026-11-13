// SPDX-License-Identifier: GPL-3.0-or-later
//
// Guest half of the VM integration run (scripts/vm/guest/integration-guest.sh): enables the input sources the
// TestHost scenarios select (docs/runbooks/integration-suite.md section 2 step 4, compat/scenarios/README.md
// "Runner prerequisites") for the logged-in user, through the Text Input Sources API. Compiled and run INSIDE the
// disposable VM only; the guest script refuses to run on a real Mac before it gets here, and so does this program.
//
// Usage: enable-input-sources <input source ID>...   Exit 0 when every ID is enabled afterwards, 1 otherwise.

import Carbon
import Foundation

/// `kern.hv_vmm_present` is 1 only inside a virtual machine.
func insideVirtualMachine() -> Bool {
    var value: Int32 = 0
    var size = MemoryLayout<Int32>.size
    return sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 && value == 1
}

/// Every installed source with `identifier` (`includeAllInstalled`), or only the enabled ones.
func sources(_ identifier: String, installed: Bool) -> [TISInputSource] {
    let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
    return TISCreateInputSourceList(filter, installed)?.takeRetainedValue() as? [TISInputSource] ?? []
}

/// The bundle of an input mode (Kotoeri's Romaji mode needs its input method enabled first).
func parentInputMethod(of source: TISInputSource) -> String? {
    guard let raw = TISGetInputSourceProperty(source, kTISPropertyBundleID) else { return nil }
    let bundle = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    return sources(bundle, installed: true).isEmpty ? nil : bundle
}

func enable(_ identifier: String) -> Bool {
    guard sources(identifier, installed: false).isEmpty else {
        print("enabled already: " + identifier)
        return true
    }
    guard let source = sources(identifier, installed: true).first else {
        print("not installed: " + identifier)
        return false
    }
    if let parent = parentInputMethod(of: source), sources(parent, installed: false).isEmpty {
        for method in sources(parent, installed: true) { TISEnableInputSource(method) }
    }
    let status = TISEnableInputSource(source)
    let enabled = !sources(identifier, installed: false).isEmpty
    print((enabled ? "enabled: " : "could not enable (status \(status)): ") + identifier)
    return enabled
}

guard insideVirtualMachine() else {
    FileHandle.standardError.write(Data("refusing: not inside a virtual machine\n".utf8))
    exit(3)
}
let identifiers = Array(CommandLine.arguments.dropFirst())
guard !identifiers.isEmpty else {
    FileHandle.standardError.write(Data("usage: enable-input-sources <input source ID>...\n".utf8))
    exit(2)
}
let results = identifiers.map(enable)
exit(results.allSatisfy { $0 } ? 0 : 1)
