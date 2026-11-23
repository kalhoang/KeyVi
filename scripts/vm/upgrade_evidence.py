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
# The system's revocation check of the update's signature, the one endpoint besides the local feed and the site host
# allowed while an update installs (PLT-R906 and spec/02-platform.md 13.7 as amended on 2026-11-23,
# docs/decisions/0011-pa-decisions-2026-11-23.md). From the install captures of the upgrade runs of 2026-11-22 and 23:
# mDNSResponder looks up Apple's OCSP name for Autoupdate (ocsp2.g.aaplimg.com, the CDN name behind ocsp2.apple.com;
# ocsp2.apple.com itself in the other phases), then trustd connects for Autoupdate to an address of the answer, TCP
# 443. Allowed: a lookup of one of these names (whole name, any case) by Autoupdate, and a connection of trustd for
# Autoupdate to TCP or UDP 443 of an address the capture saw resolved from one of them before the connection. Any
# other process, port or address, or a name that only resembles these, is not allowed.
REVOCATION_NAMES = (re.compile(r"ocsp[0-9]?\.apple\.com"), re.compile(r"ocsp[0-9]?\.g\.aaplimg\.com"))
REVOCATION_PORT = 443
REVOCATION_CLIENTS = {"Autoupdate": ("trustd",)}  # the process checked for: the processes that may send for it
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

def _is_number(value) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


# Keys of the app's defaults domain that the previous version (its update check, its quit) or the candidate's launch
# write by design, each with the values that code writes. The baseline is the export taken while the previous version
# ran, before the update check. Every other key must be equal, and no key may disappear (PLT-R1108).
DEFAULTS_RULES = {
    "launchGuard.inProgressSince": ("start time of the current launch, 0 once it survived or quit cleanly "
                                    "(LaunchGuard.beginLaunch, markSurvived, PLT-R1009)", _is_number),
    "launchGuard.appVersion": ("fingerprint of the running build's version, new after an update "
                               "(LaunchGuard.adoptVersion, PLT-R1009)", _is_number),
    "launchGuard.recentCrashes": ("crash streak, cleared to 0 when a launch survives 60 s, quits cleanly or runs a new "
                                  "version (LaunchGuard.clearStreak, PLT-R1009)", lambda value: value == 0),
    "launchGuard.firstCrashAt": ("start of the crash streak, cleared with it (LaunchGuard.clearStreak, PLT-R1009)",
                                 lambda value: value == 0),
    "launch.lastVersionFingerprint": ("version of the running build for the post-update self-check "
                                      "(UpdateSelfCheck.noteLaunch, QA-R42)", _is_number),
    "SULastCheckTime": ("Sparkle's time of the last update check (the forced check)",
                        lambda value: isinstance(value, dt.datetime)),
    "SUHasLaunchedBefore": ("Sparkle's first-launch marker", lambda value: value is True),
}
# Key prefixes with the same meaning: AppKit saves the frame of a Sparkle window (the update window the previous
# version showed) under "NSWindow Frame <autosave name>".
DEFAULTS_PREFIX_RULES = {
    "NSWindow Frame SU": ("AppKit's saved frame of a Sparkle window (the update window the previous version showed)",
                          lambda value: isinstance(value, str)),
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


def tcpdump_sender(meta: str) -> str:
    """The process that sent a PKTAP packet (`proc`): mDNSResponder or trustd when they act for another process."""
    match = re.search(r"(?:^|, )proc ([^:,]+):\d+", meta)
    return match.group(1).strip() if match else ""


def dns_id(rest: str) -> str:
    """The transaction ID that starts a DNS packet's summary (`1192+ A? ...`, `25043* 0/0/0`, `49041 NXDomain*`)."""
    match = re.match(r"(\d+)", rest)
    return match.group(1) if match else ""


def split_endpoint(text: str):
    head, _, tail = text.rpartition(".")
    return (strip_scope(head), int(tail)) if tail.isdigit() and is_address(strip_scope(head)) else None


def tcpdump_events(text: str) -> list:
    """Connection attempts and DNS lookups of `tcpdump -i pktap,all -k NP -n -tt` (every TCP SYN and UDP datagram
    with the process it belongs to and the one that sent it, PKTAP): kind syn, udp, dns-query or dns-answer. A DNS
    packet carries its transaction ID and the client's endpoint, which pair a query with its answer."""
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
        event = {"time": match.group("time"), "process": process, "pid": pid,
                 "sender": tcpdump_sender(match.group("meta")) or process, "source": "tcpdump"}
        flags = re.match(r"Flags \[([^\]]*)\]", rest)
        if flags:
            if "S" not in flags.group(1) or "." in flags.group(1):
                continue  # only the opening SYN of a connection
            event.update(kind="syn", transport="tcp", remote=dst[0], port=dst[1])
        elif dst[1] == 53:
            names = re.findall(r"\b(?:A|AAAA|HTTPS|SVCB|CNAME|Type\d+)\? (\S+?)\.? ", rest + " ")
            event.update(kind="dns-query", transport="udp", remote=dst[0], port=53, names=names,
                         txid=dns_id(rest), client=endpoint_text(*src))
        elif src[1] == 53:
            event.update(kind="dns-answer", transport="udp", remote=src[0], port=53,
                         addresses=re.findall(r"\b(?:A|AAAA) ([0-9a-fA-F:.]+[0-9a-fA-F])\b", rest),
                         txid=dns_id(rest), client=endpoint_text(*dst))
        else:
            event.update(kind="udp", transport="udp", remote=dst[0], port=dst[1])
        events.append(event)
    return events


def tcpdump_dropped(stderr_text: str):
    """Packets the kernel dropped, from the statistics tcpdump prints when it stops; None when they are missing (the
    capture did not end normally). PKTAP filters in user space, so every packet of every interface crosses the
    capture buffer: a drop can be one the filter would have kept."""
    match = re.search(r"^(\d+) packets? dropped by kernel", stderr_text, re.M)
    return int(match.group(1)) if match else None


def matches(process: str, names: tuple) -> bool:
    return any(process == n or process.startswith(n) or n.startswith(process) and len(process) >= 15 for n in names)


def is_revocation_name(name: str) -> bool:
    """One of Apple's OCSP names (REVOCATION_NAMES): the whole name, in any case, with or without the final dot."""
    folded = name.lower().rstrip(".")
    return any(pattern.fullmatch(folded) for pattern in REVOCATION_NAMES)


def revocation_text() -> str:
    names = ", ".join(pattern.pattern.replace("\\", "") for pattern in REVOCATION_NAMES)
    clients = ", ".join(f"{' or '.join(senders)} for {client}" for client, senders in REVOCATION_CLIENTS.items())
    return f"Apple's certificate revocation service ({names}, port {REVOCATION_PORT}) checked by {clients}"


def epoch(text):
    try:
        return float(text)
    except (TypeError, ValueError):
        return None


def dns_resolutions(events: list) -> dict:
    """address -> [(name, time)]: every A and AAAA record of a DNS answer in the capture, under the name its query
    asked for (a query and its answer share the transaction ID and the client's endpoint). The lookups of every
    process count: they show which name an address stood for at that moment."""
    asked = {(e["txid"], e["client"]): e["names"][0].lower().rstrip(".") for e in events
             if e["kind"] == "dns-query" and e.get("names") and e.get("txid")}
    resolved = {}
    for event in events:
        name = asked.get((event.get("txid"), event.get("client"))) if event["kind"] == "dns-answer" else None
        for address in event.get("addresses", []) if name else []:
            resolved.setdefault(address, []).append((name, event["time"]))
    return resolved


def revocation_name(flow: dict, resolved: dict) -> str:
    """The OCSP name the flow's address was resolved from before the flow, when the flow can be the system's
    revocation check (sent by a process REVOCATION_CLIENTS allows, to REVOCATION_PORT over TCP or UDP); "" otherwise.
    A flow without an epoch time (nettop) cannot be placed after its lookup."""
    at = epoch(flow["time"])
    if flow.get("sender", flow["process"]) not in REVOCATION_CLIENTS.get(flow["process"], ()) \
            or flow["port"] != REVOCATION_PORT or flow["transport"] not in ("tcp", "udp") or at is None:
        return ""
    names = [name for name, time in resolved.get(flow["remote"], [])
             if is_revocation_name(name) and epoch(time) is not None and epoch(time) <= at]
    return names[0] if names else ""


def allowed_as(flow: dict, allowed: set, resolved: dict, revocation: bool) -> str:
    """Why a flow is allowed: loopback (the local feed), an allowed host's address, the revocation check; "" if not."""
    if is_loopback(flow["remote"]):
        return "loopback"
    if flow["remote"] in allowed:
        return "allowed host"
    return "revocation check" if revocation and revocation_name(flow, resolved) else ""


def phase_endpoints(flows: list, allowed: set, resolved: dict, revocation: bool) -> list:
    """One entry per process, sending process, remote endpoint and transport, allowed only when every flow to it is.
    `name` is the name the address was resolved from (the OCSP name for a revocation check), for the evidence."""
    endpoints = {}
    for flow in flows:
        sender, reason = flow.get("sender", flow["process"]), allowed_as(flow, allowed, resolved, revocation)
        key = (flow["process"], sender, flow["remote"], flow["port"], flow["transport"])
        entry = endpoints.get(key)
        if entry is None:
            names = [name for name, _ in resolved.get(flow["remote"], [])]
            label = revocation_name(flow, resolved) if reason == "revocation check" else ""
            endpoints[key] = {"process": flow["process"], "sender": sender, "remote": flow["remote"],
                              "port": flow["port"], "transport": flow["transport"], "allowed": bool(reason),
                              "allowedAs": reason, "firstSeen": flow["time"], "seenBy": flow["source"],
                              "name": label or (names[0] if names else "")}
            continue
        if not reason:
            entry.update(allowed=False, allowedAs="")
        if flow["source"] not in entry["seenBy"].split(","):
            entry["seenBy"] += "," + flow["source"]
    return sorted(endpoints.values(), key=lambda e: (e["process"], e["sender"], e["remote"], e["port"]))


def phase_lookups(events: list, hosts: set, revocation: bool) -> tuple:
    """(process, name) of every DNS lookup of the app and the helpers, and those not allowed: any name but the
    allowed hosts, except, on the install, Apple's OCSP names looked up for a process REVOCATION_CLIENTS names."""
    asked = sorted({(e["process"], n.lower().rstrip(".")) for e in events if e["kind"] == "dns-query"
                    for n in e["names"]})
    refused = [(process, name) for process, name in asked if name not in hosts and not (
        revocation and process in REVOCATION_CLIENTS and is_revocation_name(name))]
    return asked, refused


def egress_phase(run: Path, phase: str, app_name: str, allowed_hosts: list, revocation: bool = False) -> dict:
    """Every remote endpoint and DNS lookup of the app and Sparkle's helpers in one phase, classified (13.7).
    tcpdump (PKTAP) sees every connection attempt with its process as long as the kernel dropped no packet
    (tcpdumpDropped); nettop and lsof add what was open at each second. Allowed: loopback (the local feed) and, on
    the production feed, the addresses the VM resolved for the allowed hosts during the phase; a DNS lookup of any
    other name is a disallowed attempt too. With `revocation` (the install): loopback, the addresses the capture saw
    resolved from the allowed hosts, and the system's revocation check of the update's signature (REVOCATION_*)."""
    egress = run / "egress"
    read = lambda suffix: (egress / f"{phase}-{suffix}").read_text(encoding="utf-8", errors="replace") \
        if (egress / f"{phase}-{suffix}").is_file() else ""
    names = (app_name,) + EGRESS_PROCESSES
    captured = tcpdump_events(read("tcpdump.txt"))
    events = [e for e in captured if matches(e["process"], names)]
    flows = [f for f in nettop_flows(read("nettop.csv")) + lsof_flows(read("lsof.txt"))
             if matches(f["process"], names)] + [e for e in events if e["kind"] in ("syn", "udp")]
    hosts = {h.lower().rstrip(".") for h in allowed_hosts}
    resolved = dns_resolutions(captured)
    allowed, described = set(), ["loopback (local feed)"]
    if phase == "production":
        allowed = dns_addresses(read("dns.txt")) | {
            a for e in events if e["kind"] == "dns-answer" for a in e.get("addresses", [])}
        described = sorted(hosts)
    elif revocation:
        allowed = dns_addresses(read("dns.txt")) | {
            address for address, seen in resolved.items() if any(name in hosts for name, _ in seen)}
        described += sorted(hosts) + [revocation_text()]
    connections = phase_endpoints(flows, allowed, resolved, revocation)
    asked, refused = phase_lookups(events, hosts, revocation)
    return {"phase": phase, "allowedHosts": described, "allowedAddresses": sorted(allowed),
            "lsofSamples": samples_taken(read("lsof.txt")), "nettopLines": len(read("nettop.csv").splitlines()),
            "tcpdumpLines": len(read("tcpdump.txt").splitlines()),
            "tcpdumpDropped": tcpdump_dropped(read("tcpdump.err")),
            "tcpdumpCaptured": (egress / f"{phase}-tcpdump.txt").is_file(), "connections": connections,
            "revocationChecks": [c for c in connections if c["allowedAs"] == "revocation check"],
            "lookups": sorted({name for _, name in asked}), "lookupsBy": [f"{p} {n}" for p, n in asked],
            "disallowedLookups": sorted({name for _, name in refused}),
            "disallowedLookupsBy": [f"{p} {n}" for p, n in refused],
            "disallowed": [c for c in connections if not c["allowed"]],
            "started": read("started").strip(), "ended": read("ended").strip()}


TCC_LINE = re.compile(r"^(?P<time>\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+) .*?(?P<kind>AUTHREQ_[A-Z]+): msgID=(?P<msg>[\d.]+), "
                      r"(?P<rest>.*)$")
# TCC auth reasons that mean a consent prompt was shown: 2 user consent, 9 prompt timeout.
PROMPT_REASONS = {"2", "9"}
# First line the guest writes above `log show --timezone UTC` output: compact timestamps carry no zone, so a log
# without it cannot be placed in time (upgrade-guest.sh, finish).
TCC_TIMEZONE_MARKER = "#timezone=UTC"


def tcc_requests(text: str, bundle: str) -> list:
    """TCC requests of `bundle` in the tccd log (`log show --timezone UTC --predicate 'process == "tccd"'`), joined
    by message ID: time (UTC epoch; None when the log lacks the UTC marker), service, preflight, answered,
    authValue, authReason."""
    utc = TCC_TIMEZONE_MARKER in (line.strip() for line in text.splitlines()[:3])
    requests = {}
    for line in text.splitlines():
        match = TCC_LINE.match(line)
        if not match:
            continue
        entry = requests.setdefault(match.group("msg"), {"msgID": match.group("msg"), "subject": False,
                                                         "answered": False})
        rest, kind = match.group("rest"), match.group("kind")
        if kind == "AUTHREQ_CTX":
            entry["service"] = (re.search(r"service=(\w+)", rest) or [None, ""])[1]
            entry["preflight"] = "preflight=yes" in rest
            entry["time"] = dt.datetime.strptime(match.group("time")[:26], "%Y-%m-%d %H:%M:%S.%f").replace(
                tzinfo=dt.timezone.utc).timestamp() if utc else None
        elif kind in ("AUTHREQ_SUBJECT", "AUTHREQ_ATTRIBUTION"):
            if re.search(rf"(?:subject|requesting=\{{TCCDProcess: identifier)={re.escape(bundle)}[,}}]", rest):
                entry["subject"] = True
        elif kind == "AUTHREQ_RESULT":
            entry["answered"] = True
            entry["authValue"] = (re.search(r"authValue=(\d+)", rest) or [None, ""])[1]
            entry["authReason"] = (re.search(r"authReason=(\d+)", rest) or [None, ""])[1]
    return [r for r in requests.values() if r["subject"] and r.get("service")]


def tcc_prompted(request: dict) -> bool:
    """A consent prompt was shown for the request: answered by the user or by its timeout, or still waiting (a request
    that may prompt, not a preflight, with no result: nobody answered it)."""
    if request.get("authReason") in PROMPT_REASONS:
        return True
    return not request.get("answered") and request.get("preflight") is False


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


def defaults_rule(key: str) -> tuple:
    """(reason, accepts) of the rule for a defaults key, ("", None) when no rule covers it."""
    if key in DEFAULTS_RULES:
        return DEFAULTS_RULES[key]
    for prefix, rule in DEFAULTS_PREFIX_RULES.items():
        if key.startswith(prefix):
            return rule
    return "", None


def compare_defaults(before: dict, after: dict) -> dict:
    """Changes between two exports of the app's defaults domain. A change is explained only when a rule covers the
    key and the new value is one that rule's code writes; a removed key is never explained."""
    absent = object()
    changes, unexplained = [], []
    for key in sorted(set(before) | set(after)):
        old, new = before.get(key, absent), after.get(key, absent)
        if old == new:
            continue
        reason, accepts = defaults_rule(key)
        explained = reason if reason and new is not absent and accepts(new) else ""
        changes.append({"key": key, "before": "<absent>" if old is absent else repr(old)[:120],
                        "after": "<absent>" if new is absent else repr(new)[:120], "explainedBy": explained})
        if not explained:
            unexplained.append(key)
    return {"changes": changes, "unexplained": unexplained, "keys": len(after)}


# Sections of a store dump (upgrade-store.swift dump) that must be equal; collisionMemory is collision-memory.json
# (PLT-R914), read by the same store.
STORE_SECTIONS = ("appModes", "ruleOverrides", "macros", "collisionMemory", "safeMode", "readOnlyFiles", "notices")


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
    for section in STORE_SECTIONS:
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
    for section in ("ruleOverrides", "macros", "collisionMemory"):
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
