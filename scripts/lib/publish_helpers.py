# SPDX-License-Identifier: LicenseRef-App-Pending
"""Helpers for scripts/publish-release (run with python3 -I).

Subcommands:
  appcast-insert     add one item to the Sparkle appcast (QA-R34, QA-R35, PLT-R1101, PLT-R1106, PLT-R1109)
  releases-add       add one entry to site/data/releases.json (QA-R37)
  release-notes-page write the bilingual release-notes page the appcast links to (PRD-R51, ADR 0304)
  render-cask      render packaging/homebrew/Casks/cask.rb.template (QA-R36, PLT-R1110)
  render-zap       print the zap paths with brand values (PLT-R1012)
  changelog-notes  extract the notes of one version from a Keep a Changelog file
"""
from __future__ import annotations

import argparse
import datetime as dt
import email.utils
import html
import json
import os
import re
import sys
import tempfile
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"
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
    # ADR 0304 amendment: Sparkle chooses an xml:lang variant by the macOS language, not by the app's
    # interface language (D18), so the item links one bilingual page and carries no xml:lang variants.
    text(item, f"{S}releaseNotesLink", args.notes_url)
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
    for url in (args.url, args.notes_url):
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


def fill_brand(value: str, app_name: str) -> str:
    """Release notes come from CHANGELOG sections, which may say {{AppName}} (the file is brand-neutral)."""
    return value.replace("{{AppName}}", app_name) if app_name else value


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
        "notes": {"vi": fill_brand(args.notes_vi, args.app_name), "en": fill_brand(args.notes_en, args.app_name)},
    }
    doc["releases"] = [entry] + doc["releases"]
    doc["schemaVersion"] = doc.get("schemaVersion", 1)
    atomic_write(args.file, json.dumps(doc, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(entry, ensure_ascii=False, indent=2))
    return 0


NOTES_MAX_VISIBLE_LINES = 5  # PRD-R51: five lines visible, then the "more" link to the changelog
DASHES = ("\u2013", "\u2014")  # the site's prose rule (site/test.mjs) rejects en and em dashes
# Bump the query when site/static/assets/release-notes.css changes (/assets/* is cached as immutable).
RELEASE_NOTES_CSS = "/assets/release-notes.css?v=1"
PAGE_COPY = {
    "vi": {"heading": "Tiếng Việt", "more": "Xem nhật ký thay đổi đầy đủ"},
    "en": {"heading": "English", "more": "Read the full changelog"},
}


def inline_html(value: str) -> str:
    """Escapes the text, then renders `code`, **bold** and [label](https://...) links (other links: label)."""
    out = html.escape(value, quote=True)
    out = re.sub(r"`([^`]+)`", r"<code>\1</code>", out)
    out = re.sub(r"\*\*([^*]+)\*\*", r"<strong>\1</strong>", out)
    out = re.sub(r"\[([^\]]+)\]\((https://[^)\s]+)\)", r'<a href="\2">\1</a>', out)
    return re.sub(r"\[([^\]]+)\]\([^)\s]*\)", r"\1", out)


def notes_html(notes: str) -> tuple[str, int]:
    """Renders the short Markdown of a CHANGELOG section: ### headings, - items, paragraphs. Returns the HTML
    and the number of visible lines (items and paragraphs)."""
    parts: list[str] = []
    in_list = False
    visible = 0
    for raw in notes.splitlines():
        line = raw.strip()
        item = re.match(r"^[-*+]\s+(.*)$", line)
        if in_list and not item:
            parts.append("</ul>")
            in_list = False
        if not line:
            continue
        heading = re.match(r"^#{2,6}\s+(.*?)\s*#*$", line)
        if heading:
            parts.append(f"<h3>{inline_html(heading.group(1))}</h3>")
            continue
        visible += 1
        if item:
            if not in_list:
                parts.append("<ul>")
                in_list = True
            parts.append(f"<li>{inline_html(item.group(1))}</li>")
        else:
            parts.append(f"<p>{inline_html(line)}</p>")
    if in_list:
        parts.append("</ul>")
    return "\n".join(parts), visible


def notes_section(lang: str, notes: str, changelog_url: str) -> str:
    copy = PAGE_COPY[lang]
    body, visible = notes_html(notes)
    if visible > NOTES_MAX_VISIBLE_LINES:
        print(f"release-notes-page: the {lang} notes have {visible} lines; PRD-R51 asks for at most "
              f"{NOTES_MAX_VISIBLE_LINES} (the page links the changelog for the rest)", file=sys.stderr)
    url = html.escape(changelog_url, quote=True)
    return (f'<section lang="{lang}" aria-labelledby="notes-{lang}">\n'
            f'<h2 id="notes-{lang}">{copy["heading"]}</h2>\n'
            + (body + "\n" if body else "")
            + f'<p class="more"><a href="{url}">{copy["more"]}</a></p>\n</section>')


def cmd_release_notes_page(args) -> int:
    """One bilingual page per release (ADR 0304 amendment): Vietnamese first, then English. It is what the
    in-app update window shows, so it carries no donation line (PRD-R57) and no site navigation."""
    if not VERSION_RE.match(args.version):
        raise SystemExit(f"invalid version {args.version}")
    for url in (args.changelog_url_vi, args.changelog_url_en):
        if not url.startswith("https://"):
            raise SystemExit(f"changelog links must be HTTPS: {url}")
    notes = {"vi": fill_brand(args.notes_vi, args.app_name), "en": fill_brand(args.notes_en, args.app_name)}
    for lang, value in notes.items():
        if any(dash in value for dash in DASHES):
            raise SystemExit(f"the {lang} notes contain an en or em dash; use a comma, colon or hyphen "
                             "(the site build rejects them)")
        if "{{" in value:
            raise SystemExit(f"the {lang} notes contain an unfilled {{{{token}}}}")
    if os.path.exists(args.out) and not args.force:
        raise SystemExit(f"{args.out} already exists: version {args.version} has been published")
    title = html.escape(f"{args.app_name} {args.version}")
    page = "\n".join([
        "<!doctype html>",
        '<html lang="vi">',
        "<head>",
        '<meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        '<meta name="color-scheme" content="light dark">',
        '<meta http-equiv="Content-Security-Policy" content="default-src \'none\'; style-src \'self\'; '
        "img-src 'self'; base-uri 'none'; form-action 'none'\">",
        '<meta name="robots" content="noindex">',
        f"<title>{title}</title>",
        f'<link rel="stylesheet" href="{RELEASE_NOTES_CSS}">',
        "</head>",
        "<body>",
        "<main>",
        f"<h1>{title}</h1>",
        notes_section("vi", notes["vi"], args.changelog_url_vi),
        notes_section("en", notes["en"], args.changelog_url_en),
        "</main>",
        "</body>",
        "</html>",
        "",
    ])
    atomic_write(args.out, page)
    print(page, end="")
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
    p.add_argument("--notes-url", required=True, help="the bilingual release-notes page (ADR 0304)")
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
    p.add_argument("--app-name", default="", help="fills {{AppName}} in the notes")
    p.set_defaults(func=cmd_releases_add)

    p = sub.add_parser("release-notes-page")
    p.add_argument("--out", required=True, help="site/static/release-notes/<version>/index.html")
    p.add_argument("--app-name", required=True)
    p.add_argument("--version", required=True)
    p.add_argument("--notes-vi", default="")
    p.add_argument("--notes-en", default="")
    p.add_argument("--changelog-url-vi", required=True)
    p.add_argument("--changelog-url-en", required=True)
    p.add_argument("--force", action="store_true", help="overwrite an existing page")
    p.set_defaults(func=cmd_release_notes_page)

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
