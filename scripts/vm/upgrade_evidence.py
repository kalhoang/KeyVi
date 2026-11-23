# SPDX-License-Identifier: GPL-3.0-or-later
"""Evidence parsers and comparisons of scripts/vm/upgrade-test.sh (QA-R40, spec/02-platform.md 13.5 and 13.7; loaded
by upgrade-report.py): tcpdump (PKTAP), nettop, lsof, dscacheutil, the tccd log and the app's diagnostics log, and the
comparisons of the settings snapshots and the defaults domain against the changes the candidate's code explains.
"""
from __future__ import annotations

import datetime as dt
import ipaddress
import json
import plistlib
import re
from pathlib import Path

EGRESS_PROCESSES = ("Autoupdate", "Updater", "com.apple.WebKit.Networking")
# Fields of the candidate's UserSettings that the previous stable does not have, with the value a file written by
# the previous stable reads as (Migrations.swift: "absent is unset", "an empty list").
CANDIDATE_ONLY_FIELDS = {"typoCorrection": "unset", "neverCorrect": []}

# Byte differences in a settings file after the update that a change in the candidate's code explains. Each rule
# names the code that makes the change. A difference no rule explains fails the check (PRD-R52, release.md 5.2).
MIGRATION_RULES = {
    "writtenBy": "the store stamps the version that rewrote a file into its envelope (PLT-R1002, "
                 "SettingsStore.writtenBy)",
    "englishRestoreLists.neverCorrect": "1.1.0 writes the never-correct list, empty for a 1.0.x file, whenever it "
                                        "rewrites settings.json (DocumentCodecs.swift SettingsCodec.encode, "
                                        "ENG-R1118, schema version 1 unchanged per Migrations.swift)",
}

RUNTIME_RULE = ("use, not a migration: the app focused after the relaunch moves to the front or is recorded as seen for "
                "the first time (AppModeMemory.activate, PLT-R390, PLT-R392)")

# Keys of the app's defaults domain that change on every launch or update by design; every other key must be equal.
DEFAULTS_RULES = {
    "launchGuard.inProgressSince": "start time of the current launch (LaunchGuard.beginLaunch, PLT-R1009)",
    "launchGuard.appVersion": "fingerprint of the running build's version, new after an update (LaunchGuard.adoptVersion, "
                              "PLT-R1009)",
    "launch.lastVersionFingerprint": "version of the running build for the post-update self-check "
                                     "(UpdateSelfCheck.noteLaunch, QA-R42)",
    "SULastCheckTime": "Sparkle's time of the last update check",
    "SUHasLaunchedBefore": "Sparkle's first-launch marker",
}


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


TCPDUMP_LINE = re.compile(r"^(?P<time>\S+) \((?P<meta>[^)]*)\) (?P<proto>IP6?) (?P<src>\S+) > (?P<dst>\S+?): (?P<rest>.*)$")


def tcpdump_meta(meta: str) -> tuple:
    """The process a PKTAP packet belongs to: the effective process (`eproc`, the app a DNS lookup of
    mDNSResponder is made for) when given, else `proc`. ("", 0) for a packet without process metadata."""
    for key in ("eproc", "proc"):
        match = re.search(rf"(?:^|, ){key} ([^:,]+):(\d+)", meta)
        if match:
            return match.group(1).strip(), int(match.group(2))
    return "", 0


def split_endpoint(text: str):
    head, _, tail = text.rpartition(".")
    return (strip_scope(head), int(tail)) if tail.isdigit() and is_address(strip_scope(head)) else None


def tcpdump_events(text: str) -> list:
    """Connection attempts and DNS lookups of `tcpdump -i pktap,all -k NP -n -tt` (every TCP SYN and UDP datagram
    with the process that sent it, PKTAP): kind syn, udp, dns-query or dns-answer."""
    events = []
    for line in text.splitlines():
        match = TCPDUMP_LINE.match(line)
        if not match:
            continue
        process, pid = tcpdump_meta(match.group("meta"))
        src, dst = split_endpoint(match.group("src")), split_endpoint(match.group("dst"))
        if not process or not src or not dst:
            continue
        # PKTAP tags received packets with the process too: a datagram from a service port to an ephemeral port
        # (QUIC replies, run 20261123T020752Z-upgrade) is inbound, and its sender is the remote end.
        if src[1] < 1024 <= dst[1] and src[1] != 53 and "Flags [" not in match.group("rest"):
            src, dst = dst, src
        rest = match.group("rest")
        event = {"time": match.group("time"), "process": process, "pid": pid, "source": "tcpdump"}
        flags = re.match(r"Flags \[([^\]]*)\]", rest)
        if flags:
            if "S" not in flags.group(1) or "." in flags.group(1):
                continue  # only the opening SYN of a connection
            event.update(kind="syn", transport="tcp", remote=dst[0], port=dst[1])
        elif dst[1] == 53:
            names = re.findall(r"\b(?:A|AAAA|HTTPS|SVCB|CNAME|Type\d+)\? (\S+?)\.? ", rest + " ")
            event.update(kind="dns-query", transport="udp", remote=dst[0], port=53, names=names,
                         txid=rest.split("+", 1)[0].strip())
        elif src[1] == 53:
            event.update(kind="dns-answer", transport="udp", remote=src[0], port=53,
                         addresses=re.findall(r"\b(?:A|AAAA) ([0-9a-fA-F:.]+[0-9a-fA-F])\b", rest),
                         txid=rest.split(" ", 1)[0].strip())
        else:
            event.update(kind="udp", transport="udp", remote=dst[0], port=dst[1])
        events.append(event)
    return events


def matches(process: str, names: tuple) -> bool:
    return any(process == n or process.startswith(n) or n.startswith(process) and len(process) >= 15 for n in names)


def egress_phase(run: Path, phase: str, app_name: str, allowed_hosts: list) -> dict:
    """Every remote endpoint and DNS lookup of the app and Sparkle's helpers in one phase, classified (13.7).
    tcpdump (PKTAP) sees every connection attempt with its process; nettop and lsof add what was open at each
    second. Allowed: loopback (the local feed) and, on the production feed, the addresses the VM resolved for the
    allowed hosts during the phase; a DNS lookup of any other name is a disallowed attempt too."""
    egress = run / "egress"
    read = lambda suffix: (egress / f"{phase}-{suffix}").read_text(encoding="utf-8", errors="replace") \
        if (egress / f"{phase}-{suffix}").is_file() else ""
    names = (app_name,) + EGRESS_PROCESSES
    events = [e for e in tcpdump_events(read("tcpdump.txt")) if matches(e["process"], names)]
    flows = [f for f in nettop_flows(read("nettop.csv")) + lsof_flows(read("lsof.txt"))
             if matches(f["process"], names)] + [e for e in events if e["kind"] in ("syn", "udp")]
    hosts = {h.lower().rstrip(".") for h in allowed_hosts}
    lookups = sorted({n.lower().rstrip(".") for e in events if e["kind"] == "dns-query" for n in e["names"]})
    allowed = set()
    if phase == "production":
        allowed = dns_addresses(read("dns.txt")) | {
            a for e in events if e["kind"] == "dns-answer" for a in e.get("addresses", [])}
    # The name an address was looked up under (a query and its answer share the transaction ID), for the evidence.
    asked = {e["txid"]: e["names"] for e in events if e["kind"] == "dns-query" and e.get("names")}
    named = {a: asked.get(e.get("txid"), [""])[0] for e in events if e["kind"] == "dns-answer"
             for a in e.get("addresses", [])}
    endpoints = {}
    for flow in flows:
        key = (flow["process"], flow["remote"], flow["port"], flow["transport"])
        if key not in endpoints:
            ok = is_loopback(flow["remote"]) or flow["remote"] in allowed
            endpoints[key] = {"process": flow["process"], "remote": flow["remote"], "port": flow["port"],
                              "transport": flow["transport"], "allowed": ok, "firstSeen": flow["time"],
                              "seenBy": flow["source"], "name": named.get(flow["remote"], "")}
        elif flow["source"] not in endpoints[key]["seenBy"]:
            endpoints[key]["seenBy"] += "," + flow["source"]
    connections = sorted(endpoints.values(), key=lambda e: (e["process"], e["remote"], e["port"]))
    bad_lookups = [n for n in lookups if n not in hosts]
    return {"phase": phase, "allowedHosts": sorted(hosts) if phase == "production" else ["loopback (local feed)"],
            "allowedAddresses": sorted(allowed), "lsofSamples": samples_taken(read("lsof.txt")),
            "nettopLines": len(read("nettop.csv").splitlines()), "tcpdumpLines": len(read("tcpdump.txt").splitlines()),
            "connections": connections, "lookups": lookups, "disallowedLookups": bad_lookups,
            "disallowed": [c for c in connections if not c["allowed"]],
            "started": read("started").strip(), "ended": read("ended").strip()}


TCC_LINE = re.compile(r"^(?P<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*?(?P<kind>AUTHREQ_[A-Z]+): msgID=(?P<msg>[\d.]+), "
                      r"(?P<rest>.*)$")
# TCC auth reasons that mean a consent prompt was shown: 2 user consent, 9 prompt timeout.
PROMPT_REASONS = {"2", "9"}


def tcc_requests(text: str, bundle: str) -> list:
    """TCC requests of `bundle` in the tccd log (`log show --predicate 'process == "tccd"'`), joined by message ID:
    time (UTC epoch), service, preflight, authValue, authReason."""
    requests = {}
    for line in text.splitlines():
        match = TCC_LINE.match(line)
        if not match:
            continue
        entry = requests.setdefault(match.group("msg"), {"msgID": match.group("msg"), "subject": False})
        rest, kind = match.group("rest"), match.group("kind")
        if kind == "AUTHREQ_CTX":
            entry["service"] = (re.search(r"service=(\w+)", rest) or [None, ""])[1]
            entry["preflight"] = "preflight=yes" in rest
            entry["time"] = dt.datetime.strptime(match.group("time")[:26], "%Y-%m-%d %H:%M:%S.%f").replace(
                tzinfo=dt.timezone.utc).timestamp()
        elif kind in ("AUTHREQ_SUBJECT", "AUTHREQ_ATTRIBUTION"):
            if re.search(rf"(?:subject|requesting=\{{TCCDProcess: identifier)={re.escape(bundle)}[,}}]", rest):
                entry["subject"] = True
        elif kind == "AUTHREQ_RESULT":
            entry["authValue"] = (re.search(r"authValue=(\d+)", rest) or [None, ""])[1]
            entry["authReason"] = (re.search(r"authReason=(\d+)", rest) or [None, ""])[1]
    return [r for r in requests.values() if r["subject"] and r.get("service")]


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


def runtime_changes(loaded: Path, after: Path) -> dict:
    """Changes of the new version's own session between the loaded and the settled snapshot. Only app-modes.json may
    change, and only by use: the app focused after the relaunch moves to the front or is recorded as seen for the
    first time (AppModeMemory.activate, PLT-R390, PLT-R392); every earlier entry keeps its rule and mode."""
    notes, unexplained = [], []
    names = sorted({p.name for p in loaded.glob("*") if p.is_file()} | {p.name for p in after.glob("*") if p.is_file()})
    for name in names:
        left, right = loaded / name, after / name
        if left.is_file() and right.is_file() and left.read_bytes() == right.read_bytes():
            continue
        if name != "app-modes.json" or not left.is_file() or not right.is_file():
            unexplained.append(f"{name} changed in the new session without a user action")
            continue
        before, now_doc = json.loads(left.read_text(encoding="utf-8")), json.loads(right.read_text(encoding="utf-8"))
        rest = [p for p in json_diff({k: v for k, v in before.items() if k != "apps"},
                                     {k: v for k, v in now_doc.items() if k != "apps"})]
        old_apps = {a["bundle"]: a for a in before.get("apps", [])}
        new_apps = {a["bundle"]: a for a in now_doc.get("apps", [])}
        changed = [b for b, a in old_apps.items() if new_apps.get(b) != a]
        if rest or changed:
            unexplained.append(f"app-modes.json: {[p[0] for p in rest] + changed} changed in the new session")
        added = sorted(set(new_apps) - set(old_apps))
        notes.append(f"app-modes.json in the new session: order {'changed' if list(old_apps) != [b for b in new_apps if b in old_apps] else 'kept'}"
                     f", first seen {added or 'none'} ({RUNTIME_RULE})")
    return {"notes": notes, "unexplained": unexplained}
