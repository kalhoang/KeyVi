# SPDX-License-Identifier: GPL-3.0-or-later
"""Artefact checks and the local feed of scripts/vm/upgrade-test.sh (QA-R40, PLT-R1102; loaded by upgrade-report.py).

check_artefacts verifies the previous stable and the candidate in their dist folders (SHA-256 against SHA256SUMS,
version and build against build-info.json, one SUPublicEDKey) and finds the candidate's EdDSA signature: the item of
the published appcast with the same build, length and bytes, verified with OpenSSL 3 against the previous app's key,
or a signature from Sparkle's sign_update. write_feed writes the run's feed folder.
"""
from __future__ import annotations

import base64
import hashlib
import json
import plistlib
import re
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ED25519_SPKI_PREFIX = bytes.fromhex("302a300506032b6570032100")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$")


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
