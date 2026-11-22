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
import base64
import datetime as dt
import hashlib
import ipaddress
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
TAP_LIMIT_SECONDS = 2.0  # spec/02-platform.md 13.5, release.md section 5 item 2
TYPING_LIMIT_SECONDS = 5.0  # QA-R40
MIN_MACROS = 50  # QA-R40
MIN_SETTINGS = 10  # QA-R40: at least 10 settings besides the update switches
UPDATE_SETTINGS = {"automaticallyCheckForUpdates", "automaticallyInstallUpdates", "updateChannel"}
SETTINGS_FILES = ("settings.json", "app-modes.json", "rule-overrides.json", "macros.json", "collision-memory.json")
EGRESS_PROCESSES = ("Autoupdate", "Updater", "com.apple.WebKit.Networking")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$")

# Byte differences in a settings file after the update that a change in the candidate's code explains. Each rule
# names the code that makes the change. A difference no rule explains fails the check (PRD-R52, release.md 5.2).
MIGRATION_RULES = {
    "writtenBy": "the store stamps the version that rewrote a file into its envelope (PLT-R1002, "
                 "SettingsStore.writtenBy)",
    "englishRestoreLists.neverCorrect": "1.1.0 writes the never-correct list, empty for a 1.0.x file, whenever it "
                                        "rewrites settings.json (DocumentCodecs.swift SettingsCodec.encode, "
                                        "ENG-R1118, schema version 1 unchanged per Migrations.swift)",
}

# Keys of the app's defaults domain that change on every launch or update by design; every other key must be equal.
DEFAULTS_RULES = {
    "launchGuard.inProgressSince": "start time of the current launch (LaunchGuard.beginLaunch, PLT-R1009)",
    "launchGuard.appVersion": "version of the running build (LaunchGuard.adoptVersion, PLT-R1009)",
    "launch.lastVersionFingerprint": "version of the running build for the post-update self-check "
                                     "(UpdateSelfCheck.noteLaunch, QA-R42)",
    "SULastCheckTime": "Sparkle's time of the last update check",
    "SUHasLaunchedBefore": "Sparkle's first-launch marker",
}


class ArtefactError(Exception):
    pass


# --- Artefacts --------------------------------------------------------------------------------------------------

def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def parse_sha256sums(text: str) -> dict:
    sums = {}
    for line in text.splitlines():
        match = re.match(r"^([0-9a-f]{64})\s+\*?(\S+)$", line.strip())
        if match:
            sums[match.group(2)] = match.group(1)
    return sums


def appcast_items(xml_text: str) -> list:
    """Every item of an appcast as a dict (build, version, channel, length, url, signature, ...)."""
    root = ET.fromstring(xml_text)
    items = []
    for item in root.iter("item"):
        enclosure = item.find("enclosure")
        def text(tag: str) -> str:
            node = item.find(f"{{{SPARKLE_NS}}}{tag}")
            return (node.text or "").strip() if node is not None else ""
        items.append({
            "build": text("version"), "version": text("shortVersionString"), "channel": text("channel"),
            "minimumSystemVersion": text("minimumSystemVersion"), "releaseNotesLink": text("releaseNotesLink"),
            "url": enclosure.get("url", "") if enclosure is not None else "",
            "length": int(enclosure.get("length", "0")) if enclosure is not None else 0,
            "signature": enclosure.get(f"{{{SPARKLE_NS}}}edSignature", "") if enclosure is not None else "",
        })
    return items


def find_item(items: list, build: int, version: str):
    for item in items:
        if item["build"] == str(build) and item["version"] == version:
            return item
    return None


def ed25519_public_pem(public_key_b64: str) -> bytes:
    raw = base64.b64decode(public_key_b64, validate=True)
    if len(raw) != 32:
        raise ArtefactError("SUPublicEDKey is not a 32-byte ed25519 key")
    der = ED25519_SPKI_PREFIX + raw
    body = base64.encodebytes(der).decode("ascii").replace("\n", "")
    return f"-----BEGIN PUBLIC KEY-----\n{body}\n-----END PUBLIC KEY-----\n".encode("ascii")


def verify_ed25519(openssl: str, public_key_b64: str, signature_b64: str, path: Path) -> tuple:
    """(verified, detail) with openssl pkeyutl -rawin: the check Sparkle makes with the installed app's key."""
    with tempfile.TemporaryDirectory() as tmp:
        pub = Path(tmp) / "pub.pem"
        sig = Path(tmp) / "sig.bin"
        pub.write_bytes(ed25519_public_pem(public_key_b64))
        sig.write_bytes(base64.b64decode(signature_b64, validate=True))
        proc = subprocess.run([openssl, "pkeyutl", "-verify", "-pubin", "-inkey", str(pub), "-rawin",
                               "-in", str(path), "-sigfile", str(sig)], capture_output=True, text=True)
    detail = (proc.stdout + proc.stderr).strip().splitlines()
    return proc.returncode == 0, detail[-1] if detail else f"openssl exit {proc.returncode}"


def read_build_info(folder: Path) -> dict:
    info = json.loads((folder / "build-info.json").read_text(encoding="utf-8"))
    if not VERSION_RE.match(str(info.get("version", ""))) or not str(info.get("build", "")).isdigit():
        raise ArtefactError(f"{folder}/build-info.json has no valid version and build")
    return info


def app_info(folder: Path, name: str) -> dict:
    plist = folder / f"{name}.app" / "Contents" / "Info.plist"
    if not plist.is_file():
        raise ArtefactError(f"missing {plist}")
    with plist.open("rb") as handle:
        return plistlib.load(handle)


def checked_file(folder: Path, name: str, sums: dict) -> dict:
    path = folder / name
    if not path.is_file():
        raise ArtefactError(f"missing {path}")
    digest = sha256_file(path)
    if sums.get(name) != digest:
        raise ArtefactError(f"{name}: SHA-256 {digest} does not match SHA256SUMS ({sums.get(name, 'absent')})")
    return {"path": str(path), "sha256": digest, "length": path.stat().st_size}


def check_artefacts(previous: Path, candidate: Path, slug: str, name: str, appcast_xml: str, openssl: str,
                    signature: str = "") -> dict:
    prev_info, cand_info = read_build_info(previous), read_build_info(candidate)
    prev_sums = parse_sha256sums((previous / "SHA256SUMS").read_text(encoding="utf-8"))
    cand_sums = parse_sha256sums((candidate / "SHA256SUMS").read_text(encoding="utf-8"))
    dmg = checked_file(previous, f"{slug}-{prev_info['version']}.dmg", prev_sums)
    archive = checked_file(candidate, f"{slug}-{cand_info['version']}.zip", cand_sums)
    prev_plist, cand_plist = app_info(previous, name), app_info(candidate, name)
    for info, plist, label in ((prev_info, prev_plist, "previous"), (cand_info, cand_plist, "candidate")):
        if plist.get("CFBundleShortVersionString") != info["version"] or str(plist.get("CFBundleVersion")) != str(
                info["build"]):
            raise ArtefactError(f"the {label} app's Info.plist does not match its build-info.json")
    if int(cand_info["build"]) <= int(prev_info["build"]):
        raise ArtefactError("the candidate's build number is not higher than the previous stable's")
    trusted_key = prev_plist.get("SUPublicEDKey", "")
    if cand_plist.get("SUPublicEDKey") != trusted_key:
        raise ArtefactError("the candidate's SUPublicEDKey differs from the previous stable's (key rotation is not "
                            "covered by this test)")
    items = appcast_items(appcast_xml)
    published = find_item(items, int(cand_info["build"]), cand_info["version"])
    previous_item = find_item(items, int(prev_info["build"]), prev_info["version"])
    result = {
        "previous": {**{k: prev_info[k] for k in ("version", "build", "commit")}, "dmg": dmg,
                     "item": previous_item, "minimumSystemVersion": prev_plist.get("LSMinimumSystemVersion", "")},
        "candidate": {**{k: cand_info[k] for k in ("version", "build", "commit")}, "zip": archive,
                      "minimumSystemVersion": cand_plist.get("LSMinimumSystemVersion", "")},
        "publicKey": trusted_key,
    }
    if published and published["length"] != archive["length"]:
        raise ArtefactError(f"the published item's length {published['length']} differs from the zip's "
                            f"{archive['length']}: these are not the published bytes")
    chosen, source = (signature, "sign_update") if signature else (
        (published["signature"], "published appcast") if published else ("", ""))
    if not chosen:
        result["status"] = "needs-signature"
        return result
    verified, detail = verify_ed25519(openssl, trusted_key, chosen, Path(archive["path"]))
    if not verified:
        raise ArtefactError(f"the EdDSA signature from the {source} does not verify with SUPublicEDKey: {detail}")
    result["candidate"].update({"signature": chosen, "signatureSource": source, "signatureCheck": detail,
                                "published": published is not None})
    result["status"] = "ready"
    return result


# --- Feed ------------------------------------------------------------------------------------------------------

def item_xml(item: dict) -> str:
    lines = [
        "    <item>",
        f"      <title>{item['title']}</title>",
        f"      <sparkle:version>{item['build']}</sparkle:version>",
        f"      <sparkle:shortVersionString>{item['version']}</sparkle:shortVersionString>",
        f"      <sparkle:minimumSystemVersion>{item['minimumSystemVersion']}</sparkle:minimumSystemVersion>",
    ]
    if item.get("releaseNotesLink"):
        lines.append(f"      <sparkle:releaseNotesLink>{item['releaseNotesLink']}</sparkle:releaseNotesLink>")
    if item.get("channel"):
        lines.append(f"      <sparkle:channel>{item['channel']}</sparkle:channel>")
    lines.append(f'      <enclosure url="{item["url"]}" length="{item["length"]}" type="application/octet-stream" '
                 f'sparkle:edSignature="{item["signature"]}" />')
    lines.append("    </item>")
    return "\n".join(lines)


def appcast_xml(title: str, host: str, items: list) -> str:
    body = "\n".join(item_xml(item) for item in items)
    return ('<?xml version="1.0" encoding="utf-8"?>\n'
            f'<rss xmlns:sparkle="{SPARKLE_NS}" version="2.0">\n  <channel>\n'
            f"    <title>{title}</title>\n    <link>https://{host}/appcast.xml</link>\n"
            "    <description>Local feed of scripts/vm/upgrade-test.sh</description>\n"
            f"{body}\n  </channel>\n</rss>\n")


def feed_items(artefacts: dict, name: str, host: str, notes_available: bool) -> dict:
    cand = artefacts["candidate"]
    zip_name = Path(cand["zip"]["path"]).name
    candidate = {
        "title": f"{name} {cand['version']}", "build": int(cand["build"]), "version": cand["version"],
        "minimumSystemVersion": cand["minimumSystemVersion"] or "12.0",
        "channel": "beta" if "-beta." in cand["version"] else "",
        "url": f"https://{host}/download/{zip_name}", "length": cand["zip"]["length"], "signature": cand["signature"],
        "releaseNotesLink": f"https://{host}/release-notes/{cand['version']}/" if notes_available else "",
    }
    items = [candidate]
    previous = artefacts["previous"].get("item")
    if previous:  # the stable a user comes from: offered to nobody (older build), proves no downgrade
        items.append({**previous, "title": f"{name} {previous['version']}", "releaseNotesLink": "",
                      "url": previous["url"].replace(previous["url"].split("/")[2], host, 1)})
    probe = {**candidate, "title": f"{name} channel probe", "build": int(cand["build"]) + 1,
             "version": f"{cand['version']}-channelprobe", "channel": "beta", "releaseNotesLink": ""}
    return {"upgrade": items, "channel": [probe] + items, "probe": probe}


def write_feed(artefacts: dict, out: Path, name: str, host: str, notes_root: Path) -> dict:
    cand = artefacts["candidate"]
    notes = notes_root / cand["version"] / "index.html"
    plan = feed_items(artefacts, name, host, notes.is_file())
    (out / "download").mkdir(parents=True, exist_ok=True)
    shutil.copy2(cand["zip"]["path"], out / "download" / Path(cand["zip"]["path"]).name)
    if notes.is_file():
        (out / "release-notes" / cand["version"]).mkdir(parents=True, exist_ok=True)
        shutil.copy2(notes, out / "release-notes" / cand["version"] / "index.html")
    (out / "appcast-upgrade.xml").write_text(appcast_xml(name, host, plan["upgrade"]), encoding="utf-8")
    (out / "appcast-channel.xml").write_text(appcast_xml(name, host, plan["channel"]), encoding="utf-8")
    return {"probe": {"build": plan["probe"]["build"], "version": plan["probe"]["version"]},
            "items": [{k: i[k] for k in ("build", "version", "channel")} for i in plan["channel"]],
            "releaseNotes": notes.is_file()}


# --- Evidence parsing ----------------------------------------------------------------------------------------------

def load_json(path: Path, default=None):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return default


def parse_endpoint(text: str):
    """(address, port) from 1.2.3.4:443, [2001:db8::1]:443, 2001:db8::1.443 (nettop) or 2001:db8::1:443."""
    text = text.strip()
    if not text or text.startswith("*"):
        return None
    match = re.match(r"^\[([^\]]+)\][.:](\d+)$", text)
    if match:
        return strip_scope(match.group(1)), int(match.group(2))
    for separator in (".", ":") if text.count(":") > 1 else (":",):
        head, _, tail = text.rpartition(separator)
        if tail.isdigit() and head and is_address(strip_scope(head)):
            return strip_scope(head), int(tail)
    return None


def strip_scope(address: str) -> str:
    return address.split("%", 1)[0]


def is_address(text: str) -> bool:
    try:
        ipaddress.ip_address(text)
        return True
    except ValueError:
        return False


def endpoint_text(address: str, port) -> str:
    return f"[{address}]:{port}" if ":" in address else f"{address}:{port}"


def is_loopback(address: str) -> bool:
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    mapped = getattr(ip, "ipv4_mapped", None)
    return ip.is_loopback or bool(mapped and mapped.is_loopback)


def nettop_flows(text: str) -> list:
    """Flows of `nettop -L 0 -n -x`: each `tcp4 a:p<->b:q` line belongs to the process line above it."""
    flows, process = [], ("", 0)
    for line in text.splitlines():
        fields = line.split(",")
        if len(fields) < 2 or fields[0] == "time":
            continue
        name = fields[1].strip()
        match = re.match(r"^(tcp|udp)([46])\s+(\S+)<->(\S+)$", name)
        if not match:
            proc = re.match(r"^(.+)\.(\d+)$", name)
            if proc:
                process = (proc.group(1), int(proc.group(2)))
            continue
        remote = parse_endpoint(match.group(4))
        if remote:
            flows.append({"time": fields[0], "process": process[0], "pid": process[1], "transport": match.group(1),
                          "remote": remote[0], "port": remote[1], "source": "nettop",
                          "state": fields[3].strip() if len(fields) > 3 else ""})
    return flows


def lsof_flows(text: str) -> list:
    """Connected sockets of `lsof -F cpPn` samples (`#t <epoch>` starts a sample)."""
    flows, process, pid, transport, stamp = [], "", 0, "TCP", ""
    for line in text.splitlines():
        if line.startswith("#t "):
            stamp = line[3:].strip()
            continue
        tag, value = line[:1], line[1:]
        if tag == "p":
            pid = int(value) if value.isdigit() else 0
        elif tag == "c":
            process = value
        elif tag == "P":
            transport = value.lower()
        elif tag == "n" and "->" in value:
            remote = parse_endpoint(value.split("->", 1)[1])
            if remote:
                flows.append({"time": stamp, "process": process, "pid": pid, "transport": transport,
                              "remote": remote[0], "port": remote[1], "source": "lsof"})
    return flows


def dns_addresses(text: str) -> set:
    return {strip_scope(m.group(2)) for m in re.finditer(r"^(ip_address|ipv6_address):\s*(\S+)", text, re.M)}


def samples_taken(lsof_text: str) -> int:
    return sum(1 for line in lsof_text.splitlines() if line.startswith("#t "))


def egress_phase(run: Path, phase: str, app_name: str, allowed_hosts: list) -> dict:
    """Every remote endpoint of the app and Sparkle's helpers in one phase, classified (13.7)."""
    egress = run / "egress"
    read = lambda suffix: (egress / f"{phase}-{suffix}").read_text(encoding="utf-8", errors="replace") \
        if (egress / f"{phase}-{suffix}").is_file() else ""
    names = (app_name,) + EGRESS_PROCESSES
    flows = [f for f in nettop_flows(read("nettop.csv")) + lsof_flows(read("lsof.txt"))
             if any(f["process"] == n or f["process"].startswith(n) for n in names)]
    allowed = dns_addresses(read("dns.txt")) if phase == "production" else set()
    endpoints = {}
    for flow in flows:
        key = (flow["process"], flow["remote"], flow["port"], flow["transport"])
        if key not in endpoints:
            ok = is_loopback(flow["remote"]) or flow["remote"] in allowed
            endpoints[key] = {"process": flow["process"], "remote": flow["remote"], "port": flow["port"],
                              "transport": flow["transport"], "allowed": ok, "firstSeen": flow["time"],
                              "seenBy": flow["source"]}
    connections = sorted(endpoints.values(), key=lambda e: (e["process"], e["remote"], e["port"]))
    return {"phase": phase, "allowedHosts": allowed_hosts if phase == "production" else ["loopback (local feed)"],
            "allowedAddresses": sorted(allowed), "lsofSamples": samples_taken(read("lsof.txt")),
            "nettopLines": len(read("nettop.csv").splitlines()), "connections": connections,
            "disallowed": [c for c in connections if not c["allowed"]],
            "started": read("started").strip(), "ended": read("ended").strip()}


def diagnostics_events(text: str) -> list:
    events = []
    for line in text.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        try:
            event["epoch"] = dt.datetime.strptime(event.get("at", ""), "%Y-%m-%dT%H:%M:%SZ").replace(
                tzinfo=dt.timezone.utc).timestamp()
        except ValueError:
            event["epoch"] = 0.0
        events.append(event)
    return events


def key_values(text: str) -> dict:
    values = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        if sep and key and key not in values:
            values[key] = value
    return values


# --- Comparisons ---------------------------------------------------------------------------------------------------

def json_diff(before, after, path: str = "") -> list:
    """(path, before, after) for every leaf that differs; '<absent>' marks a missing key."""
    if isinstance(before, dict) and isinstance(after, dict):
        diffs = []
        for key in sorted(set(before) | set(after)):
            sub = f"{path}.{key}" if path else key
            if key not in before:
                diffs.append((sub, "<absent>", after[key]))
            elif key not in after:
                diffs.append((sub, before[key], "<absent>"))
            else:
                diffs.extend(json_diff(before[key], after[key], sub))
        return diffs
    if isinstance(before, list) and isinstance(after, list) and len(before) == len(after):
        diffs = []
        for index, (left, right) in enumerate(zip(before, after)):
            diffs.extend(json_diff(left, right, f"{path}[{index}]"))
        return diffs
    return [] if before == after else [(path, before, after)]


def explain(file_name: str, path: str, before, after, prev_version: str, cand_version: str) -> str:
    if path == "writtenBy" and before == prev_version and after == cand_version:
        return MIGRATION_RULES["writtenBy"]
    if file_name == "settings.json" and path == "englishRestoreLists.neverCorrect" and before == "<absent>" \
            and after == []:
        return MIGRATION_RULES["englishRestoreLists.neverCorrect"]
    return ""


def compare_settings(before: Path, after: Path, prev_version: str, cand_version: str) -> dict:
    files, unexplained = [], []
    names = sorted({p.name for p in before.glob("*") if p.is_file()} | {p.name for p in after.glob("*") if p.is_file()})
    for name in names:
        left, right = before / name, after / name
        entry = {"file": name, "status": "identical", "differences": []}
        if not left.exists() or not right.exists():
            entry["status"] = "added" if not left.exists() else "removed"
            unexplained.append(f"{name} {entry['status']}")
        elif left.read_bytes() != right.read_bytes():
            entry["status"] = "migrated"
            try:
                diffs = json_diff(json.loads(left.read_text(encoding="utf-8")),
                                  json.loads(right.read_text(encoding="utf-8")))
            except ValueError:
                diffs = [("<bytes>", "not JSON", "not JSON")]
            for path, old, new in diffs:
                reason = explain(name, path, old, new, prev_version, cand_version)
                entry["differences"].append({"path": path, "before": old, "after": new, "explainedBy": reason})
                if not reason:
                    entry["status"] = "changed"
                    unexplained.append(f"{name}: {path} {json.dumps(old)} -> {json.dumps(new)}")
            if not diffs:
                entry["status"] = "changed"
                unexplained.append(f"{name}: bytes differ with equal JSON (formatting)")
        files.append(entry)
    backups_before = sorted(p.name for p in (before / "backups").glob("*")) if (before / "backups").is_dir() else []
    backups_after = sorted(p.name for p in (after / "backups").glob("*")) if (after / "backups").is_dir() else []
    new_backups = sorted(set(backups_after) - set(backups_before))
    if new_backups and not any(f["status"] == "migrated" for f in files):
        unexplained.append(f"new backups without a migration: {', '.join(new_backups)}")
    return {"files": files, "newBackups": new_backups, "unexplained": unexplained}


def load_plist(path: Path) -> dict:
    try:
        with path.open("rb") as handle:
            data = plistlib.load(handle)
        return data if isinstance(data, dict) else {}
    except (OSError, plistlib.InvalidFileException, ValueError):
        return {}


def compare_defaults(before: dict, after: dict, cand_version: str, cand_build: str) -> dict:
    changes, unexplained = [], []
    for key in sorted(set(before) | set(after)):
        old, new = before.get(key, "<absent>"), after.get(key, "<absent>")
        if old == new:
            continue
        reason = DEFAULTS_RULES.get(key, "")
        if key == "launchGuard.appVersion" and cand_version not in str(new):
            reason = ""
        changes.append({"key": key, "before": repr(old)[:120], "after": repr(new)[:120], "explainedBy": reason})
        if not reason:
            unexplained.append(key)
    return {"changes": changes, "unexplained": unexplained, "keys": len(after)}


def content_equal(before: dict, after: dict, new_fields: dict) -> list:
    """Differences between two store dumps; fields only the candidate has must hold their 'not set' value."""
    problems = []
    for key in sorted(set(before.get("user", {})) | set(after.get("user", {}))):
        old, new = before.get("user", {}).get(key, "<absent>"), after.get("user", {}).get(key, "<absent>")
        if old == "<absent>" and key in new_fields:
            if new != new_fields[key]:
                problems.append(f"user.{key}: new in the candidate with {new!r}, expected {new_fields[key]!r}")
        elif old != new:
            problems.append(f"user.{key}: {old!r} -> {new!r}")
    for section in ("appModes", "ruleOverrides", "macros", "safeMode", "readOnlyFiles", "notices"):
        if before.get(section) != after.get(section):
            problems.append(f"{section} differs")
    return problems


def seeded_survived(seeded: dict, after: dict) -> list:
    problems = []
    for key, value in seeded.get("user", {}).items():
        if after.get("user", {}).get(key) != value:
            problems.append(f"user.{key}")
    after_apps = {a["bundle"]: a for a in after.get("appModes", {}).get("apps", [])}
    for app in seeded.get("appModes", {}).get("apps", []):
        if after_apps.get(app["bundle"]) != app:
            problems.append(f"appModes {app['bundle']}")
    for section in ("ruleOverrides", "macros"):
        if seeded.get(section) != after.get(section):
            problems.append(section)
    return problems


# --- Checks --------------------------------------------------------------------------------------------------------

# Fields of the candidate's UserSettings that the previous stable does not have, with the value a file written by
# the previous stable reads as (Migrations.swift: "absent is unset", "an empty list").
CANDIDATE_ONLY_FIELDS = {"typoCorrection": "unset", "neverCorrect": []}


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
    ok = len(settings) >= MIN_SETTINGS and len(macros) >= MIN_MACROS and rules and remembered \
        and seeded.get("ruleOverrides")
    evidence = (f"through the SettingsStore of {run.prev['version']}: {len(settings)} settings besides the update "
                f"switches ({', '.join(settings)}), update switches {sorted(set(explicit) & UPDATE_SETTINGS)}, "
                f"{len(rules)} per-app rules, {len(remembered)} remembered per-app modes, "
                f"{len(seeded.get('ruleOverrides', []))} compatibility overrides, {len(macros)} macros, word lists "
                f"and {len(seeded.get('user', {}).get('learnedWords', []))} per-app learned words")
    return check("seeded", "QA-R40 step 2: at least 10 settings, per-app rules and memory, 50 macros", bool(ok),
                 evidence, ["upgrade-out/seed.json", "upgrade-out/dumps/seeded.previous.json",
                            "upgrade-out/snapshots/seeded/"])


def check_update(run: Run) -> dict:
    found = run.json("evidence/update-offer-find.json", {}) or {}
    ready = run.json("evidence/update-ready-find.json", {}) or {}
    pressed = run.json("evidence/update-install-press.json", {}) or {}
    zip_name = Path(run.cand["zip"]["path"]).name
    downloads = [r for r in run.requests() if r.get("path", "").endswith("/" + zip_name) and r.get("status") == 200]
    appcasts = [r for r in run.requests() if r.get("path", "").startswith("/appcast.xml")]
    texts = " ".join((found.get("window") or {}).get("texts", []))
    ok = bool(found.get("found")) and bool(ready.get("found")) and bool(pressed.get("pressed")) and bool(downloads) \
        and run.cand["version"] in texts
    evidence = (f"forced check from the status menu; Sparkle offered '{texts[:160]}'; pressed "
                f"'{found.get('found')}', then '{pressed.get('pressed')}'; the local feed served "
                f"{len(appcasts)} appcast request(s) and {zip_name} {len(downloads)} time(s) "
                f"({downloads[0].get('size') if downloads else 0} bytes, user agent "
                f"'{downloads[0].get('userAgent', '') if downloads else ''}')")
    return check("sparkle-update", "QA-R40 step 3: update through Sparkle from a local appcast", ok, evidence,
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
    before, after = run.out / "snapshots" / "at-exit", run.out / "snapshots" / "after"
    if not before.is_dir() or not after.is_dir():
        return check("settings-files", "QA-R40 step 4; PLT-R1108", None, "snapshots missing", []), {}
    result = compare_settings(before, after, run.prev["version"], run.cand["version"])
    relaunch = run.json("relaunch.json", {}) or {}
    early = relaunch.get("newProcessBeforeSnapshot") is True
    summary = ", ".join(f"{f['file']} {f['status']}" for f in result["files"])
    evidence = (f"{summary}; snapshot taken {relaunch.get('snapshotAt', 0) - relaunch.get('oldExitedAt', 0):.3f} s "
                f"after {run.prev['version']} exited, before the candidate started: {not early}")
    if result["unexplained"]:
        evidence += "; NOT explained by a migration: " + "; ".join(result["unexplained"])
    ok = not result["unexplained"] and not early
    return check("settings-files", "QA-R40 step 4, release.md 5.2: files byte-identical apart from migrations",
                 ok, evidence, ["upgrade-out/snapshots/at-exit/", "upgrade-out/snapshots/after/"]), result


def check_content(run: Run) -> dict:
    at_exit = run.json("dumps/at-exit.previous.json")
    after = run.json("dumps/after.candidate.json")
    seeded = run.json("dumps/seeded.previous.json")
    if not at_exit or not after or not seeded:
        return check("settings-content", "QA-R40 step 4", None, "store dumps missing", [])
    problems = content_equal(at_exit, after, CANDIDATE_ONLY_FIELDS)
    lost = seeded_survived(seeded, after)
    ok = not problems and not lost
    evidence = (f"read by the {run.prev['version']} store before and the {run.cand['version']} store after: "
                f"{len(after.get('user', {}))} user fields, {len(after.get('appModes', {}).get('apps', []))} per-app "
                f"entries, {len(after.get('ruleOverrides', []))} overrides, {len(after.get('macros', []))} macros; "
                f"differences: {problems or 'none'}; seeded values missing after the update: {lost or 'none'}")
    return check("settings-content", "QA-R40 step 4: settings, rules, per-app memory and macros identical", ok,
                 evidence, ["upgrade-out/dumps/"])


def check_defaults(run: Run) -> dict:
    before = load_plist(run.out / "snapshots" / "defaults-at-exit.plist")
    after = load_plist(run.out / "snapshots" / "defaults-after.plist")
    if not before or not after:
        return check("defaults-domain", "PLT-R1108", None, "defaults exports missing", [])
    result = compare_defaults(before, after, run.cand["version"], str(run.cand["build"]))
    explained = [f"{c['key']} ({c['explainedBy']})" for c in result["changes"] if c["explainedBy"]]
    evidence = (f"{result['keys']} keys; changed by design: {', '.join(explained) or 'none'}; other changes: "
                f"{', '.join(result['unexplained']) or 'none'}")
    return check("defaults-domain", "PLT-R1108: the app's defaults domain survives the update",
                 not result["unexplained"], evidence, ["upgrade-out/snapshots/defaults-at-exit.plist",
                                                       "upgrade-out/snapshots/defaults-after.plist"])


def check_permissions(run: Run) -> dict:
    granted = run.text("snapshots/tcc-granted.txt").strip()
    after = run.text("snapshots/tcc-after.txt").strip()
    rows = [r.split("|") for r in after.splitlines() if r]
    relaunch = run.json("relaunch.json", {}) or {}
    started = relaunch.get("newStartedAt") or 0
    # The first launch of the candidate only: later relaunches (channel switch, egress) are not the update.
    events = [e for e in run.events() if int(started) - 1 <= e["epoch"] <= started + 20]
    states = [e.get("fields", {}).get("to", "") for e in events if e.get("code") == "host.state"]
    transitions = [e for e in events if e.get("code") == "health.permissionTransition"]
    prompts = [line for line in run.text("evidence/prompt-processes.txt").splitlines()
               if "universalAccessAuthWarn" in line]
    tcc_prompts = [line for line in run.text("logs/tccd.log").splitlines()
                   if run.brand["APP_BUNDLE_ID_RELEASE"] in line and re.search(r"[Pp]rompt", line)
                   and "not prompting" not in line.lower()]
    windows = run.json("evidence/app-windows-after.json", []) or []
    ok = bool(granted) and granted == after and rows and all(r[3] == "2" for r in rows if len(r) > 3) \
        and any(s.startswith("ready") for s in states) and "noPermission" not in states and not transitions \
        and not prompts and not tcc_prompts and not windows
    evidence = (f"TCC rows for the bundle before and after identical: {granted == after} "
                f"({len(rows)} rows, auth_value {sorted({r[3] for r in rows if len(r) > 3})}); host states after "
                f"the relaunch {states}; permission transitions {len(transitions)}; prompt processes "
                f"{prompts or 'none'}; tccd prompt lines {len(tcc_prompts)}; app windows after the relaunch "
                f"{len(windows)} (the self-check shows the permission screen when a grant is lost, QA-R42)")
    return check("permissions", "QA-R40 step 4: permissions still granted, no new prompt (PRD-R52)",
                 ok if after else None, evidence,
                 ["upgrade-out/snapshots/tcc-granted.txt", "upgrade-out/snapshots/tcc-after.txt",
                  "upgrade-out/logs/tccd.log", "upgrade-out/evidence/after-relaunch.png"])


def check_tap(run: Run) -> dict:
    relaunch = run.json("relaunch.json", {}) or {}
    latency = relaunch.get("tapLatencySeconds")
    ok = isinstance(latency, (int, float)) and latency <= TAP_LIMIT_SECONDS
    evidence = (f"new process {relaunch.get('newPid')} started {relaunch.get('newStartedAt')}; its event tap was "
                f"enabled after {latency if latency is None else round(latency, 3)} s (CGGetEventTapList, polled every "
                f"10 ms; limit {TAP_LIMIT_SECONDS} s); taps {relaunch.get('taps')}")
    return check("tap-within-2s", "spec/02-platform.md 13.5, release.md 5.2: tap active within 2 s of relaunch",
                 ok if relaunch else None, evidence, ["upgrade-out/relaunch.json"])


def check_typing(run: Run) -> dict:
    relaunch = run.json("relaunch.json", {}) or {}
    latency = relaunch.get("typingLatencySeconds")
    attempts = relaunch.get("attempts", [])
    ok = isinstance(latency, (int, float)) and latency <= TYPING_LIMIT_SECONDS
    tried = "; ".join(f"{a['value']!r} at {a['endedAt'] - relaunch.get('newStartedAt', 0):.2f} s" for a in attempts)
    evidence = (f"TestHost field read {tried or 'nothing'} (keys of testhost.native.telex, expected 'duyệt'); first "
                f"match {latency if latency is None else round(latency, 3)} s after the new process started (limit "
                f"{TYPING_LIMIT_SECONDS} s), no click or prompt in between")
    return check("typing-within-5s", "QA-R40 step 4: typing works in the test host within 5 s, no user action",
                 ok if relaunch else None, evidence, ["upgrade-out/relaunch.json"])


def check_channel(run: Run, probe: dict) -> dict:
    rows = [line.split("\t") for line in run.text("channel.tsv").splitlines() if line]
    if not rows:
        return check("channel-switch", "release.md 5.3: beta to stable and back", None, "not run", [])
    install = {"Install Update"} | {t for t in run.text("titles-install.txt").splitlines() if t}
    outcome, ok = [], len(rows) == 3
    for index, channel, found in [(r + ["", ""])[:3] for r in rows]:
        window = run.json(f"evidence/channel-{index}-{channel}-window.json", {}) or {}
        texts = " ".join(window.get("texts", []))
        offered = found in install
        expected = channel == "beta"
        good = offered == expected and (not offered or probe["version"] in texts)
        ok = ok and good
        outcome.append(f"{channel}: {'probe ' + probe['version'] + ' offered' if offered else 'up to date'}"
                       f"{'' if good else ' (WRONG)'}")
    found_events = [e for e in run.events() if e.get("code") == "update.updateFound"
                    and e.get("fields", {}).get("build") == str(probe["build"])]
    evidence = (f"feed with the candidate, the previous stable and a beta-only probe build {probe['build']}; "
                f"{'; '.join(outcome)}; update.updateFound for the probe logged {len(found_events)} time(s); "
                f"no downgrade offered on stable")
    return check("channel-switch", "release.md 5.3: beta to stable and back (PLT-R1101, PRD-R53)", ok, evidence,
                 ["upgrade-out/channel.tsv", "upgrade-out/evidence/"])


def check_egress(run: Run, phase: str, minutes: int) -> tuple:
    hosts = [run.brand["APP_SITE_HOST"]]
    report = egress_phase(run.out, phase, run.brand["APP_DISPLAY_NAME"], hosts)
    menu = run.json(f"evidence/egress-{phase}-menu.json", {}) or {}
    duration = 0
    if report["started"].isdigit() and report["ended"].isdigit():
        duration = int(report["ended"]) - int(report["started"])
    allowed_seen = [c for c in report["connections"] if c["allowed"] and c["process"] == run.brand["APP_DISPLAY_NAME"]
                    and not (phase == "production" and is_loopback(c["remote"]))]
    if phase == "local":
        allowed_seen = [c for c in report["connections"] if c["port"] == 443]
    ran = bool(report["started"])
    ok = ran and not report["disallowed"] and bool(menu.get("pressed")) and bool(allowed_seen) \
        and duration >= minutes * 60 - 5
    endpoints = ", ".join(f"{c['process']} {endpoint_text(c['remote'], c['port'])}/{c['transport']}"
                          f"{'' if c['allowed'] else ' NOT ALLOWED'}" for c in report["connections"])
    evidence = (f"{duration} s with a forced check ({menu.get('pressed')}); {report['lsofSamples']} lsof samples, "
                f"{report['nettopLines']} nettop lines; allowed: {', '.join(report['allowedHosts'])} "
                f"{report['allowedAddresses'] if phase == 'production' else ''}; endpoints: {endpoints or 'none'}")
    name = "egress-local" if phase == "local" else "egress-production"
    requirement = ("spec/02-platform.md 13.7 phase 1: local appcast, forced check, only allowed hosts" if phase == "local"
                   else "spec/02-platform.md 13.7 phase 2: production feed, only the site host (PLT-R906)")
    return check(name, requirement, ok if ran else None, evidence,
                 [f"upgrade-out/egress/{phase}-nettop.csv", f"upgrade-out/egress/{phase}-lsof.txt",
                  f"upgrade-out/egress/{phase}-dns.txt"]), report


def check_update_egress(run: Run) -> tuple:
    report = egress_phase(run.out, "update", run.brand["APP_DISPLAY_NAME"], [])
    ok = bool(report["started"]) and not report["disallowed"]
    endpoints = ", ".join(f"{c['process']} {endpoint_text(c['remote'], c['port'])}" for c in report["connections"])
    return check("egress-update", "spec/02-platform.md 13.7: the update itself contacts only the local feed", ok
                 if report["started"] else None, f"endpoints during the update: {endpoints or 'none'}",
                 ["upgrade-out/egress/update-nettop.csv", "upgrade-out/egress/update-lsof.txt"]), report


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
    failed = [c["id"] for c in checks if c["result"] == "fail"]
    missing = [c["id"] for c in checks if c["result"] == "not-run"]
    if options.get("watchdogStops"):
        verdict = "ABORTED"
    elif failed:
        verdict = "FAIL"
    else:
        verdict = "INCOMPLETE" if missing else "PASS"
    return {"verdict": verdict, "failed": failed, "notRun": missing, "checks": checks,
            "settingsFiles": files_detail, "egress": egress}


def summary_text(result: dict) -> str:
    lines = [f"RESULT: {result['verdict']}  ({result['previous']['version']} -> {result['candidate']['version']})", ""]
    for item in result["checks"]:
        lines.append(f"[{item['result'].upper():7}] {item['id']}: {item['evidence']}")
    for stop in result.get("watchdog", {}).get("stops", []):
        lines.append(f"[WATCHDOG] {stop}")
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
        "watchdog": {"stops": stops},
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
