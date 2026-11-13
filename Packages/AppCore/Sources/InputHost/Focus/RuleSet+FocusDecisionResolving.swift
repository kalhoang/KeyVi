// SPDX-License-Identifier: GPL-3.0-or-later
//
// The compiled rule set as the focus tracker's resolver (PLT-R380, PLT-R510, PLT-R520-R523). `resolve`,
// `overlayBundles` and `titlePatternBundles` are RuleSet's own members; fingerprinting inspects the bundle on
// disk with the rules' `webkitBrowsers` group. The tracker caches the result per (path, CFBundleVersion).

public import AppModel
public import CompatRules
public import Foundation

extension RuleSet: FocusDecisionResolving {
    public func fingerprint(bundleURL: URL, bundle: BundleKey) -> EngineFingerprint {
        EngineFingerprinter(inspector: FileSystemBundleInspector(), webkitBrowsers: webkitBrowsers)
            .fingerprint(bundleURL: bundleURL, bundle: bundle)
    }
}
