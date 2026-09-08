#!/usr/bin/env python3
"""Parse dumps.yaml (small subset) and print TSV rows.

Columns: container, type, user, database, password_env, command
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def parse_simple_yaml(text: str) -> list[dict[str, str]]:
    dumps: list[dict[str, str]] = []
    current: dict[str, str] | None = None
    seen_dumps_key = False

    for raw in text.splitlines():
        line = raw.split("#", 1)[0].rstrip()
        if not line.strip():
            continue
        stripped = line.strip()
        if stripped == "dumps:":
            seen_dumps_key = True
            continue
        if stripped.startswith("- "):
            if current:
                dumps.append(current)
            current = {}
            rest = stripped[2:].strip()
            if rest and ":" in rest:
                key, value = rest.split(":", 1)
                current[key.strip()] = value.strip().strip("\"'")
            continue
        if current is not None and ":" in stripped:
            key, value = stripped.split(":", 1)
            current[key.strip()] = value.strip().strip("\"'")
            continue
        if not seen_dumps_key:
            continue
        raise ValueError(f"unrecognized dumps.yaml line: {raw!r}")

    if current:
        dumps.append(current)
    return dumps


def main() -> int:
    parser = argparse.ArgumentParser(description="Parse docker-backup dumps.yaml")
    parser.add_argument("--config", required=True, help="path to dumps.yaml")
    args = parser.parse_args()

    path = Path(args.config)
    if not path.is_file():
        return 0

    text = path.read_text(encoding="utf-8")
    try:
        entries = parse_simple_yaml(text)
    except ValueError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    for entry in entries:
        container = entry.get("container", "").strip()
        dump_type = entry.get("type", "").strip()
        if not container or not dump_type:
            print("ERROR: each dumps entry needs container and type", file=sys.stderr)
            return 1
        fields = [
            container,
            dump_type,
            entry.get("user", ""),
            entry.get("database", ""),
            entry.get("password_env", ""),
            entry.get("command", ""),
        ]
        print("\t".join(fields))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
