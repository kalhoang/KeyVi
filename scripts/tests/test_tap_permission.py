# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the tap permission check (docs/runbooks/vm-test-lab.md section 11): scripts/vm/tap-permission.sh and
scripts/vm/guest/tap-permission-probe.swift. Run: python3 -I scripts/tests/test_tap_permission.py

The host mode runs against the fake `tart` and `ssh` of test_vm_lab.py (no virtual machine starts), with a fake
`pgrep` (the Safari rule), a fake `swiftc` and a fake `codesign`. The guest mode runs with a fake `sysctl` and fake
system tools, so it never resets or writes TCC, starts a probe or posts a key on the host.
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

from support import SCRIPTS  # noqa: E402
from test_vm_lab import DEV, FAKE_SSH, LabTestCase, brand_value, write_exe  # noqa: E402

TAP = SCRIPTS / "vm" / "tap-permission.sh"
PROBE = SCRIPTS / "vm" / "guest" / "tap-permission-probe.swift"
PHASES = ["fresh", "accessibility-live", "accessibility-relaunch", "input-monitoring-live", "input-monitoring-relaunch"]

FAKE_PGREP = '#!/bin/sh\necho "pgrep $*" >>"$FAKE_DIR/calls.log"\n[ "$*" = "-x Safari" ] && [ "${FAKE_SAFARI:-0}" = 1 ]\n'

FAKE_SWIFTC = r"""#!/bin/bash
printf 'swiftc %s\n' "$*" >>"$FAKE_DIR/calls.log"
[ -z "${FAKE_SWIFTC_FAIL:-}" ] || { echo "error: fake compiler failure" >&2; exit 1; }
while [ $# -gt 0 ]; do
  case "$1" in -o) printf '#!/bin/sh\nexit 0\n' >"$2"; chmod +x "$2"; shift 2 ;; *) shift ;; esac
done
"""

FAKE_CODESIGN = '#!/bin/sh\necho "codesign $*" >>"$FAKE_DIR/calls.log"\n'

# Answers the guest commands tap-permission.sh sends, keeps the archive it pushes, delegates the rest to the lab fake.
TAP_SSH = r"""#!/bin/bash
remote="${@: -1}"
case "$remote" in
  *"csrutil status"*) echo "System Integrity Protection status: ${FAKE_SIP:-disabled}."; exit 0 ;;
  *"-xf -"*) printf 'ssh %s\n' "$*" >>"$FAKE_DIR/calls.log"; cat >"$FAKE_DIR/pushed.tar"; exit 0 ;;
esac
exec "$FAKE_DIR/ssh-lab" "$@"
"""


class TapPermissionHostTests(LabTestCase):
    def setUp(self) -> None:
        super().setUp()
        write_exe(self.bin / "pgrep", FAKE_PGREP)
        write_exe(self.bin / "swiftc", FAKE_SWIFTC)
        write_exe(self.bin / "codesign", FAKE_CODESIGN)
        write_exe(self.fake / "ssh-lab", FAKE_SSH)
        write_exe(self.bin / "ssh", TAP_SSH)

    def run_tap(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return self.script(TAP, *args, **env)

    def test_help_and_usage_errors(self):
        result = self.run_tap("--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Usage: scripts/vm/tap-permission.sh [options]", result.stdout)
        for args, message in ((("--keys", "0"), "--keys must be a whole number from 1 to 50"),
                              (("--keys", "51"), "--keys must be a whole number from 1 to 50"),
                              (("--keys", "ten"), "--keys must be a whole number from 1 to 50"),
                              (("--vm",), "--vm needs a value"),
                              (("--vm", "bad name"), "invalid VM name"),
                              (("--bogus",), "unknown option")):
            with self.subTest(args=args):
                result = self.run_tap(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn(message, result.stderr)
        self.assertEqual(self.tart_calls("run") + self.tart_calls("clone"), [])

    def test_it_refuses_while_safari_runs_before_any_build_or_tart_call(self):
        result = self.run_tap(FAKE_SAFARI="1")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("Safari is open on the host", result.stderr)
        self.assertIn("pgrep -x Safari", self.calls())
        self.assertEqual([c for c in self.calls() if c.startswith(("tart ", "swiftc ", "codesign "))], [])

    def test_the_probe_is_built_on_the_host_before_any_vm_starts(self):
        result = self.run_tap(FAKE_SWIFTC_FAIL="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("could not build tap-permission-probe", result.stderr)
        builds = [c for c in self.calls() if c.startswith("swiftc ")]
        self.assertEqual(len(builds), 1, self.calls())
        self.assertIn("-target arm64-apple-macos12.0", builds[0])
        self.assertIn(str(PROBE), builds[0])
        self.assertEqual(self.tart_calls("clone") + self.tart_calls("run"), [], "no VM before the build")

    def test_a_signed_bundle_the_typer_and_the_scripts_go_to_the_guest_and_the_clone_is_deleted(self):
        out = self.tmp / "run"
        result = self.run_tap("--keys", "7", "--output", str(out))
        calls = self.calls()
        self.assertEqual(len(self.tart_calls("clone")), 1, calls)
        self.assertIn(f"clone {DEV} {DEV}-tap", self.tart_calls("clone")[0])
        build = calls.index(next(c for c in calls if c.startswith("swiftc ")))
        signs = [i for i, c in enumerate(calls) if c.startswith("codesign --force --sign - ")]
        self.assertEqual(len(signs), 2, calls)  # the bundle and the typer, ad hoc
        self.assertLess(max(build, *signs), calls.index(self.tart_calls("clone")[0]), "built and signed first")
        with tarfile.open(self.fake / "pushed.tar") as archive:
            names = set(archive.getnames())
            info = plistlib.loads(archive.extractfile("tap/TapProbe.app/Contents/Info.plist").read())
        self.assertLessEqual({"tap/TapProbe.app/Contents/MacOS/tap-permission-probe", "tap/tap-typer",
                              "tap/grant-tcc.sh", "tap/tap-permission.sh"}, names)
        self.assertEqual(info["CFBundleIdentifier"], brand_value("APP_BUNDLE_ID_DEV") + ".tapprobe")
        self.assertTrue(info["LSUIElement"])
        guest = [c for c in self.tart_calls("exec") if "tap-permission.sh guest" in c]
        self.assertEqual(len(guest), 1, calls)
        self.assertIn("--keys 7", guest[0])
        self.assertIn("--grant", guest[0])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)  # nothing ran in the fake guest
        self.assertIn("RESULT: FAIL", result.stdout)
        self.assertEqual(self.running(), set(), result.stderr)
        self.assertFalse((self.fake / "vms" / f"{DEV}-tap").exists(), "the throwaway clone is deleted")
        self.assertTrue((self.fake / "vms" / DEV).exists(), "the base VM is kept")

    def test_a_guest_with_sip_enabled_is_refused_and_cleaned_up(self):
        result = self.run_tap(FAKE_SIP="enabled")
        self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
        self.assertIn("SIP is enabled", result.stderr)
        self.assertEqual([c for c in self.tart_calls("exec") if "guest" in c], [])
        self.assertEqual(self.running(), set())
        self.assertFalse((self.fake / "vms" / f"{DEV}-tap").exists())


class TapPermissionGuestTests(unittest.TestCase):
    """The guest mode resets and writes TCC, uses sudo, starts the probe and posts keys: it must refuse to run anywhere
    but inside a VM (kern.hv_vmm_present = 1), and inside one it must run the phases in order."""

    TOOLS = ("sudo", "open", "pkill", "tccutil", "csrutil", "sw_vers")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "calls.log"
        write_exe(self.bin / "sysctl", '#!/bin/sh\n[ "$*" = "-n kern.hv_vmm_present" ] || exit 1\necho "$FAKE_VMM"\n')
        write_exe(self.bin / "pgrep", f'#!/bin/sh\necho "pgrep $*" >>"{self.log}"\nexit 1\n')
        for tool in self.TOOLS:
            write_exe(self.bin / tool, f'#!/bin/sh\necho "{tool} $*" >>"{self.log}"\nexit 0\n')
        self.bundle = self.tmp / "inbox" / "TapProbe.app"
        (self.bundle / "Contents" / "MacOS").mkdir(parents=True)
        (self.bundle / "Contents" / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleIdentifier": "com.example.tapprobe", "CFBundleExecutable": "tap-permission-probe"}))
        self.typer = self.tmp / "inbox" / "tap-typer"
        write_exe(self.typer, f'#!/bin/sh\necho "typer $*" >>"{self.log}"\n')
        self.grant = self.tmp / "inbox" / "grant-tcc.sh"
        self.grant.write_text("# fake\n", encoding="utf-8")

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_guest(self, *args: str, vmm: str = "1") -> subprocess.CompletedProcess:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.tmp), "FAKE_VMM": vmm,
               "LC_ALL": "C", "TAP_PERMISSION_SETTLE": "0", "TAP_PERMISSION_DRAIN": "0"}
        return subprocess.run(["bash", str(TAP), "guest", *args], capture_output=True, text=True, env=env,
                              cwd=self.tmp, stdin=subprocess.DEVNULL, timeout=60)

    def logged(self) -> list[str]:
        return self.log.read_text(encoding="utf-8").splitlines() if self.log.exists() else []

    def full_args(self) -> list[str]:
        return ["--out", str(self.tmp / "out"), "--bundle", str(self.bundle), "--typer", str(self.typer),
                "--grant", str(self.grant), "--keys", "3"]

    def test_it_refuses_to_run_outside_a_virtual_machine(self):
        for vmm in ("0", ""):
            with self.subTest(vmm=vmm):
                result = self.run_guest(*self.full_args(), vmm=vmm)
                self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                self.assertIn("refusing: not inside a virtual machine", result.stderr)
                self.assertEqual(self.logged(), [], "no tool may run before the guard")
                self.assertFalse((self.tmp / "out").exists())

    def test_inside_a_virtual_machine_usage_errors_exit_2(self):
        missing = self.full_args()
        missing[missing.index("--typer") + 1] = str(self.tmp / "missing")
        for args in ([], ["--out"], self.full_args()[:-2] + ["--keys", "0"], self.full_args()[:-2] + ["--keys", "x"],
                     missing):
            with self.subTest(args=args):
                result = self.run_guest(*args)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("Usage:", result.stderr)
        self.assertEqual(self.logged(), [])

    def test_the_phases_run_in_order_with_only_the_grants_each_one_names(self):
        result = self.run_guest(*self.full_args())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("GUEST RESULT: PASS", result.stdout)
        markers = [line for line in (self.tmp / "out" / "probe.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(markers, [f'{{"phase":"{name}","typed":3}}' for name in PHASES])
        log = self.logged()
        self.assertIn("tccutil reset All com.example.tapprobe", log, "fresh TCC for the probe")
        installed = self.tmp / "Applications" / "TapProbe.app"
        grants = [line for line in log if line.startswith("sudo -n bash ")]
        self.assertEqual(len(grants), 3, log)
        self.assertIn("--service kTCCServiceAccessibility --service kTCCServicePostEvent", grants[0])
        self.assertIn(f"--binary {self.typer}", grants[0])
        self.assertTrue(grants[1].endswith(f"--service kTCCServiceAccessibility --bundle {installed}"), grants[1])
        self.assertTrue(grants[2].endswith(f"--service kTCCServiceListenEvent --bundle {installed}"), grants[2])
        self.assertEqual(log.index(grants[0]) < log.index(grants[1]) < log.index(grants[2]), True)
        opens = [line for line in log if line.startswith("open ")]
        self.assertEqual(len(opens), 3, log)  # the first start and the two relaunches
        self.assertIn(f"-n -g -a {installed} --args probe --out", opens[0])
        kills = [line for line in log if line.startswith("pkill ")]
        self.assertTrue(kills and all(line == f"pkill -f {installed}/Contents/MacOS/tap-permission-probe"
                                      for line in kills), kills)
        self.assertEqual([line for line in log if line.startswith("typer ")], ["typer type --count 3"] * 5)


class TapPermissionSummaryTests(unittest.TestCase):
    def summarize(self, text: str) -> subprocess.CompletedProcess:
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "probe.jsonl"
            path.write_text(text, encoding="utf-8")
            return subprocess.run(["bash", str(TAP), "summarize", "--input", str(path)], capture_output=True,
                                  text=True, timeout=60)

    @staticmethod
    def line(pid: int, keys: int, echoes: int, posted: int, **flags: bool) -> str:
        values = {"ax": False, "postPreflight": False, "listenPreflight": False, "activeTap": False,
                  "listenOnlyTapNow": False}
        values.update(flags)
        fields = ",".join(f'"{name}":{str(value).lower()}' for name, value in values.items())
        return f'{{"t":1,"pid":{pid},{fields},"tapCreateAttempts":1,"keys":{keys},"posted":{posted},' \
               f'"echoes":{echoes},"tapDisabled":0}}\n'

    def test_the_table_counts_each_phase_on_the_process_that_ended_it(self):
        text = ('{"phase":"fresh","typed":10}\n' + self.line(100, 0, 0, 1) + self.line(100, 0, 0, 2)
                + '{"phase":"accessibility-live","typed":10}\n'
                + self.line(100, 0, 0, 3, ax=True) + self.line(100, 10, 4, 7, ax=True, activeTap=True)
                + '{"phase":"accessibility-relaunch","typed":10}\n'
                + self.line(100, 12, 5, 8, ax=True, activeTap=True)  # the old process, before it was stopped
                + self.line(200, 0, 0, 1, ax=True, postPreflight=True, activeTap=True)
                + self.line(200, 10, 3, 4, ax=True, postPreflight=True, activeTap=True)
                + '{"phase":"input-monitoring-live","typed":10}\n')
        result = self.summarize(text)
        self.assertEqual(result.returncode, 0, result.stderr)
        rows = {line.split()[0]: line.split() for line in result.stdout.splitlines()[1:]}
        self.assertEqual(rows["fresh"][1:], ["no", "no", "no", "no", "no", "0/10", "0/1"])
        self.assertEqual(rows["accessibility-live"][1:], ["yes", "no", "no", "yes", "no", "10/10", "4/4"])
        self.assertEqual(rows["accessibility-relaunch"][1:], ["yes", "yes", "no", "yes", "no", "10/10", "3/3"])
        self.assertIn("input-monitoring-live", result.stdout)
        self.assertIn("(no probe line)", result.stdout)

    def test_a_missing_log_is_a_usage_error(self):
        result = subprocess.run(["bash", str(TAP), "summarize", "--input", "/nonexistent/probe.jsonl"],
                                capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 2)
        self.assertIn("no such probe log", result.stderr)


class TapPermissionProbeSourceTests(unittest.TestCase):
    """The probe is compiled on the host but must never run there, and it records counts, never keys (PLT-R901)."""

    def test_the_probe_refuses_a_real_mac_before_anything_else(self):
        source = PROBE.read_text(encoding="utf-8")
        guard = source.index("guard insideVirtualMachine()")
        self.assertLess(guard, source.index("let arguments = "))
        self.assertLess(guard, source.index("NSApplication.shared"))

    def test_the_probe_mirrors_the_app_tap_and_never_records_a_key(self):
        source = PROBE.read_text(encoding="utf-8")
        self.assertIn("tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap", source)
        self.assertIn("options: .listenOnly", source)
        self.assertNotIn("keyboardEventKeycode", source)
        self.assertNotIn("keyboardGetUnicodeString", source)


if __name__ == "__main__":
    unittest.main(verbosity=1)
