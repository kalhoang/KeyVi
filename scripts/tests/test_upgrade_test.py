# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the scripted upgrade, channel switch and egress checks: the host script scripts/vm/upgrade-test.sh
and the guest scripts (scripts/vm/guest/upgrade-guest.sh and its tools). Run: python3 -I scripts/tests/test_upgrade_test.py

The host script runs with the fake tart, ssh and git of test_vm_lab.py and fake host-load tools, so no virtual machine
starts and nothing is launched. The host-side logic is tested in test_upgrade_report.py, whose helpers are reused.
"""
from __future__ import annotations

import base64
import json
import subprocess
import sys
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import SCRIPTS  # noqa: E402
from test_upgrade_report import (  # noqa: E402
    BUNDLE, DRIVER, FEED_SERVER, GUEST, HOST, NAME, PLAN, REPORT_PATH, SLUG, STORE, UPGRADE, appcast, item, report,
    write_dist,
)
from test_vm_lab import DEV, LabTestCase, write_exe  # noqa: E402


FAKE_IDLE_TOOLS = {
    "sysctl": """#!/bin/bash
case "$*" in
  *vm.loadavg*) echo "{ ${FAKE_LOAD:-1.00} 1.00 1.00 }" ;;
  *memorystatus_vm_pressure_level*) echo "${FAKE_PRESSURE:-1}" ;;
  *) /usr/sbin/sysctl "$@" ;;
esac
""",
    "memory_pressure": """#!/bin/bash
echo "System-wide memory free percentage: ${FAKE_FREE:-60}%"
""",
    "pgrep": """#!/bin/bash
exit 1
""",
    "openssl": """#!/bin/bash
case "$1" in version) echo "OpenSSL 3.9.9 fake" ;; pkeyutl) echo "Signature Verified Successfully" ;; esac
""",
    "git": """#!/bin/bash
printf 'git %s\\n' "$*" >>"$FAKE_DIR/calls.log"
case " $* " in
  *" status "*) exit 0 ;;
  *" rev-parse "*) echo 1234abc ;;
  *" cat-file "*) exit 0 ;;
  *" archive "*) mkdir -p "$FAKE_DIR/empty"; tar -C "$FAKE_DIR/empty" -cf - . ;;
  *) echo "fake git: unsupported $*" >&2; exit 64 ;;
esac
""",
}


class UpgradeScriptTests(LabTestCase):
    """The host script with fake tart, ssh, git, openssl and host-load tools: no VM starts, nothing is launched."""

    def setUp(self) -> None:
        super().setUp()
        for name, text in FAKE_IDLE_TOOLS.items():
            write_exe(self.bin / name, text)
        self.dist = self.tmp / "dist"
        self.prev = write_dist(self.dist / "prev", "1.0.1", 1000199, base64.b64encode(b"\x02" * 32).decode(),
                               commit="1234abc")
        self.cand = write_dist(self.dist / "cand", "1.1.0-beta.1", 1010001, base64.b64encode(b"\x02" * 32).decode())
        self.appcast = self.tmp / "appcast.xml"
        self.write_appcast(published=True)

    def upgrade(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        merged = {"OPENSSL": str(self.bin / "openssl"), "IDLE_POLL": "1", **env}
        return self.script(UPGRADE, "--previous", str(self.dist / "prev"), "--candidate", str(self.dist / "cand"),
                           "--output", str(self.tmp / "run"), "--appcast", str(self.appcast), *args, **merged)

    def write_appcast(self, published: bool) -> None:
        """The appcast the script looks the candidate up in, with or without the candidate's item."""
        size = self.cand["zip"].stat().st_size
        items = [item("1.1.0-beta.1", 1010001, size, "U0lH", "beta")] if published else []
        self.appcast.write_text(appcast(items))

    def test_help_and_usage_errors_start_nothing(self):
        self.assertEqual(self.script(UPGRADE, "--help").returncode, 0)
        self.assertEqual(self.script(UPGRADE).returncode, 2)
        for args in (("--egress-minutes", "0"), ("--memory", "99999"), ("--vm", "../x"), ("--bogus",)):
            with self.subTest(args=args):
                self.assertEqual(self.upgrade(*args).returncode, 2)
        self.assertEqual(self.tart_calls("run"), [])

    def test_an_unpublished_candidate_stops_with_exit_6_before_any_vm(self):
        self.write_appcast(published=False)
        result = self.upgrade("--wait-idle", "0")
        self.assertEqual(result.returncode, 6, result.stderr)
        self.assertIn("--sign", result.stdout)
        self.assertEqual(json.loads((self.tmp / "run" / "result.json").read_text())["verdict"], "ERROR")
        self.assertEqual(self.tart_calls("run"), [])

    def test_sign_asks_sign_update_and_a_hanging_call_stops_that_path(self):
        self.write_appcast(published=False)
        signer = self.tmp / "sign_update"
        write_exe(signer, '#!/bin/bash\necho "sparkle:edSignature=\\"U0lH\\" length=\\"9\\""\n')
        signed = self.upgrade("--sign", "--wait-idle", "0", "--no-watchdog", SPARKLE_SIGN_UPDATE=str(signer),
                              FAKE_NO_AGENT="1")
        self.assertEqual(signed.returncode, 1, signed.stdout + signed.stderr)  # reached the VM, the guest failed
        artefacts = json.loads((self.tmp / "run" / "artefacts.json").read_text())
        self.assertEqual(artefacts["candidate"]["signatureSource"], "sign_update")
        self.assertEqual(self.running(), set())
        hanging = self.tmp / "sign_hang"
        write_exe(hanging, "#!/bin/bash\nexec sleep 30\n")  # one process, like the real sign_update
        stuck = self.upgrade("--sign", "--wait-idle", "0", SPARKLE_SIGN_UPDATE=str(hanging), SIGN_TIMEOUT="1")
        self.assertEqual(stuck.returncode, 6, stuck.stdout + stuck.stderr)
        self.assertIn("did not finish within 1s", stuck.stderr)
        missing = self.upgrade("--sign", "--wait-idle", "0", SPARKLE_SIGN_UPDATE=str(self.tmp / "absent"))
        self.assertEqual(missing.returncode, 6)

    def test_a_busy_host_is_waited_for_and_then_skipped_with_exit_4(self):
        result = self.upgrade("--wait-idle", "0", FAKE_FREE="20")
        self.assertEqual(result.returncode, 4, result.stdout + result.stderr)
        self.assertIn("host busy", result.stderr)
        self.assertIn("free=20%", result.stderr)
        self.assertEqual(json.loads((self.tmp / "run" / "result.json").read_text())["verdict"], "SKIPPED")
        self.assertEqual(self.tart_calls("run"), [])

    def test_a_failing_guest_still_stops_and_deletes_the_throwaway_clone(self):
        result = self.upgrade("--wait-idle", "0", "--no-watchdog",
                              FAKE_NO_AGENT="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn(f"clone {DEV} {DEV}-upgrade", "\n".join(self.calls()))
        self.assertIn(f"set {DEV}-upgrade --memory 4096 --cpu 4", "\n".join(self.tart_calls("set")))
        self.assertFalse((self.fake / "vms" / f"{DEV}-upgrade").exists())
        self.assertEqual(self.running(), set())
        params = (self.tmp / "run" / "in" / "params.env").read_text()
        self.assertIn("SEED_CHANNEL=beta", params)
        self.assertIn("PROBE_BUILD=1010002", params)
        self.assertTrue((self.tmp / "run" / "in" / "feed" / "appcast-channel.xml").is_file())
        self.assertTrue((self.tmp / "run" / "result.json").is_file())

    def test_it_refuses_while_another_vm_runs(self):
        self.assertEqual(self.lab("up", DEV).returncode, 0)
        result = self.upgrade("--wait-idle", "0")
        self.assertEqual(result.returncode, 4, result.stderr)  # the idle check counts running VMs first
        self.assertIn("runningVMs=1", result.stderr)
        self.lab("down", DEV)

    def test_the_watchdog_runs_beside_the_vm_and_its_stop_is_reported(self):
        ops = self.tmp / "ops"
        ops.mkdir()
        write_exe(ops / "watchdog.sh", '#!/bin/bash\nOPS="$(dirname "$0")"\necho "x level=4 free=9%: stop vm"\n'
                                       'while [ ! -e "$OPS/watchdog.stop" ]; do sleep 0.1; done\n')
        result = self.upgrade("--wait-idle", "0", "--watchdog", str(ops),
                              FAKE_NO_AGENT="1")
        self.assertEqual(result.returncode, 5, result.stdout + result.stderr)
        self.assertTrue((ops / "watchdog.stop").exists())
        self.assertIn("stop vm", (self.tmp / "run" / "watchdog-stops.txt").read_text())
        self.assertEqual(json.loads((self.tmp / "run" / "result.json").read_text())["verdict"], "ABORTED")

    def test_a_watchdog_ended_by_another_script_is_started_again(self):
        ops = self.tmp / "ops2"
        ops.mkdir()
        write_exe(ops / "watchdog.sh", '#!/bin/bash\necho "start"\n')  # ends at once, as when watchdog.stop appears
        result = self.upgrade("--wait-idle", "0", "--watchdog", str(ops), FAKE_NO_AGENT="1", VM_AGENT_TIMEOUT="3")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        restarts = (self.tmp / "run" / "watchdog-restarts.txt").read_text()
        self.assertIn("started again", restarts)
        self.assertGreaterEqual(len((ops / "watchdog.log").read_text().splitlines()), 2)
        self.assertTrue((ops / "watchdog.stop").exists())
        self.assertIn("started again", (self.tmp / "run" / "summary.txt").read_text())


class GuestScriptTests(unittest.TestCase):
    def test_every_guest_part_refuses_a_real_mac_before_doing_anything(self):
        out = subprocess.run(["bash", str(GUEST), "--in", "/nonexistent", "--out", "/nonexistent"],
                             capture_output=True, text=True)
        if subprocess.run(["sysctl", "-n", "kern.hv_vmm_present"], capture_output=True, text=True).stdout.strip() \
                != "1":
            self.assertEqual(out.returncode, 3)
            self.assertIn("not inside a virtual machine", out.stderr)
        text = GUEST.read_text(encoding="utf-8")
        self.assertLess(text.index("kern.hv_vmm_present"), text.index("while [ $# -gt 0 ]"))
        for path in (DRIVER, STORE):
            source = path.read_text(encoding="utf-8")
            guard = source.index("guard insideVirtualMachine()")
            self.assertLess(guard, source.index("let arguments = Arguments("), path.name)
        server = FEED_SERVER.read_text(encoding="utf-8")
        self.assertLess(server.index("if not inside_virtual_machine()"), server.index("parser.parse_args"))

    def test_the_guest_runs_under_the_system_bash_and_never_hard_codes_the_brand(self):
        for path in (GUEST, UPGRADE, REPORT_PATH, DRIVER, STORE, FEED_SERVER, PLAN):
            text = path.read_text(encoding="utf-8")
            for value in (NAME, SLUG, HOST, BUNDLE):
                self.assertNotIn(value, text, f"{path.name} names {value}; read scripts/brand.env instead")
        guest = GUEST.read_text(encoding="utf-8")
        for bashism in ("declare -A", "mapfile", "readarray", "${!", ",,}", "^^}"):
            self.assertNotIn(bashism, guest)

    def test_the_seed_plan_meets_qa_r40(self):
        plan = json.loads(PLAN.read_text(encoding="utf-8"))
        settings = [k for k in plan["settings"] if k not in report.UPDATE_SETTINGS]
        self.assertGreaterEqual(len(settings), 10)
        self.assertEqual(len(plan["macros"]), 50)
        self.assertEqual(len({m["trigger"] for m in plan["macros"]}), 50)
        self.assertGreaterEqual(len(plan["appRules"]), 1)
        self.assertGreaterEqual(len(plan["rememberedModes"]), 1)
        self.assertGreaterEqual(len(plan["ruleOverrides"]), 1)
        self.assertNotIn("typingMethod", plan["settings"])  # the typing check types Telex keys
        self.assertTrue(all(o["rule"]["id"].startswith("user.") for o in plan["ruleOverrides"]))

    def test_the_guest_takes_the_exit_snapshot_before_the_new_version_starts_and_types_in_testhost(self):
        guest = GUEST.read_text(encoding="utf-8")
        relaunch = guest.index('"$driver" relaunch')
        self.assertLess(relaunch, guest.index('press "$bundle" "${relaunch_args[@]}" --timeout 20'))
        self.assertIn("--snapshot-dst \"$out/snapshots/at-exit\"", guest)
        self.assertIn('"$prev_store" seed --dir "$support" --written-by "$PREV_VERSION"', guest)
        self.assertIn("grant-tcc.sh", guest)
        self.assertIn('printf \'127.0.0.1 %s\\n::1 %s\\n\' "$APP_SITE_HOST"', guest)


class RunShTests(unittest.TestCase):
    def test_the_suite_loop_runs_this_file(self):
        text = (SCRIPTS / "tests" / "run.sh").read_text(encoding="utf-8")
        loop = next(line for line in text.splitlines() if line.startswith("for suite in"))
        self.assertIn("test_upgrade_test", loop)


if __name__ == "__main__":
    unittest.main(verbosity=1)
