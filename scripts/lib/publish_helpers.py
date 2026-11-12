# SPDX-License-Identifier: LicenseRef-App-Pending
"""Helpers for scripts/publish-release (run with python3 -I).

Subcommands:
  appcast-insert   add one item to the Sparkle appcast (QA-R34, QA-R35, PLT-R1101, PLT-R1106, PLT-R1109)
  releases-add     add one entry to site/data/releases.json (QA-R37)
  render-cask      render packaging/homebrew/Casks/cask.rb.template (QA-R36, PLT-R1110)
  render-zap       print the zap paths with brand values (PLT-R1012)
  changelog-notes  extract the notes of one version from a Keep a Changelog file
"""
from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
XML_LANG = "{http://www.w3.org/XML/1998/namespace}lang"
S = "{%s}" % SPARKLE_NS
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(-beta\.\d+)?$")


def atomic_write(path: str, data: str) -> None:
    directory = os.path.dirname(os.path.abspath(path))
    os.makedirs(directory, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".tmp-")
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(data)
    os.replace(tmp, path)


def new_appcast(title: str, link: str) -> ET.ElementTree:
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = link
    ET.SubElement(channel, "description").text = f"{title} updates"
    ET.SubElement(channel, "language").text = "vi"
    return ET.ElementTree(rss)


def text(parent: ET.Element, tag: str, value: str, attrib: dict | None = None) -> ET.Element:
    element = ET.SubElement(parent, tag, attrib or {})
    element.text = value
    return element


def build_item(args) -> ET.Element:
    item = ET.Element("item")
    text(item, "title", f"{args.app_name} {args.version}")
    pub = dt.datetime.fromisoformat(args.date) if args.date else dt.datetime.now(dt.timezone.utc)
    if pub.tzinfo is None:
        pub = pub.replace(tzinfo=dt.timezone.utc)
    text(item, "pubDate", email.utils.format_datetime(pub))
    text(item, f"{S}version", str(args.build))
    text(item, f"{S}shortVersionString", args.version)
    text(item, f"{S}minimumSystemVersion", args.minimum_system_version)
    if args.minimum_autoupdate_version:
        text(item, f"{S}minimumAutoupdateVersion", args.minimum_autoupdate_version)
    text(item, f"{S}releaseNotesLink", args.notes_url_vi, {XML_LANG: "vi"})
    text(item, f"{S}releaseNotesLink", args.notes_url_en, {XML_LANG: "en"})
    if args.channel == "beta":
        text(item, f"{S}channel", "beta")
    elif args.phased_interval > 0:
        text(item, f"{S}phasedRolloutInterval", str(args.phased_interval))
    if args.critical:
        ET.SubElement(item, f"{S}criticalUpdate")
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        "length": str(args.length),
        "type": "application/octet-stream",
        f"{S}edSignature": args.signature,
    })
    return item


def cmd_appcast_insert(args) -> int:
    if not VERSION_RE.match(args.version):
        raise SystemExit(f"invalid version {args.version}")
    if args.channel == "beta" and "-beta." not in args.version:
        raise SystemExit("channel beta requires an X.Y.Z-beta.N version")
    if args.channel == "stable" and "-beta." in args.version:
        raise SystemExit("a beta version cannot go to the stable channel")
    if not re.fullmatch(r"[A-Za-z0-9+/=]{40,200}", args.signature):
        raise SystemExit("edSignature does not look like a base64 EdDSA signature")
    for url in (args.url, args.notes_url_vi, args.notes_url_en):
        if not url.startswith("https://"):
            raise SystemExit(f"appcast URLs must be HTTPS (PLT-R1102): {url}")
    ET.register_namespace("sparkle", SPARKLE_NS)
    ET.register_namespace("dc", DC_NS)
    if os.path.exists(args.appcast):
        tree = ET.parse(args.appcast)
    else:
        tree = new_appcast(args.app_name, args.site_url)
    channel = tree.getroot().find("channel")
    if channel is None:
        raise SystemExit("appcast has no <channel>")
    for existing in channel.findall("item"):
        raw = (existing.findtext(f"{S}version") or "").strip()
        if not raw.isdigit():
            continue
        existing_channel = existing.findtext(f"{S}channel") or "stable"
        if int(raw) == args.build:
            raise SystemExit(f"build {args.build} is already in the appcast")
        if existing_channel == args.channel and int(raw) > args.build:
            raise SystemExit(f"build {args.build} is lower than published {args.channel} build {raw} (QA-R26)")
    item = build_item(args)
    children = list(channel)
    index = next((i for i, child in enumerate(children) if child.tag == "item"), len(children))
    channel.insert(index, item)
    ET.indent(tree, space="  ")
    data = '<?xml version="1.0" encoding="utf-8"?>\n' + ET.tostring(tree.getroot(), encoding="unicode") + "\n"
    atomic_write(args.appcast, data)
    print(ET.tostring(item, encoding="unicode"))
    return 0


def cmd_releases_add(args) -> int:
    doc = {"schemaVersion": 1, "releases": []}
    if os.path.exists(args.file):
        with open(args.file, encoding="utf-8") as handle:
            doc = json.load(handle)
        if not isinstance(doc.get("releases"), list):
            raise SystemExit(f"{args.file}: expected an object with a releases array")
    if any(entry.get("version") == args.version for entry in doc["releases"]):
        raise SystemExit(f"{args.file}: version {args.version} already listed")
    if not re.fullmatch(r"[0-9a-f]{64}", args.sha256):
        raise SystemExit("sha256 must be 64 lowercase hex characters")
    entry = {
        "version": args.version,
        "build": args.build,
        "channel": args.channel,
        "date": args.date,
        "dmgUrl": args.dmg_url,
        "sha256": args.sha256,
        "size": args.size,
        "minimumSystemVersion": args.minimum_system_version,
        "notes": {"vi": args.notes_vi, "en": args.notes_en},
    }
    doc["releases"] = [entry] + doc["releases"]
    doc["schemaVersion"] = doc.get("schemaVersion", 1)
    atomic_write(args.file, json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(entry, ensure_ascii=False, indent=2))
    return 0


def zap_lines(path: str, folder: str, bundle_id: str) -> list[str]:
    out = []
    with open(path, encoding="utf-8") as handle:
        for raw in handle:
            line = raw.split("#", 1)[0].strip()
            if not line:
                continue
            out.append(line.replace("{{storage-folder}}", folder).replace("{{bundle-id}}", bundle_id))
    return out


def ruby_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"').replace("#{", "\\#{") + '"'


def cmd_render_zap(args) -> int:
    for line in zap_lines(args.zap, args.folder, args.bundle_id):
        print(line)
    return 0


def cmd_render_cask(args) -> int:
    with open(args.template, encoding="utf-8") as handle:
        template = handle.read()
    zap = zap_lines(args.zap, args.folder, args.bundle_id)
    zap_block = ",\n".join(f"    {ruby_string(path)}" for path in zap)
    values = {
        "{{app-slug}}": args.slug,
        "{{AppName}}": args.app_name,
        "{{version}}": args.version,
        "{{sha256}}": args.sha256,
        "{{dmg-url}}": args.url,
        "{{site-host}}": args.site_host,
        "{{desc}}": args.desc,
        "{{zap-paths}}": zap_block,
    }
    for key, value in values.items():
        if key != "{{zap-paths}}" and ('"' in value or "\n" in value):
            raise SystemExit(f"value for {key} must not contain quotes or newlines")
        template = template.replace(key, value)
    leftover = re.findall(r"\{\{[^}]+\}\}", template)
    if leftover:
        raise SystemExit(f"unrendered placeholders in the cask template: {sorted(set(leftover))}")
    rendered = "\n".join(line for line in template.splitlines()
                         if not line.lstrip().startswith("# TEMPLATE:")) + "\n"
    atomic_write(args.out, rendered)
    print(rendered, end="")
    return 0


def cmd_changelog_notes(args) -> int:
    if not os.path.exists(args.file):
        return 0
    with open(args.file, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    heading = re.compile(r"^##\s+\[?v?%s\]?(\s|$)" % re.escape(args.version))
    collecting = False
    out: list[str] = []
    for line in lines:
        if line.startswith("## "):
            if collecting:
                break
            collecting = bool(heading.match(line))
            continue
        if collecting:
            out.append(line)
    print("\n".join(out).strip())
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)

    p = sub.add_parser("appcast-insert")
    p.add_argument("--appcast", required=True)
    p.add_argument("--app-name", required=True)
    p.add_argument("--site-url", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True, type=int)
    p.add_argument("--minimum-system-version", required=True)
    p.add_argument("--minimum-autoupdate-version", default="")
    p.add_argument("--channel", choices=["stable", "beta"], required=True)
    p.add_argument("--phased-interval", type=int, default=86400)
    p.add_argument("--critical", action="store_true")
    p.add_argument("--url", required=True)
    p.add_argument("--length", required=True, type=int)
    p.add_argument("--signature", required=True)
    p.add_argument("--notes-url-vi", required=True)
    p.add_argument("--notes-url-en", required=True)
    p.add_argument("--date", default="")
    p.set_defaults(func=cmd_appcast_insert)

    p = sub.add_parser("releases-add")
    p.add_argument("--file", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--build", required=True, type=int)
    p.add_argument("--channel", choices=["stable", "beta"], required=True)
    p.add_argument("--date", required=True)
    p.add_argument("--dmg-url", required=True)
    p.add_argument("--sha256", required=True)
    p.add_argument("--size", required=True, type=int)
    p.add_argument("--minimum-system-version", required=True)
    p.add_argument("--notes-vi", default="")
    p.add_argument("--notes-en", default="")
    p.set_defaults(func=cmd_releases_add)

    for name, func in (("render-cask", cmd_render_cask), ("render-zap", cmd_render_zap)):
        p = sub.add_parser(name)
        p.add_argument("--zap", required=True)
        p.add_argument("--folder", required=True)
        p.add_argument("--bundle-id", required=True)
        if name == "render-cask":
            p.add_argument("--template", required=True)
            p.add_argument("--out", required=True)
            p.add_argument("--slug", required=True)
            p.add_argument("--app-name", required=True)
            p.add_argument("--version", required=True)
            p.add_argument("--sha256", required=True)
            p.add_argument("--url", required=True)
            p.add_argument("--site-host", required=True)
            p.add_argument("--desc", required=True)
        p.set_defaults(func=func)

    p = sub.add_parser("changelog-notes")
    p.add_argument("--file", required=True)
    p.add_argument("--version", required=True)
    p.set_defaults(func=cmd_changelog_notes)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
