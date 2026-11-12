# SPDX-License-Identifier: LicenseRef-App-Pending
"""A small JSON Schema validator (subset of draft 2020-12) using only the standard library.

CI scripts run with `python3 -I` and no third-party packages, so this covers the keywords the
repository schemas use: type, enum, const, required, properties, additionalProperties,
patternProperties, items, prefixItems, minItems, maxItems, uniqueItems, minLength, maxLength,
pattern, minimum, maximum, exclusiveMinimum, exclusiveMaximum, format (date, date-time, uri),
allOf, anyOf, oneOf, not, if/then/else, $ref (local "#/..." pointers and "$defs"), $defs, definitions.
Unknown keywords are ignored, as the specification allows.
"""
from __future__ import annotations

import datetime as _dt
import json
import re
from typing import Any

_TYPES = {
    "object": lambda v: isinstance(v, dict),
    "array": lambda v: isinstance(v, list),
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "number": lambda v: isinstance(v, (int, float)) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def _format_ok(fmt: str, value: str) -> bool:
    try:
        if fmt == "date":
            _dt.date.fromisoformat(value)
            return bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}", value))
        if fmt == "date-time":
            _dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
            return True
        if fmt in ("uri", "url"):
            return bool(re.match(r"^[A-Za-z][A-Za-z0-9+.-]*:", value))
    except ValueError:
        return False
    return True


class Validator:
    def __init__(self, schema: dict[str, Any]):
        self.root = schema

    def resolve(self, ref: str) -> Any:
        if not ref.startswith("#"):
            raise ValueError(f"only local $ref values are supported: {ref}")
        node: Any = self.root
        for part in [p for p in ref[1:].split("/") if p]:
            part = part.replace("~1", "/").replace("~0", "~")
            node = node[int(part)] if isinstance(node, list) else node[part]
        return node

    def errors(self, value: Any, schema: Any = None, path: str = "$") -> list[str]:
        schema = self.root if schema is None else schema
        if schema is True or schema == {}:
            return []
        if schema is False:
            return [f"{path}: not allowed"]
        out: list[str] = []
        if "$ref" in schema:
            out += self.errors(value, self.resolve(schema["$ref"]), path)
        out += self._type_and_values(value, schema, path)
        out += self._combinators(value, schema, path)
        if isinstance(value, dict):
            out += self._object(value, schema, path)
        if isinstance(value, list):
            out += self._array(value, schema, path)
        if isinstance(value, str):
            out += self._string(value, schema, path)
        if _TYPES["number"](value):
            out += self._number(value, schema, path)
        return out

    def _type_and_values(self, value, schema, path):
        out = []
        expected = schema.get("type")
        if expected is not None:
            names = expected if isinstance(expected, list) else [expected]
            if not any(_TYPES[name](value) for name in names):
                out.append(f"{path}: expected {'/'.join(names)}, got {type(value).__name__}")
        if "enum" in schema and value not in schema["enum"]:
            out.append(f"{path}: {json.dumps(value)} is not one of {json.dumps(schema['enum'])}")
        if "const" in schema and value != schema["const"]:
            out.append(f"{path}: must equal {json.dumps(schema['const'])}")
        return out

    def _combinators(self, value, schema, path):
        out = []
        for sub in schema.get("allOf", []):
            out += self.errors(value, sub, path)
        if "anyOf" in schema and not any(not self.errors(value, s, path) for s in schema["anyOf"]):
            out.append(f"{path}: does not match any allowed shape (anyOf)")
        if "oneOf" in schema:
            matches = sum(1 for s in schema["oneOf"] if not self.errors(value, s, path))
            if matches != 1:
                out.append(f"{path}: must match exactly one shape (oneOf), matched {matches}")
        if "not" in schema and not self.errors(value, schema["not"], path):
            out.append(f"{path}: matches a forbidden shape (not)")
        if "if" in schema:
            branch = "then" if not self.errors(value, schema["if"], path) else "else"
            if branch in schema:
                out += self.errors(value, schema[branch], path)
        return out

    def _object(self, value, schema, path):
        out = []
        for key in schema.get("required", []):
            if key not in value:
                out.append(f"{path}: missing required property '{key}'")
        props = schema.get("properties", {})
        patterns = schema.get("patternProperties", {})
        extra = schema.get("additionalProperties", True)
        for key, item in value.items():
            child = f"{path}.{key}"
            matched = False
            if key in props:
                matched = True
                out += self.errors(item, props[key], child)
            for pattern, sub in patterns.items():
                if re.search(pattern, key):
                    matched = True
                    out += self.errors(item, sub, child)
            if not matched:
                if extra is False:
                    out.append(f"{path}: unexpected property '{key}'")
                elif isinstance(extra, dict):
                    out += self.errors(item, extra, child)
        return out

    def _array(self, value, schema, path):
        out = []
        prefix = schema.get("prefixItems", [])
        for index, sub in enumerate(prefix[: len(value)]):
            out += self.errors(value[index], sub, f"{path}[{index}]")
        items = schema.get("items")
        if isinstance(items, dict) or isinstance(items, bool):
            for index in range(len(prefix), len(value)):
                out += self.errors(value[index], items, f"{path}[{index}]")
        if "minItems" in schema and len(value) < schema["minItems"]:
            out.append(f"{path}: needs at least {schema['minItems']} item(s)")
        if "maxItems" in schema and len(value) > schema["maxItems"]:
            out.append(f"{path}: allows at most {schema['maxItems']} item(s)")
        if schema.get("uniqueItems"):
            seen = [json.dumps(v, sort_keys=True) for v in value]
            if len(seen) != len(set(seen)):
                out.append(f"{path}: items must be unique")
        return out

    def _string(self, value, schema, path):
        out = []
        if "minLength" in schema and len(value) < schema["minLength"]:
            out.append(f"{path}: shorter than {schema['minLength']}")
        if "maxLength" in schema and len(value) > schema["maxLength"]:
            out.append(f"{path}: longer than {schema['maxLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            out.append(f"{path}: does not match pattern {schema['pattern']}")
        if "format" in schema and not _format_ok(schema["format"], value):
            out.append(f"{path}: not a valid {schema['format']}")
        return out

    def _number(self, value, schema, path):
        out = []
        if "minimum" in schema and value < schema["minimum"]:
            out.append(f"{path}: below minimum {schema['minimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            out.append(f"{path}: above maximum {schema['maximum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            out.append(f"{path}: must be greater than {schema['exclusiveMinimum']}")
        if "exclusiveMaximum" in schema and value >= schema["exclusiveMaximum"]:
            out.append(f"{path}: must be less than {schema['exclusiveMaximum']}")
        return out


def validate(value: Any, schema: dict[str, Any]) -> list[str]:
    return Validator(schema).errors(value)
