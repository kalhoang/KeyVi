#!/usr/bin/env -S python3 -I
# SPDX-License-Identifier: GPL-3.0-or-later
"""Documentation lints (QA-R66, CLAUDE.md "Name").

  links  every relative Markdown link in docs/ and in the Markdown files of the front door resolves: the
         file or directory exists, and a #fragment names a heading (GitHub slug rules) or an explicit anchor
         of the target Markdown file. Absolute URLs, mail links and template links ({{...}}) are skipped.
  brand  docs/ (except docs/decisions/, the historical records) contains no literal display name, slug,
         bundle ID or site host from scripts/brand.env: it says {{AppName}} and {{app-slug}}, so a rename
         needs no change there. The front door (FRONT_DOOR: the files GitHub or the DMG shows exactly as they
         are, so nothing fills a placeholder in) is the reverse: it contains no {{...}} placeholder and writes
         the literal values, which scripts/rename-app.sh rewrites on a rename (ADR 0400 decision 1, amended
         2026-11-13).

Fenced code blocks and inline code are ignored by `links`; `brand` checks them too (a command line with
the literal name would break after a rename, and a placeholder in code is shown as it is).

Usage: python3 -I scripts/check-docs.py links|brand [--root DIR] [--brand-env FILE]
Exit status: 0 clean, 1 findings.
"""
from __future__ import annotations

import argparse
import fnmatch
import os
import re
import subprocess
import sys
import unicodedata
from pathlib import Path
from urllib.parse import unquote

REPO_ROOT = Path(__file__).resolve().parents[1]
# The front door: files GitHub (or the DMG, which copies THIRD_PARTY_NOTICES.md) shows exactly as they are. Every
# root-level Markdown file, the pull request template and the issue forms. `*` never crosses a `/`.
FRONT_DOOR = ("*.md", ".github/*.md", ".github/ISSUE_TEMPLATE/*")
# Not in the front door yet: CHANGELOG.md still says {{AppName}} (the site build fills it in for its changelog page).
FRONT_DOOR_PENDING = frozenset({"CHANGELOG.md"})
PLACEHOLDER = re.compile(r"(?<!\$)\{\{\s*[A-Za-z][\w-]*\s*\}\}")
INLINE_LINK = re.compile(r"!?\[(?:[^\[\]]|\[[^\]]*\])*\]\(\s*(<[^>]+>|[^)\s]+)(?:\s+(?:\"[^\"]*\"|'[^']*'))?\s*\)")
# Footnote definitions ("[^1]: text") are not link definitions; their text is no target.
REFERENCE_DEF = re.compile(r"^\s{0,3}\[(?!\^)[^\]]+\]:\s*(<[^>]+>|\S+)")
HEADING = re.compile(r"^\s{0,3}(#{1,6})\s+(.*?)\s*#*\s*$")
HTML_ANCHOR = re.compile(r"<a\s+[^>]*(?:id|name)=\"([^\"]+)\"", re.I)
FENCE = re.compile(r"^\s{0,3}(`{3,}|~{3,})")
SCHEME = re.compile(r"^[A-Za-z][A-Za-z0-9+.-]*:")


def listed_files(root: Path) -> list[str]:
    """Repository-relative POSIX paths of the tracked and untracked, not ignored files."""
    try:
        listed = subprocess.run(["git", "-C", str(root), "ls-files", "--cached", "--others", "--exclude-standard"],
                                capture_output=True, text=True, check=True).stdout.splitlines()
    except (OSError, subprocess.CalledProcessError):
        listed = [p.relative_to(root).as_posix() for p in root.rglob("*") if ".git" not in p.parts]
    return sorted(set(listed))


def in_docs(rel: str, include_decisions: bool) -> bool:
    if not (rel.startswith("docs/") and rel.endswith(".md")):
        return False
    return include_decisions or not rel.startswith("docs/decisions/")


def in_front_door(rel: str) -> bool:
    parts = rel.split("/")
    return rel not in FRONT_DOOR_PENDING and any(
        len(parts) == len(pattern.split("/"))
        and all(fnmatch.fnmatchcase(part, glob) for part, glob in zip(parts, pattern.split("/")))
        for pattern in FRONT_DOOR)


def in_link_scope(rel: str) -> bool:
    return in_docs(rel, include_decisions=True) or (in_front_door(rel) and rel.endswith(".md"))


def select(root: Path, files: list[str], keep) -> list[Path]:
    return [root / rel for rel in files if keep(rel) and (root / rel).is_file()]


def prose_lines(text: str):
    """Yields (line number, line) outside fenced code blocks, with inline code spans blanked."""
    fence = None
    for number, line in enumerate(text.splitlines(), 1):
        match = FENCE.match(line)
        if match:
            marker = match.group(1)[0]
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
            continue
        if fence is None:
            yield number, re.sub(r"`+[^`]*`+", lambda m: " " * len(m.group(0)), line)


def github_slug(heading: str) -> str:
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", heading)  # links keep their text
    text = re.sub(r"<[^>]+>", "", text).lower()
    kept = []
    for ch in text:
        category = unicodedata.category(ch)
        if ch in " -_" or category[0] in "LNM":
            kept.append(ch)
    return "".join(kept).replace(" ", "-")


def anchors_of(path: Path, cache: dict[Path, set[str]]) -> set[str]:
    if path not in cache:
        found: set[str] = set()
        counts: dict[str, int] = {}
        text = path.read_text(encoding="utf-8", errors="replace")
        for _, line in prose_lines(text):
            found.update(HTML_ANCHOR.findall(line))
        for line in text.splitlines():
            match = HEADING.match(line)
            if not match:
                continue
            slug = github_slug(match.group(2))
            suffix = counts.get(slug, 0)
            counts[slug] = suffix + 1
            found.add(slug if suffix == 0 else f"{slug}-{suffix}")
        cache[path] = found
    return cache[path]


def link_targets(text: str):
    for number, line in prose_lines(text):
        for match in INLINE_LINK.finditer(line):
            yield number, match.group(1)
        ref = REFERENCE_DEF.match(line)
        if ref:
            yield number, ref.group(1)


def check_links(root: Path) -> list[str]:
    problems = []
    cache: dict[Path, set[str]] = {}
    for path in select(root, listed_files(root), in_link_scope):
        rel = path.relative_to(root)
        for number, raw in link_targets(path.read_text(encoding="utf-8", errors="replace")):
            target = raw[1:-1] if raw.startswith("<") else raw
            if SCHEME.match(target) or target.startswith("//") or "{{" in target:
                continue
            file_part, _, fragment = target.partition("#")
            resolved = path if file_part == "" else (path.parent / unquote(file_part.split("?")[0])).resolve()
            if not resolved.exists():
                problems.append(f"{rel}:{number}: link target not found: {target}")
                continue
            if fragment and resolved.is_file() and resolved.suffix == ".md":
                if unquote(fragment) not in anchors_of(resolved, cache):
                    problems.append(f"{rel}:{number}: no heading or anchor #{fragment} in {os.path.relpath(resolved, root)}")
    return problems


def brand_values(env_file: Path) -> dict[str, str]:
    values = {}
    for line in env_file.read_text(encoding="utf-8").splitlines():
        match = re.match(r'^\s*(APP_[A-Z_]+)="?(.*?)"?\s*$', line)
        if match and not line.lstrip().startswith("#"):
            values[match.group(1)] = match.group(2)
    return values


def check_brand(root: Path, env_file: Path) -> list[str]:
    values = brand_values(env_file)
    patterns = []
    for key, label in (("APP_BUNDLE_ID_DEV", "bundle ID"), ("APP_BUNDLE_ID_RELEASE", "bundle ID"),
                       ("APP_SITE_HOST", "site host"), ("APP_DISPLAY_NAME", "display name ({{AppName}})")):
        if values.get(key):
            patterns.append((re.compile(re.escape(values[key])), label))
    if values.get("APP_SLUG"):
        slug = re.escape(values["APP_SLUG"])
        patterns.append((re.compile(r"(?<![A-Za-z0-9_])" + slug + r"(?![A-Za-z0-9_])"), "slug ({{app-slug}})"))
    problems = []
    files = listed_files(root)
    for path in select(root, files, lambda rel: in_docs(rel, include_decisions=False)):
        rel = path.relative_to(root)
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for pattern, label in patterns:
                match = pattern.search(line)
                if match:
                    problems.append(f"{rel}:{number}: literal {label} {match.group(0)!r}; use the placeholder")
                    break
    for path in select(root, files, in_front_door):
        rel = path.relative_to(root)
        for number, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            for match in PLACEHOLDER.finditer(line):
                problems.append(f"{rel}:{number}: placeholder {match.group(0)} is shown as it is here (front door); "
                                "write the literal value from scripts/brand.env")
    return problems


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Documentation lints: relative links, brand values.")
    parser.add_argument("check", choices=["links", "brand"])
    parser.add_argument("--root", default=str(REPO_ROOT))
    parser.add_argument("--brand-env", default="", help="default: <root>/scripts/brand.env")
    args = parser.parse_args(argv)
    root = Path(args.root).resolve()
    if args.check == "links":
        problems = check_links(root)
    else:
        problems = check_brand(root, Path(args.brand_env) if args.brand_env else root / "scripts" / "brand.env")
    for problem in problems:
        print(f"check-docs {args.check}: {problem}", file=sys.stderr)
    print(f"check-docs {args.check}: {len(problems)} problem(s)", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
