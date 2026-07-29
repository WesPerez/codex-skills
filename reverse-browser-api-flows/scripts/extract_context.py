#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract bounded source context for exact strings in public frontend artifacts"
    )
    parser.add_argument("paths", nargs="+", type=Path)
    parser.add_argument("--needle", action="append", required=True)
    parser.add_argument("--radius", type=int, default=240)
    parser.add_argument("--max-matches", type=int, default=5)
    return parser.parse_args()


def source_location(text: str, offset: int) -> tuple[int, int]:
    line = text.count("\n", 0, offset) + 1
    previous_newline = text.rfind("\n", 0, offset)
    return line, offset - previous_newline


def main() -> int:
    args = parse_args()
    if not 0 <= args.radius <= 2000:
        raise SystemExit("--radius must be between 0 and 2000")
    if not 1 <= args.max_matches <= 50:
        raise SystemExit("--max-matches must be between 1 and 50")
    if any(not needle or len(needle) > 240 for needle in args.needle):
        raise SystemExit("needles must contain 1 to 240 characters")

    output: list[dict[str, object]] = []
    for path in args.paths:
        if not path.is_file():
            raise SystemExit(f"not a file: {path}")
        if path.stat().st_size > 100 * 1024 * 1024:
            raise SystemExit(f"file exceeds 100 MiB limit: {path}")
        raw = path.read_bytes()
        source = raw.decode("utf-8", errors="replace")
        matches: list[dict[str, object]] = []
        for needle in args.needle:
            start = 0
            for _ in range(args.max_matches):
                offset = source.find(needle, start)
                if offset < 0:
                    break
                line, column = source_location(source, offset)
                left = max(0, offset - args.radius)
                right = min(len(source), offset + len(needle) + args.radius)
                matches.append(
                    {
                        "needle": needle,
                        "line": line,
                        "column": column,
                        "character_offset": offset,
                        "context": source[left:right].replace("\n", " "),
                    }
                )
                start = offset + len(needle)
        output.append(
            {
                "file": str(path),
                "size": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
                "matches": matches,
            }
        )

    print(
        json.dumps(
            {
                "warning": (
                    "Context contains source text. Use this only for public or already-sanitized "
                    "artifacts, and never commit credential-bearing output."
                ),
                "artifacts": output,
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
