# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the tart VM lab scripts (scripts/vm). Run: python3 -I scripts/tests/test_vm_lab.py

A fake `tart`, `ssh` and `ssh-keygen` on PATH stand in for the real tools, so no virtual machine starts and no
network connection is made. The fakes keep their state in a temporary directory and log every call.
"""
from __future__ import annotations

import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/tests free of __pycache__
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS  # noqa: E402


def brand_value(key: str) -> str:
    """VM names follow APP_SLUG of scripts/brand.env, as scripts/vm/lib.sh derives them."""
    for line in (REPO / "scripts" / "brand.env").read_text(encoding="utf-8").splitlines():
        match = re.match(rf'^{key}="(.*)"$', line)
        if match:
            return match.group(1)
    raise AssertionError(f"{key} missing from scripts/brand.env")


SLUG = brand_value("APP_SLUG")
MONTEREY = f"{SLUG}-monterey"
DEV = f"{SLUG}-dev"

LAB = SCRIPTS / "vm" / "lab.sh"
SMOKE = SCRIPTS / "vm" / "smoke-macos12.sh"
GRANT = SCRIPTS / "vm" / "grant-tcc.sh"
MACHO = SCRIPTS / "vm" / "macho-info.pl"
GUEST = SCRIPTS / "vm" / "guest" / "smoke-guest.sh"
INTEGRATION_GUEST = SCRIPTS / "vm" / "guest" / "integration-guest.sh"
INTEGRATION = SCRIPTS / "vm" / "integration-dev.sh"

FAKE_TART = r"""#!/bin/bash
# Fake tart: VMs are files in $FAKE_DIR/vms, running VMs have a pid file in $FAKE_DIR/running.
d="$FAKE_DIR"
mkdir -p "$d/vms" "$d/running"
printf 'tart TART_HOME=%s NOPRUNE=%s %s\n' "${TART_HOME:-}" "${TART_NO_AUTO_PRUNE:-}" "$*" >>"$d/calls.log"
cmd="$1"; shift
case "$cmd" in
  list)
    quiet=0
    for a in "$@"; do [ "$a" = "--quiet" ] && quiet=1; done
    [ $quiet -eq 1 ] || echo "Source Name Disk Size Accessed State"
    for f in "$d"/vms/*; do
      [ -e "$f" ] || continue
      n=$(basename "$f"); s=stopped; [ -e "$d/running/$n" ] && s=running
      if [ $quiet -eq 1 ]; then echo "$n"; else echo "local $n 50 20 2 minutes ago $s"; fi
    done ;;
  run)
    n="${@: -1}"
    [ -e "$d/vms/$n" ] || { echo "VM $n does not exist" >&2; exit 1; }
    [ -z "${FAKE_RUN_FAIL:-}" ] || { echo "fake run failure" >&2; exit 1; }
    echo $$ >"$d/running/$n"
    trap 'rm -f "$d/running/$n"; exit 143' TERM
    i=0
    while [ -e "$d/running/$n" ] && [ $i -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    rm -f "$d/running/$n" ;;
  ip)
    [ -e "$d/running/$1" ] && [ -z "${FAKE_NO_IP:-}" ] || exit 1
    echo 192.168.64.9 ;;
  stop)
    [ -n "${FAKE_STOP_IGNORED:-}" ] || rm -f "$d/running/$1" ;;
  set) ;;
  clone)
    [ -e "$d/vms/$1" ] && [ ! -e "$d/vms/$2" ] || exit 1
    touch "$d/vms/$2" ;;
  delete)
    rm -f "$d/vms/$1" ;;
  exec)
    [ -z "${FAKE_NO_AGENT:-}" ] || { echo "Failed to connect to the guest agent" >&2; exit 1; }
    shift; "$@" ;;
  *) echo "fake tart: unsupported $cmd" >&2; exit 64 ;;
esac
"""

FAKE_SSH = r"""#!/bin/bash
# Fake ssh: key authentication works once the password flow ran; remote commands are logged, not run.
d="$FAKE_DIR"
printf 'ssh askpass=%s %s\n' "${SSH_ASKPASS_REQUIRE:-}" "$*" >>"$d/calls.log"
if [ -n "${FAKE_SSH_DOWN:-}" ]; then echo "ssh: connect to host 192.168.64.9 port 22: Connection refused" >&2; exit 255; fi
remote="${@: -1}"
if [ "${SSH_ASKPASS_REQUIRE:-}" = force ]; then
  pw=$("$SSH_ASKPASS" "admin@192.168.64.9's password: ")
  [ "$pw" = "${FAKE_SSH_PASSWORD:-admin}" ] || { echo "Permission denied (password)." >&2; exit 255; }
  cat >"$d/installed-key"
  exit 0
fi
case "$*" in
  *PubkeyAuthentication=no*) echo "fake ssh: password flow without askpass" >&2; exit 255 ;;
esac
if [ ! -e "$d/installed-key" ]; then echo "admin@192.168.64.9: Permission denied (publickey,password)." >&2; exit 255; fi
case "$remote" in
  *"shutdown -h now"*) [ "${FAKE_SSH_EXIT:-0}" = 0 ] || exit "$FAKE_SSH_EXIT"; rm -f "$d"/running/*; exit 0 ;;
  *smoke-guest.sh*) cat >/dev/null; echo "FAIL arm64: fake guest"; exit "${FAKE_GUEST_EXIT:-1}" ;;
  *"-cf -"*) exit "${FAKE_PULL_EXIT:-1}" ;;
  *"-xf -"*) cat >/dev/null; exit 0 ;;
esac
exit "${FAKE_SSH_EXIT:-0}"
"""

FAKE_SSH_KEYGEN = r"""#!/bin/bash
d="$FAKE_DIR"
printf 'ssh-keygen %s\n' "$*" >>"$d/calls.log"
out=""
while [ $# -gt 0 ]; do
  case "$1" in -f) out="$2"; shift 2 ;; -R) shift 2 ;; *) shift ;; esac
done
case " $* " in *) ;; esac
if [ -n "$out" ] && grep -q -- '-t ed25519' <<<"$(tail -n 1 "$d/calls.log")"; then
  echo "PRIVATE" >"$out"; echo "ssh-ed25519 AAAAfake lab-test-key" >"$out.pub"
fi
exit 0
"""


def write_exe(path: Path, text: str) -> None:
    path.write_text(text, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class LabTestCase(unittest.TestCase):
    """A temporary lab root, fake tools on PATH and the two local VMs MONTEREY and DEV."""

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.fake = self.tmp / "fake"
        (self.fake / "vms").mkdir(parents=True)
        (self.fake / "running").mkdir()
        for vm in (MONTEREY, DEV):
            (self.fake / "vms" / vm).touch()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        write_exe(self.bin / "tart", FAKE_TART)
        write_exe(self.bin / "ssh", FAKE_SSH)
        write_exe(self.bin / "ssh-keygen", FAKE_SSH_KEYGEN)
        self.root = self.tmp / "lab"
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": str(self.home),
            "FAKE_DIR": str(self.fake),
            "VM_LAB_ROOT": str(self.root),
            "TART_BIN": str(self.bin / "tart"),
            "VM_BOOT_TIMEOUT": "5",
            "VM_STOP_TIMEOUT": "2",
            "VM_LAB_POLL": "0.1",
            "LC_ALL": "C",
        }
        for name in ("TMPDIR",):
            if name in os.environ:
                self.env[name] = os.environ[name]

    def tearDown(self) -> None:
        for pid_file in (self.fake / "running").glob("*"):
            pid_file.unlink(missing_ok=True)  # the fake `tart run` loops exit within 0.1 s
        time.sleep(0.3)
        self._tmp.cleanup()

    def lab(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return self.script(LAB, *args, **env)

    def script(self, path: Path, *args: str, **env: str) -> subprocess.CompletedProcess:
        merged = dict(self.env)
        merged.update(env)
        return subprocess.run(["bash", str(path), *args], capture_output=True, text=True, env=merged,
                              stdin=subprocess.DEVNULL, timeout=60)

    def calls(self) -> list[str]:
        log = self.fake / "calls.log"
        return log.read_text(encoding="utf-8").splitlines() if log.exists() else []

    def tart_calls(self, verb: str) -> list[str]:
        return [c for c in self.calls() if c.startswith("tart ") and f" {verb} " in f"{c} "]

    def running(self) -> set[str]:
        return {p.name for p in (self.fake / "running").iterdir()}


class UsageTests(LabTestCase):
    def test_help_usage_and_unknown_commands(self):
        self.assertEqual(self.lab("--help").returncode, 0)
        self.assertIn("up <vm>", self.lab("--help").stdout)
        self.assertEqual(self.lab().returncode, 2)
        result = self.lab("teleport")
        self.assertEqual(result.returncode, 2)
        self.assertIn("unknown command", result.stderr)

    def test_invalid_vm_names_are_rejected_before_tart_runs(self):
        for name in ("../vm", "a b", "-rf", "vm;rm", ""):
            with self.subTest(name=name):
                result = self.lab("up", name)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.tart_calls("run"), [])

    def test_unknown_vm_is_rejected(self):
        result = self.lab("up", f"{SLUG}-ventura")
        self.assertEqual(result.returncode, 2)
        self.assertIn(f"no local VM named {SLUG}-ventura", result.stderr)

    def test_bad_memory_and_cpu_values_are_rejected(self):
        for args in (("--memory", "lots"), ("--memory", "999999"), ("--memory", "512"), ("--cpus", "0"),
                     ("--cpus", "64"), ("--cpus",), ("--colour", "blue")):
            with self.subTest(args=args):
                result = self.lab("up", MONTEREY, *args)
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.tart_calls("run"), [])

    def test_a_keys_folder_under_the_users_ssh_folder_is_refused(self):
        result = self.lab("up", MONTEREY, VM_LAB_KEYS=str(self.home / ".ssh" / "lab"))
        self.assertEqual(result.returncode, 3)
        self.assertIn("never use", result.stderr)
        self.assertFalse((self.home / ".ssh").exists())


class UpDownTests(LabTestCase):
    def test_defaults_are_sized_per_vm_and_every_tart_call_sets_tart_home(self):
        for vm, memory, cpus in ((MONTEREY, "4096", "2"), (DEV, "6144", "4")):
            with self.subTest(vm=vm):
                up = self.lab("up", vm)
                self.assertEqual(up.returncode, 0, up.stderr)
                self.assertIn("192.168.64.9", up.stdout)
                self.assertIn(f"set {vm} --memory {memory} --cpu {cpus}", "\n".join(self.tart_calls("set")))
                self.assertIn(vm, self.running())
                down = self.lab("down", vm)
                self.assertEqual(down.returncode, 0, down.stderr)
                self.assertEqual(self.running(), set())
        expected = f"TART_HOME={self.root / 'home'} "
        self.assertTrue(all(expected in c for c in self.calls() if c.startswith("tart ")), self.calls())

    def test_memory_and_cpus_can_be_overridden(self):
        up = self.lab("up", MONTEREY, "--memory", "3072", "--cpus", "3")
        self.assertEqual(up.returncode, 0, up.stderr)
        self.assertIn(f"set {MONTEREY} --memory 3072 --cpu 3", "\n".join(self.tart_calls("set")))
        self.lab("down", MONTEREY)

    def test_a_second_vm_is_refused_while_one_runs(self):
        self.assertEqual(self.lab("up", MONTEREY).returncode, 0)
        result = self.lab("up", DEV)
        self.assertEqual(result.returncode, 3)
        self.assertIn(f"{MONTEREY} is running", result.stderr)
        self.assertEqual(len(self.tart_calls("run")), 1)
        self.assertEqual(self.running(), {MONTEREY})
        again = self.lab("up", MONTEREY)
        self.assertEqual(again.returncode, 0, again.stderr)
        self.assertIn("already running", again.stderr)
        self.assertEqual(len(self.tart_calls("run")), 1)
        self.lab("down", MONTEREY)

    def test_the_key_is_installed_once_with_the_password_and_home_ssh_is_never_used(self):
        env = {"VM_SSH_PASSWORD": "s3cret-pw", "FAKE_SSH_PASSWORD": "s3cret-pw"}
        self.assertEqual(self.lab("up", MONTEREY, **env).returncode, 0)
        self.lab("down", MONTEREY)
        self.assertEqual(self.lab("up", MONTEREY, **env).returncode, 0)
        self.lab("down", MONTEREY)
        keys = self.root / "keys"
        self.assertTrue((keys / "id_ed25519").exists())
        self.assertEqual((self.fake / "installed-key").read_text().strip(), "ssh-ed25519 AAAAfake lab-test-key")
        ssh_calls = [c for c in self.calls() if c.startswith("ssh ")]
        self.assertEqual(sum("askpass=force" in c for c in ssh_calls), 1, ssh_calls)
        for call in ssh_calls:
            self.assertIn(f"UserKnownHostsFile={keys / 'known_hosts'}", call)
            self.assertIn("StrictHostKeyChecking=no", call)
            self.assertIn("-F /dev/null", call)
            self.assertIn("IdentitiesOnly=yes", call)
        self.assertFalse((self.home / ".ssh").exists())
        leaked = [str(p) for p in self.tmp.rglob("*") if p.is_file() and b"s3cret-pw" in p.read_bytes()]
        self.assertEqual(leaked, [], "the password must never be written to a file or a command line")
        self.assertEqual(stat.S_IMODE(keys.stat().st_mode), 0o700)

    def test_a_wrong_password_fails_and_stops_the_vm(self):
        result = self.lab("up", MONTEREY, VM_SSH_PASSWORD="wrong")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("could not install", result.stderr)
        self.assertEqual(self.running(), set())

    def test_a_vm_that_never_answers_ssh_is_stopped_on_failure(self):
        result = self.lab("up", MONTEREY, FAKE_SSH_DOWN="1", VM_BOOT_TIMEOUT="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("SSH", result.stderr)
        self.assertEqual(self.running(), set())
        self.assertTrue(self.tart_calls("stop"), "the failed up must stop the VM it started")

    def test_a_vm_without_an_ip_is_stopped_on_failure(self):
        result = self.lab("up", MONTEREY, FAKE_NO_IP="1", VM_BOOT_TIMEOUT="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("no IP address", result.stderr)
        self.assertEqual(self.running(), set())

    def test_a_tart_run_that_exits_at_once_is_reported(self):
        result = self.lab("up", MONTEREY, FAKE_RUN_FAIL="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("tart run exited", result.stderr)

    def test_down_falls_back_to_killing_tart_run(self):
        self.assertEqual(self.lab("up", MONTEREY).returncode, 0)
        result = self.lab("down", MONTEREY, FAKE_STOP_IGNORED="1", FAKE_SSH_EXIT="1")
        (self.fake / "running").mkdir(exist_ok=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("forced", result.stderr)
        self.assertEqual(self.running(), set())

    def test_down_of_a_stopped_vm_is_a_no_op(self):
        result = self.lab("down", DEV)
        self.assertEqual(result.returncode, 0)
        self.assertIn("not running", result.stderr)

    def test_with_stops_the_vm_even_when_the_command_fails(self):
        result = self.lab("with", MONTEREY, "--", "sh", "-c", 'echo "ip=$VM_IP name=$VM_NAME"; exit 7')
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertIn(f"ip=192.168.64.9 name={MONTEREY}", result.stdout)
        self.assertEqual(self.running(), set())

    def test_with_does_not_stop_a_vm_it_did_not_start(self):
        self.assertEqual(self.lab("up", MONTEREY).returncode, 0)
        result = self.lab("with", MONTEREY, "--", "true")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.running(), {MONTEREY})
        self.lab("down", MONTEREY)

    def test_with_hands_its_standard_input_to_the_host_command(self):
        """self-hosted-runner.md section 8.3 feeds the runner token on stdin: booting the VM must not consume it,
        and it must reach no tart or ssh command line."""
        merged = dict(self.env)
        result = subprocess.run(["bash", str(LAB), "with", MONTEREY, "--", "sh", "-c", 'read -r t; echo "got=$t"'],
                                input="token-on-stdin\n", capture_output=True, text=True, env=merged, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("got=token-on-stdin", result.stdout)
        self.assertNotIn("token-on-stdin", "\n".join(self.calls()))
        self.assertEqual(self.running(), set())

    def test_with_stops_the_vm_on_ctrl_c_and_on_sigterm(self):
        """Ctrl-C (SIGINT to the process group) and SIGTERM must still run the EXIT trap that stops the VM."""
        for sig, code in ((signal.SIGINT, 130), (signal.SIGTERM, 143)):
            with self.subTest(signal=sig.name):
                started = self.tmp / f"started-{sig.name}"
                process = subprocess.Popen(
                    ["bash", str(LAB), "with", MONTEREY, "--", "sh", "-c", 'touch "$1"; exec sleep 60', "sh",
                     str(started)],
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True, stdin=subprocess.DEVNULL,
                    env=self.env, start_new_session=True)
                try:
                    deadline = time.monotonic() + 20
                    while not started.exists():
                        self.assertIsNone(process.poll(), "lab.sh with exited before the host command ran")
                        self.assertLess(time.monotonic(), deadline, "the host command never started")
                        time.sleep(0.1)
                    self.assertEqual(self.running(), {MONTEREY})
                    os.killpg(process.pid, sig)
                    _, stderr = process.communicate(timeout=30)
                finally:
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                        process.wait()
                self.assertEqual(process.returncode, code, stderr)
                self.assertEqual(self.running(), set())


class GuestAccessTests(LabTestCase):
    def test_ssh_push_pull_and_exec_need_a_running_vm(self):
        for args in (("ssh", MONTEREY, "true"), ("push", MONTEREY, str(self.tmp), "x"),
                     ("pull", MONTEREY, "x", str(self.tmp)), ("exec", MONTEREY, "true"),
                     ("probe", MONTEREY)):
            with self.subTest(args=args):
                result = self.lab(*args)
                self.assertEqual(result.returncode, 3, result.stderr)
                self.assertIn("not running", result.stderr)

    def test_push_and_pull_refuse_unsafe_remote_paths(self):
        self.assertEqual(self.lab("up", MONTEREY).returncode, 0)
        for remote in ("/tmp/it's", "$(reboot)", "a`b`", ""):
            with self.subTest(remote=remote):
                self.assertEqual(self.lab("push", MONTEREY, str(self.tmp), remote).returncode, 2)
                self.assertEqual(self.lab("pull", MONTEREY, remote, str(self.tmp)).returncode, 2)
        missing = self.lab("push", MONTEREY, str(self.tmp / "missing"), "inbox")
        self.assertEqual(missing.returncode, 2)
        ok = self.lab("push", MONTEREY, str(self.bin), "inbox")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertTrue(any("tar -C 'inbox' -xf -" in c for c in self.calls()), self.calls())
        self.lab("down", MONTEREY)

    def test_exec_explains_a_missing_guest_agent(self):
        self.assertEqual(self.lab("up", MONTEREY).returncode, 0)
        result = self.lab("exec", MONTEREY, "true", FAKE_NO_AGENT="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("guest agent", result.stderr)
        ok = self.lab("exec", MONTEREY, "echo", "agent-ok")
        self.assertEqual(ok.returncode, 0, ok.stderr)
        self.assertIn("agent-ok", ok.stdout)
        self.lab("down", MONTEREY)


class CloneDeleteTests(LabTestCase):
    def test_only_clones_made_by_the_lab_can_be_deleted(self):
        for vm in (MONTEREY, DEV):
            result = self.lab("delete", vm)
            self.assertEqual(result.returncode, 3)
            self.assertIn("not created by", result.stderr)
            self.assertTrue((self.fake / "vms" / vm).exists())
        clone = self.lab("clone", MONTEREY, f"{MONTEREY}-run")
        self.assertEqual(clone.returncode, 0, clone.stderr)
        self.assertIn(f"NOPRUNE=1 clone {MONTEREY} {MONTEREY}-run", "\n".join(self.calls()))
        self.assertEqual(self.lab("clone", MONTEREY, f"{MONTEREY}-run").returncode, 3)
        self.assertEqual(self.lab("up", f"{MONTEREY}-run").returncode, 0)
        busy = self.lab("delete", f"{MONTEREY}-run")
        self.assertEqual(busy.returncode, 3)
        self.assertIn("running", busy.stderr)
        self.lab("down", f"{MONTEREY}-run")
        self.assertEqual(self.lab("delete", f"{MONTEREY}-run").returncode, 0)
        self.assertFalse((self.fake / "vms" / f"{MONTEREY}-run").exists())

    def test_status_lists_vms_without_starting_any(self):
        result = self.lab("status")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(MONTEREY, result.stdout)
        self.assertEqual(self.tart_calls("run"), [])


@unittest.skipUnless(shutil.which("perl"), "perl is needed")
class MachOInfoTests(unittest.TestCase):
    def test_non_mach_o_files_fail(self):
        with tempfile.NamedTemporaryFile() as handle:
            handle.write(b"#!/bin/sh\necho hi\n")
            handle.flush()
            result = subprocess.run(["perl", str(MACHO), handle.name], capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not a", result.stderr)

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "needs clang on macOS")
    def test_universal_binary_reports_both_slices_and_minos(self):
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "main.c"
            source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
            binary = Path(tmp) / "fat"
            subprocess.run(["clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0", "-o",
                            str(binary), str(source)], check=True, capture_output=True)
            full = subprocess.run(["perl", str(MACHO), str(binary)], capture_output=True, text=True, check=True)
            archs = subprocess.run(["perl", str(MACHO), "--archs", str(binary)], capture_output=True, text=True,
                                   check=True)
        lines = sorted(full.stdout.splitlines())
        self.assertEqual(len(lines), 2, full.stdout)
        self.assertRegex(lines[0], r"^arm64 minos 12\.0 sdk \d+")
        self.assertRegex(lines[1], r"^x86_64 minos 12\.0 sdk \d+")
        self.assertEqual(sorted(archs.stdout.split()), ["arm64", "x86_64"])


class SmokeArgumentTests(LabTestCase):
    def fake_app(self, binary: Path | None = None) -> Path:
        app = self.tmp / "Fake.app"
        (app / "Contents" / "MacOS").mkdir(parents=True, exist_ok=True)
        (app / "Contents" / "Info.plist").write_text(textwrap.dedent("""\
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
            <key>CFBundleExecutable</key><string>Fake</string>
            <key>CFBundleIdentifier</key><string>test.example.fake</string>
            </dict></plist>
            """), encoding="utf-8")
        target = app / "Contents" / "MacOS" / "Fake"
        if binary is None:
            write_exe(target, "#!/bin/sh\n")
        else:
            shutil.copy2(binary, target)
        return app

    def smoke(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return self.script(SMOKE, *args, **env)

    def test_help_and_unknown_options(self):
        self.assertEqual(self.smoke("--help").returncode, 0)
        self.assertEqual(self.smoke("--bogus").returncode, 2)

    def test_the_alive_window_is_at_least_twenty_seconds(self):
        for value in ("5", "19", "abc", "100000"):
            with self.subTest(value=value):
                result = self.smoke("--alive-seconds", value, "--app", str(self.fake_app()))
                self.assertEqual(result.returncode, 2, result.stderr)
        self.assertEqual(self.tart_calls("run"), [])

    def test_the_app_must_be_a_bundle_with_an_executable(self):
        missing = self.smoke("--app", str(self.tmp / "Nope.app"))
        self.assertEqual(missing.returncode, 2)
        empty = self.tmp / "Empty.app"
        empty.mkdir()
        self.assertEqual(self.smoke("--app", str(empty)).returncode, 2)
        self.assertEqual(self.tart_calls("run"), [])

    @unittest.skipUnless(sys.platform == "darwin", "reads Info.plist with plutil")
    def test_the_build_is_universal_ad_hoc_without_hardened_runtime_outside_the_data_volume(self):
        write_exe(self.bin / "xcodegen", '#!/bin/bash\necho "xcodegen $*" >>"$FAKE_DIR/calls.log"\n')
        write_exe(self.bin / "xcodebuild", textwrap.dedent("""\
            #!/bin/bash
            echo "xcodebuild $*" >>"$FAKE_DIR/calls.log"
            while [ $# -gt 0 ]; do [ "$1" = -derivedDataPath ] && dd="$2"; shift; done
            app="$dd/Build/Products/Release/$FAKE_APP_NAME.app"
            mkdir -p "$app/Contents/MacOS"
            printf '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>Fake</string><key>CFBundleIdentifier</key><string>test.fake</string></dict></plist>' >"$app/Contents/Info.plist"
            printf '#!/bin/sh\n' >"$app/Contents/MacOS/Fake"
            """))
        refused = self.smoke("--derived-data", "/Volumes/Data/dd")
        self.assertEqual(refused.returncode, 2, refused.stderr)
        result = self.smoke("--derived-data", str(self.tmp / "dd"), FAKE_APP_NAME=brand_value("APP_DISPLAY_NAME"))
        self.assertEqual(result.returncode, 1, result.stderr)  # the fake executable is no Mach-O
        build = next(c for c in self.calls() if c.startswith("xcodebuild "))
        for flag in ("-configuration Release", "ARCHS=arm64 x86_64", "ONLY_ACTIVE_ARCH=NO", "CODE_SIGN_IDENTITY=-",
                     "DEVELOPMENT_TEAM= ", "ENABLE_HARDENED_RUNTIME=NO", f"-derivedDataPath {self.tmp / 'dd'}"):
            self.assertIn(flag, build)
        self.assertIn("FAIL host slices", result.stderr)
        self.assertEqual(self.tart_calls("clone"), [])

    def test_the_base_vm_must_be_a_valid_name(self):
        result = self.smoke("--vm", "../x", "--app", str(self.fake_app()))
        self.assertEqual(result.returncode, 2)

    @unittest.skipUnless(sys.platform == "darwin", "reads Info.plist with plutil")
    def test_a_host_side_slice_failure_stops_before_any_vm_starts(self):
        result = self.smoke("--app", str(self.fake_app()))
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("FAIL", result.stdout + result.stderr)
        self.assertEqual(self.tart_calls("run"), [])
        self.assertEqual(self.tart_calls("clone"), [])

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "needs clang and plutil on macOS")
    def test_a_failing_guest_run_still_stops_and_deletes_the_throwaway_clone(self):
        source = self.tmp / "main.c"
        source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        binary = self.tmp / "fat"
        subprocess.run(["clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=12.0", "-o",
                        str(binary), str(source)], check=True, capture_output=True)
        app = self.fake_app(binary)
        result = self.smoke("--app", str(app), "--output", str(self.tmp / "run"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        output = result.stdout + result.stderr
        self.assertIn("RESULT: FAIL", output)
        self.assertIn(f"clone {MONTEREY} {MONTEREY}-smoke", "\n".join(self.calls()))
        self.assertFalse((self.fake / "vms" / f"{MONTEREY}-smoke").exists(), "the clone must be deleted")
        self.assertTrue((self.fake / "vms" / MONTEREY).exists(), "the base VM must stay")
        self.assertEqual(self.running(), set())
        self.assertEqual([c for c in self.tart_calls("run") if f"{MONTEREY}-smoke" not in c], [])
        self.assertTrue((self.tmp / "run" / "summary.txt").exists())

    @unittest.skipUnless(sys.platform == "darwin" and shutil.which("clang"), "needs clang and plutil on macOS")
    def test_a_minos_newer_than_12_0_fails_on_the_host_before_any_vm_starts(self):
        """ADR 0315 step 2 and vm-test-lab.md: the host checks both slices AND their minos 12.0 (PLT-R106)."""
        source = self.tmp / "main.c"
        source.write_text("int main(void) { return 0; }\n", encoding="utf-8")
        binary = self.tmp / "fat13"
        subprocess.run(["clang", "-arch", "arm64", "-arch", "x86_64", "-mmacosx-version-min=13.0", "-o",
                        str(binary), str(source)], check=True, capture_output=True)
        result = self.smoke("--app", str(self.fake_app(binary)), "--output", str(self.tmp / "run"))
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode, 1, output)
        self.assertIn("FAIL host minos: arm64 needs macOS 13.0", output)
        self.assertIn("FAIL host minos: x86_64 needs macOS 13.0", output)
        self.assertEqual(self.tart_calls("run"), [])
        self.assertEqual(self.tart_calls("clone"), [])

    @unittest.skipUnless(sys.platform == "darwin", "reads Info.plist with plutil")
    def test_a_foreign_vm_with_the_clone_name_is_never_replaced(self):
        (self.fake / "vms" / f"{MONTEREY}-smoke").touch()
        result = self.smoke("--app", str(self.fake_app()))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn("not created by", result.stderr)
        self.assertTrue((self.fake / "vms" / f"{MONTEREY}-smoke").exists())
        self.assertEqual([c for c in self.calls() if " delete " in f"{c} "], [])

    @unittest.skipUnless(sys.platform == "darwin", "reads Info.plist with plutil")
    def test_the_smoke_test_refuses_to_start_while_another_vm_runs(self):
        self.assertEqual(self.lab("up", DEV).returncode, 0)
        result = self.smoke("--app", str(self.fake_app()))
        self.assertEqual(result.returncode, 3, result.stderr)
        self.assertIn(f"{DEV} is running", result.stderr)
        self.assertEqual(self.tart_calls("clone"), [])
        self.assertEqual(self.running(), {DEV})
        self.lab("down", DEV)


class IntegrationDevArgumentTests(LabTestCase):
    def integration(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        return self.script(INTEGRATION, *args, **env)

    def test_help_and_usage_errors(self):
        self.assertEqual(self.integration("--help").returncode, 0)
        for args in (("--bogus",), ("--vm",), ("--vm", "../x"), ("--memory", "99999"), ("--cpus", "0")):
            with self.subTest(args=args):
                self.assertEqual(self.integration(*args).returncode, 2)
        self.assertEqual(self.tart_calls("run"), [])

    def test_it_refuses_while_another_vm_runs_and_never_replaces_a_foreign_clone(self):
        self.assertEqual(self.lab("up", MONTEREY).returncode, 0)
        busy = self.integration()
        self.assertEqual(busy.returncode, 3, busy.stderr)
        self.assertIn(f"{MONTEREY} is running", busy.stderr)
        self.lab("down", MONTEREY)
        (self.fake / "vms" / f"{DEV}-suite").touch()
        foreign = self.integration()
        self.assertEqual(foreign.returncode, 3, foreign.stderr)
        self.assertIn("not created by", foreign.stderr)
        self.assertTrue((self.fake / "vms" / f"{DEV}-suite").exists())
        self.assertEqual(self.tart_calls("clone"), [])
        self.assertEqual(len(self.tart_calls("run")), 1)  # only the VM this test started itself

    def test_a_failing_guest_run_stops_and_deletes_the_clone(self):
        result = self.integration("--output", str(self.tmp / "run"), FAKE_NO_AGENT="1")
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("RESULT: FAIL", result.stdout)
        self.assertIn(f"clone {DEV} {DEV}-suite", "\n".join(self.calls()))
        self.assertIn(f"set {DEV}-suite --memory 6144 --cpu 4", "\n".join(self.tart_calls("set")))
        self.assertFalse((self.fake / "vms" / f"{DEV}-suite").exists())
        self.assertTrue((self.fake / "vms" / DEV).exists())
        self.assertEqual(self.running(), set())


TCC_SCHEMA = """CREATE TABLE access (service TEXT NOT NULL, client TEXT NOT NULL, client_type INTEGER NOT NULL,
  auth_value INTEGER NOT NULL, auth_reason INTEGER NOT NULL, auth_version INTEGER NOT NULL, csreq BLOB,
  policy_id INTEGER, indirect_object_identifier_type INTEGER,
  indirect_object_identifier TEXT NOT NULL DEFAULT 'UNUSED', indirect_object_code_identity BLOB, flags INTEGER,
  last_modified INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)), pid INTEGER, pid_version INTEGER,
  boot_uuid TEXT NOT NULL DEFAULT 'UNUSED', last_reminded INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (service, client, client_type, indirect_object_identifier));"""


@unittest.skipUnless(sys.platform == "darwin" and Path("/usr/bin/sqlite3").exists(), "needs macOS tools")
class GrantTccTests(unittest.TestCase):
    """grant-tcc.sh against a temporary database; fake sysctl, csrutil, codesign and pkill on PATH."""

    def setUp(self) -> None:
        import sqlite3
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        write_exe(self.bin / "sysctl", '#!/bin/sh\necho "${FAKE_VMM:-1}"\n')
        write_exe(self.bin / "csrutil", '#!/bin/sh\necho "System Integrity Protection status: ${FAKE_SIP:-disabled}."\n')
        write_exe(self.bin / "codesign", '#!/bin/sh\necho "Executable=$4" >&2\n'
                                         'echo \'designated => identifier "test.example.fake" and anchor apple\'\n')
        write_exe(self.bin / "pkill", '#!/bin/sh\necho "pkill $*" >>"$FAKE_LOG"\n')
        self.db = self.tmp / "TCC.db"
        with sqlite3.connect(self.db) as connection:
            connection.executescript(TCC_SCHEMA)
        self.app = self.tmp / "Fake.app"
        (self.app / "Contents").mkdir(parents=True)
        (self.app / "Contents" / "Info.plist").write_text(
            '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key>'
            "<string>test.example.fake</string></dict></plist>", encoding="utf-8")
        self.tool = self.tmp / "compat-harness"
        write_exe(self.tool, "#!/bin/sh\n")
        self.env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "TCC_DB": str(self.db),
                    "FAKE_LOG": str(self.tmp / "calls.log"), "HOME": str(self.tmp)}

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def grant(self, *args: str, **env: str) -> subprocess.CompletedProcess:
        merged = dict(self.env)
        merged.update(env)
        return subprocess.run(["bash", str(GRANT), *args], capture_output=True, text=True, env=merged,
                              stdin=subprocess.DEVNULL, timeout=60)

    def rows(self) -> list[tuple]:
        import sqlite3
        with sqlite3.connect(self.db) as connection:
            return connection.execute("SELECT service, client, client_type, auth_value, length(csreq) FROM access "
                                      "ORDER BY service, client").fetchall()

    def test_it_refuses_a_real_mac_and_an_enabled_sip(self):
        clients = ("--bundle", str(self.app), "--binary", str(self.tool))
        host = self.grant(*clients, FAKE_VMM="0")
        self.assertEqual(host.returncode, 3)
        self.assertIn("not a virtual machine", host.stderr)
        sip = self.grant(*clients, FAKE_SIP="enabled")
        self.assertEqual(sip.returncode, 3)
        self.assertIn("System Integrity Protection is enabled", sip.stderr)
        self.assertEqual(self.rows(), [])

    def test_usage_errors(self):
        for args in ((), ("--bogus",), ("--binary", "relative/tool"), ("--bundle", str(self.tool)),
                     ("--service", "Accessibility", "--binary", str(self.tool)), ("--binary",)):
            with self.subTest(args=args):
                self.assertEqual(self.grant(*args).returncode, 2)
        self.assertEqual(self.rows(), [])

    def test_bundles_and_binaries_get_the_three_services_with_their_code_requirement(self):
        for _ in range(2):  # idempotent
            result = self.grant("--bundle", str(self.app), "--binary", str(self.tool))
            self.assertEqual(result.returncode, 0, result.stderr)
        rows = self.rows()
        self.assertEqual(len(rows), 6, rows)
        services = {row[0] for row in rows}
        self.assertEqual(services, {"kTCCServiceAccessibility", "kTCCServiceListenEvent", "kTCCServicePostEvent"})
        self.assertEqual({(row[1], row[2]) for row in rows},
                         {("test.example.fake", 0), (str(self.tool.resolve()), 1)})
        self.assertTrue(all(row[3] == 2 and row[4] and row[4] > 0 for row in rows), rows)
        log = self.tmp / "calls.log"
        self.assertFalse(log.exists() and "tccd" in log.read_text(), "tccd is restarted only for the real database")

    def test_a_symlinked_binary_is_granted_under_its_resolved_path(self):
        """tccd keys path clients by the resolved executable path (the dev image lists the guest agent under
        /opt/homebrew/Cellar/..., not the /opt/homebrew/bin symlink), so a row for the link would be dead."""
        link_dir = self.tmp / "links"
        link_dir.mkdir()
        link = link_dir / "harness-link"
        link.symlink_to(self.tool)
        result = self.grant("--service", "kTCCServiceListenEvent", "--binary", str(link))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([(row[1], row[2]) for row in self.rows()], [(str(self.tool.resolve()), 1)])

    def test_dry_run_prints_the_sql_and_writes_nothing(self):
        result = self.grant("--dry-run", "--service", "kTCCServiceAccessibility", "--binary", str(self.tool))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("INSERT OR REPLACE INTO access", result.stdout)
        self.assertIn("'kTCCServiceAccessibility'", result.stdout)
        self.assertNotIn("kTCCServiceListenEvent", result.stdout)
        self.assertEqual(self.rows(), [])


class GuestScriptTests(unittest.TestCase):
    def test_the_guest_script_runs_under_the_macos_12_system_bash(self):
        """macOS 12 ships bash 3.2: no associative arrays, mapfile or ${var,,} in the guest script."""
        text = GUEST.read_text(encoding="utf-8")
        self.assertTrue(text.startswith("#!/bin/bash\n"))
        for construct in ("declare -A", "mapfile", "readarray", ",,}", "^^}", "|&", "&>>"):
            self.assertNotIn(construct, text)

    def test_the_guest_script_checks_what_adr_0315_asks_for(self):
        text = GUEST.read_text(encoding="utf-8")
        for needle in ("--install-rosetta --agree-to-license", "arch \"-$arch\"", "libRosettaRuntime", "log show",
                       "DiagnosticReports", "Symbol not found", "Library not loaded", "lipo -archs", "minos",
                       "Sparkle.framework", "/Applications/"):
            self.assertIn(needle, text)

    def test_the_app_process_is_matched_by_name_not_by_command_line(self):
        """The first real run (2026-11-13) watched the `sudo launchctl asuser` wrapper because `pgrep -f` matched
        the binary path on the wrapper's command line; the app's own process name must be matched."""
        text = GUEST.read_text(encoding="utf-8")
        self.assertIn('pgrep -n -x "$exec_name"', text)
        self.assertNotIn("pgrep -n -f", text)
        self.assertNotIn("pkill -f", text)


class GuestVmGuardTests(unittest.TestCase):
    """Both guest scripts change global settings, replace apps, use sudo and post events: they must refuse to run
    anywhere but inside a VM (kern.hv_vmm_present = 1), before argument parsing and before any side effect.
    The scripts are run without arguments only, so even a missing guard could do no more than print the usage."""

    TOOLS = ("defaults", "open", "ditto", "pkill", "sudo", "softwareupdate", "launchctl", "xcodebuild", "xcodegen",
             "arch", "lipo", "log", "tccutil", "killall", "rm", "cp", "mkdir")

    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "calls.log"
        write_exe(self.bin / "sysctl", '#!/bin/sh\n[ "$*" = "-n kern.hv_vmm_present" ] || exit 1\necho "$FAKE_VMM"\n')
        for tool in self.TOOLS:
            write_exe(self.bin / tool, f'#!/bin/sh\necho "{tool} $*" >>"{self.log}"\n')

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def run_guest(self, script: Path, vmm: str) -> subprocess.CompletedProcess:
        env = {"PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.tmp), "FAKE_VMM": vmm,
               "LC_ALL": "C"}
        return subprocess.run(["bash", str(script)], capture_output=True, text=True, env=env, cwd=self.tmp,
                              stdin=subprocess.DEVNULL, timeout=30)

    def test_the_guest_scripts_refuse_to_run_outside_a_virtual_machine(self):
        for script in (GUEST, INTEGRATION_GUEST):
            for vmm in ("0", ""):
                with self.subTest(script=script.name, vmm=vmm):
                    result = self.run_guest(script, vmm)
                    self.assertEqual(result.returncode, 3, result.stdout + result.stderr)
                    self.assertIn("refusing: not inside a virtual machine", result.stderr)
                    self.assertFalse(self.log.exists() and self.log.read_text(encoding="utf-8"),
                                     "no tool may run before the guard")

    def test_inside_a_virtual_machine_the_guard_lets_the_script_reach_its_usage_check(self):
        for script in (GUEST, INTEGRATION_GUEST):
            with self.subTest(script=script.name):
                result = self.run_guest(script, "1")
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("usage:", result.stderr)


class IntegrationGuestTests(unittest.TestCase):
    MARKER_LINE = re.compile(r'^HOOKS_MARKER="(.+)"$', re.M)

    def test_the_guest_builds_through_run_integration_with_the_ad_hoc_identity(self):
        """The VM has no Apple Development identity: the guest asks scripts/run-integration.sh build for an ad-hoc
        test build instead of keeping its own copy of the build (and of the ADR 0502 hooks marker check)."""
        guest = INTEGRATION_GUEST.read_text(encoding="utf-8")
        build = next(line for line in guest.splitlines()
                     if "INTEGRATION_CODE_SIGN_IDENTITY=-" in line and not line.startswith("#"))
        self.assertIn("COMPAT_HARNESS_LIVE=1", build)
        self.assertIn('INTEGRATION_APP_DIR="$apps"', build)
        self.assertIn("scripts/run-integration.sh build", guest)
        self.assertNotIn("xcodebuild -project", guest)
        self.assertNotIn("ENABLE_HARDENED_RUNTIME", guest)
        self.assertIsNone(self.MARKER_LINE.search(guest), "the hooks marker check lives in run-integration.sh only")
        reference = (SCRIPTS / "run-integration.sh").read_text(encoding="utf-8")
        self.assertIsNotNone(self.MARKER_LINE.search(reference))
        self.assertIn('INTEGRATION_CODE_SIGN_IDENTITY:-', reference)

    def test_the_guest_enables_every_layout_the_testhost_scenarios_select(self):
        """integration-suite.md section 2 step 4, inside the VM only: the list is read from the scenarios."""
        guest = INTEGRATION_GUEST.read_text(encoding="utf-8")
        self.assertIn("compat/scenarios/testhost.*.json", guest)
        self.assertIn("scripts/vm/guest/enable-input-sources.swift", guest)
        self.assertLess(guest.index("enable-input-sources"), guest.index("scripts/run-integration.sh tests"))
        program = (SCRIPTS / "vm" / "guest" / "enable-input-sources.swift").read_text(encoding="utf-8")
        self.assertIn("kern.hv_vmm_present", program)
        self.assertLess(program.index("insideVirtualMachine() else"), program.index("CommandLine.arguments"))
        self.assertIn("TISEnableInputSource", program)
        layouts = set()
        for scenario in (REPO / "compat" / "scenarios").glob("testhost.*.json"):
            match = re.search(r'"layout":\s*"([^"]+)"', scenario.read_text(encoding="utf-8"))
            if match:
                layouts.add(match.group(1))
        self.assertTrue({"com.apple.keylayout.French", "com.apple.keylayout.German", "com.apple.keylayout.Dvorak",
                         "com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese"} <= layouts, layouts)
        # The guest's sed expression must read every one of them.
        sed = subprocess.run(
            ["sh", "-c", "sed -n 's/.*\"layout\": *\"\\([^\"]*\\)\".*/\\1/p' compat/scenarios/testhost.*.json | sort -u"],
            capture_output=True, text=True, cwd=REPO, check=True)
        self.assertEqual(set(sed.stdout.split()), layouts)


class RunShTests(unittest.TestCase):
    def test_the_suite_loop_runs_this_file(self):
        text = (SCRIPTS / "tests" / "run.sh").read_text(encoding="utf-8")
        loop = next(line for line in text.splitlines() if line.startswith("for suite in"))
        self.assertIn("test_vm_lab", loop)


if __name__ == "__main__":
    unittest.main(verbosity=1)
