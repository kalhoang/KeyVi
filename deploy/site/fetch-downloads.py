#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: LicenseRef-App-Pending
"""Fetches the release files the website serves under https://<site host>/download/ (Pa, 2026-11-13, Q10: updates
and DMGs live on the site host only; ADR 0602).

Reads site/data/releases.json (every DMG on the download and archive pages, QA-R38) and site/static/appcast.xml
(every update archive Sparkle may download, PLT-R1107). For each URL under https://<APP_SITE_HOST>/download/ named
<slug>-<version>.dmg or .zip, it downloads the asset of the GitHub Release v<version> with `gh release download`, then
checks it: a DMG against the SHA-256 (and size, when given) of releases.json, an update archive against the appcast
enclosure length. Files already in --out with the right checksum or length are kept. Files hosted elsewhere (GitHub
Release URLs of publish-release --github-release) are skipped.

Usage: python3 -I deploy/site/fetch-downloads.py --out DIR [--repo OWNER/NAME] [--root DIR] [--brand-env FILE]
  --repo       default: $GITHUB_REPOSITORY (needed only when something must be downloaded)
  --root       repository root (default: this checkout); --brand-env default <root>/scripts/brand.env
Environment: GH_TOKEN for gh (site-image.yml passes the workflow token). Exit status: 0 done, 1 a file is
missing or does not match, 2 usage or input error.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
VERSION = r"[0-9]+\.[0-9]+\.[0-9]+(?:-beta\.[0-9]+)?"


class InputError(Exception):
    pass


def brand_values(env_file: Path) -> dict[str, str]:
    values = {}
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^\s*(APP_[A-Z_]+)="?(.*?)"?\s*$', line)
        if match and not line.lstrip().startswith("#"):
            values[match.group(1)] = match.group(2)
    return values


def site_file_name(url: str, host: str) -> str | None:
    prefix = f"https://{host}/download/"
    if not isinstance(url, str) or not url.startswith(prefix):
        return None
    name = url[len(prefix):]
    if not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise InputError(f"unexpected download file name in {url}")
    return name


def release_entries(data: object) -> list[dict]:
    """The release objects of releases.json: a list, or an object with a `releases` (or `items`) list, the shapes
    site/lib/data.mjs reads. Any other shape is an input error, never a traceback."""
    if isinstance(data, list):
        entries = data
    elif isinstance(data, dict):
        key = next((name for name in ("releases", "items") if name in data), None)
        if key is None:
            return []
        entries = data[key]
        if not isinstance(entries, list):
            raise InputError(f"releases.json: `{key}` is not a list")
    else:
        raise InputError("releases.json: expected an object with `releases` or a list")
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict):
            raise InputError(f"releases.json: entry {index} is not an object")
    return entries


def wanted_files(root: Path, host: str, slug: str) -> dict[str, dict]:
    """name -> {version, sha256?, size?} for every release file on the site host."""
    pattern = re.compile(rf"{re.escape(slug)}-({VERSION})\.(dmg|zip)")
    wanted: dict[str, dict] = {}

    def add(name: str, check: dict) -> None:
        match = pattern.fullmatch(name)
        if not match:
            raise InputError(f"{name}: expected {slug}-<version>.dmg or .zip")
        entry = wanted.setdefault(name, {"version": match.group(1)})
        for key, value in check.items():
            if key in entry and entry[key] != value:
                raise InputError(f"{name}: releases.json and appcast.xml disagree on {key}")
            entry[key] = value

    releases_path = root / "site" / "data" / "releases.json"
    if releases_path.is_file():
        data = json.loads(releases_path.read_text(encoding="utf-8"))
        for release in release_entries(data):
            name = site_file_name(release.get("dmgUrl"), host)
            if name is None:
                continue
            sha = str(release.get("sha256", "")).lower()
            if not re.fullmatch(r"[0-9a-f]{64}", sha):
                raise InputError(f"{name}: releases.json has no valid sha256")
            check = {"sha256": sha}
            if isinstance(release.get("size"), int):
                check["size"] = release["size"]
            add(name, check)
    appcast_path = root / "site" / "static" / "appcast.xml"
    if appcast_path.is_file():
        for enclosure in ET.parse(appcast_path).getroot().iter("enclosure"):
            name = site_file_name(enclosure.get("url"), host)
            if name is None:
                continue
            length = enclosure.get("length", "")
            if not length.isdigit():
                raise InputError(f"{name}: appcast enclosure has no length")
            add(name, {"size": int(length)})
    return wanted


def sha256_of(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def problems_of(path: Path, check: dict) -> list[str]:
    problems = []
    if "size" in check and path.stat().st_size != check["size"]:
        problems.append(f"{path.name}: {path.stat().st_size} bytes, expected {check['size']}")
    if "sha256" in check and sha256_of(path) != check["sha256"]:
        problems.append(f"{path.name}: SHA-256 does not match releases.json")
    return problems


def download(name: str, version: str, repo: str, into: Path) -> Path:
    command = ["gh", "release", "download", f"v{version}", "--repo", repo, "--pattern", name, "--dir", str(into)]
    result = subprocess.run(command, capture_output=True, text=True)
    target = into / name
    if result.returncode != 0 or not target.is_file():
        raise RuntimeError(f"{name}: gh release download v{version} failed: {result.stderr.strip()}")
    return target


def fetch(out: Path, wanted: dict[str, dict], repo: str) -> list[str]:
    problems: list[str] = []
    out.mkdir(parents=True, exist_ok=True)
    for name in sorted(wanted):
        check = wanted[name]
        existing = out / name
        if existing.is_file() and not problems_of(existing, check):
            print(f"kept {name}")
            continue
        if not repo:
            problems.append(f"{name}: needs a download but no repository is known (--repo or GITHUB_REPOSITORY)")
            continue
        with tempfile.TemporaryDirectory() as tmp:
            try:
                fetched = download(name, check["version"], repo, Path(tmp))
            except RuntimeError as error:
                problems.append(str(error))
                continue
            found = problems_of(fetched, check)
            if found:
                problems.extend(found)
                continue
            shutil.move(str(fetched), existing)
            print(f"fetched {name}")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Fetch the release files served under https://<site host>/download/.")
    parser.add_argument("--out", required=True)
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", ""))
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--brand-env", default="")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    brand = brand_values(Path(args.brand_env) if args.brand_env else root / "scripts" / "brand.env")
    host, slug = brand.get("APP_SITE_HOST", ""), brand.get("APP_SLUG", "")
    if not host or not slug:
        print("fetch-downloads: APP_SITE_HOST and APP_SLUG must be set in the brand file", file=sys.stderr)
        return 2
    try:
        wanted = wanted_files(root, host, slug)
    except (InputError, json.JSONDecodeError, ET.ParseError, OSError) as error:
        print(f"fetch-downloads: {error}", file=sys.stderr)
        return 2
    problems = fetch(Path(args.out), wanted, args.repo)
    for problem in problems:
        print(f"fetch-downloads: {problem}", file=sys.stderr)
    print(f"fetch-downloads: {len(wanted)} file(s) on the site host, {len(problems)} problem(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
