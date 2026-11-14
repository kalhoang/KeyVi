# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the Settings window snapshot tool (W8-D): scripts/snapshots/settings.sh and the SettingsSnapshots
test bundle. Run: python3 -I scripts/tests/test_settings_snapshots.py

The script runs against fake `xcodegen` and `xcodebuild` (nothing is built or rendered). The Swift driver is checked
statically for the host-safety rules of the product owner's Mac: it never starts InputHost or the app environment,
never creates an event tap, never requests or checks a permission, never posts an event and never shows a window.
"""
from __future__ import annotations

import os
import re
import tempfile
import unittest
from pathlib import Path

import sys

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS, run  # noqa: E402

SCRIPT = SCRIPTS / "snapshots" / "settings.sh"
DRIVER = SCRIPTS / "snapshots" / "SettingsSnapshots"
PROJECT = REPO / "project.yml"

# Records its arguments and the test runner variables, then writes two PNGs and a manifest like the real bundle.
FAKE_XCODEBUILD = r"""#!/bin/bash
{ printf 'xcodebuild %s\n' "$*"; env | grep '^TEST_RUNNER_' | sort; } >>"$FAKE_DIR/calls.log"
[ -z "${FAKE_FAIL:-}" ] || exit 65
dir="$TEST_RUNNER_SNAPSHOT_OUTPUT/$TEST_RUNNER_SNAPSHOT_LABEL"
mkdir -p "$dir"
printf 'png' >"$dir/general-vi-light-min.png"
printf 'png' >"$dir/typing-en-dark-default.png"
printf 'general-vi-light-min.png\ntyping-en-dark-default.png\n' >"$dir/manifest.txt"
"""

FAKE_XCODEGEN = '#!/bin/sh\necho "xcodegen $*" >>"$FAKE_DIR/calls.log"\n'

FORBIDDEN = [
    "AppEnvironment(", "InputHostController", "AppMain", "CGEvent", "tapCreate", "AXIsProcessTrusted",
    "IOHIDRequestAccess", "IOHIDCheckAccess", "CGRequestListenEventAccess", "CGPreflightListenEventAccess",
    "CGRequestPostEventAccess", "makeKeyAndOrderFront", "orderFront", "orderFrontRegardless", "showWindow",
    "NSApp.run", ".run()", "activate(", "SMAppService", "NSWorkspace.shared.open", "TISSelectInputSource",
    # Anything else that puts a window on screen or spins a modal loop.
    "orderBack(", "orderWindow(", "makeKey()", "makeMain()", "runModal", "setIsVisible(true)", "beginSheet(",
    "beginCriticalSheet(",
]


def write_exe(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(0o755)


class SnapshotScriptTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        write_exe(self.bin / "xcodebuild", FAKE_XCODEBUILD)
        write_exe(self.bin / "xcodegen", FAKE_XCODEGEN)
        self.out = self.tmp / "screens"
        self.env = {"PATH": f"{self.bin}:{os.environ['PATH']}", "FAKE_DIR": str(self.tmp), "TMPDIR": str(self.tmp)}

    def calls(self) -> str:
        log = self.tmp / "calls.log"
        return log.read_text(encoding="utf-8") if log.exists() else ""

    def snapshot(self, *args: str, **env: str):
        return run("bash", str(SCRIPT), "--out", str(self.out), "--derived-data", str(self.tmp / "dd"), *args,
                   env={**self.env, **env})

    def test_help_lists_every_option(self) -> None:
        result = run("bash", str(SCRIPT), "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        for option in ["--label", "--baseline", "--out", "--derived-data", "--jobs", "--only", "--no-generate"]:
            self.assertIn(option, result.stdout)

    def test_rejects_bad_arguments(self) -> None:
        for args in [["--bogus"], ["--label", "../up"], ["--label", "a b"], ["--jobs", "many"]]:
            with self.subTest(args=args):
                result = self.snapshot(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(self.calls(), "", "nothing runs after a usage error")

    def test_runs_the_bundle_and_writes_the_images_and_index(self) -> None:
        result = self.snapshot("--label", "after")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertIn("xcodegen generate --quiet", calls)
        self.assertRegex(calls, r"xcodebuild -project App\.xcodeproj -scheme SettingsSnapshots .*-jobs 3 ")
        self.assertIn("CODE_SIGNING_ALLOWED=NO", calls)
        self.assertRegex(calls, r"SNAPSHOT_CONDITIONS= test\n")
        self.assertIn("TEST_RUNNER_SNAPSHOT_LABEL=after", calls)
        self.assertIn("TEST_RUNNER_SNAPSHOT_ONLY=\n", calls)
        images = sorted(p.name for p in (self.out / "after").glob("*.png"))
        self.assertEqual(images, ["general-vi-light-min.png", "typing-en-dark-default.png"])
        index = (self.out / "index.md").read_text(encoding="utf-8")
        self.assertIn("## after", index)
        self.assertIn("- [general-vi-light-min.png](after/general-vi-light-min.png)", index)
        self.assertIn("wrote 2 images", result.stdout)
        self.assertEqual(list(self.tmp.glob("settings-snapshots-run.*")), [], "the staging folder is removed")

    def test_baseline_and_only(self) -> None:
        stale = self.out / "before" / "apps-vi-light-min.png"
        stale.parent.mkdir(parents=True)
        stale.write_text("old", encoding="utf-8")
        result = self.snapshot("--label", "before", "--baseline", "--only", "general", "--no-generate")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        calls = self.calls()
        self.assertNotIn("xcodegen", calls)
        self.assertIn("SNAPSHOT_CONDITIONS=SETTINGS_SNAPSHOT_BASELINE test", calls)
        self.assertIn("TEST_RUNNER_SNAPSHOT_ONLY=general", calls)
        self.assertTrue(stale.exists(), "--only keeps the label's other images")
        index = (self.out / "index.md").read_text(encoding="utf-8")
        self.assertIn("before/apps-vi-light-min.png", index)

    def test_full_run_replaces_the_label_images(self) -> None:
        stale = self.out / "after" / "old-name.png"
        stale.parent.mkdir(parents=True)
        stale.write_text("old", encoding="utf-8")
        self.assertEqual(self.snapshot("--label", "after").returncode, 0)
        self.assertFalse(stale.exists())

    def test_a_failed_test_run_fails_and_copies_nothing(self) -> None:
        result = self.snapshot("--label", "after", FAKE_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.out / "index.md").exists())


class SnapshotSafetyTests(unittest.TestCase):
    def driver_code(self) -> str:
        texts = []
        for path in sorted(DRIVER.glob("*.swift")):
            # Comments may name what the driver avoids; only code counts.
            lines = [line for line in path.read_text(encoding="utf-8").splitlines()
                     if not line.lstrip().startswith("//")]
            texts.append("\n".join(lines))
        return "\n".join(texts)

    def test_driver_never_starts_the_app_or_touches_input_or_permissions(self) -> None:
        code = self.driver_code()
        self.assertTrue(code)
        for token in FORBIDDEN:
            self.assertNotIn(token, code, f"the snapshot driver must not use {token}")
        self.assertIn("setActivationPolicy(.prohibited)", code)
        self.assertIn("cacheDisplay(", code)

    def test_driver_removes_its_temporary_stores(self) -> None:
        # Every variant's settings store lives in its own temporary folder; the run removes each one and checks at
        # the end that none is left behind (hygiene on the developer's Mac).
        code = self.driver_code()
        self.assertIn("removeItem(at: store.folder)", code)
        self.assertIn("SnapshotFixtures.leftoverStores()", code)

    def test_bundle_has_no_host_app_and_no_entry_point(self) -> None:
        text = PROJECT.read_text(encoding="utf-8")
        match = re.search(r"\n  SettingsSnapshots:\n(.*?)\n  [A-Za-z]+:\n", text, re.S)
        self.assertIsNotNone(match, "SettingsSnapshots target in project.yml")
        target = match.group(1)
        self.assertIn("type: bundle.unit-test", target)
        self.assertNotIn("TEST_HOST", target)
        self.assertNotIn("BUNDLE_LOADER", target)
        self.assertIn('"Composition/AppMain.swift"', target)

    def test_script_launches_nothing(self) -> None:
        text = SCRIPT.read_text(encoding="utf-8")
        for token in ["open ", "/Contents/MacOS/", "tart", "sudo", "osascript", "screencapture"]:
            self.assertNotIn(token, text)



class SettingsViewObservationTests(unittest.TestCase):
    """A Settings view that keeps the window model as a plain `let` is not redrawn when the model publishes: SwiftUI
    compares the view's stored values, finds the same reference and keeps the old body. That made "Tùy chọn nâng cao"
    impossible to open (Pa, 15/11/2026; AdvancedDisclosureTests in the snapshot bundle draws the fix). Every view
    struct under App/Sources/Settings that stores SettingsWindowModel must observe it."""

    SETTINGS = REPO / "App" / "Sources" / "Settings"
    VIEW = re.compile(r"^(?:struct|final class|class) (\w+)(?:<[^>]*>)?: (?:View|ViewModifier)\b(.*?)^}", re.S | re.M)
    PLAIN = re.compile(r"^\s*(?:let|var) \w+: SettingsWindowModel\b", re.M)

    def test_every_settings_view_observes_the_window_model(self) -> None:
        offenders = []
        views = 0
        for path in sorted(self.SETTINGS.glob("*.swift")):
            for match in self.VIEW.finditer(path.read_text(encoding="utf-8")):
                views += 1
                for line in self.PLAIN.findall(match.group(2)):
                    offenders.append(f"{path.name}: {match.group(1)}: {line.strip()}")
        self.assertGreater(views, 30, "the scan found the Settings views")
        self.assertEqual(offenders, [], "use @ObservedObject var model: SettingsWindowModel")

    def test_the_scan_catches_a_plain_reference(self) -> None:
        sample = "struct AdvancedSection: View {\n    let model: SettingsWindowModel\n    var body: some View { x }\n}\n"
        match = self.VIEW.search(sample)
        self.assertIsNotNone(match)
        self.assertEqual(len(self.PLAIN.findall(match.group(2))), 1)


if __name__ == "__main__":
    unittest.main(verbosity=1)
