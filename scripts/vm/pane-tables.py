#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Reads the System Settings (macOS 13 and later) or System Preferences (macOS 12) pane names, and Terminal's
Secure Keyboard Entry menu item, from Apple's localization tables of a macOS system volume, in English and
Vietnamese, and compares them with the App/Resources/SystemPanes.json entry for that macOS version (PLT-R704,
PRD-R64, PLT-R398C, ADR 0315; docs/runbooks/vm-test-lab.md section 10).

Read-only: it opens files under ROOT and runs `plutil` to decode old-style .strings files, nothing else. ROOT is a
system volume mounted read-only from a throwaway clone of a lab VM (section 10.2), or / for the running system.
The tables say how macOS spells a name; whether the pane shows it is the on-screen check of scripts/vm/pane-names.sh.

Usage: python3 -I scripts/vm/pane-tables.py [--root DIR] [--check SystemPanes.json]
Exit status: 0 every compared name matches, 1 a name differs or was not found, 2 usage error.
"""

import argparse
import json
import plistlib
import subprocess
import sys
from pathlib import Path

PANES = "System/Library/PreferencePanes"
EXTENSIONS = "System/Library/ExtensionKit/Extensions"
TERMINAL = "System/Applications/Utilities/Terminal.app"

# name -> (bundle, table, key). macOS 12 keeps .strings files per language; a key with an object ID is a label of
# a compiled nib whose English text stays in Base.lproj (only the Vietnamese side is read). IDs are those of 12.7.6.
LEGACY = {
    "systemSettings": ("System/Applications/System Preferences.app", "InfoPlist.strings", "CFBundleName"),
    "privacySecurity.pane": (f"{PANES}/Security.prefPane", "InfoPlist.strings", "NSPrefPaneIconLabel"),
    "privacySecurity.bundleName": (f"{PANES}/Security.prefPane", "InfoPlist.strings", "CFBundleName"),
    "privacySecurity.tab": (f"{PANES}/Security.prefPane", "SecurityPref.strings", "201924.label"),
    "accessibility": (f"{PANES}/Security.prefPane", "Localizable.strings", "ACCESSIBILITY"),
    "inputMonitoring": (f"{PANES}/Security.prefPane", "Localizable.strings", "LISTEN_EVENT"),
    "keyboard": (f"{PANES}/Keyboard.prefPane", "InfoPlist.strings", "CFBundleName"),
    "textReplacements": (f"{PANES}/Keyboard.prefPane/Contents/Resources/IntlTexts.prefPane", "InfoPlist.strings",
                         "CFBundleName"),
    "usersGroups": (f"{PANES}/Accounts.prefPane", "InfoPlist.strings", "CFBundleName"),
    "loginItems": (f"{PANES}/Accounts.prefPane", "AccountsPref.strings", "122.label"),
    "terminal.secureKeyboardEntry": (TERMINAL, "MainMenu.strings", "511.title"),
}
# From macOS 13 every language sits in one .loctable per table (a binary property list keyed by language).
MODERN = {
    "systemSettings": ("System/Applications/System Settings.app", "InfoPlist.loctable", "CFBundleDisplayName"),
    "privacySecurity": (f"{EXTENSIONS}/SecurityPrivacyExtension.appex", "InfoPlist.loctable", "CFBundleDisplayName"),
    "accessibility": (f"{EXTENSIONS}/SecurityPrivacyExtension.appex", "Localizable.loctable", "ACCESSIBILITY"),
    "inputMonitoring": (f"{EXTENSIONS}/SecurityPrivacyExtension.appex", "Localizable.loctable", "LISTEN_EVENT"),
    "keyboard": (f"{EXTENSIONS}/KeyboardSettings.appex", "InfoPlist.loctable", "CFBundleDisplayName"),
    "textReplacements": (f"{EXTENSIONS}/KeyboardSettings.appex", "Localizable.loctable", "Text Replacements…"),
    "usersGroups": (f"{EXTENSIONS}/GeneralSettings.appex", "InfoPlist.loctable", "CFBundleDisplayName"),
    "loginItems": (f"{EXTENSIONS}/LoginItems.appex", "Localizable.loctable", "Login Items & Extensions"),
    "terminal.secureKeyboardEntry": (TERMINAL, "MainMenu.loctable", "511.title"),
}
LANGUAGES = ("en", "vi")


def read_strings(path: Path) -> dict:
    """An old-style .strings file, decoded by plutil (binary output: some values hold control characters)."""
    if not path.is_file():
        return {}
    result = subprocess.run(["plutil", "-convert", "binary1", "-o", "-", str(path)], capture_output=True, check=False)
    return plistlib.loads(result.stdout) if result.returncode == 0 else {}


def lookup(root: Path, bundle: str, table: str, key: str, language: str) -> str | None:
    resources = root / bundle / "Contents" / "Resources"
    if table.endswith(".loctable"):
        path = resources / table
        if not path.is_file():
            return None
        tables = plistlib.loads(path.read_bytes())
        for name in ((language,) if language != "en" else ("en", "en_US", "en_GB")):
            if key in tables.get(name, {}):
                return tables[name][key]
        # English is the development language: an English source key is its own text.
        return key if language == "en" and " " in key else None
    folders = (f"{language}.lproj",) if language != "en" else ("en.lproj", "English.lproj")
    for folder in folders:
        value = read_strings(resources / folder / table).get(key)
        if value is not None:
            return value
    return None


def system_version(root: Path) -> tuple[str, str]:
    info = plistlib.loads((root / "System/Library/CoreServices/SystemVersion.plist").read_bytes())
    return info["ProductVersion"], info["ProductBuildVersion"]


def version_tuple(text: str) -> tuple[int, int, int]:
    parts = [int(p) for p in text.split(".")[:3]]
    return tuple(parts + [0] * (3 - len(parts)))  # type: ignore[return-value]


def entry_for(table: dict, version: str) -> dict:
    """The entry SystemPaneTable picks: the range that contains the version, else the nearest older, else the first."""
    target = version_tuple(version)
    entries = table["entries"]
    for entry in entries:
        high = entry["macOS"].get("max")
        if version_tuple(entry["macOS"]["min"]) <= target and (high is None or target <= version_tuple(high)):
            return entry
    older = [e for e in entries if e["macOS"].get("max") and version_tuple(e["macOS"]["max"]) < target]
    return max(older, key=lambda e: version_tuple(e["macOS"]["max"])) if older else entries[0]


def expected(entry: dict, name: str, language: str, legacy: bool) -> str | None:
    """The SystemPanes.json value a table name is compared with (None: not compared)."""
    names = entry["names"].get(language, {})
    if legacy and name.startswith("privacySecurity."):
        pane, _, tab = names.get("privacySecurity", "").partition(" > ")
        return {"privacySecurity.pane": pane, "privacySecurity.tab": tab}.get(name)
    return names.get(name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--root", default="/", help="mounted macOS system volume (default /)")
    parser.add_argument("--check", help="SystemPanes.json to compare with")
    args = parser.parse_args()
    root = Path(args.root)
    try:
        version, build = system_version(root)
    except (OSError, KeyError, plistlib.InvalidFileException) as error:
        print(f"pane-tables: not a macOS system volume: {root} ({error})", file=sys.stderr)
        return 2
    legacy = (root / LEGACY["systemSettings"][0]).is_dir()
    entry = entry_for(json.loads(Path(args.check).read_text(encoding="utf-8")), version) if args.check else None
    print(f"macOS {version} ({build}) at {root}, {'System Preferences' if legacy else 'System Settings'} tables")
    status = 0
    for name, (bundle, table, key) in (LEGACY if legacy else MODERN).items():
        for language in LANGUAGES:
            value = lookup(root, bundle, table, key, language)
            shown = None if value is None else " ".join(value.split())
            want = expected(entry, name, language, legacy) if entry else None
            if value is None:
                verdict = "NOT FOUND" if language == "vi" or "." not in key else "base nib (not in the tables)"
                status = status or (1 if verdict == "NOT FOUND" else 0)
            elif want is None:
                verdict = "read"
            elif shown == want:
                verdict = "MATCH"
            elif shown.rstrip("…").rstrip(".") == want:
                # A button that opens a sheet ends in an ellipsis; copy quotes the name without it.
                verdict = "MATCH (without the button's ellipsis)"
            else:
                verdict = f"DIFF (SystemPanes.json: {want!r})"
                status = 1
            print(f"{name}\t{language}\t{shown!r}\t{verdict}\t{bundle.rsplit('/', 1)[-1]}/{table}:{key}")
    return status


if __name__ == "__main__":
    sys.exit(main())
