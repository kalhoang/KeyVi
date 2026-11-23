# SPDX-License-Identifier: GPL-3.0-or-later
"""Self-tests for the host-side logic of the upgrade test (scripts/vm/upgrade-report.py, upgrade_feed.py,
upgrade_evidence.py) and the guest's feed server. Run: python3 -I scripts/tests/test_upgrade_report.py

Artefact and signature checks (a throwaway openssl key), the local feed, the evidence parsers (tcpdump, nettop, lsof,
dscacheutil, tccd), the comparisons and the verdict, against synthetic files. test_upgrade_test.py covers the host
script and the guest scripts and reuses the helpers defined here.
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
import types
import unittest
import zipfile
from pathlib import Path

sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__ (the modules below are loaded by path)
sys.path.insert(0, str(Path(__file__).resolve().parent))

from support import REPO, SCRIPTS  # noqa: E402
from test_vm_lab import brand_value  # noqa: E402

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


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# upgrade-report.py and the two modules it loads from scripts/vm, as one namespace for the tests below.
_report = load("upgrade_report", REPORT_PATH)
report = types.SimpleNamespace(**{**vars(load("upgrade_feed_test", SCRIPTS / "vm" / "upgrade_feed.py")),
                                  **vars(load("upgrade_evidence_test", SCRIPTS / "vm" / "upgrade_evidence.py")),
                                  **vars(_report)})


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
        # As seen in run 20261123T042942Z-upgrade between the export while 1.0.1 ran and the one after the update:
        # the launch guard and the self-check store integer fingerprints, the old version's quit cleared the crash
        # streak, its update check stamped SULastCheckTime and AppKit saved the frame of Sparkle's update window.
        before = {"diagnostics.redactionSalt": b"salt", "launchGuard.appVersion": 3450518130,
                  "launch.lastVersionFingerprint": 2513584745694642, "launchGuard.inProgressSince": 1795408644.69,
                  "SUEnableAutomaticChecks": False, "PermissionLastGrantedIdentity": 4208059965609703}
        after = dict(before, **{"launchGuard.appVersion": 3923503363, "launch.lastVersionFingerprint": 1763444526767235,
                                "launchGuard.inProgressSince": 1795408679.89, "launchGuard.recentCrashes": 0,
                                "launchGuard.firstCrashAt": 0.0, "SULastCheckTime": report.dt.datetime(2026, 11, 23),
                                "NSWindow Frame SUUpdateAlert2": "246 266 561 402 0 0 1024 738 "})
        self.assertEqual(report.compare_defaults(before, after)["unexplained"], [])
        lost = dict(after, **{"diagnostics.redactionSalt": b"other", "PermissionLastGrantedIdentity": 1})
        lost.pop("SUEnableAutomaticChecks")
        self.assertEqual(report.compare_defaults(before, lost)["unexplained"],
                         ["PermissionLastGrantedIdentity", "SUEnableAutomaticChecks", "diagnostics.redactionSalt"])
        # A rule covers only the values its code writes, and never a removed key.
        crashed = dict(after, **{"launchGuard.recentCrashes": 2})
        self.assertEqual(report.compare_defaults(before, crashed)["unexplained"], ["launchGuard.recentCrashes"])
        gone = {k: v for k, v in after.items() if k != "launchGuard.appVersion"}
        self.assertEqual(report.compare_defaults(before, gone)["unexplained"], ["launchGuard.appVersion"])

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
        # The learned collision choices (collision-memory.json, PLT-R914) are compared like the macros.
        learned = dict(before, collisionMemory=['{"word":"bar"}'])
        self.assertEqual(report.content_equal(learned, dict(after, collisionMemory=[]), report.CANDIDATE_ONLY_FIELDS),
                         ["collisionMemory differs"])
        self.assertEqual(report.seeded_survived(dict(seeded, collisionMemory=['{"word":"bar"}']), after_apps),
                         ["collisionMemory"])


START = 1_800_000_000.0
TCCD_RUN = """#timezone=UTC
{t0} Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=40.1, function=<private>, service=kTCCServiceAccessibility, preflight=yes, query=1, client_dict=(null)
{t0} Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=40.1, subject={bundle},
{t0} Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_RESULT: msgID=40.1, authValue=2, authReason=4, authVersion=1, desired_auth=0, error=(null),
#exit=0
"""
# The capture of the install (tcpdump alone, from START - 40), as in run 20261123T055630Z-upgrade: the app's lookup of
# the site host (answered by the local feed's DNS) and its connection to the local feed, a lookup of Safari's, and the
# system's revocation check of the update's signature: mDNSResponder looks up Apple's OCSP name for Autoupdate, then
# trustd connects for Autoupdate to an address of the answer. syspolicyd is the system's, not the app's.
UPDATE_OCSP_LOOKUP = ("1799999981.590000 (proc mDNSResponder:229, eproc Autoupdate:2047) IP 192.168.64.55.52731 > "
                      "192.168.64.1.53: 1192+ A? ocsp2.g.aaplimg.com. (37)")
UPDATE_OCSP_ANSWER = ("1799999981.630000 (proc mDNSResponder:229, eproc Autoupdate:2047) IP 192.168.64.1.53 > "
                      "192.168.64.55.52731: 1192 2/0/0 A 17.253.61.136, A 17.253.61.154 (69)")
UPDATE_OCSP_SYN = ("1799999981.640000 (proc trustd:371, eproc Autoupdate:2047) IP 192.168.64.55.63623 > "
                   "17.253.61.136.443: Flags [SEW], seq 3, win 65535, length 0")
UPDATE_TCPDUMP = """1799999975.100000 (proc mDNSResponder:229, eproc {name}:1946) IP 127.0.0.1.63636 > 127.0.0.1.53: 25043+ Type65? {host}. (30)
1799999975.100020 (proc Python:915) IP 127.0.0.1.63636 > 127.0.0.1.53: 25043+ Type65? {host}. (30)
1799999975.200000 (proc {name}:1946) IP6 ::1.49158 > ::1.443: Flags [S], seq 1, win 65535, length 0
1799999975.200010 () IP6 ::1.49158 > ::1.443: Flags [S], seq 1, win 65535, length 0
1799999975.300000 (proc mDNSResponder:229, eproc {name}:1946) IP 127.0.0.1.53 > 127.0.0.1.63636: 25043* 0/0/0 (30)
1799999978.500000 (proc mDNSResponder:229, eproc com.apple.Safari:1234) IP 192.168.64.55.57037 > 192.168.64.1.53: 10933+ A? token.safebrowsing.apple. (42)
1799999978.550000 (proc mDNSResponder:229, eproc com.apple.Safari:1234) IP 192.168.64.1.53 > 192.168.64.55.57037: 10933 3/0/0 CNAME safebrowsing.g.aaplimg.com., A 17.253.61.154, A 17.253.61.146 (146)
{lookup}
{answer}
{syn}
1799999982.400000 (proc syspolicyd:256) IP 192.168.64.55.61620 > 17.248.224.65.443: quic, protected
""".replace("{name}", NAME).replace("{host}", HOST).replace("{lookup}", UPDATE_OCSP_LOOKUP).replace(
    "{answer}", UPDATE_OCSP_ANSWER).replace("{syn}", UPDATE_OCSP_SYN)


def utc_stamp(epoch: float, fmt: str = "%Y-%m-%dT%H:%M:%SZ") -> str:
    return report.dt.datetime.fromtimestamp(epoch, report.dt.timezone.utc).strftime(fmt)


def write_run(folder: Path, *, tap: float = 0.4, typing: float = 1.8, offered_probe: bool = True) -> dict:
    """A complete synthetic guest output, as upgrade-guest.sh writes it, for a passing run."""
    out = folder / "upgrade-out"
    for sub in ("snapshots/at-exit", "snapshots/loaded", "snapshots/after", "snapshots/seeded", "evidence", "egress",
                "logs", "dumps"):
        (out / sub).mkdir(parents=True, exist_ok=True)
    start = START
    files = {"settings.json": json.dumps(settings_doc("1.0.1")), "macros.json": "{}",
             "collision-memory.json": json.dumps({"schemaVersion": 1, "entries": [{"word": "bar"}]})}
    for snap in ("at-exit", "loaded", "after", "seeded"):
        for name, text in files.items():
            (out / "snapshots" / snap / name).write_text(text)
    defaults = {"diagnostics.redactionSalt": b"s", "launchGuard.inProgressSince": start - 60,
                "SUEnableAutomaticChecks": False}
    for name, values in (("before", defaults), ("at-exit", dict(defaults, **{"launchGuard.inProgressSince": 0.0})),
                         ("after", dict(defaults, **{"launchGuard.inProgressSince": start}))):
        with (out / "snapshots" / f"defaults-{name}.plist").open("wb") as handle:
            plistlib.dump(values, handle)
    tcc = f"kTCCServiceAccessibility|{BUNDLE}|0|2|4|FADE\nkTCCServiceListenEvent|{BUNDLE}|0|2|4|FADE\n"
    (out / "snapshots" / "tcc-granted.txt").write_text(tcc)
    (out / "snapshots" / "tcc-after.txt").write_text(tcc)
    (out / "logs" / "tccd.log").write_text(
        TCCD_RUN.replace("{t0}", utc_stamp(start + 0.5, "%Y-%m-%d %H:%M:%S.500")).replace("{bundle}", BUNDLE))
    designated = 'identifier "x" and anchor apple generic'
    (out / "evidence" / "app-before.txt").write_text(
        f"version=1.0.1\nbuild=1000199\ndesignated={designated}\nspctl=/Applications/x.app: accepted source=Notarized\n")
    (out / "evidence" / "app-after.txt").write_text(f"version=1.1.0-beta.1\nbuild=1010001\ndesignated={designated}\n")
    (out / "evidence" / "typing-before.json").write_text(json.dumps({"matched": True}))
    (out / "evidence" / "app-windows-after.json").write_text("[]")
    (out / "evidence" / "prompt-processes.txt").write_text("#exit=1\n")
    (out / "evidence" / "update-offer-find.json").write_text(json.dumps(
        {"found": "Install Update", "window": {"texts": ["A new version 1.1.0-beta.1 is available"]}}))
    (out / "evidence" / "update-offer-menu.json").write_text(json.dumps({"pressed": "Check for updates..."}))
    (out / "evidence" / "update-ready-find.json").write_text(json.dumps({"found": "Install and Relaunch"}))
    (out / "evidence" / "update-install-press.json").write_text(json.dumps({"pressed": "Install and Relaunch"}))
    requests = [{"path": "/appcast.xml", "status": 200, "at": start - 30},
                {"path": f"/download/{SLUG}-1.1.0-beta.1.zip", "status": 200, "size": 9, "userAgent": "u",
                 "at": start - 20},
                {"kind": "dns", "name": HOST, "type": "HTTPS", "answers": 0, "at": start + 100},
                {"path": "/appcast.xml", "status": 200, "at": start + 130}]
    (out / "feed-requests.jsonl").write_text("".join(json.dumps(r) + "\n" for r in requests))
    keys_at = start + typing  # the first key of the one typing attempt; it counts only after the tap (start + tap)
    (out / "relaunch.json").write_text(json.dumps({
        "oldExitedAt": start - 2, "snapshotAt": start - 1.99, "newProcessBeforeSnapshot": False, "newPid": 900,
        "newStartedAt": start, "tapEnabledAt": start + tap, "tapLatencySeconds": tap, "taps": [],
        "defaultsAt": start + 0.4,
        "attempts": [{"value": "duyệt", "matched": True, "startedAt": keys_at - 0.1, "keysStartedAt": keys_at,
                      "keysEndedAt": keys_at + 0.7, "endedAt": keys_at + 1.0}]}))
    events = [{"at": start, "code": "lifecycle.launched", "fields": {"version": "1.1.0-beta.1", "build": "1010001"}},
              {"at": start, "code": "host.state", "fields": {"to": "readyVietnamese"}}]
    probe = {"build": 1010002, "version": "1.1.0-beta.1-channelprobe"}
    rows = []
    for index, channel in ((1, "beta"), (2, "stable"), (3, "beta")):
        offered = channel == "beta" and offered_probe
        step_start = int(start) + 50 + index * 20
        rows.append(f"{index}\t{channel}\t{'Install Update' if offered else 'OK'}\t{step_start}\t{step_start + 8}")
        texts = [f"{probe['version']} is now available"] if offered else [
            "You’re up to date!", f"{NAME} 1.0.1 is currently the newest version available."]
        (out / "evidence" / f"channel-{index}-{channel}-window.json").write_text(json.dumps({"texts": texts}))
        if offered:
            events.append({"at": step_start + 4, "code": "update.updateFound", "fields": {"build": str(probe["build"])}})
    events.append({"at": start + 700, "code": "update.updateFound", "fields": {"build": str(probe["build"])}})
    (out / "logs" / "app-diagnostics.jsonl").write_text(
        "".join(json.dumps(dict(e, at=utc_stamp(e["at"]))) + "\n" for e in events))
    (out / "channel.tsv").write_text("\n".join(rows) + "\n")
    (out / "titles-install.txt").write_text("Install Update\n")
    (out / "titles-uptodate.txt").write_text("You’re up to date!\nBạn đang dùng phiên bản mới nhất!\n")
    collision = ['{"context":"afterEnglish","word":"bar"}']
    dump = {"user": {"tonePlacement": "set(modern)"}, "explicitSettings": [f"s{i}" for i in range(12)],
            "appModes": {"globalMode": "vi", "apps": [{"bundle": "a", "rule": "ignore", "mode": None},
                                                     {"bundle": "b", "rule": None, "mode": "en"}]},
            "ruleOverrides": [{"rule": "{}"}], "macros": [{"id": str(i)} for i in range(50)],
            "collisionMemory": collision, "safeMode": False, "readOnlyFiles": [], "notices": []}
    (out / "dumps" / "seeded.previous.json").write_text(json.dumps(dump))
    (out / "dumps" / "at-exit.previous.json").write_text(json.dumps(dump))
    after = dict(dump, user=dict(dump["user"], typoCorrection="unset", neverCorrect=[]))
    (out / "dumps" / "after.candidate.json").write_text(json.dumps(after))
    (out / "dumps" / "loaded.candidate.json").write_text(json.dumps(after))
    phases = {"update": (int(start) - 40, []), "local": (int(start) + 120, NETTOP.splitlines()[:3]),
              "production": (int(start) + 800, [NETTOP.splitlines()[0], NETTOP.splitlines()[1],
                                                NETTOP.splitlines()[3]])}
    for phase, (phase_start, nettop) in phases.items():
        if phase == "update":  # tcpdump alone during the install (upgrade-guest.sh: sampler_start update light)
            (out / "egress" / "update-tcpdump.txt").write_text(UPDATE_TCPDUMP)
        else:
            (out / "egress" / f"{phase}-nettop.csv").write_text("\n".join(nettop) + "\n")
            (out / "egress" / f"{phase}-lsof.txt").write_text("#t 1\n" * 600)
            (out / "egress" / f"{phase}-dns.txt").write_text(DNS)
        (out / "egress" / f"{phase}-tcpdump.err").write_text(
            "92 packets captured\n830 packets received by filter\n0 packets dropped by kernel\n")
        (out / "egress" / f"{phase}-started").write_text(f"{phase_start}\n")
        (out / "egress" / f"{phase}-ended").write_text(f"{phase_start + 600}\n")
        (out / "evidence" / f"egress-{phase}-menu.json").write_text(json.dumps({"pressed": "Check for updates..."}))
        (out / "evidence" / f"egress-{phase}-find.json").write_text(json.dumps({"found": "OK"}))
    artefacts = {"previous": {"version": "1.0.1", "build": 1000199, "commit": "a", "dmg": {"sha256": "0" * 64}},
                 "candidate": {"version": "1.1.0-beta.1", "build": 1010001, "commit": "b",
                               "zip": {"path": f"/x/{SLUG}-1.1.0-beta.1.zip", "sha256": "1" * 64, "length": 9},
                               "signatureSource": "published appcast", "signatureCheck": "Signature Verified"}}
    return {"artefacts": artefacts, "feed": {"probe": probe}}


def edit_json(path: Path, change) -> None:
    """Rewrites a JSON evidence file of a synthetic run with `change(data)` (which returns the new data)."""
    path.write_text(json.dumps(change(json.loads(path.read_text(encoding="utf-8")))), encoding="utf-8")


class VerdictHelpers:
    """The verdict of a synthetic run (write_run), changed by the test first."""

    def evaluate(self, change=None, minutes: int = 10, **kwargs) -> dict:
        """The verdict of a synthetic passing run, after `change(upgrade-out folder)` when given."""
        with tempfile.TemporaryDirectory() as tmp:
            data = write_run(Path(tmp), **kwargs)
            if change:
                change(Path(tmp) / "upgrade-out")
            run = report.Run(Path(tmp), data["artefacts"], report.brand_values(REPO / "scripts" / "brand.env"))
            return report.evaluate(run, data["feed"], {"channel": True, "egress": True, "minutes": minutes,
                                                       "watchdogStops": []})

    def results(self, result: dict) -> dict:
        return {c["id"]: c["result"] for c in result["checks"]}

    def evidence(self, result: dict, identifier: str) -> str:
        return next(c["evidence"] for c in result["checks"] if c["id"] == identifier)


class VerdictTests(VerdictHelpers, unittest.TestCase):
    def test_a_complete_run_passes_every_check(self):
        result = self.evaluate()
        self.assertEqual(result["verdict"], "PASS", [c for c in result["checks"] if c["result"] != "pass"])
        self.assertEqual(len(result["checks"]), 15)

    def test_a_slow_tap_or_slow_typing_fails_its_check(self):
        self.assertEqual(self.results(self.evaluate(tap=2.4))["tap-within-2s"], "fail")
        result = self.evaluate(typing=5.6)
        self.assertEqual(self.results(result)["typing-within-5s"], "fail")
        self.assertEqual(result["verdict"], "FAIL")

    def test_a_word_typed_before_the_tap_was_enabled_does_not_count(self):
        # d, u and y read the same without the app: keys posted before its tap prove nothing (QA-R40).
        result = self.evaluate(tap=1.0, typing=0.6)
        self.assertEqual(self.results(result)["typing-within-5s"], "fail")
        self.assertIn("before the tap: not counted", self.evidence(result, "typing-within-5s"))

        def second_attempt(out: Path) -> None:
            edit_json(out / "relaunch.json", lambda r: dict(r, attempts=r["attempts"] + [
                {"value": "duyệt", "matched": True, "keysStartedAt": START + 3.2, "keysEndedAt": START + 3.9,
                 "endedAt": START + 4.2}]))
        later = self.evaluate(second_attempt, tap=1.0, typing=0.6)
        self.assertEqual(self.results(later)["typing-within-5s"], "pass")
        self.assertIn("typing worked from 3.200 s", self.evidence(later, "typing-within-5s"))

    def test_the_defaults_baseline_is_the_export_taken_while_the_previous_version_ran(self):
        # A key the candidate drops in its first second is already gone from the export at the old version's exit
        # (taken after the candidate started); the export before the update check still has it.
        def dropped_early(out: Path) -> None:
            for name in ("at-exit", "after"):
                path = out / "snapshots" / f"defaults-{name}.plist"
                values = report.load_plist(path)
                values.pop("SUEnableAutomaticChecks")
                with path.open("wb") as handle:
                    plistlib.dump(values, handle)
        result = self.evaluate(dropped_early)
        self.assertEqual(self.results(result)["defaults-domain"], "fail")
        self.assertIn("SUEnableAutomaticChecks False -> <absent>", self.evidence(result, "defaults-domain"))

    def test_missing_permission_evidence_is_not_a_pass(self):
        for name in ("evidence/app-windows-after.json", "evidence/prompt-processes.txt", "logs/tccd.log"):
            with self.subTest(missing=name):
                result = self.evaluate(lambda out, name=name: (out / name).unlink())
                self.assertEqual(self.results(result)["permissions"], "not-run")
                self.assertEqual(result["verdict"], "INCOMPLETE")
        failed_listing = self.evaluate(lambda out: (out / "evidence" / "prompt-processes.txt").write_text("#exit=3\n"))
        self.assertEqual(self.results(failed_listing)["permissions"], "not-run")
        # Compact timestamps without the UTC marker cannot be placed in time.
        no_zone = self.evaluate(lambda out: (out / "logs" / "tccd.log").write_text(
            "\n".join((out / "logs" / "tccd.log").read_text().splitlines()[1:]) + "\n"))
        self.assertEqual(self.results(no_zone)["permissions"], "not-run")

    def test_a_prompt_nobody_answered_or_a_window_fails_the_permissions_check(self):
        pending = """{t} Df tccd[1:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=41.1, function=<private>, service=kTCCServicePostEvent, preflight=no, query=1, client_dict=(null)
{t} Df tccd[1:1] [com.apple.TCC:access] AUTHREQ_SUBJECT: msgID=41.1, subject={bundle},
""".replace("{t}", utc_stamp(START + 1, "%Y-%m-%d %H:%M:%S.100")).replace("{bundle}", BUNDLE)

        def add_pending(out: Path) -> None:
            log = out / "logs" / "tccd.log"
            log.write_text(log.read_text() + pending)
        self.assertEqual(self.results(self.evaluate(add_pending))["permissions"], "fail")
        window = self.evaluate(lambda out: (out / "evidence" / "app-windows-after.json").write_text(
            json.dumps([{"title": "Permissions", "texts": [], "buttons": []}])))
        self.assertEqual(self.results(window)["permissions"], "fail")

    def test_the_candidate_store_must_read_the_learned_collision_choices(self):
        def lost(out: Path) -> None:
            for name in ("loaded", "after"):
                edit_json(out / "dumps" / f"{name}.candidate.json", lambda d: dict(d, collisionMemory=[]))
        result = self.evaluate(lost)
        self.assertEqual(self.results(result)["settings-content"], "fail")
        self.assertIn("collisionMemory differs", self.evidence(result, "settings-content"))
        unseeded = self.evaluate(lambda out: edit_json(out / "dumps" / "seeded.previous.json",
                                                       lambda d: dict(d, collisionMemory=[])))
        self.assertEqual(self.results(unseeded)["seeded"], "fail")

    def test_a_beta_channel_that_offers_nothing_fails_the_channel_switch(self):
        self.assertEqual(self.results(self.evaluate(offered_probe=False))["channel-switch"], "fail")

    def test_stable_must_say_up_to_date_and_find_nothing(self):
        def error_alert(out: Path) -> None:
            (out / "evidence" / "channel-2-stable-window.json").write_text(json.dumps(
                {"texts": ["Update Error!", "An error occurred in retrieving update information."]}))
        result = self.evaluate(error_alert)
        self.assertEqual(self.results(result)["channel-switch"], "fail")

        def found_on_stable(out: Path) -> None:
            stable = (out / "channel.tsv").read_text().splitlines()[1].split("\t")
            log = out / "logs" / "app-diagnostics.jsonl"
            log.write_text(log.read_text() + json.dumps({"at": utc_stamp(int(stable[3]) + 2),
                                                         "code": "update.updateFound",
                                                         "fields": {"build": "1010001"}}) + "\n")
        self.assertEqual(self.results(self.evaluate(found_on_stable))["channel-switch"], "fail")
        # The probe build found later (the production phase: the real next beta has the same build) is not counted.
        self.assertIn("update.updateFound in this step 1 (probe build 1)", self.evidence(self.evaluate(), "channel-switch"))

    def test_a_channel_row_without_step_times_is_not_evidence(self):
        def untimed_stable(out: Path) -> None:
            rows = [line.split("\t") for line in (out / "channel.tsv").read_text().splitlines()]
            rows[1] = rows[1][:3]
            (out / "channel.tsv").write_text("".join("\t".join(row) + "\n" for row in rows))
        result = self.evaluate(untimed_stable)
        self.assertEqual(self.results(result)["channel-switch"], "not-run")
        self.assertEqual(result["verdict"], "INCOMPLETE")
        self.assertIn("stable: up to date", self.evidence(result, "channel-switch"))
        self.assertIn("(no step times)", self.evidence(result, "channel-switch"))

    def test_a_shortened_or_incomplete_egress_phase_is_not_a_pass(self):
        short = self.evaluate(minutes=1)
        self.assertEqual(self.results(short)["egress-local"], "not-run")
        self.assertEqual(self.results(short)["egress-production"], "not-run")
        self.assertEqual(short["verdict"], "INCOMPLETE")
        self.assertIn("shortened to 1 min", self.evidence(short, "egress-local"))
        drops = self.evaluate(lambda out: (out / "egress" / "local-tcpdump.err").write_text(
            "3017 packets captured\n14655 packets dropped by kernel\n"))
        self.assertEqual(self.results(drops)["egress-local"], "not-run")
        self.assertIn("14655 packets dropped by the kernel", self.evidence(drops, "egress-local"))
        no_stats = self.evaluate(lambda out: (out / "egress" / "production-tcpdump.err").write_text(""))
        self.assertEqual(self.results(no_stats)["egress-production"], "not-run")

        def no_feed_request(out: Path) -> None:
            lines = (out / "feed-requests.jsonl").read_text().splitlines()
            (out / "feed-requests.jsonl").write_text("\n".join(lines[:3]) + "\n")
        silent = self.evaluate(no_feed_request)
        self.assertEqual(self.results(silent)["egress-local"], "not-run")
        self.assertIn("no appcast request reached the local feed", self.evidence(silent, "egress-local"))
        nothing_found = self.evaluate(lambda out: (out / "evidence" / "egress-local-find.json").write_text("{}"))
        self.assertIn("Sparkle's window: none found", self.evidence(nothing_found, "egress-local"))

    def test_a_disallowed_endpoint_fails_even_an_incomplete_phase(self):
        def leak(out: Path) -> None:
            (out / "egress" / "local-tcpdump.txt").write_text(TCPDUMP)  # the app reaches 93.184.216.34 over UDP
            (out / "egress" / "local-tcpdump.err").write_text("12 packets dropped by kernel\n")
        result = self.evaluate(leak, minutes=5)
        self.assertEqual(self.results(result)["egress-local"], "fail")
        self.assertEqual(result["verdict"], "FAIL")

    def test_a_late_exit_snapshot_fails_and_the_update_egress_is_part_of_the_verdict(self):
        def late_and_leaking(out: Path) -> None:
            nettop = "\n".join([NETTOP.splitlines()[0], NETTOP.splitlines()[5], NETTOP.splitlines()[6]]) + "\n"
            (out / "egress" / "update-nettop.csv").write_text(nettop)  # Autoupdate's own socket to an Apple address
            relaunch = json.loads((out / "relaunch.json").read_text())
            relaunch["snapshotAt"] = relaunch["newStartedAt"] + 0.1  # copied after the start: allowed by itself
            relaunch["snapshotModified"] = {"settings.json": relaunch["newStartedAt"] + 0.05}  # but written after it
            (out / "relaunch.json").write_text(json.dumps(relaunch))
        result = self.evaluate(late_and_leaking)
        results = self.results(result)
        self.assertEqual(results["egress-update"], "fail")
        self.assertEqual(results["settings-files"], "fail")
        self.assertEqual(result["failed"], ["settings-files", "egress-update"])
        self.assertEqual(result["advisories"], [])
        self.assertIn("Autoupdate 17.253.1.1:443/tcp NOT ALLOWED", self.evidence(result, "egress-update"))

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


def capture_edit(old: str, new: str, phase: str = "update"):
    """A change for VerdictHelpers.evaluate: replaces `old` by `new` in the phase's tcpdump capture."""
    def change(out: Path) -> None:
        path = out / "egress" / f"{phase}-tcpdump.txt"
        text = path.read_text(encoding="utf-8")
        assert old in text, old
        path.write_text(text.replace(old, new), encoding="utf-8")
    return change


class UpdateEgressTests(VerdictHelpers, unittest.TestCase):
    """egress-update: during the install, only the local feed, the site host and the system's revocation check of the
    update's signature (PLT-R906 and spec/02-platform.md 13.7 as amended on 2026-11-23)."""

    def assert_update(self, result: dict, expected: str, verdict: str) -> str:
        self.assertEqual(self.results(result)["egress-update"], expected, self.evidence(result, "egress-update"))
        self.assertEqual(result["verdict"], verdict)
        return self.evidence(result, "egress-update")

    def test_the_revocation_check_of_trustd_for_autoupdate_passes_and_is_named(self):
        result = self.evaluate()
        evidence = self.assert_update(result, "pass", "PASS")
        self.assertIn("trustd for Autoupdate 17.253.61.136:443/tcp (ocsp2.g.aaplimg.com)", evidence)
        self.assertIn("revocation checks: trustd for Autoupdate", evidence)
        self.assertIn(f"{NAME} [::1]:443/tcp", evidence)
        self.assertIn("served the candidate's archive 1 time(s) during the capture", evidence)
        self.assertNotIn("NOT ALLOWED", evidence)
        self.assertFalse(next(c for c in result["checks"] if c["id"] == "egress-update").get("advisory"))
        # The name behind the CDN name, answered through its CNAME, and the check over QUIC pass too.
        cname = capture_edit("A? ocsp2.g.aaplimg.com.", "A? ocsp2.apple.com.")
        answer = capture_edit("1192 2/0/0 A", "1192 3/0/0 CNAME ocsp2.g.aaplimg.com., A")
        self.assert_update(self.evaluate(lambda out: (cname(out), answer(out))), "pass", "PASS")
        quic = capture_edit("17.253.61.136.443: Flags [SEW], seq 3, win 65535, length 0",
                            "17.253.61.136.443: UDP, length 1200")
        self.assertIn("17.253.61.136:443/udp (ocsp2.g.aaplimg.com)",
                      self.assert_update(self.evaluate(quic), "pass", "PASS"))
        # Runs before the guest wrote update-ended: the capture lasts until the end of the step.
        self.assert_update(self.evaluate(lambda out: (out / "egress" / "update-ended").unlink()), "pass", "PASS")

    def test_an_apple_address_reached_without_a_matching_lookup_fails(self):
        no_lookup = capture_edit(UPDATE_OCSP_LOOKUP + "\n" + UPDATE_OCSP_ANSWER + "\n", "")
        evidence = self.assert_update(self.evaluate(no_lookup), "fail", "FAIL")
        self.assertIn("trustd for Autoupdate 17.253.61.136:443/tcp NOT ALLOWED", evidence)
        # Resolved only after the connection (times decide, not the order of the lines): the lookup does not explain it.
        early_syn = UPDATE_OCSP_SYN.replace("1799999981.640000", "1799999981.500000")
        self.assert_update(self.evaluate(capture_edit(UPDATE_OCSP_SYN, early_syn)), "fail", "FAIL")
        # A lookup without a connection (trustd had the answer cached) is allowed by itself.
        self.assert_update(self.evaluate(capture_edit(UPDATE_OCSP_SYN + "\n", "")), "pass", "PASS")
        # An address answered only for another name (Safari's lookup), even one on Apple's CDN.
        other = capture_edit("> 17.253.61.136.443: Flags [SEW]", "> 17.253.61.146.443: Flags [SEW]")
        self.assertIn("17.253.61.146:443/tcp (token.safebrowsing.apple) NOT ALLOWED",
                      self.assert_update(self.evaluate(other), "fail", "FAIL"))
        # An answer that belongs to another query (same ID, another client port) resolves nothing.
        stray = capture_edit("192.168.64.55.52731: 1192 2/0/0", "192.168.64.55.52799: 1192 2/0/0")
        self.assert_update(self.evaluate(stray), "fail", "FAIL")

    def test_a_lookup_of_a_name_that_only_resembles_apples_revocation_service_fails(self):
        for name in ("ocsp.apple.com.evil.example", "xocsp.apple.com", "ocsp.aaplimg.com.example",
                     "ocsp2.g.aaplimg.com.evil.example", "ocsp2-apple.com", "ocspx.apple.com", "ocsp2.apple.co"):
            with self.subTest(name=name):
                evidence = self.assert_update(self.evaluate(capture_edit("A? ocsp2.g.aaplimg.com.", f"A? {name}.")),
                                              "fail", "FAIL")
                self.assertIn(f"NOT ALLOWED lookups: Autoupdate {name}", evidence)
                self.assertIn("17.253.61.136:443/tcp", evidence)
        for name in ("ocsp.apple.com", "ocsp2.apple.com", "OCSP2.Apple.COM.", "ocsp2.g.aaplimg.com",
                     "ocsp.g.aaplimg.com"):
            self.assertTrue(report.is_revocation_name(name), name)
        for name in ("ocsp2.apple.com.edgesuite.net", "a1845.dscg2.akamai.net", "ocsp12.apple.com", "apple.com"):
            self.assertFalse(report.is_revocation_name(name), name)

    def test_only_trustd_for_autoupdate_may_make_the_revocation_check(self):
        for meta in (f"(proc {NAME}:1946)", f"(proc trustd:371, eproc {NAME}:1946)", "(proc Autoupdate:2047)",
                     "(proc trustd:371, eproc Updater:2050)"):
            with self.subTest(meta=meta):
                change = capture_edit("(proc trustd:371, eproc Autoupdate:2047)", meta)
                self.assertIn("17.253.61.136:443/tcp (ocsp2.g.aaplimg.com) NOT ALLOWED",
                              self.assert_update(self.evaluate(change), "fail", "FAIL"))
        port80 = capture_edit("17.253.61.136.443: Flags", "17.253.61.136.80: Flags")
        self.assert_update(self.evaluate(port80), "fail", "FAIL")
        # The app may not look the name up either.
        app_lookup = capture_edit("(proc mDNSResponder:229, eproc Autoupdate:2047) IP 192.168.64.55.52731 >",
                                  f"(proc mDNSResponder:229, eproc {NAME}:1946) IP 192.168.64.55.52731 >")
        self.assertIn(f"NOT ALLOWED lookups: {NAME} ocsp2.g.aaplimg.com",
                      self.assert_update(self.evaluate(app_lookup), "fail", "FAIL"))
        # Outside the install the revocation check is not allowed: the other phases stay as strict as before.
        def local_check(out: Path) -> None:
            path = out / "egress" / "local-tcpdump.txt"
            path.write_text("\n".join((UPDATE_OCSP_LOOKUP, UPDATE_OCSP_ANSWER, UPDATE_OCSP_SYN)) + "\n")
        local = self.evaluate(local_check)
        self.assertEqual(self.results(local)["egress-local"], "fail")
        self.assertEqual(self.results(local)["egress-update"], "pass")

    def test_a_capture_with_drops_without_statistics_or_missing_is_not_a_pass(self):
        err = "117 packets captured\n6225 packets received by filter\n259 packets dropped by kernel\n"
        drops = self.evaluate(lambda out: (out / "egress" / "update-tcpdump.err").write_text(err))
        self.assertIn("259 packets dropped by the kernel", self.assert_update(drops, "not-run", "INCOMPLETE"))
        self.assertIn("trustd for Autoupdate 17.253.61.136:443/tcp (ocsp2.g.aaplimg.com)",
                      self.evidence(drops, "egress-update"))
        no_stats = self.evaluate(lambda out: (out / "egress" / "update-tcpdump.err").write_text("tcpdump: listening\n"))
        self.assertIn("tcpdump printed no capture statistics", self.assert_update(no_stats, "not-run", "INCOMPLETE"))
        missing = self.evaluate(lambda out: (out / "egress" / "update-tcpdump.txt").unlink())
        self.assertIn("no capture of the install", self.assert_update(missing, "not-run", "INCOMPLETE"))
        unstarted = self.evaluate(lambda out: (out / "egress" / "update-started").unlink())
        self.assertIn("no start time of the capture", self.assert_update(unstarted, "not-run", "INCOMPLETE"))

        def downloaded_before(out: Path) -> None:
            path = out / "feed-requests.jsonl"
            lines = [json.loads(line) for line in path.read_text().splitlines()]
            lines[1]["at"] = START - 50  # before the capture started
            path.write_text("".join(json.dumps(line) + "\n" for line in lines))
        early = self.evaluate(downloaded_before)
        self.assertIn("no download of the candidate's archive while the capture ran",
                      self.assert_update(early, "not-run", "INCOMPLETE"))
        app_syn = (f"1799999975.200000 (proc {NAME}:1946) IP6 ::1.49158 > ::1.443: Flags [S], seq 1, win 65535, "
                   "length 0\n")
        unseen = self.evaluate(capture_edit(app_syn, ""))
        self.assertIn("no connection of the app to the local feed in the capture",
                      self.assert_update(unseen, "not-run", "INCOMPLETE"))

    def test_a_disallowed_host_fails_even_when_the_capture_dropped_packets_or_has_no_start(self):
        leak = (f"1799999983.000000 (proc {NAME}:1946) IP 192.168.64.55.50301 > 93.184.216.34.443: Flags [S], "
                "seq 7, win 65535, length 0\n")

        def leak_with_drops(out: Path) -> None:
            path = out / "egress" / "update-tcpdump.txt"
            path.write_text(path.read_text() + leak)
            (out / "egress" / "update-tcpdump.err").write_text("12 packets dropped by kernel\n")
            (out / "egress" / "update-started").unlink()
        result = self.evaluate(leak_with_drops)
        evidence = self.assert_update(result, "fail", "FAIL")
        self.assertIn("egress-update", result["failed"])
        self.assertIn(f"{NAME} 93.184.216.34:443/tcp NOT ALLOWED", evidence)
        self.assertIn("12 packets dropped by the kernel", evidence)


TCPDUMP = """1800000001.100000 (proc {name}:812) IP6 ::1.50211 > ::1.443: Flags [S], seq 1, win 65535, length 0
1800000001.100010 () IP6 ::1.50211 > ::1.443: Flags [S], seq 1, win 65535, length 0
1800000001.200000 (proc {name}:812) IP6 ::1.50211 > ::1.443: Flags [.], ack 2, win 6379, length 0
1800000002.000000 (proc mDNSResponder:240, eproc {name}:812) IP 192.168.64.43.63136 > 192.168.64.1.53: 4+ A? {host}. (30)
1800000002.050000 (proc mDNSResponder:240, eproc {name}:812) IP 192.168.64.1.53 > 192.168.64.43.63136: 4 2/0/0 A 104.21.1.1, A 172.67.1.1 (62)
1800000002.100000 (proc {name}:812) IP 192.168.64.43.50300 > 104.21.1.1.443: Flags [SEW], seq 5, win 65535, length 0
1800000003.000000 (proc mDNSResponder:240, eproc {name}:812) IP 192.168.64.43.63137 > 192.168.64.1.53: 5+ AAAA? tracker.example. (33)
1800000003.100000 (proc {name}:812) IP 192.168.64.43.50301 > 93.184.216.34.443: UDP, length 1200
1800000004.000000 (proc softwareupdated:300) IP 192.168.64.43.50400 > 17.253.1.1.443: Flags [S], seq 9, length 0
1800000005.000000 (proc {name}:812) IP 104.21.1.1.443 > 192.168.64.43.57696: quic, initial, scid 01d2, length 22
""".replace("{name}", NAME).replace("{host}", HOST)


class TcpdumpTests(unittest.TestCase):
    def test_syn_udp_and_dns_lookups_are_attributed_to_the_sending_process(self):
        events = report.tcpdump_events(TCPDUMP)
        kinds = [(e["kind"], e["process"], e.get("remote"), e.get("port")) for e in events]
        self.assertIn(("syn", NAME, "::1", 443), kinds)
        self.assertIn(("syn", NAME, "104.21.1.1", 443), kinds)
        self.assertIn(("udp", NAME, "93.184.216.34", 443), kinds)
        self.assertIn(("syn", "softwareupdated", "17.253.1.1", 443), kinds)
        self.assertIn(("udp", NAME, "104.21.1.1", 443), kinds)  # an inbound QUIC reply names its sender
        self.assertNotIn("192.168.64.43", {k[2] for k in kinds})
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

    def test_a_packet_sent_for_another_process_names_both_and_answers_join_their_query(self):
        events = report.tcpdump_events(UPDATE_TCPDUMP)
        syn = next(e for e in events if e["kind"] == "syn" and e["remote"] == "17.253.61.136")
        self.assertEqual((syn["sender"], syn["process"], syn["port"], syn["transport"]),
                         ("trustd", "Autoupdate", 443, "tcp"))
        app = next(e for e in events if e["kind"] == "syn" and e["remote"] == "::1")
        self.assertEqual((app["sender"], app["process"]), (NAME, NAME))
        resolved = report.dns_resolutions(events)
        self.assertEqual(resolved["17.253.61.136"], [("ocsp2.g.aaplimg.com", "1799999981.630000")])
        self.assertEqual({name for name, _ in resolved["17.253.61.154"]},
                         {"token.safebrowsing.apple", "ocsp2.g.aaplimg.com"})
        # An authoritative answer (`25043*`) still carries the query's ID.
        answer = next(e for e in events if e["kind"] == "dns-answer" and e["process"] == NAME)
        self.assertEqual(answer["txid"], "25043")
        self.assertEqual(answer["client"], "127.0.0.1:63636")


TCCD = """#timezone=UTC
2026-11-23 01:57:50.300 Df tccd[164:1] [com.apple.TCC:access] AUTHREQ_CTX: msgID=7.1, function=<private>, service=kTCCServiceAccessibility, preflight=yes, query=1, client_dict=(null)
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
        self.assertEqual([r["msgID"] for r in requests if report.tcc_prompted(r)], ["8.1"])
        self.assertAlmostEqual(requests[0]["time"], 1795399070.3, places=1)

    def test_times_need_the_utc_marker_and_an_unanswered_request_is_a_prompt(self):
        unzoned = report.tcc_requests(TCCD.split("\n", 1)[1], BUNDLE)
        self.assertEqual({r["time"] for r in unzoned}, {None})
        self.assertTrue(report.tcc_prompted({"preflight": False, "answered": False}))
        self.assertFalse(report.tcc_prompted({"preflight": True, "answered": False}))
        self.assertFalse(report.tcc_prompted({"preflight": False, "answered": True, "authReason": "4"}))
        self.assertTrue(report.tcc_prompted({"preflight": True, "answered": True, "authReason": "9"}))

    def test_tcpdump_drops_come_from_its_closing_statistics(self):
        self.assertEqual(report.tcpdump_dropped("3017 packets captured\n2552004 packets received by filter\n"
                                                "14655 packets dropped by kernel\n"), 14655)
        self.assertEqual(report.tcpdump_dropped("listening on pktap,all\n"), None)


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


class RunShTests(unittest.TestCase):
    def test_the_suite_loop_runs_this_file(self):
        text = (SCRIPTS / "tests" / "run.sh").read_text(encoding="utf-8")
        loop = next(line for line in text.splitlines() if line.startswith("for suite in"))
        self.assertIn("test_upgrade_report", loop)


if __name__ == "__main__":
    unittest.main(verbosity=1)
