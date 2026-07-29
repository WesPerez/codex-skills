#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


ROUTE_PATTERN = re.compile(
    r"(?P<quote>['\"`])(?P<route>/(?:api|user/api|frontend-api|oauth|v1)/[^'\"`\s]{1,240})(?P=quote)"
)
STORAGE_PATTERN = re.compile(
    r"(?P<storage>localStorage|sessionStorage)\s*\.\s*(?:getItem|setItem|removeItem)\s*\(\s*"
    r"(?P<quote>['\"`])(?P<key>[^'\"`]{1,160})(?P=quote)"
)
HEADER_PATTERN = re.compile(
    r"(?P<quote>['\"`])(?P<header>authorization|content-type|new-api-user|x-[a-z0-9-]{2,80})"
    r"(?P=quote)\s*:",
    re.IGNORECASE,
)
HEADER_SET_PATTERN = re.compile(
    r"\.\s*(?:set|append)\s*\(\s*"
    r"(?P<quote>['\"`])(?P<header>authorization|content-type|new-api-user|x-[a-z0-9-]{2,80})"
    r"(?P=quote)\s*,",
    re.IGNORECASE,
)


def location(path: Path, text: str, start: int) -> dict[str, object]:
    line = text.count("\n", 0, start) + 1
    previous_newline = text.rfind("\n", 0, start)
    return {
        "file": str(path),
        "line": line,
        "column": start - previous_newline,
        "character_offset": start,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Extract candidate API routes, storage keys, and header names from local bundles"
    )
    parser.add_argument("paths", nargs="+", type=Path)
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    routes: set[str] = set()
    storage: set[tuple[str, str]] = set()
    headers: set[str] = set()
    scanned: list[str] = []
    artifacts: list[dict[str, object]] = []
    evidence: dict[tuple[str, str, str], dict[str, object]] = {}

    for path in args.paths:
        if not path.is_file():
            raise SystemExit(f"not a file: {path}")
        if path.stat().st_size > 100 * 1024 * 1024:
            raise SystemExit(f"file exceeds 100 MiB limit: {path}")
        raw = path.read_bytes()
        text = raw.decode("utf-8", errors="replace")
        scanned.append(str(path))
        artifacts.append(
            {
                "file": str(path),
                "size": len(raw),
                "sha256": hashlib.sha256(raw).hexdigest(),
            }
        )
        for match in ROUTE_PATTERN.finditer(text):
            route = match.group("route")
            routes.add(route)
            key = ("route", route, str(path))
            evidence.setdefault(
                key,
                {
                    "kind": "route",
                    "value": route,
                    "dynamic": "${" in route,
                    **location(path, text, match.start("route")),
                },
            )
        for match in STORAGE_PATTERN.finditer(text):
            item = (match.group("storage"), match.group("key"))
            storage.add(item)
            key = ("storage_key", f"{item[0]}:{item[1]}", str(path))
            evidence.setdefault(
                key,
                {
                    "kind": "storage_key",
                    "storage": item[0],
                    "value": item[1],
                    **location(path, text, match.start("key")),
                },
            )
        for pattern in (HEADER_PATTERN, HEADER_SET_PATTERN):
            for match in pattern.finditer(text):
                header = match.group("header").lower()
                headers.add(header)
                key = ("header", header, str(path))
                evidence.setdefault(
                    key,
                    {
                        "kind": "header",
                        "value": header,
                        **location(path, text, match.start("header")),
                    },
                )

    print(
        json.dumps(
            {
                "files": scanned,
                "artifacts": artifacts,
                "classification": "candidate",
                "warning": (
                    "Static strings do not prove runtime use, HTTP method, value flow, "
                    "or response semantics. Correlate them with call context or Network evidence."
                ),
                "routes": sorted(routes),
                "storage_keys": [
                    {"storage": item[0], "key": item[1]} for item in sorted(storage)
                ],
                "header_names": sorted(headers),
                "evidence": sorted(
                    evidence.values(),
                    key=lambda item: (
                        str(item["file"]),
                        int(item["line"]),
                        int(item["column"]),
                        str(item["kind"]),
                    ),
                ),
            },
            ensure_ascii=False,
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
