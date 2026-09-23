"""Bound values and qmark translation; values are never interpolated into SQL."""
import math
from collections.abc import Sequence
from .vector import Vector

Value = str | int | float | Vector | None


def encode(value: Value) -> dict:
    if isinstance(value, Vector):
        return {"kind": "vector", "vector": list(value)}
    if value is None:
        return {"kind": "null"}
    if isinstance(value, int):
        if not -(2**63) <= value < 2**63:
            raise ValueError("Integers must fit SQLite's signed 64-bit range")
        return {"kind": "integer", "integer": int(value)}
    if isinstance(value, float):
        if not math.isfinite(value):
            raise ValueError("Floating-point parameters must be finite")
        return {"kind": "real", "real": value}
    if isinstance(value, str):
        if len(value.encode('utf-8')) > 256:
            raise ValueError("Text parameters are limited to 256 UTF-8 bytes")
        return {"kind": "text", "text": value}
    raise TypeError("Parameters support str, int, float, Vector, and None")


def prepare(sql: str, parameters: Sequence[Value], offset: int = 0) -> tuple[str, tuple[Value, ...]]:
    if not isinstance(sql, str) or not sql.strip() or '\x00' in sql:
        raise ValueError("SQL must be a nonempty string without NUL")
    if isinstance(parameters, (str, bytes, dict)):
        raise TypeError("Parameters must be a sequence of values")
    values = tuple(parameters)
    if offset + len(values) > 16:
        raise ValueError("A request supports at most 16 parameters")
    if sum(len(v) for v in values if isinstance(v, Vector)) > 384:
        raise ValueError("A request supports at most 384 vector components in total")
    for value in values:
        encode(value)
    # SQLite lexical quoting and comments; reject numbered/named bindings so a
    # batch can assign one unambiguous global parameter tuple to all statements.
    out, count, i = [], 0, 0
    while i < len(sql):
        char = sql[i]
        if sql.startswith('--', i):
            end = sql.find('\n', i)
            end = len(sql) if end == -1 else end
        elif sql.startswith('/*', i):
            end = sql.find('*/', i + 2)
            if end == -1:
                raise ValueError("Unterminated SQL comment")
            end += 2
        elif char in "'\"`[":
            closing = ']' if char == '[' else char
            end = i + 1
            while end < len(sql):
                if sql[end] == closing:
                    end += 1
                    if closing != ']' and end < len(sql) and sql[end] == closing:
                        end += 1
                        continue
                    break
                end += 1
            else:
                raise ValueError("Unterminated SQL quote")
        else:
            if char == '?':
                if i + 1 < len(sql) and sql[i + 1].isdigit():
                    raise ValueError("Use plain ? placeholders, not numbered parameters")
                count += 1
                out.append(f'?{offset + count}')
            elif char in ':@$':
                raise ValueError("Use plain ? placeholders, not named parameters")
            else:
                out.append(char)
            i += 1
            continue
        out.append(sql[i:end])
        i = end
    if count != len(values):
        raise ValueError(f"SQL has {count} placeholders but received {len(values)} parameters")
    text = ''.join(out)
    if len(text.encode('utf-8')) > 4096:
        raise ValueError("A SQL request is limited to 4096 UTF-8 bytes")
    return text, values
