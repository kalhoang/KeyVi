# SPDX-License-Identifier: LicenseRef-App-Pending
"""Just enough Swift reading for the documentation tests: enum raw values and the issue-block key order.

This is not a Swift parser. It relies on the shapes used in Packages/AppCore/Sources/Diagnostics (one
`list.add(` call per key, `for (name, _) in helper(metrics)` loops for key families) and fails loudly when they
change, so a test that depends on it cannot pass vacuously.
"""
from __future__ import annotations

import re

_COMMENT = re.compile(r"//[^\n]*")


def braced_body(text: str, start: int) -> str:
    """The text between the first `{` at or after `start` and its matching `}`."""
    opening = text.index("{", start)
    depth = 0
    for index in range(opening, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[opening + 1: index]
    raise ValueError("unbalanced braces")


def enum_raw_values(source: str, name: str, inside: str | None = None) -> list[str]:
    """Raw values of `enum <name>` (optionally the one declared inside `struct|enum <inside>`), in order."""
    offset = 0
    if inside is not None:
        container = re.search(rf"\b(?:struct|enum|extension) {re.escape(inside)}\b", source)
        if container is None:
            raise ValueError(f"no type {inside}")
        offset = container.start()
    match = re.compile(rf"\benum {re.escape(name)}\b").search(source, offset)
    if match is None:
        raise ValueError(f"no enum {name}")
    body = _COMMENT.sub("", braced_body(source, match.start()))
    values: list[str] = []
    depth = 0
    for statement in re.split(r"(?=\bcase\b)|([{}])", body):
        if statement in ("{", "}"):
            depth += 1 if statement == "{" else -1
            continue
        if not statement or depth != 0 or not statement.startswith("case "):
            continue
        declaration = re.split(r"\n\s*(?:public|static|var|func|init)\b", statement[5:], maxsplit=1)[0]
        for item in declaration.split(","):
            item = item.strip()
            if not item:
                continue
            raw = re.fullmatch(r'`?(\w+)`?\s*(?:=\s*"([^"]*)")?', item)
            if raw is None:
                raise ValueError(f"unexpected case syntax in enum {name}: {item!r}")
            values.append(raw.group(2) if raw.group(2) is not None else raw.group(1))
    if not values:
        raise ValueError(f"enum {name} has no cases")
    return values


def _function_body(source: str, name: str) -> str:
    match = re.search(rf"static func {re.escape(name)}\(", source)
    if match is None:
        raise ValueError(f"no static func {name}")
    return braced_body(source, match.start())


def _loop_names(fields: str, helper: str) -> list[str]:
    names = re.findall(r'\("(\w+)", metrics\.', _function_body(fields, helper))
    if not names:
        raise ValueError(f"no names in {helper}")
    return names


def _expand_loops(body: str, fields: str) -> str:
    """Rewrites `for (name, _) in helper(metrics) { list.add("a." + name + ".b", ...) }` as literal calls."""
    loop = re.compile(r"for \(name, \w+\) in (\w+)\(metrics\)\s*")
    while (match := loop.search(body)) is not None:
        inner = braced_body(body, match.end() - 1)
        end = body.index(inner, match.end()) + len(inner) + 1
        templates = re.findall(r'list\.add\(\s*"([^"]*)"\s*\+\s*name(?:\s*\+\s*"([^"]*)")?', inner)
        if not templates:
            raise ValueError("a key-family loop without templates")
        calls = [f'list.add("{head}{name}{tail}", x)' for name in _loop_names(fields, match.group(1))
                 for head, tail in templates]
        body = body[: match.start()] + "\n".join(calls) + body[end:]
    return body


def _keys_in(body: str, block_keys: dict[str, str]) -> list[str]:
    keys = []
    for argument in re.findall(r'list\.add\(\s*([^,]+),', body):
        argument = argument.strip()
        if argument.startswith("."):
            keys.append(block_keys[argument[1:]])
        elif re.fullmatch(r'"[^"]+"', argument):
            keys.append(argument[1:-1])
        else:
            raise ValueError(f"unexpected key expression {argument!r}")
    return keys


def always_present_keys(report: str, issue_block: str, fields: str) -> list[str]:
    """Keys the renderer writes for every report, in output order (ADR 0501 rule 6): optional `probe.*` and
    numbered `health.event.NN` lines are left out."""
    enum = _COMMENT.sub("", braced_body(report, report.index("public enum DiagnosticsBlockKey")))
    block_keys = dict(re.findall(r'case (\w+) = "([^"]+)"', enum))
    order = _function_body(issue_block, "fields")
    order = order.split("let budget", 1)[0] + "\n" + re.sub(
        r"for \(offset, event\).*", "", order.split("let budget", 1)[1], flags=re.DOTALL)
    keys: list[str] = []
    for step in re.finditer(r'BlockFields\.(\w+)\(report|list\.add\(\s*"([^"]+)"', order):
        if step.group(1):
            body = _function_body(fields, step.group(1)).split("guard let probe", 1)[0]
            keys += _keys_in(_expand_loops(body, fields), block_keys)
        else:
            keys.append(step.group(2))
    return keys
