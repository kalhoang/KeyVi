# SPDX-License-Identifier: GPL-3.0-or-later
"""Host side of scripts/vm/upgrade-test.sh: artefact checks, the local feed, and the verdict.

The release candidate checks of docs/runbooks/release.md section 5 items 2 and 3 (QA-R40, PLT-R1108,
spec/02-platform.md 13.5) and the network egress test of spec/02-platform.md 13.7. Nothing here starts a VM or an
app: upgrade-test.sh runs the guest half (scripts/vm/guest/upgrade-guest.sh) and calls this file before and after.

  artefacts  checks the previous stable and the candidate in their dist folders (SHA-256 against SHA256SUMS, version
             and build against build-info.json, the same SUPublicEDKey) and finds the candidate's EdDSA signature: the
             item of the published appcast with the same build, length and bytes (verified with openssl against the
             previous app's SUPublicEDKey), or --signature from Sparkle's sign_update. Exit 0 ready, 6 no signature
             (an unpublished candidate: sign with --sign), 1 a problem with the artefacts.
  feed       writes the run's feed folder: appcast-upgrade.xml (candidate and previous stable), appcast-channel.xml
             (plus a beta-only probe item that is offered but never installed), the update archive and the
             candidate's release-notes page when the repository has it.
  analyse    reads the guest's evidence and writes result.json and summary.txt. Every difference in the settings
             files must be one a migration of the candidate explains (MIGRATION_RULES), otherwise the check fails.

Usage: python3 -I scripts/vm/upgrade-report.py artefacts|feed|analyse --help
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

sys.dont_write_bytecode = True  # the sibling modules below are loaded from scripts/vm; leave no __pycache__ there
sys.path.insert(0, str(Path(__file__).resolve().parent))  # python3 -I leaves the script's folder out of sys.path

from upgrade_evidence import (  # noqa: E402
    CANDIDATE_ONLY_FIELDS, compare_defaults, compare_settings, content_equal, diagnostics_events, egress_phase,
    endpoint_text, is_loopback, key_values, load_json, load_plist, runtime_changes, seeded_survived, tcc_prompted,
    tcc_requests,
)
from upgrade_feed import ArtefactError, check_artefacts, write_feed  # noqa: E402

TAP_LIMIT_SECONDS = 2.0  # spec/02-platform.md 13.5, release.md section 5 item 2
TYPING_LIMIT_SECONDS = 5.0  # QA-R40
MIN_MACROS = 50  # QA-R40
MIN_SETTINGS = 10  # QA-R40: at least 10 settings besides the update switches
UPDATE_SETTINGS = {"automaticallyCheckForUpdates", "automaticallyInstallUpdates", "updateChannel"}
EGRESS_MINUTES_REQUIRED = 10  # spec/02-platform.md 13.7: 10 minutes per phase
PERMISSION_WINDOW_SECONDS = 20  # the candidate's first launch: its permission checks run within the first seconds


def is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def fold(text: str) -> str:
    """Text compared as the driver compares titles: without case, with the typographic apostrophe folded."""
    return text.replace("\u2019", "'").replace("\u2026", "...").strip().lower()


# --- Checks --------------------------------------------------------------------------------------------------------

def check(identifier: str, requirement: str, passed, evidence: str, files: list) -> dict:
    result = "not-run" if passed is None else ("pass" if passed else "fail")
    return {"id": identifier, "requirement": requirement, "result": result, "evidence": evidence, "files": files}


class Run:
    """The pulled guest output (upgrade-out) and the host's artefacts.json."""

    def __init__(self, folder: Path, artefacts: dict, brand: dict):
        self.folder = folder
        self.out = folder / "upgrade-out"
        self.artefacts = artefacts
        self.brand = brand
        self.prev = artefacts["previous"]
        self.cand = artefacts["candidate"]

    def text(self, relative: str) -> str:
        path = self.out / relative
        return path.read_text(encoding="utf-8", errors="replace") if path.is_file() else ""

    def json(self, relative: str, default=None):
        return load_json(self.out / relative, default)

    def steps(self) -> list:
        return [line.split("\t") for line in self.text("steps.tsv").splitlines() if line]

    def step_ok(self, prefix: str) -> bool:
        return any(len(s) >= 3 and s[1] == "ok" and s[2].startswith(prefix) for s in self.steps())

    def events(self) -> list:
        return diagnostics_events(self.text("logs/app-diagnostics.jsonl"))

    def requests(self) -> list:
        return [json.loads(line) for line in self.text("feed-requests.jsonl").splitlines() if line.strip()]


def archive_downloads(run: Run, since: float = 0.0, until: float = float("inf")) -> list:
    """Downloads of the candidate's update archive that the local feed served between `since` and `until`."""
    zip_name = Path(run.cand["zip"]["path"]).name
    return [r for r in run.requests() if r.get("path", "").endswith("/" + zip_name) and r.get("status") == 200
            and since <= r.get("at", 0) <= until]


def check_artefacts_result(run: Run) -> dict:
    cand, prev = run.cand, run.prev
    evidence = (f"previous {prev['version']} ({prev['build']}) DMG SHA-256 {prev['dmg']['sha256'][:16]}... = "
                f"SHA256SUMS; candidate {cand['version']} ({cand['build']}) zip SHA-256 {cand['zip']['sha256'][:16]}... "
                f"= SHA256SUMS, {cand['zip']['length']} bytes; EdDSA signature from the {cand['signatureSource']} "
                f"verified with the previous app's SUPublicEDKey ({cand['signatureCheck']})")
    return check("artefacts", "release.md 5.2 on the notarized artefacts; PLT-R1102", True, evidence,
                 ["artefacts.json"])


def check_previous(run: Run) -> dict:
    before = key_values(run.text("evidence/app-before.txt"))
    typing = run.json("evidence/typing-before.json", {}) or {}
    ok = before.get("version") == run.prev["version"] and before.get("build") == str(run.prev["build"]) \
        and "accepted" in before.get("spctl", "") and typing.get("matched") is True
    evidence = (f"installed from the DMG: {before.get('version')} ({before.get('build')}), spctl: "
                f"{before.get('spctl', '').strip()[:80]}; typing in TestHost before the update matched: "
                f"{typing.get('matched')}")
    return check("previous-stable", "QA-R40 step 1: install the previous stable from its DMG, grant, launch",
                 ok if before else None, evidence, ["upgrade-out/evidence/app-before.txt",
                                                     "upgrade-out/evidence/typing-before.json"])


def check_seeded(run: Run) -> dict:
    seeded = run.json("dumps/seeded.previous.json")
    if not seeded:
        return check("seeded", "QA-R40 step 2", None, "no dump of the seeded settings", [])
    explicit = list(seeded.get("explicitSettings", []))
    settings = [k for k in explicit if k not in UPDATE_SETTINGS and k not in (
        "keepAsTyped", "keepVietnamese", "learnedWords", "optedInRules")]
    apps = seeded.get("appModes", {}).get("apps", [])
    rules = [a for a in apps if a.get("rule")]
    remembered = [a for a in apps if a.get("mode") and not a.get("rule")]
    macros = seeded.get("macros", [])
    collision = seeded.get("collisionMemory", [])
    ok = len(settings) >= MIN_SETTINGS and len(macros) >= MIN_MACROS and rules and remembered \
        and seeded.get("ruleOverrides") and collision
    evidence = (f"through the SettingsStore of {run.prev['version']}: {len(settings)} settings besides the update "
                f"switches ({', '.join(settings)}), update switches {sorted(set(explicit) & UPDATE_SETTINGS)}, "
                f"{len(rules)} per-app rules, {len(remembered)} remembered per-app modes, "
                f"{len(seeded.get('ruleOverrides', []))} compatibility overrides, {len(macros)} macros, word lists, "
                f"{len(seeded.get('user', {}).get('learnedWords', []))} per-app learned words and {len(collision)} "
                f"learned collision choices (collision-memory.json)")
    return check("seeded", "QA-R40 step 2: at least 10 settings, per-app rules and memory, 50 macros", bool(ok),
                 evidence, ["upgrade-out/seed.json", "upgrade-out/dumps/seeded.previous.json",
                            "upgrade-out/snapshots/seeded/"])


def check_update(run: Run) -> dict:
    found = run.json("evidence/update-offer-find.json", {}) or {}
    ready = run.json("evidence/update-ready-find.json", {}) or {}
    pressed = run.json("evidence/update-install-press.json", {}) or {}
    relaunch = run.json("relaunch.json", {}) or {}
    # The press is shown by the button the driver located in the ready window (its label, or the window it dumped,
    # when the app ended before the label could be read) and by the relaunch that followed.
    ready_titles = {b.get("title") for b in (pressed.get("window") or {}).get("buttons", [])}
    pressed_label = pressed.get("pressed") or pressed.get("found") or (
        ready.get("found") if ready.get("found") in ready_titles and relaunch.get("newPid") else "")
    zip_name = Path(run.cand["zip"]["path"]).name
    downloads = archive_downloads(run)
    appcasts = [r for r in run.requests() if r.get("path", "").startswith("/appcast.xml")]
    texts = " ".join((found.get("window") or {}).get("texts", []))
    ok = bool(found.get("found")) and bool(ready.get("found")) and bool(pressed_label) and bool(downloads) \
        and run.cand["version"] in texts
    evidence = (f"forced check from the status menu; Sparkle offered '{texts[:160]}'; pressed "
                f"'{found.get('found')}', then '{pressed_label}' (the app relaunched as {relaunch.get('newPid')}); the "
                f"local feed served "
                f"{len(appcasts)} appcast request(s) and {zip_name} {len(downloads)} time(s) "
                f"({downloads[0].get('size') if downloads else 0} bytes, user agent "
                f"'{downloads[0].get('userAgent', '') if downloads else ''}')")
    ran = (run.out / "evidence" / "update-offer-menu.json").is_file()
    return check("sparkle-update", "QA-R40 step 3: update through Sparkle from a local appcast", ok if ran else None,
                 evidence,
                 ["upgrade-out/evidence/update-offer-window.json", "upgrade-out/evidence/update-ready-window.json",
                  "upgrade-out/feed-requests.jsonl", "upgrade-out/evidence/update-offer.png"])


def check_version(run: Run) -> dict:
    after = key_values(run.text("evidence/app-after.txt"))
    before = key_values(run.text("evidence/app-before.txt"))
    relaunch = run.json("relaunch.json", {}) or {}
    started = relaunch.get("newStartedAt") or 0
    launched = [e for e in run.events() if e.get("code") == "lifecycle.launched" and e["epoch"] >= int(started) - 1]
    first = launched[0]["fields"] if launched else {}
    ok = after.get("version") == run.cand["version"] and after.get("build") == str(run.cand["build"]) \
        and first.get("version") == run.cand["version"] and first.get("build") == str(run.cand["build"]) \
        and after.get("designated") == before.get("designated") and bool(after.get("designated"))
    evidence = (f"/Applications app {after.get('version')} ({after.get('build')}); relaunched process "
                f"{relaunch.get('newPid')} logged lifecycle.launched {first.get('version')} ({first.get('build')}); "
                f"designated requirement unchanged: {after.get('designated') == before.get('designated')}")
    return check("version-after", "QA-R40 step 4: the version is the candidate", ok if after else None, evidence,
                 ["upgrade-out/evidence/app-after.txt", "upgrade-out/relaunch.json"])


def check_files(run: Run) -> tuple:
    exit_snapshot = run.out / "snapshots" / "at-exit"
    loaded, after = run.out / "snapshots" / "loaded", run.out / "snapshots" / "after"
    if not exit_snapshot.is_dir() or not after.is_dir():
        return check("settings-files", "QA-R40 step 4; PLT-R1108", None, "snapshots missing", []), {}
    first = loaded if loaded.is_dir() else after
    result = compare_settings(exit_snapshot, first, run.prev["version"], run.cand["version"])
    runtime = runtime_changes(loaded, after) if loaded.is_dir() else {"notes": [], "unexplained": []}
    relaunch = run.json("relaunch.json", {}) or {}
    # The exit snapshot is the old version's only if no file in it was written after the new process started (the
    # copy may end a few ms after Autoupdate relaunched the app; the new version loads its settings later).
    started = relaunch.get("newStartedAt") or 0
    modified = relaunch.get("snapshotModified") or {}
    late_files = sorted(name for name, at in modified.items() if started and at >= started)
    early = bool(late_files) if modified else relaunch.get("newProcessBeforeSnapshot") is True
    summary = ", ".join(f"{f['file']} {f['status']}" for f in result["files"])
    loaded_at = relaunch.get("loadedSnapshotAt")
    evidence = (f"exit snapshot ({relaunch.get('snapshotAt', 0) - relaunch.get('oldExitedAt', 0):.3f} s after "
                f"{run.prev['version']} exited; files written after the candidate started: {late_files or 'none'}) "
                f"against the snapshot "
                f"after the candidate loaded the folder ("
                f"{'%.2f s after its start' % (loaded_at - relaunch.get('newStartedAt', 0)) if loaded_at else 'settled'}"
                f"): {summary}")
    if runtime["notes"]:
        evidence += "; " + "; ".join(runtime["notes"])
    problems = result["unexplained"] + runtime["unexplained"]
    if problems:
        evidence += "; NOT explained by a migration: " + "; ".join(problems)
    ok = not problems and not early
    result["runtime"] = runtime
    return check("settings-files", "QA-R40 step 4, release.md 5.2: files byte-identical apart from migrations",
                 ok, evidence, ["upgrade-out/snapshots/at-exit/", "upgrade-out/snapshots/loaded/",
                                "upgrade-out/snapshots/after/"]), result


def check_content(run: Run) -> dict:
    at_exit = run.json("dumps/at-exit.previous.json")
    loaded = run.json("dumps/loaded.candidate.json") or run.json("dumps/after.candidate.json")
    after = run.json("dumps/after.candidate.json")
    seeded = run.json("dumps/seeded.previous.json")
    if not at_exit or not after or not seeded or not loaded:
        return check("settings-content", "QA-R40 step 4", None, "store dumps missing", [])
    problems = content_equal(at_exit, loaded, CANDIDATE_ONLY_FIELDS)
    session = content_equal(dict(loaded, appModes=None), dict(after, appModes=None), {})
    lost = seeded_survived(seeded, after) + seeded_survived(
        {"appModes": at_exit.get("appModes", {})}, {"appModes": after.get("appModes", {})})
    ok = not problems and not lost and not session
    evidence = (f"read by the {run.prev['version']} store at exit and the {run.cand['version']} store (built from "
                f"the candidate's commit {str(run.cand.get('commit', ''))[:12]}) after loading: "
                f"{len(loaded.get('user', {}))} user fields, {len(loaded.get('appModes', {}).get('apps', []))} per-app "
                f"entries, {len(loaded.get('ruleOverrides', []))} overrides, {len(loaded.get('macros', []))} macros, "
                f"{len(loaded.get('collisionMemory', []))} learned collision choices; "
                f"differences: {problems or 'none'}; changes later in the new session (per-app order aside): "
                f"{session or 'none'}; seeded or exit values missing 15 s after the update: {lost or 'none'}")
    return check("settings-content", "QA-R40 step 4: settings, rules, per-app memory and macros identical", ok,
                 evidence, ["upgrade-out/dumps/"])


def check_defaults(run: Run) -> dict:
    # The baseline is the export taken while the previous version ran, before the update check: the export at its
    # exit runs after the copy of the settings folder, once the candidate may have started (relaunch.json defaultsAt
    # against newStartedAt), so it is evidence only.
    before = load_plist(run.out / "snapshots" / "defaults-before.plist")
    after = load_plist(run.out / "snapshots" / "defaults-after.plist")
    if not before or not after:
        return check("defaults-domain", "PLT-R1108", None, "defaults exports missing (before or after the update)", [])
    result = compare_defaults(before, after)
    relaunch = run.json("relaunch.json", {}) or {}
    exported, started = relaunch.get("defaultsAt"), relaunch.get("newStartedAt")
    exit_note = (f"; the export at the old version's exit ran {exported - started:+.3f} s from the candidate's start "
                 f"(not the baseline)" if is_number(exported) and is_number(started) else "")
    explained = [f"{c['key']} {c['before']} -> {c['after']} ({c['explainedBy']})" for c in result["changes"]
                 if c["explainedBy"]]
    unexplained = [f"{c['key']} {c['before']} -> {c['after']}" for c in result["changes"] if not c["explainedBy"]]
    evidence = (f"export while {run.prev['version']} ran (before the update check) against the export 15 s after the "
                f"relaunch: {result['keys']} keys; written by design: {'; '.join(explained) or 'none'}; NOT explained: "
                f"{'; '.join(unexplained) or 'none'}{exit_note}")
    return check("defaults-domain", "PLT-R1108: the app's defaults domain survives the update",
                 not result["unexplained"], evidence, ["upgrade-out/snapshots/defaults-before.plist",
                                                       "upgrade-out/snapshots/defaults-after.plist",
                                                       "upgrade-out/snapshots/defaults-at-exit.plist"])


def permission_evidence(run: Run, started: float) -> dict:
    """What the candidate's first launch showed or asked: TCC requests and prompts, prompt processes, its windows.
    `missing` names the evidence that could not be read: without it "no prompt" cannot be shown."""
    window = (int(started) - 1, started + PERMISSION_WINDOW_SECONDS)
    requests = [r for r in tcc_requests(run.text("logs/tccd.log"), run.brand["APP_BUNDLE_ID_RELEASE"])
                if is_number(r.get("time")) and window[0] <= r["time"] <= window[1]]
    listing = run.text("evidence/prompt-processes.txt")
    windows = run.json("evidence/app-windows-after.json")
    missing = []
    if not re.search(r"^#exit=[01]$", listing, re.M):  # pgrep: 0 found, 1 none; anything else is an error
        missing.append("the prompt process list (evidence/prompt-processes.txt)")
    if not isinstance(windows, list):
        missing.append("the app's windows after the relaunch (evidence/app-windows-after.json)")
    if not requests:
        missing.append(f"a TCC request of the candidate in its first {PERMISSION_WINDOW_SECONDS} s (logs/tccd.log "
                       f"with the UTC marker; the app checks its permissions at launch)")
    return {"requests": requests, "prompts": [r for r in requests if tcc_prompted(r)],
            "processes": [line for line in listing.splitlines() if "universalAccessAuthWarn" in line],
            "windows": windows if isinstance(windows, list) else [], "missing": missing}


def check_permissions(run: Run) -> dict:
    # The rows as the previous version used them (after its own launch), against the rows after the update.
    granted = (run.text("snapshots/tcc-before.txt") or run.text("snapshots/tcc-granted.txt")).strip()
    after = run.text("snapshots/tcc-after.txt").strip()
    rows = [r.split("|") for r in after.splitlines() if r]
    relaunch = run.json("relaunch.json", {}) or {}
    started = relaunch.get("newStartedAt") or 0
    # The first launch of the candidate only: later relaunches (channel switch, egress) are not the update.
    events = [e for e in run.events() if int(started) - 1 <= e["epoch"] <= started + PERMISSION_WINDOW_SECONDS]
    states = [e.get("fields", {}).get("to", "") for e in events if e.get("code") == "host.state"]
    transitions = [e for e in events if e.get("code") == "health.permissionTransition"]
    seen = permission_evidence(run, started)
    asked = sorted({f"{r['service'].replace('kTCCService', '')}={r.get('authValue', '-')}/{r.get('authReason', '-')}"
                    f"{'' if r.get('answered') else ' (no answer)'}" for r in seen["requests"]})
    intact = bool(granted) and granted == after and bool(rows) and all(r[3] == "2" for r in rows if len(r) > 3)
    quiet = any(s.startswith("ready") for s in states) and "noPermission" not in states and not transitions \
        and not seen["prompts"] and not seen["processes"] and not seen["windows"]
    passed = False if not (intact and quiet) else (None if seen["missing"] else True)
    evidence = (f"TCC rows for the bundle before and after identical: {granted == after} "
                f"({len(rows)} rows, auth_value {sorted({r[3] for r in rows if len(r) > 3})}); host states after "
                f"the relaunch {states}; permission transitions {len(transitions)}; prompt processes "
                f"{seen['processes'] or 'none'}; TCC requests of the candidate in its first "
                f"{PERMISSION_WINDOW_SECONDS} s (service=authValue/authReason) {asked}, prompted (consent answer, "
                f"timeout or no answer) "
                f"{len(seen['prompts'])}; app windows after the relaunch {len(seen['windows'])} (the self-check shows "
                f"the permission screen when a grant is lost, QA-R42)"
                f"{'; evidence missing: ' + '; '.join(seen['missing']) if seen['missing'] else ''}")
    return check("permissions", "QA-R40 step 4: permissions still granted, no new prompt (PRD-R52)",
                 passed if after else None, evidence,
                 ["upgrade-out/snapshots/tcc-before.txt", "upgrade-out/snapshots/tcc-after.txt",
                  "upgrade-out/logs/tccd.log", "upgrade-out/evidence/prompt-processes.txt",
                  "upgrade-out/evidence/app-windows-after.json", "upgrade-out/evidence/after-relaunch.png"])


def check_tap(run: Run) -> dict:
    relaunch = run.json("relaunch.json", {}) or {}
    latency = relaunch.get("tapLatencySeconds")
    ok = isinstance(latency, (int, float)) and latency <= TAP_LIMIT_SECONDS
    evidence = (f"new process {relaunch.get('newPid')} started {relaunch.get('newStartedAt')}; its event tap was "
                f"enabled after {latency if latency is None else round(latency, 3)} s (CGGetEventTapList, polled every "
                f"10 ms; limit {TAP_LIMIT_SECONDS} s); taps {relaunch.get('taps')}")
    return check("tap-within-2s", "spec/02-platform.md 13.5, release.md 5.2: tap active within 2 s of relaunch",
                 ok if relaunch else None, evidence, ["upgrade-out/relaunch.json"])


def typed_after_tap(attempt: dict, tap_at) -> bool:
    """Every key of the attempt was posted once the candidate's tap was enabled: a key posted earlier passes through
    unchanged, and d, u and y of the word read the same with or without the app."""
    keys_at = attempt.get("keysStartedAt")
    return is_number(tap_at) and is_number(keys_at) and keys_at > 0 and keys_at >= tap_at


def check_typing(run: Run) -> dict:
    relaunch = run.json("relaunch.json", {}) or {}
    base = relaunch.get("newStartedAt") or 0
    tap_at = relaunch.get("tapEnabledAt")
    attempts = relaunch.get("attempts") or []
    counted = next((a for a in attempts if a.get("matched") and typed_after_tap(a, tap_at)), None)
    latency = counted["keysStartedAt"] - base if counted else None
    verified = counted["endedAt"] - base if counted and is_number(counted.get("endedAt")) else None
    ok = latency is not None and latency <= TYPING_LIMIT_SECONDS
    tried = "; ".join(
        (f"keys typed {a['keysStartedAt'] - base:.2f} to {a['keysEndedAt'] - base:.2f} s"
         f"{'' if typed_after_tap(a, tap_at) else ' (before the tap: not counted)'}, " if a.get("keysStartedAt")
         else "") + f"read {a.get('value')!r} at {a.get('endedAt', base) - base:.2f} s" for a in attempts)
    tap_text = f"{tap_at - base:.3f} s" if is_number(tap_at) else "never"
    evidence = (f"TestHost field (keys of testhost.native.telex, expected 'duyệt'): {tried or 'nothing'}; the "
                f"candidate's tap was enabled at {tap_text}; typing worked from "
                f"{'never' if latency is None else '%.3f s' % latency} after the new process started (the first key of "
                f"the first attempt typed wholly after the tap that read back right; limit {TYPING_LIMIT_SECONDS} s"
                f"{'; read back at %.3f s' % verified if verified is not None else ''}), no click or prompt in between")
    return check("typing-within-5s", "QA-R40 step 4: typing works in the test host within 5 s, no user action",
                 ok if relaunch else None, evidence, ["upgrade-out/relaunch.json"])


def in_step(event: dict, start: str, end: str) -> bool:
    """The event was logged during a step that ran from `start` to `end` (epoch seconds; the log has whole seconds)."""
    return start.isdigit() and end.isdigit() and int(start) - 1 <= event["epoch"] <= int(end) + 1


def check_channel(run: Run, probe: dict) -> dict:
    rows = [line.split("\t") for line in run.text("channel.tsv").splitlines() if line]
    if not rows:
        return check("channel-switch", "release.md 5.3: beta to stable and back", None, "not run", [])
    install = {"Install Update"} | {t for t in run.text("titles-install.txt").splitlines() if t}
    up_to_date = [fold(t) for t in run.text("titles-uptodate.txt").splitlines() if t.strip()]
    found_events = [e for e in run.events() if e.get("code") == "update.updateFound"]
    outcome, ok, untimed = [], len(rows) == 3, False
    for index, channel, found, start, end in [(r + [""] * 5)[:5] for r in rows]:
        # Without its start and end a step cannot show what was (not) found in it: not evidence either way.
        timed = start.isdigit() and end.isdigit()
        untimed = untimed or not timed
        window = run.json(f"evidence/channel-{index}-{channel}-window.json", {}) or {}
        texts = " ".join(window.get("texts", []))
        offered = found in install
        logged = [e for e in found_events if in_step(e, start, end)]
        probe_logged = [e for e in logged if e.get("fields", {}).get("build") == str(probe["build"])]
        if channel == "beta":
            good = offered and probe["version"] in texts and bool(probe_logged)
            seen = f"probe {probe['version']} offered" if offered else f"'{found}' (no offer)"
        else:
            told = [t for t in up_to_date if t in fold(texts)]
            good = not offered and not logged and bool(told)
            seen = f"up to date ({told[0]!r})" if told else f"'{found}' with {texts[:120]!r}"
        outcome.append(f"{channel}: {seen}, update.updateFound in this step {len(logged)} "
                       f"(probe build {len(probe_logged)})"
                       f"{'' if timed else ' (no step times)'}{'' if good or not timed else ' (WRONG)'}")
        ok = ok and (good or not timed)
    evidence = (f"feed with the candidate, the previous stable and a beta-only probe build {probe['build']}; "
                f"{'; '.join(outcome)}; on stable Sparkle must say it is up to date (its own localized text, "
                f"titles-uptodate.txt), which also shows that nothing older was offered")
    result = None if ok and untimed else ok
    return check("channel-switch", "release.md 5.3: beta to stable and back (PLT-R1101, PRD-R53)", result, evidence,
                 ["upgrade-out/channel.tsv", "upgrade-out/evidence/"])


def egress_gaps(run: Run, phase: str, report: dict, minutes: int, duration: int) -> list:
    """What the phase did not cover, each a reason it cannot pass (13.7 asks for 10 minutes with a forced check, and
    the capture must have seen every packet)."""
    gaps = []
    if minutes < EGRESS_MINUTES_REQUIRED:
        gaps.append(f"shortened to {minutes} min with --egress-minutes (13.7: {EGRESS_MINUTES_REQUIRED} min)")
    if duration < minutes * 60 - 5:
        gaps.append(f"ran {duration} s of {minutes * 60}")
    if not (run.json(f"evidence/egress-{phase}-menu.json", {}) or {}).get("pressed"):
        gaps.append("no forced check from the menu")
    return gaps + capture_gaps(report)


def capture_gaps(report: dict) -> list:
    """The capture saw every packet only if tcpdump printed its statistics and the kernel dropped nothing."""
    dropped = report["tcpdumpDropped"]
    if dropped is None:
        return ["tcpdump printed no capture statistics"]
    if dropped:
        return [f"tcpdump: {dropped} packets dropped by the kernel (a connection attempt may be missing)"]
    return []


def endpoints_text(connections: list) -> str:
    """Each endpoint with its process (`trustd for Autoupdate` when one process sent for another), the name its
    address was resolved from, and NOT ALLOWED when it is not."""
    return ", ".join(
        f"{c['process'] if c.get('sender', c['process']) == c['process'] else c['sender'] + ' for ' + c['process']} "
        f"{endpoint_text(c['remote'], c['port'])}/{c['transport']}{' (' + c['name'] + ')' if c['name'] else ''}"
        f"{'' if c['allowed'] else ' NOT ALLOWED'}" for c in connections)


def check_egress(run: Run, phase: str, minutes: int) -> tuple:
    hosts = [run.brand["APP_SITE_HOST"]]
    report = egress_phase(run.out, phase, run.brand["APP_DISPLAY_NAME"], hosts)
    report["allowedHosts"] = report["allowedHosts"] if phase == "local" else hosts
    menu = run.json(f"evidence/egress-{phase}-menu.json", {}) or {}
    found = (run.json(f"evidence/egress-{phase}-find.json", {}) or {}).get("found")
    started, ended = report["started"], report["ended"]
    duration = int(ended) - int(started) if started.isdigit() and ended.isdigit() else 0
    gaps = egress_gaps(run, phase, report, minutes, duration)
    if phase == "local":
        appcasts = [r for r in run.requests() if r.get("path", "").startswith("/appcast.xml") and duration
                    and int(started) <= r.get("at", 0) <= int(ended)]
        reached = f"{len(appcasts)} appcast request(s) of the app reached the local feed during the phase"
        if not appcasts:
            gaps.append("no appcast request reached the local feed during the phase")
    else:
        seen = [c for c in report["connections"] if c["allowed"] and c["process"] == run.brand["APP_DISPLAY_NAME"]
                and not is_loopback(c["remote"])]
        reached = f"{len(seen)} connection(s) of the app to the site host"
        if not seen:
            gaps.append("no connection of the app to the site host")
    bad_lookups = report["disallowedLookups"]
    violated = bool(report["disallowed"] or bad_lookups)
    endpoints = endpoints_text(report["connections"])
    evidence = (f"{duration} s; forced check {menu.get('pressed')!r}, Sparkle's window: "
                f"{repr(found) if found else 'none found within 120 s'}; {reached}; {report['tcpdumpLines']} tcpdump "
                f"lines ({report['tcpdumpDropped']} packets dropped by the kernel), {report['lsofSamples']} lsof "
                f"samples, {report['nettopLines']} nettop lines; allowed: {', '.join(report['allowedHosts'])} "
                f"{report['allowedAddresses'] if phase == 'production' else ''}; endpoints: {endpoints or 'none'}; DNS "
                f"lookups by the app: {report['lookups'] or 'none'}"
                f"{'; NOT ALLOWED lookups: ' + ', '.join(bad_lookups) if bad_lookups else ''}"
                f"{'; not covered: ' + '; '.join(gaps) if gaps else ''}")
    name = "egress-local" if phase == "local" else "egress-production"
    requirement = ("spec/02-platform.md 13.7 phase 1: local appcast, forced check, only allowed hosts" if phase == "local"
                   else "spec/02-platform.md 13.7 phase 2: production feed, only the site host (PLT-R906)")
    passed = None if not started else (False if violated else (None if gaps else True))
    return check(name, requirement, passed, evidence,
                 [f"upgrade-out/egress/{phase}-tcpdump.txt", f"upgrade-out/egress/{phase}-tcpdump.err",
                  f"upgrade-out/egress/{phase}-nettop.csv", f"upgrade-out/egress/{phase}-lsof.txt",
                  f"upgrade-out/egress/{phase}-dns.txt"]), report


def update_downloads(run: Run, report: dict) -> list:
    """The candidate's archive served while the install was captured (no end in runs before the guest wrote
    update-ended: the capture lasted until the end of the update step)."""
    started, ended = report["started"], report["ended"]
    if not started.isdigit():
        return []
    return archive_downloads(run, int(started), int(ended) if ended.isdigit() else float("inf"))


def update_gaps(run: Run, report: dict, downloads: list) -> list:
    """What the capture of the install did not cover, each a reason the check cannot pass: the capture itself, its
    start, every packet, and the download of the update it should contain."""
    gaps = [] if report["tcpdumpCaptured"] else ["no capture of the install (egress/update-tcpdump.txt)"]
    started = report["started"]
    if not started.isdigit():
        gaps.append("no start time of the capture (egress/update-started)")
    gaps += capture_gaps(report)
    if started.isdigit() and not downloads:
        gaps.append("no download of the candidate's archive while the capture ran (feed-requests.jsonl)")
    app = run.brand["APP_DISPLAY_NAME"]
    if not any(c["process"] == app and is_loopback(c["remote"]) and "tcpdump" in c["seenBy"]
               for c in report["connections"]):
        gaps.append("no connection of the app to the local feed in the capture")
    return gaps


def check_update_egress(run: Run) -> tuple:
    """13.7 and PLT-R906 during the install (amended on 2026-11-23, docs/decisions/0011-pa-decisions-2026-11-23.md):
    the download, the signature checks and the install reach only the local feed, the site host, and the system's
    revocation check of the update's signature (upgrade_evidence.REVOCATION_*). A disallowed endpoint or lookup fails
    whatever else is missing; a capture that may have missed a packet, or that is missing, is not evidence of none."""
    report = egress_phase(run.out, "update", run.brand["APP_DISPLAY_NAME"], [run.brand["APP_SITE_HOST"]],
                          revocation=True)
    downloads = update_downloads(run, report)
    gaps = update_gaps(run, report, downloads)
    started, ended = report["started"], report["ended"]
    window = (f"from {started} to {ended} ({int(ended) - int(started)} s)" if started.isdigit() and ended.isdigit()
              else f"from {started or 'an unknown time'} to the end of the update step")
    bad_lookups = report["disallowedLookupsBy"]
    violated = bool(report["disallowed"] or bad_lookups)
    evidence = (f"capture of the install {window}: {report['tcpdumpLines']} tcpdump lines "
                f"({report['tcpdumpDropped']} packets dropped by the kernel); the local feed served the candidate's "
                f"archive {len(downloads)} time(s) during the capture; allowed: {'; '.join(report['allowedHosts'])}"
                f"{' ' + str(report['allowedAddresses']) if report['allowedAddresses'] else ''}; revocation checks: "
                f"{endpoints_text(report['revocationChecks']) or 'none'}; endpoints: "
                f"{endpoints_text(report['connections']) or 'none'}; DNS lookups by the app and its helpers: "
                f"{', '.join(report['lookupsBy']) or 'none'}"
                f"{'; NOT ALLOWED lookups: ' + ', '.join(bad_lookups) if bad_lookups else ''}"
                f"{'; not covered: ' + '; '.join(gaps) if gaps else ''}")
    passed = False if violated else (None if gaps else True)
    item = check("egress-update", "spec/02-platform.md 13.7 and PLT-R906 (amended 2026-11-23): during the install "
                 "only the local feed, the site host and the system's revocation check of the update's signature",
                 passed, evidence, ["upgrade-out/egress/update-tcpdump.txt", "upgrade-out/egress/update-tcpdump.err",
                                    "upgrade-out/feed-requests.jsonl"])
    return item, report


def evaluate(run: Run, feed: dict, options: dict) -> dict:
    checks = [check_artefacts_result(run), check_previous(run), check_seeded(run), check_update(run),
              check_version(run)]
    files_check, files_detail = check_files(run)
    checks += [files_check, check_content(run), check_defaults(run), check_permissions(run), check_tap(run),
               check_typing(run)]
    update_check, update_report = check_update_egress(run)
    checks.append(update_check)
    channel = check_channel(run, feed["probe"]) if options["channel"] else check(
        "channel-switch", "release.md 5.3", None, "skipped (--no-channel)", [])
    checks.append(channel)
    egress = {"update": update_report}
    for phase in ("local", "production"):
        if options["egress"]:
            item, egress[phase] = check_egress(run, phase, options["minutes"])
        else:
            item = check(f"egress-{phase}", "spec/02-platform.md 13.7", None, "skipped (--no-egress)", [])
        checks.append(item)
    failed = [c["id"] for c in checks if c["result"] == "fail" and not c.get("advisory")]
    missing = [c["id"] for c in checks if c["result"] == "not-run" and not c.get("advisory")]
    advisories = [c["id"] for c in checks if c.get("advisory") and c["result"] == "fail"]
    if options.get("watchdogStops"):
        verdict = "ABORTED"
    elif failed:
        verdict = "FAIL"
    else:
        verdict = "INCOMPLETE" if missing else "PASS"
    return {"verdict": verdict, "failed": failed, "notRun": missing, "advisories": advisories, "checks": checks,
            "settingsFiles": files_detail, "egress": egress}


def summary_text(result: dict) -> str:
    lines = [f"RESULT: {result['verdict']}  ({result['previous']['version']} -> {result['candidate']['version']})", ""]
    for item in result["checks"]:
        tag = item["result"].upper() + ("*" if item.get("advisory") else "")
        lines.append(f"[{tag:8}] {item['id']}: {item['evidence']}")
    if any(item.get("advisory") for item in result["checks"]):
        lines.append("(* advisory: reported, not part of the verdict)")
    watchdog = result.get("watchdog", {})
    if not watchdog.get("used", True):
        lines.append("[WATCHDOG] none ran beside the VM")
    for stop in watchdog.get("stops", []):
        lines.append(f"[WATCHDOG] {stop}")
    for restart in watchdog.get("restarts", []):
        lines.append(f"[WATCHDOG] {restart}")
    if result.get("guest", {}).get("stopped"):
        lines.append(f"[GUEST] {result['guest']['stopped']}")
    return "\n".join(lines) + "\n"


def brand_values(path: Path) -> dict:
    values = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^([A-Z_]+)="(.*)"$', line.strip())
        if match:
            values[match.group(1)] = match.group(2)
    return values


# --- Command line --------------------------------------------------------------------------------------------------

def command_artefacts(args) -> int:
    try:
        result = check_artefacts(Path(args.previous), Path(args.candidate), args.slug, args.name,
                                 Path(args.appcast).read_text(encoding="utf-8"), args.openssl, args.signature or "")
    except (ArtefactError, OSError, ValueError, ET.ParseError) as error:
        Path(args.out).write_text(json.dumps({"status": "error", "error": str(error)}, indent=2) + "\n",
                                  encoding="utf-8")
        print(f"upgrade-report: artefacts: {error}", file=sys.stderr)
        return 1
    Path(args.out).write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    if result["status"] == "needs-signature":
        print("upgrade-report: the candidate is not in the published appcast: it needs an EdDSA signature "
              "(upgrade-test.sh --sign)", file=sys.stderr)
        return 6
    print(f"upgrade-report: artefacts ready, signature from the {result['candidate']['signatureSource']}",
          file=sys.stderr)
    return 0


def command_feed(args) -> int:
    artefacts = load_json(Path(args.artefacts))
    feed = write_feed(artefacts, Path(args.out), args.name, args.site_host, Path(args.release_notes))
    Path(args.plan).write_text(json.dumps(feed, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"PROBE_BUILD={feed['probe']['build']}")
    return 0


def command_analyse(args) -> int:
    run_dir = Path(args.run)
    artefacts = load_json(Path(args.artefacts))
    feed = load_json(Path(args.feed), {"probe": {"build": 0, "version": ""}})
    brand = brand_values(Path(args.brand_env))
    stops = [line for line in Path(args.watchdog_log).read_text(encoding="utf-8").splitlines() if line.strip()] \
        if args.watchdog_log and Path(args.watchdog_log).is_file() else []
    run = Run(run_dir, artefacts, brand)
    options = {"channel": not args.no_channel, "egress": not args.no_egress, "minutes": args.egress_minutes,
               "watchdogStops": stops}
    result = evaluate(run, feed, options)
    stopped = [s for s in run.steps() if len(s) >= 3 and s[1] == "fail"]
    result.update({
        "schema": 1, "tool": "scripts/vm/upgrade-test.sh", "analysedAt": dt.datetime.now(dt.timezone.utc).isoformat(),
        "previous": {k: run.prev[k] for k in ("version", "build", "commit")} | {"dmg": run.prev["dmg"]},
        "candidate": {k: run.cand[k] for k in ("version", "build", "commit")} | {
            "zip": run.cand["zip"], "signatureSource": run.cand.get("signatureSource")},
        "feed": {"method": "site host mapped to loopback in the VM's /etc/hosts; local HTTPS server with a VM-only CA",
                 "host": brand.get("APP_SITE_HOST"), **feed},
        "watchdog": {"stops": stops, "used": (run_dir / "watchdog-used.txt").is_file(),
                     "restarts": [line for line in (run_dir / "watchdog-restarts.txt").read_text(encoding="utf-8")
                                  .splitlines() if line] if (run_dir / "watchdog-restarts.txt").is_file() else []},
        "guest": {"steps": run.steps(), "stopped": " ".join(stopped[0][2:]) if stopped else ""},
    })
    if result["guest"]["stopped"] and result["verdict"] == "PASS":
        result["verdict"] = "INCOMPLETE"
    Path(args.out).write_text(json.dumps(result, indent=2, sort_keys=True, ensure_ascii=False) + "\n",
                              encoding="utf-8")
    text = summary_text(result)
    Path(args.summary).write_text(text, encoding="utf-8")
    print(text, end="")
    return {"PASS": 0, "FAIL": 1, "INCOMPLETE": 1, "ABORTED": 5}[result["verdict"]]


def main(argv: list) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = parser.add_subparsers(dest="command", required=True)
    art = sub.add_parser("artefacts")
    for name in ("previous", "candidate", "slug", "name", "appcast", "out"):
        art.add_argument(f"--{name}", required=True)
    art.add_argument("--openssl", default="openssl")
    art.add_argument("--signature", default="")
    feed = sub.add_parser("feed")
    for name in ("artefacts", "out", "name", "site-host", "release-notes", "plan"):
        feed.add_argument(f"--{name}", required=True)
    ana = sub.add_parser("analyse")
    for name in ("run", "artefacts", "feed", "brand-env", "out", "summary"):
        ana.add_argument(f"--{name}", required=True)
    ana.add_argument("--watchdog-log", default="")
    ana.add_argument("--egress-minutes", type=int, default=10)
    ana.add_argument("--no-channel", action="store_true")
    ana.add_argument("--no-egress", action="store_true")
    args = parser.parse_args(argv)
    return {"artefacts": command_artefacts, "feed": command_feed, "analyse": command_analyse}[args.command](args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
