# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the scripted upgrade, channel switch and egress checks (scripts/vm/upgrade-test.sh,
scripts/vm/upgrade-report.py, scripts/vm/guest/upgrade-guest.sh). Run: python3 -I scripts/tests/test_upgrade_test.py

The host-side logic (artefact and signature checks, the local feed, the evidence parsers, the comparisons and the
verdict) is tested against synthetic files; the host script runs with the fake tart, ssh and git of test_vm_lab.py
and fake host-load tools, so no virtual machine starts and nothing is launched.
"""
from __future__ import annotations

import base64
import contextlib
import importlib.util
import io
import json
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__ (the modules below are loaded by path)
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS  # noqa: E402
from test_vm_lab import DEV, LabTestCase, brand_value, write_exe  # noqa: E402

REPORT_PATH = SCRIPTS / "vm" / "upgrade-report.py"
UPGRADE = SCRIPTS / "vm" / "upgrade-test.sh"
GUEST = SCRIPTS / "vm" / "guest" / "upgrade-guest.sh"
DRIVER = SCRIPTS / "vm" / "guest" / "upgrade-driver.swift"
STORE = SCRIPTS / "vm" / "guest" / "upgrade-store.swift"
FEED_SERVER = SCRIPTS / "vm" / "guest" / "local-feed-server.py"
PLAN = SCRIPTS / "vm" / "fixtures" / "upgrade-plan.json"

SLUG = brand_value("APP_SLUG")
NAME = brand_value("APP_DISPLAY_NAME")
HOST = brand_value("APP_SITE_HOST")
BUNDLE = brand_value("APP_BUNDLE_ID_RELEASE")


def load_report():
    spec = importlib.util.spec_from_file_location("upgrade_report", REPORT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


report = load_report()


def find_openssl3() -> str:
    for candidate in ("/opt/homebrew/opt/openssl@3/bin/openssl", "/opt/homebrew/bin/openssl",
                      "/usr/local/opt/openssl@3/bin/openssl", shutil.which("openssl") or ""):
        if not candidate or not Path(candidate).exists():
            continue
        out = subprocess.run([candidate, "version"], capture_output=True, text=True)
        if out.stdout.startswith("OpenSSL") and not out.stdout.startswith(("OpenSSL 0", "OpenSSL 1")):
            return candidate
    return ""


OPENSSL = find_openssl3()


class Keys:
    """A throwaway Ed25519 key pair made with openssl, standing in for the Sparkle key."""

    def __init__(self, folder: Path):
        self.key = folder / "ed.key"
        subprocess.run([OPENSSL, "genpkey", "-algorithm", "ed25519", "-out", str(self.key)], check=True,
                       capture_output=True)
        der = subprocess.run([OPENSSL, "pkey", "-in", str(self.key), "-pubout", "-outform", "DER"], check=True,
                             capture_output=True).stdout
        self.public = base64.b64encode(der[-32:]).decode()

    def sign(self, path: Path) -> str:
        sig = subprocess.run([OPENSSL, "pkeyutl", "-sign", "-inkey", str(self.key), "-rawin", "-in", str(path)],
                             check=True, capture_output=True).stdout
        return base64.b64encode(sig).decode()


def write_dist(folder: Path, version: str, build: int, public_key: str, commit: str = "abc1234") -> dict:
    """A dist folder like scripts/build-release.sh leaves: app, DMG, zip, SHA256SUMS, build-info.json."""
    folder.mkdir(parents=True)
    contents = folder / f"{NAME}.app" / "Contents"
    contents.mkdir(parents=True)
    with (contents / "Info.plist").open("wb") as handle:
        plistlib.dump({"CFBundleShortVersionString": version, "CFBundleVersion": str(build),
                       "SUPublicEDKey": public_key, "LSMinimumSystemVersion": "12.0"}, handle)
    (folder / "build-info.json").write_text(json.dumps({"version": version, "build": build, "commit": commit}))
    dmg = folder / f"{SLUG}-{version}.dmg"
    dmg.write_bytes(b"dmg " + version.encode())
    archive = folder / f"{SLUG}-{version}.zip"
    with zipfile.ZipFile(archive, "w") as zipped:
        zipped.writestr(f"{NAME}.app/Contents/Info.plist", version)
    sums = "".join(f"{report.sha256_file(p)}  {p.name}\n" for p in (dmg, archive))
    (folder / "SHA256SUMS").write_text(sums)
    return {"dmg": dmg, "zip": archive}


def appcast(items: list) -> str:
    return report.appcast_xml(NAME, HOST, items)


def item(version: str, build: int, length: int, signature: str, channel: str = "") -> dict:
    return {"title": f"{NAME} {version}", "build": build, "version": version, "minimumSystemVersion": "12.0",
            "channel": channel, "url": f"https://{HOST}/download/{SLUG}-{version}.zip", "length": length,
            "signature": signature, "releaseNotesLink": ""}


@unittest.skipUnless(OPENSSL, "needs OpenSSL 3 for Ed25519")
class ArtefactTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.tmp = Path(self._tmp.name)
        self.keys = Keys(self.tmp)
        self.prev = write_dist(self.tmp / "prev", "1.0.1", 1000199, self.keys.public)
        self.cand = write_dist(self.tmp / "cand", "1.1.0-beta.1", 1010001, self.keys.public)
        self.signature = self.keys.sign(self.cand["zip"])
        prev_sig = self.keys.sign(self.prev["zip"])
        self.items = [item("1.1.0-beta.1", 1010001, self.cand["zip"].stat().st_size, self.signature, "beta"),
                      item("1.0.1", 1000199, self.prev["zip"].stat().st_size, prev_sig)]

    def tearDown(self) -> None:
        self._tmp.cleanup()

    def check(self, items=None, signature: str = "") -> dict:
        return report.check_artefacts(self.tmp / "prev", self.tmp / "cand", SLUG, NAME,
                                      appcast(self.items if items is None else items), OPENSSL, signature)

    def test_the_published_signature_of_the_same_bytes_is_reused_after_verification(self):
        result = self.check()
        self.assertEqual(result["status"], "ready")
        self.assertEqual(result["candidate"]["signatureSource"], "published appcast")
        self.assertEqual(result["candidate"]["signature"], self.signature)
        self.assertEqual(result["previous"]["item"]["version"], "1.0.1")

    def test_an_unpublished_candidate_needs_a_signature_and_a_given_one_is_verified(self):
        self.assertEqual(self.check(items=self.items[1:])["status"], "needs-signature")
        signed = self.check(items=self.items[1:], signature=self.signature)
        self.assertEqual(signed["candidate"]["signatureSource"], "sign_update")
        (self.tmp / "other").mkdir()
        other = Keys(self.tmp / "other")
        with self.assertRaisesRegex(report.ArtefactError, "does not verify"):
            self.check(items=self.items[1:], signature=other.sign(self.cand["zip"]))

    def test_bytes_that_differ_from_sha256sums_or_the_published_length_are_refused(self):
        self.cand["zip"].write_bytes(self.cand["zip"].read_bytes() + b"x")
        with self.assertRaisesRegex(report.ArtefactError, "does not match SHA256SUMS"):
            self.check()
        sums = self.tmp / "cand" / "SHA256SUMS"
        sums.write_text("".join(f"{report.sha256_file(p)}  {p.name}\n" for p in self.cand.values()))
        with self.assertRaisesRegex(report.ArtefactError, "not the published bytes"):
            self.check()

    def test_a_tampered_signature_is_refused(self):
        bad = self.items[:]
        bad[0] = dict(bad[0], signature=self.keys.sign(self.prev["zip"]))
        with self.assertRaisesRegex(report.ArtefactError, "does not verify"):
            self.check(items=bad)

    def test_a_different_update_key_or_an_older_build_is_refused(self):
        with (self.tmp / "cand" / f"{NAME}.app" / "Contents" / "Info.plist").open("wb") as handle:
            plistlib.dump({"CFBundleShortVersionString": "1.1.0-beta.1", "CFBundleVersion": "1010001",
                           "SUPublicEDKey": base64.b64encode(b"\x01" * 32).decode()}, handle)
        with self.assertRaisesRegex(report.ArtefactError, "SUPublicEDKey differs"):
            self.check()

    def test_the_command_exits_6_for_an_unpublished_candidate_and_1_for_bad_artefacts(self):
        feed = self.tmp / "appcast.xml"
        feed.write_text(appcast(self.items[1:]))
        args = ["artefacts", "--previous", str(self.tmp / "prev"), "--candidate", str(self.tmp / "cand"), "--slug",
                SLUG, "--name", NAME, "--appcast", str(feed), "--openssl", OPENSSL, "--out", str(self.tmp / "a.json")]
        with contextlib.redirect_stderr(io.StringIO()):
            self.assertEqual(report.main(args), 6)
            (self.tmp / "cand" / "SHA256SUMS").write_text("")
            self.assertEqual(report.main(args), 1)
        self.assertEqual(json.loads((self.tmp / "a.json").read_text())["status"], "error")


class FeedTests(unittest.TestCase):
    def artefacts(self, folder: Path, version: str = "1.1.0-beta.1") -> dict:
        archive = folder / f"{SLUG}-{version}.zip"
        archive.write_bytes(b"zip")
        return {"candidate": {"version": version, "build": 1010001, "minimumSystemVersion": "12.0",
                              "zip": {"path": str(archive), "length": 3}, "signature": "SIG=="},
                "previous": {"item": dict(item("1.0.1", 1000199, 9, "PREV=="),
                                          url="https://elsewhere.example/download/x.zip")}}

    def test_the_feed_offers_the_candidate_and_a_beta_only_probe_that_points_at_the_same_archive(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            notes = folder / "notes" / "1.1.0-beta.1"
            notes.mkdir(parents=True)
            (notes / "index.html").write_text("<p>notes</p>")
            plan = report.write_feed(self.artefacts(folder), folder / "feed", NAME, HOST, folder / "notes")
            upgrade = report.appcast_items((folder / "feed" / "appcast-upgrade.xml").read_text())
            channel = report.appcast_items((folder / "feed" / "appcast-channel.xml").read_text())
            self.assertEqual([i["build"] for i in upgrade], ["1010001", "1000199"])
            self.assertEqual(upgrade[0]["channel"], "beta")  # a beta candidate stays a beta item
            self.assertEqual(upgrade[0]["releaseNotesLink"], f"https://{HOST}/release-notes/1.1.0-beta.1/")
            self.assertTrue(upgrade[1]["url"].startswith(f"https://{HOST}/"))
            self.assertEqual(channel[0]["build"], "1010002")
            self.assertEqual(channel[0]["channel"], "beta")
            self.assertEqual(channel[0]["url"], upgrade[0]["url"])
            self.assertEqual(plan["probe"], {"build": 1010002, "version": "1.1.0-beta.1-channelprobe"})
            self.assertTrue((folder / "feed" / "download" / f"{SLUG}-1.1.0-beta.1.zip").is_file())
            self.assertTrue((folder / "feed" / "release-notes" / "1.1.0-beta.1" / "index.html").is_file())

    def test_a_stable_candidate_is_a_default_channel_item_and_missing_notes_are_left_out(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            report.write_feed(self.artefacts(folder, "1.1.0"), folder / "feed", NAME, HOST, folder / "none")
            upgrade = report.appcast_items((folder / "feed" / "appcast-upgrade.xml").read_text())
            self.assertEqual(upgrade[0]["channel"], "")
            self.assertEqual(upgrade[0]["releaseNotesLink"], "")


NETTOP = """time,,interface,state,bytes_in,bytes_out,rx_dupe,rx_ooo,re-tx,rtt_avg,rcvsize,tx_win,tc_class,
12:00:01.000000,{name}.812,,,100,200,0,0,0,,,,,
12:00:01.000000,tcp4 127.0.0.1:50211<->127.0.0.1:443,lo0,Established,100,200,0,0,0,1.2,,,,
12:00:01.000000,tcp6 2001:db8::5.50212<->2606:4700::6812:1.443,en0,Established,1,2,0,0,0,9.1,,,,
12:00:01.000000,udp4 *:5353<->*:*,,,0,0,,,,,,,,
12:00:01.000000,Autoupdate.900,,,0,0,0,0,0,,,,,
12:00:01.000000,tcp4 10.0.0.2:50300<->17.253.1.1:443,en0,SynSent,0,0,0,0,0,,,,,
12:00:01.000000,Safari.77,,,0,0,0,0,0,,,,,
12:00:01.000000,tcp4 10.0.0.2:50301<->8.8.8.8:443,en0,Established,0,0,0,0,0,,,,,
""".replace("{name}", NAME)

LSOF = """#t 1700000000
p812
c{name}
f12
PTCP
n127.0.0.1:50211->127.0.0.1:443
f13
PUDP
n*:5353
#t 1700000001
p812
c{name}
f14
PTCP
n[::1]:50400->[::1]:443
""".replace("{name}", NAME)

DNS = """#t 1700000000
name: {host}
ipv6_address: 2606:4700::6812:1

name: {host}
ip_address: 104.21.1.1
ip_address: 172.67.1.1

""".replace("{host}", HOST)


class ParserTests(unittest.TestCase):
    def test_endpoints_in_every_notation_nettop_and_lsof_print(self):
        self.assertEqual(report.parse_endpoint("127.0.0.1:443"), ("127.0.0.1", 443))
        self.assertEqual(report.parse_endpoint("[::1]:443"), ("::1", 443))
        self.assertEqual(report.parse_endpoint("2606:4700::6812:1.443"), ("2606:4700::6812:1", 443))
        self.assertEqual(report.parse_endpoint("fe80::1%lo0.50000"), ("fe80::1", 50000))
        self.assertIsNone(report.parse_endpoint("*:*"))
        self.assertTrue(report.is_loopback("::ffff:127.0.0.1"))
        self.assertFalse(report.is_loopback("104.21.1.1"))

    def test_nettop_flows_belong_to_the_process_line_above_them(self):
        flows = report.nettop_flows(NETTOP)
        self.assertEqual([(f["process"], f["remote"], f["port"]) for f in flows], [
            (NAME, "127.0.0.1", 443), (NAME, "2606:4700::6812:1", 443), ("Autoupdate", "17.253.1.1", 443),
            ("Safari", "8.8.8.8", 443)])

    def test_lsof_samples_and_dns_answers(self):
        flows = report.lsof_flows(LSOF)
        self.assertEqual([(f["process"], f["remote"], f["port"], f["time"]) for f in flows],
                         [(NAME, "127.0.0.1", 443, "1700000000"), (NAME, "::1", 443, "1700000001")])
        self.assertEqual(report.samples_taken(LSOF), 2)
        self.assertEqual(report.dns_addresses(DNS), {"2606:4700::6812:1", "104.21.1.1", "172.67.1.1"})


class EgressTests(unittest.TestCase):
    def phase(self, phase: str) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            egress = Path(tmp) / "egress"
            egress.mkdir()
            (egress / f"{phase}-nettop.csv").write_text(NETTOP)
            (egress / f"{phase}-lsof.txt").write_text(LSOF)
            (egress / f"{phase}-dns.txt").write_text(DNS)
            (egress / f"{phase}-started").write_text("1700000000\n")
            (egress / f"{phase}-ended").write_text("1700000600\n")
            return report.egress_phase(Path(tmp), phase, NAME, [HOST])

    def test_production_allows_loopback_and_the_site_hosts_addresses_only(self):
        result = self.phase("production")
        disallowed = {(c["process"], c["remote"]) for c in result["disallowed"]}
        self.assertEqual(disallowed, {("Autoupdate", "17.253.1.1")})  # Safari is not the app or a helper
        self.assertIn("2606:4700::6812:1", result["allowedAddresses"])
        self.assertEqual(result["lsofSamples"], 2)

    def test_the_local_phase_allows_loopback_only(self):
        result = self.phase("local")
        self.assertEqual({c["remote"] for c in result["disallowed"]}, {"2606:4700::6812:1", "17.253.1.1"})


def settings_doc(written_by: str, **extra) -> dict:
    lists = {"keepAsTyped": ["github"], "keepVietnamese": [], "learnedWords": []}
    lists.update(extra.pop("lists", {}))
    doc = {"schemaVersion": 1, "writtenBy": written_by, "settings": {"tonePlacement": "modern"},
           "englishRestoreLists": lists}
    doc.update(extra)
    return doc


class ComparisonTests(unittest.TestCase):
    def folders(self, before: dict, after: dict):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        root = Path(tmp.name)
        for name, docs in (("before", before), ("after", after)):
            (root / name).mkdir()
            for file, doc in docs.items():
                data = doc if isinstance(doc, bytes) else json.dumps(doc, indent=2).encode()
                (root / name / file).write_bytes(data)
        return root / "before", root / "after"

    def test_identical_files_pass(self):
        doc = {"settings.json": settings_doc("1.0.1"), "macros.json": {"schemaVersion": 1, "macros": []}}
        result = report.compare_settings(*self.folders(doc, doc), "1.0.1", "1.1.0")
        self.assertEqual(result["unexplained"], [])
        self.assertEqual({f["status"] for f in result["files"]}, {"identical"})

    def test_a_rewrite_by_the_candidate_is_explained_by_its_migration_rules(self):
        after = settings_doc("1.1.0", lists={"neverCorrect": []})
        result = report.compare_settings(*self.folders({"settings.json": settings_doc("1.0.1")},
                                                       {"settings.json": after}), "1.0.1", "1.1.0")
        self.assertEqual(result["unexplained"], [])
        self.assertEqual(result["files"][0]["status"], "migrated")
        self.assertTrue(all(d["explainedBy"] for d in result["files"][0]["differences"]))

    def test_a_lost_or_changed_value_is_not_explained(self):
        after = settings_doc("1.1.0", lists={"neverCorrect": [], "keepAsTyped": []})
        result = report.compare_settings(*self.folders({"settings.json": settings_doc("1.0.1")},
                                                       {"settings.json": after}), "1.0.1", "1.1.0")
        self.assertEqual(len(result["unexplained"]), 1)
        self.assertIn("keepAsTyped", result["unexplained"][0])
        removed = report.compare_settings(*self.folders({"macros.json": {"m": 1}}, {}), "1.0.1", "1.1.0")
        self.assertEqual(removed["unexplained"], ["macros.json removed"])

    def test_the_new_session_may_only_reorder_or_add_per_app_entries(self):
        apps = {"schemaVersion": 1, "globalMode": "vi", "apps": [{"bundle": "a", "mode": "vi"},
                                                                  {"bundle": "b", "rule": "ignore"}]}
        used = dict(apps, apps=[{"bundle": "c", "mode": "vi"}, {"bundle": "b", "rule": "ignore"},
                                {"bundle": "a", "mode": "vi"}])
        result = report.runtime_changes(*self.folders({"app-modes.json": apps}, {"app-modes.json": used}))
        self.assertEqual(result["unexplained"], [])
        self.assertIn("first seen ['c']", result["notes"][0])
        lost = dict(apps, apps=[{"bundle": "a", "mode": "en"}, {"bundle": "b", "rule": "ignore"}])
        self.assertEqual(len(report.runtime_changes(*self.folders({"app-modes.json": apps},
                                                                  {"app-modes.json": lost}))["unexplained"]), 1)
        settings = report.runtime_changes(*self.folders({"settings.json": settings_doc("1.1.0")},
                                                        {"settings.json": settings_doc("1.1.0", x=1)}))
        self.assertEqual(settings["unexplained"], ["settings.json changed in the new session without a user action"])

    def test_the_defaults_domain_allows_only_the_keys_that_change_by_design(self):
        # As seen in run 20261122T214034Z-upgrade: the launch guard and the self-check store integer fingerprints.
        before = {"diagnostics.redactionSalt": b"salt", "launchGuard.appVersion": 3450518130,
                  "launch.lastVersionFingerprint": 2513584745694642, "launchGuard.inProgressSince": 0.0,
                  "SUEnableAutomaticChecks": False, "PermissionLastGrantedIdentity": 4208059965609703}
        after = dict(before, **{"launchGuard.appVersion": 3923503363, "launch.lastVersionFingerprint": 1763444526767235,
                                "launchGuard.inProgressSince": 1795393351.9})
        self.assertEqual(report.compare_defaults(before, after, "1.1.0", "1010099")["unexplained"], [])
        lost = dict(after, **{"diagnostics.redactionSalt": b"other", "PermissionLastGrantedIdentity": 1})
        lost.pop("SUEnableAutomaticChecks")
        self.assertEqual(report.compare_defaults(before, lost, "1.1.0", "1010099")["unexplained"],
                         ["PermissionLastGrantedIdentity", "SUEnableAutomaticChecks", "diagnostics.redactionSalt"])

    def test_store_dumps_compare_every_field_and_new_fields_must_read_as_not_set(self):
        before = {"user": {"tonePlacement": "set(modern)"}, "appModes": {"apps": []}, "macros": [1]}
        after = {"user": {"tonePlacement": "set(modern)", "typoCorrection": "unset", "neverCorrect": []},
                 "appModes": {"apps": []}, "macros": [1]}
        self.assertEqual(report.content_equal(before, after, report.CANDIDATE_ONLY_FIELDS), [])
        self.assertEqual(len(report.content_equal(before, dict(after, macros=[]), report.CANDIDATE_ONLY_FIELDS)), 1)
        changed = dict(after, user=dict(after["user"], typoCorrection="set(false)"))
        self.assertIn("typoCorrection", report.content_equal(before, changed, report.CANDIDATE_ONLY_FIELDS)[0])
        seeded = {"user": {"tonePlacement": "set(modern)"}, "appModes": {"apps": [{"bundle": "a", "mode": "en"}]},
                  "ruleOverrides": [], "macros": [1]}
        after_apps = dict(after, appModes={"apps": [{"bundle": "a", "mode": "en"}, {"bundle": "b"}]},
                          ruleOverrides=[])
        self.assertEqual(report.seeded_survived(seeded, after_apps), [])
        self.assertEqual(report.seeded_survived(seeded, dict(after_apps, appModes={"apps": []})), ["appModes a"])


def write_run(folder: Path, *, tap: float = 0.4, typing: float = 1.8, offered_probe: bool = True) -> dict:
    """A complete synthetic guest output, as upgrade-guest.sh writes it, for a passing run."""
    out = folder / "upgrade-out"
    for sub in ("snapshots/at-exit", "snapshots/loaded", "snapshots/after", "snapshots/seeded", "evidence", "egress",
                "logs", "dumps"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    start = 1_800_000_000.0
    files = {"settings.json": json.dumps(settings_doc("1.0.1")), "macros.json": "{}"}
    for snap in ("at-exit", "loaded", "after", "seeded"):
        for name, text in files.items():
            (out / "snapshots" / snap / name).write_text(text)
    defaults = {"diagnostics.redactionSalt": b"s", "launchGuard.inProgressSince": start - 60}
    with (out / "snapshots" / "defaults-at-exit.plist").open("wb") as handle:
        plistlib.dump(defaults, handle)
    with (out / "snapshots" / "defaults-after.plist").open("wb") as handle:
        plistlib.dump(dict(defaults, **{"launchGuard.inProgressSince": start}), handle)
    tcc = f"kTCCServiceAccessibility|{BUNDLE}|0|2|4|FADE\nkTCCServiceListenEvent|{BUNDLE}|0|2|4|FADE\n"
    (out / "snapshots" / "tcc-granted.txt").write_text(tcc)
    (out / "snapshots" / "tcc-after.txt").write_text(tcc)
    designated = 'identifier "x" and anchor apple generic'
    (out / "evidence" / "app-before.txt").write_text(
        f"version=1.0.1\nbuild=1000199\ndesignated={designated}\nspctl=/Applications/x.app: accepted source=Notarized\n")
    (out / "evidence" / "app-after.txt").write_text(f"version=1.1.0-beta.1\nbuild=1010001\ndesignated={designated}\n")
    (out / "evidence" / "typing-before.json").write_text(json.dumps({"matched": True}))
    (out / "evidence" / "app-windows-after.json").write_text("[]")
    (out / "evidence" / "prompt-processes.txt").write_text("")
    (out / "evidence" / "update-offer-find.json").write_text(json.dumps(
        {"found": "Install Update", "window": {"texts": ["A new version 1.1.0-beta.1 is available"]}}))
    (out / "evidence" / "update-offer-menu.json").write_text(json.dumps({"pressed": "Check for updates..."}))
    (out / "evidence" / "update-ready-find.json").write_text(json.dumps({"found": "Install and Relaunch"}))
    (out / "evidence" / "update-install-press.json").write_text(json.dumps({"pressed": "Install and Relaunch"}))
    (out / "feed-requests.jsonl").write_text(
        json.dumps({"path": "/appcast.xml", "status": 200}) + "\n"
        + json.dumps({"path": f"/download/{SLUG}-1.1.0-beta.1.zip", "status": 200, "size": 9, "userAgent": "u"}) + "\n")
    (out / "relaunch.json").write_text(json.dumps({
        "oldExitedAt": start - 2, "snapshotAt": start - 1.99, "newProcessBeforeSnapshot": False, "newPid": 900,
        "newStartedAt": start, "tapLatencySeconds": tap, "taps": [],
        "typingLatencySeconds": typing, "attempts": [{"value": "duyệt", "endedAt": start + typing}]}))
    events = [{"at": "2027-01-15T08:00:00Z", "code": "lifecycle.launched",
               "fields": {"version": "1.1.0-beta.1", "build": "1010001"}},
              {"at": "2027-01-15T08:00:00Z", "code": "host.state", "fields": {"to": "readyVietnamese"}}]
    stamp = report.dt.datetime.fromtimestamp(start, report.dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    (out / "logs" / "app-diagnostics.jsonl").write_text(
        "".join(json.dumps(dict(e, at=stamp)) + "\n" for e in events))
    dump = {"user": {"tonePlacement": "set(modern)"}, "explicitSettings": [f"s{i}" for i in range(12)],
            "appModes": {"globalMode": "vi", "apps": [{"bundle": "a", "rule": "ignore", "mode": None},
                                                     {"bundle": "b", "rule": None, "mode": "en"}]},
            "ruleOverrides": [{"rule": "{}"}], "macros": [{"id": str(i)} for i in range(50)], "safeMode": False,
            "readOnlyFiles": [], "notices": []}
    (out / "dumps" / "seeded.previous.json").write_text(json.dumps(dump))
    (out / "dumps" / "at-exit.previous.json").write_text(json.dumps(dump))
    after = dict(dump, user=dict(dump["user"], typoCorrection="unset", neverCorrect=[]))
    (out / "dumps" / "after.candidate.json").write_text(json.dumps(after))
    (out / "dumps" / "loaded.candidate.json").write_text(json.dumps(after))
    probe = {"build": 1010002, "version": "1.1.0-beta.1-channelprobe"}
    rows = []
    for index, channel in ((1, "beta"), (2, "stable"), (3, "beta")):
        offered = channel == "beta" and offered_probe
        rows.append(f"{index}\t{channel}\t{'Install Update' if offered else 'OK'}")
        texts = [f"{probe['version']} is now available"] if offered else ["You're up to date!"]
        (out / "evidence" / f"channel-{index}-{channel}-window.json").write_text(json.dumps({"texts": texts}))
    (out / "channel.tsv").write_text("\n".join(rows) + "\n")
    (out / "titles-install.txt").write_text("Install Update\n")
    for phase, nettop in (("update", NETTOP.splitlines()[:3]), ("local", NETTOP.splitlines()[:3]),
                          ("production", [NETTOP.splitlines()[0], NETTOP.splitlines()[1], NETTOP.splitlines()[3]])):
        (out / "egress" / f"{phase}-nettop.csv").write_text("\n".join(nettop) + "\n")
        (out / "egress" / f"{phase}-lsof.txt").write_text("#t 1\n" * 600)
        (out / "egress" / f"{phase}-dns.txt").write_text(DNS)
        (out / "egress" / f"{phase}-started").write_text("1800000000\n")
        (out / "egress" / f"{phase}-ended").write_text("1800000600\n")
        (out / "evidence" / f"egress-{phase}-menu.json").write_text(json.dumps({"pressed": "Check for updates..."}))
    artefacts = {"previous": {"version": "1.0.1", "build": 1000199, "commit": "a", "dmg": {"sha256": "0" * 64}},
                 "candidate": {"version": "1.1.0-beta.1", "build": 1010001, "commit": "b",
                               "zip": {"path": f"/x/{SLUG}-1.1.0-beta.1.zip", "sha256": "1" * 64, "length": 9},
                               "signatureSource": "published appcast", "signatureCheck": "Signature Verified"}}
    return {"artefacts": artefacts, "feed": {"probe": probe}}


class VerdictTests(unittest.TestCase):
    def evaluate(self, **kwargs) -> dict:
        with tempfile.TemporaryDirectory() as tmp:
            data = write_run(Path(tmp), **kwargs)
            run = report.Run(Path(tmp), data["artefacts"], report.brand_values(REPO / "scripts" / "brand.env"))
            stops = kwargs.get("stops", [])
            return report.evaluate(run, data["feed"], {"channel": True, "egress": True, "minutes": 10,
                                                       "watchdogStops": stops})

    def results(self, result: dict) -> dict:
        return {c["id"]: c["result"] for c in result["checks"]}

    def test_a_complete_run_passes_every_check(self):
        result = self.evaluate()
        self.assertEqual(result["verdict"], "PASS", [c for c in result["checks"] if c["result"] != "pass"])
        self.assertEqual(len(result["checks"]), 15)

    def test_a_slow_tap_or_slow_typing_fails_its_check(self):
        self.assertEqual(self.results(self.evaluate(tap=2.4))["tap-within-2s"], "fail")
        result = self.evaluate(typing=5.6)
        self.assertEqual(self.results(result)["typing-within-5s"], "fail")
        self.assertEqual(result["verdict"], "FAIL")

    def test_a_beta_channel_that_offers_nothing_fails_the_channel_switch(self):
        self.assertEqual(self.results(self.evaluate(offered_probe=False))["channel-switch"], "fail")

    def test_the_update_egress_is_advisory_and_a_late_exit_snapshot_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            data = write_run(Path(tmp))
            nettop = "\n".join([NETTOP.splitlines()[0], NETTOP.splitlines()[5], NETTOP.splitlines()[6]]) + "\n"
            (Path(tmp) / "upgrade-out" / "egress" / "update-nettop.csv").write_text(nettop)  # Autoupdate to Apple
            relaunch = json.loads((Path(tmp) / "upgrade-out" / "relaunch.json").read_text())
            relaunch["snapshotAt"] = relaunch["newStartedAt"] + 0.1  # copied after the start: allowed by itself
            relaunch["snapshotModified"] = {"settings.json": relaunch["newStartedAt"] + 0.05}  # but written after it
            (Path(tmp) / "upgrade-out" / "relaunch.json").write_text(json.dumps(relaunch))
            run = report.Run(Path(tmp), data["artefacts"], report.brand_values(REPO / "scripts" / "brand.env"))
            result = report.evaluate(run, data["feed"], {"channel": True, "egress": True, "minutes": 10,
                                                         "watchdogStops": []})
        results = self.results(result)
        self.assertEqual(results["egress-update"], "fail")
        self.assertEqual(result["advisories"], ["egress-update"])
        self.assertEqual(results["settings-files"], "fail")
        self.assertEqual(result["failed"], ["settings-files"])

    def test_the_command_writes_result_and_summary_and_exits_by_verdict(self):
        with tempfile.TemporaryDirectory() as tmp:
            folder = Path(tmp)
            data = write_run(folder)
            (folder / "artefacts.json").write_text(json.dumps(data["artefacts"]))
            (folder / "feed.json").write_text(json.dumps(data["feed"]))
            stops = folder / "stops.txt"
            stops.write_text("")
            args = ["analyse", "--run", tmp, "--artefacts", str(folder / "artefacts.json"), "--feed",
                    str(folder / "feed.json"), "--brand-env", str(REPO / "scripts" / "brand.env"), "--out",
                    str(folder / "result.json"), "--summary", str(folder / "summary.txt"), "--watchdog-log",
                    str(stops)]
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.main(args), 0)
            result = json.loads((folder / "result.json").read_text())
            self.assertEqual(result["verdict"], "PASS")
            self.assertIn("RESULT: PASS", (folder / "summary.txt").read_text())
            stops.write_text("2026-11-23 01:00:00 level=4 free=10%: stop vm\n")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(report.main(args), 5)
            self.assertEqual(json.loads((folder / "result.json").read_text())["verdict"], "ABORTED")


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


TCPDUMP = """1800000001.100000 (proc {name}:812) IP6 ::1.50211 > ::1.443: Flags [S], seq 1, win 65535, length 0
1800000001.100010 () IP6 ::1.50211 > ::1.443: Flags [S], seq 1, win 65535, length 0
1800000001.200000 (proc {name}:812) IP6 ::1.50211 > ::1.443: Flags [.], ack 2, win 6379, length 0
1800000002.000000 (proc mDNSResponder:240, eproc {name}:812) IP 192.168.64.43.63136 > 192.168.64.1.53: 4+ A? {host}. (30)
1800000002.050000 (proc mDNSResponder:240, eproc {name}:812) IP 192.168.64.1.53 > 192.168.64.43.63136: 4 2/0/0 A 104.21.1.1, A 172.67.1.1 (62)
1800000002.100000 (proc {name}:812) IP 192.168.64.43.50300 > 104.21.1.1.443: Flags [SEW], seq 5, win 65535, length 0
1800000003.000000 (proc mDNSResponder:240, eproc {name}:812) IP 192.168.64.43.63137 > 192.168.64.1.53: 5+ AAAA? tracker.example. (33)
1800000003.100000 (proc {name}:812) IP 192.168.64.43.50301 > 93.184.216.34.443: UDP, length 1200
1800000004.000000 (proc softwareupdated:300) IP 192.168.64.43.50400 > 17.253.1.1.443: Flags [S], seq 9, length 0
""".replace("{name}", NAME).replace("{host}", HOST)


class TcpdumpTests(unittest.TestCase):
    def test_syn_udp_and_dns_lookups_are_attributed_to_the_sending_process(self):
        events = report.tcpdump_events(TCPDUMP)
        kinds = [(e["kind"], e["process"], e.get("remote"), e.get("port")) for e in events]
        self.assertIn(("syn", NAME, "::1", 443), kinds)
        self.assertIn(("syn", NAME, "104.21.1.1", 443), kinds)
        self.assertIn(("udp", NAME, "93.184.216.34", 443), kinds)
        self.assertIn(("syn", "softwareupdated", "17.253.1.1", 443), kinds)
        self.assertEqual(len([k for k in kinds if k[0] == "syn" and k[2] == "::1"]), 1)  # no ACK, no blank meta
        queries = [e["names"] for e in events if e["kind"] == "dns-query"]
        self.assertEqual(queries, [[HOST], ["tracker.example"]])
        answers = [e["addresses"] for e in events if e["kind"] == "dns-answer"]
        self.assertEqual(answers, [["104.21.1.1", "172.67.1.1"]])

    def test_the_production_phase_flags_other_hosts_and_other_lookups(self):
        with tempfile.TemporaryDirectory() as tmp:
            egress = Path(tmp) / "egress"
            egress.mkdir()
            (egress / "production-tcpdump.txt").write_text(TCPDUMP)
            (egress / "production-started").write_text("1800000000\n")
            result = report.egress_phase(Path(tmp), "production", NAME, [HOST])
        self.assertEqual({c["remote"] for c in result["disallowed"]}, {"93.184.216.34"})  # softwareupdated ignored
        self.assertIn("104.21.1.1", result["allowedAddresses"])  # from the app's own DNS answer
        self.assertEqual(result["disallowedLookups"], ["tracker.example"])


TCCD = """2026-11-23 01:57:50.300 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=7.1, function=<private>, service=kTCCServiceAccessibility, preflight=yes, query=1, client_dict=(null)
2026-11-23 01:57:50.301 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_ATTRIBUTION: msgID=7.1, attribution={requesting={TCCDProcess: identifier={bundle}, pid=2227, auid=501, euid=501, binary_path=/x}, },
2026-11-23 01:57:50.302 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=7.1, authValue=2, authReason=4, authVersion=1, desired_auth=0, error=(null),
2026-11-23 01:57:51.300 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=8.1, function=<private>, service=kTCCServiceListenEvent, preflight=no, query=1, client_dict=(null)
2026-11-23 01:57:51.301 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=8.1, subject={bundle},
2026-11-23 01:57:59.302 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=8.1, authValue=2, authReason=2, authVersion=1, desired_auth=0, error=(null),
2026-11-23 01:57:52.300 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=9.1, function=<private>, service=kTCCServiceAccessibility, preflight=yes, query=1, client_dict=(null)
2026-11-23 01:57:52.301 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=9.1, subject={bundle}.dev.testhost,
""".replace("{bundle}", BUNDLE)


class TccLogTests(unittest.TestCase):
    def test_requests_are_joined_by_message_and_a_consent_answer_shows_a_prompt(self):
        requests = sorted(report.tcc_requests(TCCD, BUNDLE), key=lambda r: r["msgID"])
        self.assertEqual([(r["service"], r["authValue"], r["authReason"]) for r in requests],
                         [("kTCCServiceAccessibility", "2", "4"), ("kTCCServiceListenEvent", "2", "2")])
        self.assertEqual([r["msgID"] for r in requests if r["authReason"] in report.PROMPT_REASONS], ["8.1"])
        self.assertAlmostEqual(requests[0]["time"], 1795399070.3, places=1)


class FeedServerTests(unittest.TestCase):
    def test_every_request_is_logged_with_its_status_size_and_user_agent(self):
        import threading
        import urllib.request
        from http.server import ThreadingHTTPServer
        spec = importlib.util.spec_from_file_location("feed_server", FEED_SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "feed"
            root.mkdir()
            (root / "appcast.xml").write_text("<rss/>")
            module.FeedHandler.log_path = str(Path(tmp) / "log.jsonl")
            handler = module.functools.partial(module.FeedHandler, directory=str(root))
            server = ThreadingHTTPServer(("127.0.0.1", 0), handler)  # plain HTTP on loopback, test only
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f"http://127.0.0.1:{server.server_address[1]}"
                request = urllib.request.Request(base + "/appcast.xml", headers={"User-Agent": "probe/1"})
                self.assertEqual(urllib.request.urlopen(request).read(), b"<rss/>")
                with self.assertRaises(urllib.error.HTTPError), contextlib.redirect_stderr(io.StringIO()):
                    urllib.request.urlopen(base + "/missing.zip")
            finally:
                server.shutdown()
                server.server_close()
            lines = [json.loads(line) for line in (Path(tmp) / "log.jsonl").read_text().splitlines()]
        self.assertEqual([(r["path"], r["status"], r["size"]) for r in lines][0], ("/appcast.xml", 200, 6))
        self.assertEqual(lines[0]["userAgent"], "probe/1")
        self.assertEqual(lines[1]["status"], 404)


def dns_query(name: str, qtype: int, ident: int = 0x1234) -> bytes:
    import struct
    labels = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return struct.pack(">HHHHHH", ident, 0x0100, 1, 0, 0, 1) + labels + struct.pack(">HH", qtype, 1)


class LocalDnsTests(unittest.TestCase):
    """The feed server's DNS: loopback for A and AAAA of the site host, nothing for the HTTPS record (the record that
    sent the download to the production host over HTTP/3 in run 20261122T214034Z-upgrade)."""

    def server(self):
        spec = importlib.util.spec_from_file_location("feed_server_dns", FEED_SERVER)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module

    def test_a_and_aaaa_answer_loopback_and_https_has_no_answer(self):
        import struct
        dns = self.server()
        reply, name, qtype, answers = dns.dns_reply(dns_query(HOST, 1), HOST)
        self.assertEqual((name, qtype, answers), (HOST, 1, 1))
        self.assertEqual(struct.unpack(">H", reply[:2])[0], 0x1234)
        self.assertEqual(reply[-4:], bytes([127, 0, 0, 1]))
        reply, _, _, answers = dns.dns_reply(dns_query(HOST, 28), HOST)
        self.assertEqual((answers, reply[-16:]), (1, bytes(15) + b"\x01"))
        reply, _, _, answers = dns.dns_reply(dns_query(HOST, 65), HOST)
        self.assertEqual(answers, 0)
        self.assertEqual(struct.unpack(">H", reply[2:4])[0] & 0x000F, 0)  # NOERROR, no data
        reply, _, _, _ = dns.dns_reply(dns_query("other." + HOST, 1), HOST)
        self.assertEqual(struct.unpack(">H", reply[2:4])[0] & 0x000F, 3)  # NXDOMAIN
        self.assertEqual(dns.dns_reply(b"short", HOST)[0], b"")


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
