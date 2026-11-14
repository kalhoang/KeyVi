# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the system pane-name check (docs/runbooks/vm-test-lab.md section 10): scripts/vm/pane-names.sh,
scripts/vm/guest/pane-names-guest.sh and scripts/vm/pane-tables.py. Run: python3 -I scripts/tests/test_pane_names.py

The host driver runs against the fake `tart` and `ssh` of test_vm_lab.py (no virtual machine starts), with a fake
`pgrep` (the Safari rule) and a fake `swiftc` (the host build of the Accessibility reader). The guest script runs
with a fake `sysctl` and fake system tools, so it never opens, kills or grants anything on the host.
"""
from __future__ import annotations

import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS  # noqa: E402
from test_vm_lab import FAKE_SSH, MONTEREY, LabTestCase, write_exe  # noqa: E402

PANE_NAMES = SCRIPTS / "vm" / "pane-names.sh"
PANE_GUEST = SCRIPTS / "vm" / "guest" / "pane-names-guest.sh"
PANE_TABLES = SCRIPTS / "vm" / "pane-tables.py"
SYSTEM_PANES = REPO / "App" / "Resources" / "SystemPanes.json"

# Safari open on the host when FAKE_SAFARI=1 (Pa's VM rule, vm-test-lab.md section 10).
FAKE_PGREP = '#!/bin/sh\necho "pgrep $*" >>"$FAKE_DIR/calls.log"\n[ "$*" = "-x Safari" ] && [ "${FAKE_SAFARI:-0}" = 1 ]\n'

# Logs its arguments; writes the -o file unless FAKE_SWIFTC_FAIL is set.
FAKE_SWIFTC = r"""#!/bin/bash
printf 'swiftc %s\n' "$*" >>"$FAKE_DIR/calls.log"
[ -z "${FAKE_SWIFTC_FAIL:-}" ] || { echo "error: fake compiler failure" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in -o) printf '#!/bin/sh\nexit 0\n' >"$2"; chmod +x "$2"; shift 2 ;; *) shift ;; esac
done
"""

# Answers the guest commands pane-names.sh sends, keeps the archive it pushes, delegates the rest to the lab fake.
PANE_SSH = r"""#!/bin/bash
remote="${@: -1}"
case "$remote" in
  *"sw_vers -productVersion"*) echo "12.7.6"; exit 0 ;;
  *"defaults read -g AppleLanguages"*) echo '("en")'; exit 0 ;;
  *"csrutil status"*) echo "System Integrity Protection status: enabled."; exit 0 ;;
  *pane-names-guest.sh*) printf 'ssh %s\n' "$*" >>"$FAKE_DIR/calls.log"; exit 0 ;;
  *"-xf -"*) printf 'ssh %s\n' "$*" >>"$FAKE_DIR/calls.log"; cat >"$FAKE_DIR/pushed.tar"; exit 0 ;;
esac
exec "$FAKE_DIR/ssh-lab" "$@"
"""


class PaneNamesHostTests(LabTestCase):
    def setUp(self) -> None:
        super().setUp()
        write_exe(self.bin / "pgrep", FAKE_PGREP)
        write_exe(self.bin / "swiftc", FAKE_SWIFTC)

    def run_panes(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return self.script(PANE_NAMES, *args, **env)

    def test_help_and_usage_errors(self):
        result = self.run_panes("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: scripts/vm/pane-names.sh --vm NAME", result.stdout)
        for args, message in ((("--languages", "en"), "--vm is required"),
                              (("--vm", MONTEREY, "--languages", "fr"), "--languages takes en and vi"),
                              (("--vm", MONTEREY, "--languages", "en,vi,"), "--languages takes en and vi"),
                              (("--vm",), "--vm needs a value"),
                              (("--bogus",), "unknown option")):
            with self.subTest(args=args):
                result = self.run_panes(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
        self.assertEqual(self.tart_calls("run") + self.tart_calls("clone"), [])

    def test_it_refuses_while_safari_runs_before_any_build_or_tart_call(self):
        result = self.run_panes("--vm", MONTEREY, FAKE_SAFARI="1")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("Safari is open on the host", result.stderr)
        self.assertIn("pgrep -x Safari", self.calls())
        self.assertEqual([c for c in self.calls() if c.startswith(("tart ", "swiftc "))], [])

    def test_the_reader_is_built_on_the_host_for_macos_12_before_any_vm_starts(self):
        # The macOS 12 lab image has no command line tools (smoke-guest.sh), so the guest cannot compile it.
        result = self.run_panes("--vm", MONTEREY, FAKE_SWIFTC_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("could not build ax-dump", result.stderr)
        self.assertIn("fake compiler failure", result.stderr)
        builds = [c for c in self.calls() if c.startswith("swiftc ")]
        self.assertEqual(len(builds), 1, self.calls())
        self.assertIn("-target arm64-apple-macos12.0", builds[0])
        self.assertIn(str(SCRIPTS / "vm" / "guest" / "ax-dump.swift"), builds[0])
        self.assertEqual(self.tart_calls("clone") + self.tart_calls("run"), [], "no VM before the build")

    def test_the_prebuilt_reader_is_pushed_and_handed_to_the_guest_and_the_clone_is_deleted(self):
        (self.fake / "ssh-lab").write_text(FAKE_SSH, encoding="utf-8")
        (self.fake / "ssh-lab").chmod(0o755)
        write_exe(self.bin / "ssh", PANE_SSH)
        out = self.tmp / "run"
        result = self.run_panes("--vm", MONTEREY, "--languages", "en", "--output", str(out))
        calls = self.calls()
        self.assertEqual(len(self.tart_calls("clone")), 1, calls)
        self.assertLess(calls.index(next(c for c in calls if c.startswith("swiftc "))),
                        calls.index(self.tart_calls("clone")[0]), "the reader is built before the clone")
        with tarfile.open(self.fake / "pushed.tar") as archive:
            pushed = {Path(name).name for name in archive.getnames()}
        self.assertLessEqual({"ax-dump", "pane-names-guest.sh", "grant-tcc.sh", "links.tsv"}, pushed)
        self.assertNotIn("ax-dump.swift", pushed, "the guest gets the binary, not the source")
        guest = [c for c in calls if "pane-names-guest.sh" in c]
        self.assertEqual(len(guest), 1, calls)
        self.assertIn("--tool inbox/panes/ax-dump ", guest[0] + " ")
        self.assertIn("--out panes-out/en", guest[0])
        links = (out / "links.tsv").read_text(encoding="utf-8")
        self.assertIn("probe.privacy\tx-apple.systempreferences:com.apple.preference.security?Privacy", links)
        self.assertEqual(self.running(), set(), result.stderr)
        self.assertFalse((self.fake / "vms" / f"{MONTEREY}-panes").exists(), "the throwaway clone is deleted")
        self.assertTrue((self.fake / "vms" / MONTEREY).exists(), "the base VM is kept")


class PaneNamesGuestTests(unittest.TestCase):
    """The guest script kills and opens System Settings and Terminal and uses sudo: it must refuse to run anywhere but
    inside a VM (kern.hv_vmm_present = 1), and inside one it must not need a compiler (macOS 12 image)."""

    TOOLS = ("defaults", "open", "pkill", "sudo", "launchctl", "swiftc", "screencapture", "csrutil", "killall")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "calls.log"
        write_exe(self.bin / "sysctl", '#!/bin/sh\n[ "$*" = "-n kern.hv_vmm_present" ] || exit 1\necho "$FAKE_VMM"\n')
        write_exe(self.bin / "sw_vers", '#!/bin/sh\necho 12.7.6\n')
        write_exe(self.bin / "xcode-select", f'#!/bin/sh\necho "xcode-select $*" >>"{self.log}"\nexit 2\n')
        for tool in self.TOOLS:
            write_exe(self.bin / tool, f'#!/bin/sh\necho "{tool} $*" >>"{self.log}"\nexit 1\n')
        self.links = self.tmp / "links.tsv"
        self.links.write_text("keyboard\tx-apple.systempreferences:com.apple.preference.keyboard\n", encoding="utf-8")
        self.swift = self.tmp / "ax-dump.swift"
        self.swift.write_text("// source\n", encoding="utf-8")
        self.binary = self.tmp / "ax-dump"
        write_exe(self.binary, f'#!/bin/sh\necho "ax-dump $*" >>"{self.log}"\nexit 4\n')

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_guest(self, *args: str, vmm: str = "1") -> subprocess.CompletedProcess:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.tmp), "FAKE_VMM": vmm,
               "LC_ALL": "C"}
        return subprocess.run(["bash", str(PANE_GUEST), *args], capture_output=True, text=True, env=env, cwd=self.tmp,
                              stdin=subprocess.DEVNULL, timeout=60)

    def logged(self) -> str:
        return self.log.read_text(encoding="utf-8") if self.log.exists() else ""

    def full_args(self, tool: Path) -> list[str]:
        return ["--out", str(self.tmp / "out"), "--links", str(self.links), "--tool", str(tool), "--settle", "1"]

    def test_it_refuses_to_run_outside_a_virtual_machine(self):
        for vmm in ("0", ""):
            with self.subTest(vmm=vmm):
                result = self.run_guest(*self.full_args(self.binary), vmm=vmm)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("refusing: not inside a virtual machine", result.stderr)
                self.assertEqual(self.logged(), "", "no tool may run before the guard")
                self.assertFalse((self.tmp / "out").exists())

    def test_inside_a_virtual_machine_usage_errors_exit_2(self):
        not_executable = self.tmp / "notes.txt"
        not_executable.write_text("x\n", encoding="utf-8")
        for args in ([], ["--out"], ["--settle", "0"], self.full_args(not_executable),
                     self.full_args(self.tmp / "missing")):
            with self.subTest(args=args):
                result = self.run_guest(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("usage:", result.stderr)
                self.assertFalse((self.tmp / "out").exists())
        self.assertEqual(self.logged(), "")

    def test_a_swift_source_without_command_line_tools_stops_before_compiling(self):
        result = self.run_guest(*self.full_args(self.swift))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        summary = (self.tmp / "out" / "summary.txt").read_text(encoding="utf-8")
        self.assertIn("STOPPED: no command line tools", summary)
        self.assertIn("xcode-select -p", self.logged())
        self.assertNotIn("swiftc", self.logged(), "the shim would ask to install the tools in the guest")

    def test_a_prebuilt_reader_runs_without_a_compiler(self):
        result = self.run_guest(*self.full_args(self.binary))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)  # the fake sudo refuses everything
        summary = (self.tmp / "out" / "summary.txt").read_text(encoding="utf-8")
        self.assertIn("system: macOS 12.7.6", summary)
        self.assertIn("accessibility:", summary)
        self.assertIn("keyboard: x-apple.systempreferences:com.apple.preference.keyboard -> window not read", summary)
        self.assertNotIn("swiftc", self.logged())
        self.assertNotIn("xcode-select", self.logged())
        self.assertIn("sudo -n launchctl asuser ", self.logged(), "GUI work runs in the logged-in session")


class PaneTablesTests(unittest.TestCase):
    def run_tables(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run([sys.executable, "-I", str(PANE_TABLES), *args], capture_output=True, text=True,
                              timeout=120)

    def test_a_folder_that_is_not_a_system_volume_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as empty:
            result = self.run_tables("--root", empty, "--check", str(SYSTEM_PANES))
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("not a macOS system volume", result.stderr)

    def test_the_verified_entry_matches_the_tables_of_this_mac(self):
        version_plist = Path("/System/Library/CoreServices/SystemVersion.plist")
        if not version_plist.is_file():
            self.skipTest("not macOS")
        version = plistlib.loads(version_plist.read_bytes())["ProductVersion"]
        # Only macOS 12 and 27 were checked against the tables (section 10); other versions keep VERIFY values.
        if version.split(".")[0] not in ("12", "27"):
            self.skipTest(f"macOS {version} has no table-checked SystemPanes.json entry")
        result = self.run_tables("--root", "/", "--check", str(SYSTEM_PANES))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn("DIFF", result.stdout)
        self.assertNotIn("NOT FOUND", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=1)
