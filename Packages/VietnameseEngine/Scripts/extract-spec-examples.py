# SPDX-License-Identifier: MPL-2.0
"""Extract the worked examples of spec/01-engine.md into test corpus files.

Reads tables 13.8 (W001-W253 with W158a-W158j, W184a-W184c, W242a-W242w and W243a-W243o), 13.9, 13.9.1 and 13.9.2 (B001-B072) and 13.10 (E01-E08, E02b), the fixture
paragraph of 13.9 and the ENG-R821 proposal table, and writes into
Tests/VietnameseEngineTests/Corpus/:

    worked-examples.tsv    13.8, one row per W example (Backspace kept as the "⌫" marker)
    commit-decisions.tsv   13.9, 13.9.1 and 13.9.2, one row per B example
    restore-toggle.tsv     13.10, one row per E example
    commit-fixtures.tsv    the 13.9 fixture lists and the ENG-R821 ambiguity proposals

Values are copied verbatim from the spec (backticks removed). A few columns are derived and say so in
their header comment. Field escapes: "\\t" tab, "\\n" newline, "\\\\" backslash, and "\\s" for a space at
the start or end of a field (so that editors cannot strip it).

Usage (from any directory):
    python3 -I Scripts/extract-spec-examples.py           # write the files
    python3 -I Scripts/extract-spec-examples.py --check   # exit 1 if a committed file differs
    python3 -I Scripts/extract-spec-examples.py --spec PATH
"""
import re
import sys
from pathlib import Path

PACKAGE_DIR = Path(__file__).resolve().parent.parent
DEFAULT_SPEC = PACKAGE_DIR.parent.parent / "spec" / "01-engine.md"
CORPUS_DIR = PACKAGE_DIR / "Tests" / "VietnameseEngineTests" / "Corpus"

BOUNDARY_KEYS = {"Space": " ", "Return": "\n", "Tab": "\t"}
EXPECTED_ROWS = {"worked-examples.tsv": 304, "commit-decisions.tsv": 72, "restore-toggle.tsv": 9}


def fail(message):
    raise SystemExit(f"extract-spec-examples: {message}")


def section(lines, heading):
    """Lines after the heading line that starts with `heading`, up to the next heading of any level."""
    for index, line in enumerate(lines):
        if line.startswith(heading):
            body = []
            for following in lines[index + 1:]:
                if following.startswith("#"):
                    break
                body.append(following)
            return body
    fail(f"heading not found: {heading}")


def table_rows(body, id_pattern):
    rows = []
    for line in body:
        if not line.startswith("| "):
            continue
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if re.fullmatch(id_pattern, cells[0]):
            rows.append(cells)
    return rows


def unquote(cell):
    """Strip one pair of surrounding backticks; the content is kept exactly (spaces included)."""
    if len(cell) >= 2 and cell.startswith("`") and cell.endswith("`") and cell.count("`") == 2:
        return cell[1:-1]
    return cell


def backticked(text):
    return re.findall(r"`([^`]*)`", text)


def escape(value):
    value = value.replace("\\", "\\\\").replace("\t", "\\t").replace("\n", "\\n")
    if value.startswith(" "):
        value = "\\s" + value[1:]
    if value.endswith(" ") and len(value) > 0:
        value = value[:-1] + "\\s"
    return value


def render(comment_lines, header, rows):
    out = [f"# {line}" for line in comment_lines]
    out.append("\t".join(header))
    for row in rows:
        if len(row) != len(header):
            fail(f"row has {len(row)} fields, header {len(header)}: {row}")
        out.append("\t".join(escape(value) for value in row))
    return "\n".join(out) + "\n"


# ---------------------------------------------------------------- 13.8 worked examples

def worked_examples(lines):
    rows = table_rows(section(lines, "### 13.8"), r"W\d{3}[a-z]?")
    result = []
    for cells in rows:
        if len(cells) != 8:
            fail(f"13.8 row with {len(cells)} cells: {cells[0]}")
        number, group, method, style, options, keys, expected, note = cells
        result.append([number, group, method, style, options, unquote(keys), unquote(expected), note])
    return result


# ---------------------------------------------------------------- 13.9 commit decisions

def outcome_of(rule_text):
    tail = rule_text.rsplit(":", 1)[-1].strip()
    if tail.startswith("restore"):
        return "restored"
    if tail.startswith("keep"):
        return "kept"
    if tail.startswith("nothing to decide"):
        return "unchanged"
    return ""


def rule_code_of(rule_text):
    match = re.match(r"(L\d+b?)\b", rule_text)
    if match:
        return match.group(1)
    if rule_text.startswith("raw not English"):
        return "L7"  # same wording as rule L7 in 8.1 and rows B026, B038
    return ""


def commit_decisions(lines):
    result = []
    for cells in table_rows(section(lines, "### 13.9 "), r"B\d{3}"):
        if len(cells) != 7:
            fail(f"13.9 row with {len(cells)} cells: {cells[0]}")
        number, keys, method, previous, context, committed, rule = cells
        committed = unquote(committed)
        result.append([number, unquote(keys), " ", method, previous, context, committed + " ", committed, rule])
    # 13.9.2 (ENG-R823) has the columns of 13.9.1; its keys hold several tokens separated by spaces.
    boundary_rows = table_rows(section(lines, "#### 13.9.1"), r"B\d{3}") + table_rows(
        section(lines, "#### 13.9.2"), r"B\d{3}")
    for cells in boundary_rows:
        if len(cells) != 8:
            fail(f"13.9.1 or 13.9.2 row with {len(cells)} cells: {cells[0]}")
        number, keys, boundary_cell, method, previous, context, after, rule = cells
        boundary = BOUNDARY_KEYS.get(boundary_cell) or unquote(boundary_cell)
        if len(boundary) != 1:
            fail(f"{number}: unknown boundary key {boundary_cell!r}")
        if boundary == "\n":
            quoted = backticked(after)
            if len(quoted) != 1 or not after.endswith("then a new line"):
                fail(f"{number}: cannot read the text after Return: {after!r}")
            expected = quoted[0] + "\n"
        else:
            expected = unquote(after)
        if not expected.endswith(boundary):
            fail(f"{number}: text after the boundary does not end with the boundary key")
        result.append([number, unquote(keys), boundary, method, previous, context, expected, expected[:-1], rule])

    by_id = {}
    rows = []
    for number, keys, boundary, method, previous, context, expected, committed, rule in result:
        code, outcome = rule_code_of(rule), outcome_of(rule)
        same = re.fullmatch(r"same as (B\d{3})", rule)
        if same:
            code, outcome = by_id[same.group(1)]
        if not code or not outcome:
            fail(f"{number}: cannot derive rule code or outcome from {rule!r}")
        by_id[number] = (code, outcome)
        rows.append([number, keys, boundary, method, previous, context, expected, committed, rule, code, outcome])
    return rows


# ---------------------------------------------------------------- 13.10 restore toggle

def split_events(text):
    """Split on ", " outside backticks and parentheses."""
    parts, depth, quoted, current = [], 0, False, ""
    index = 0
    while index < len(text):
        char = text[index]
        if char == "`":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
        if not quoted and depth == 0 and text.startswith(", ", index):
            parts.append(current)
            current = ""
            index += 2
            continue
        current += char
        index += 1
    parts.append(current)
    return [part.strip() for part in parts]


def restore_toggles(lines):
    rows = []
    for cells in table_rows(section(lines, "### 13.10"), r"E\d{2}b?"):
        if len(cells) != 3:
            fail(f"13.10 row with {len(cells)} cells: {cells[0]}")
        number, events_text, result_text = cells
        method = "Telex"
        events = []
        for part in split_events(events_text):
            bare = re.sub(r"\s*\(.*\)$", "", part).strip()
            if bare.startswith("VNI "):
                method = "VNI"
                bare = bare[4:].strip()
            if bare == "toggle":
                events.append("toggle")
            elif bare == "Backspace":
                events.append("backspace")
            elif bare == "space":
                events.append("space")
            elif bare.startswith("`") and bare.endswith("`"):
                keys = unquote(bare)
                if " " in keys or not keys:
                    fail(f"{number}: unexpected keys {keys!r}")
                events.append("keys:" + keys)
            else:
                fail(f"{number}: unknown event {part!r}")
        quoted = backticked(result_text)
        expected_active = quoted[0] if quoted else ""
        last_action = "passThrough" if "passes through" in result_text else "edit"
        rows.append([number, method, " ".join(events), expected_active, last_action, events_text, result_text])
    return rows


# ---------------------------------------------------------------- 13.9 fixtures and ENG-R821

def commit_fixtures(lines):
    body = " ".join(section(lines, "### 13.9 "))
    def listed(pattern):
        match = re.search(pattern, body)
        if not match:
            fail(f"fixture list not found: {pattern}")
        return match.group(1).split()
    rows = []
    for kind, pattern in (
        ("english", r"the English lexicon contains `([^`]*)`"),
        ("techAlways", r"the tech-always list contains `([^`]*)`"),
        ("techCodeOnly", r"the code-only list contains `([^`]*)`"),
        ("unattested", r"every Tier A syllable is attested except `([^`]*)`"),
    ):
        rows += [[kind, word, "", ""] for word in listed(pattern)]
    if "the ambiguity table is the proposal in ENG-R821" not in body:
        fail("13.9 no longer points at the ENG-R821 proposal")

    start = next(i for i, line in enumerate(lines) if line.startswith("- **ENG-R821"))
    for line in lines[start + 1:]:
        stripped = line.strip()
        if not stripped:
            continue
        if not stripped.startswith("|"):
            break
        cells = [cell.strip() for cell in stripped.strip("|").split("|")]
        if cells[0] in ("Raw", "---") or set(cells[0]) <= {"-"}:
            continue
        raws = [raw.strip() for raw in cells[0].split(",")]
        displays = [display.strip() for display in cells[1].split(",")]
        if len(raws) != len(displays) or cells[2] not in ("vi", "en"):
            fail(f"ENG-R821 row not understood: {stripped}")
        rows += [["ambiguity", raw, display, cells[2]] for raw, display in zip(raws, displays)]
    return rows


# ---------------------------------------------------------------- main

def build(spec_path):
    lines = spec_path.read_text(encoding="utf-8").splitlines()
    source = "spec/01-engine.md"
    files = {
        "worked-examples.tsv": render(
            [f"Generated by Scripts/extract-spec-examples.py from {source} section 13.8. Do not edit.",
             "keys: typed in order, \"⌫\" is Backspace. expected: display after the last key, before any boundary."],
            ["id", "group", "method", "style", "options", "keys", "expected", "note"],
            worked_examples(lines)),
        "commit-decisions.tsv": render(
            [f"Generated by Scripts/extract-spec-examples.py from {source} sections 13.9, 13.9.1 and 13.9.2. Do not edit.",
             "boundary: the boundary key (13.9 rows use Space). expected_text: text after the boundary key.",
             "Derived columns: committed = expected_text without the boundary key; rule_code = the L rule named",
             "by rule_text (\"raw not English\" = L7, \"same as Bnnn\" = that row); outcome = kept, restored or",
             "unchanged, read from the end of rule_text."],
            ["id", "keys", "boundary", "method", "previous", "context", "expected_text", "committed", "rule_text",
             "rule_code", "outcome"],
            commit_decisions(lines)),
        "restore-toggle.tsv": render(
            [f"Generated by Scripts/extract-spec-examples.py from {source} section 13.10. Do not edit.",
             "Derived columns: events = space-separated keys:<typed keys> | space | backspace | toggle;",
             "expected_active = first backticked text of the result (the active token's display, empty when none);",
             "last_action = passThrough when the result says the toggle passes through, otherwise edit."],
            ["id", "method", "events", "expected_active", "last_action", "events_text", "result_text"],
            restore_toggles(lines)),
        "commit-fixtures.tsv": render(
            [f"Generated by Scripts/extract-spec-examples.py from {source} section 13.9 (fixture lists) and",
             "ENG-R821 (ambiguity proposals). kind: english | techAlways | techCodeOnly | unattested | ambiguity."],
            ["kind", "value", "display", "decision"],
            commit_fixtures(lines)),
    }
    for name, expected in EXPECTED_ROWS.items():
        count = sum(1 for line in files[name].splitlines()[1:] if not line.startswith("#")) - 1
        if count != expected:
            fail(f"{name}: {count} rows, expected {expected}")
    return files


def main(argv):
    spec_path = DEFAULT_SPEC
    if "--spec" in argv:
        spec_path = Path(argv[argv.index("--spec") + 1])
    files = build(spec_path)
    if "--check" in argv:
        stale = [name for name, text in files.items()
                 if not (CORPUS_DIR / name).exists() or (CORPUS_DIR / name).read_text(encoding="utf-8") != text]
        if stale:
            print("out of date: " + ", ".join(stale) + "; run Scripts/extract-spec-examples.py", file=sys.stderr)
            return 1
        print("spec example files are up to date")
        return 0
    CORPUS_DIR.mkdir(parents=True, exist_ok=True)
    for name, text in files.items():
        (CORPUS_DIR / name).write_text(text, encoding="utf-8", newline="\n")
        print(f"wrote {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
