#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import Any


ALLOWED_STATUSES = {"observed", "correlated", "candidate", "unknown"}
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify that every non-unknown evidence claim cites exact local artifact bytes"
    )
    parser.add_argument("report", type=Path)
    return parser.parse_args()


def fail(message: str) -> None:
    raise SystemExit(f"invalid evidence report: {message}")


def load_report(path: Path) -> dict[str, Any]:
    if not path.is_file():
        fail(f"not a file: {path}")
    if path.stat().st_size > 1024 * 1024:
        fail("report exceeds 1 MiB")
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"could not parse JSON: {type(exc).__name__}")
    if not isinstance(payload, dict):
        fail("root must be an object")
    return payload


def verify_evidence_item(item: Any, claim_index: int, evidence_index: int) -> None:
    prefix = f"claims[{claim_index}].evidence[{evidence_index}]"
    if not isinstance(item, dict):
        fail(f"{prefix} must be an object")

    file_value = item.get("file")
    digest = item.get("sha256")
    needle = item.get("needle")
    if not isinstance(file_value, str) or not file_value:
        fail(f"{prefix}.file is required")
    if not isinstance(digest, str) or not SHA256_PATTERN.fullmatch(digest):
        fail(f"{prefix}.sha256 must be a lowercase SHA-256")
    if not isinstance(needle, str) or not needle or len(needle) > 500:
        fail(f"{prefix}.needle must contain 1 to 500 characters")

    path = Path(file_value)
    if not path.is_file():
        fail(f"{prefix}.file does not exist")
    if path.stat().st_size > 100 * 1024 * 1024:
        fail(f"{prefix}.file exceeds 100 MiB")
    raw = path.read_bytes()
    if hashlib.sha256(raw).hexdigest() != digest:
        fail(f"{prefix}.sha256 does not match the artifact")
    source = raw.decode("utf-8", errors="replace")

    expected_offsets: list[int] = []
    offset = item.get("character_offset")
    if offset is not None:
        if not isinstance(offset, int) or offset < 0:
            fail(f"{prefix}.character_offset must be a non-negative integer")
        expected_offsets.append(offset)

    line = item.get("line")
    column = item.get("column")
    if line is not None or column is not None:
        if not isinstance(line, int) or line < 1:
            fail(f"{prefix}.line must be a positive integer")
        if not isinstance(column, int) or column < 1:
            fail(f"{prefix}.column must be a positive integer")
        lines = source.splitlines(keepends=True)
        if line > len(lines):
            fail(f"{prefix}.line is outside the artifact")
        line_text = lines[line - 1]
        if column > len(line_text) + 1:
            fail(f"{prefix}.column is outside the cited line")
        expected_offsets.append(sum(len(part) for part in lines[: line - 1]) + column - 1)

    if not expected_offsets:
        fail(f"{prefix} needs character_offset or line plus column")
    if len(set(expected_offsets)) != 1:
        fail(f"{prefix} location fields disagree")
    cited_offset = expected_offsets[0]
    if not source.startswith(needle, cited_offset):
        fail(f"{prefix}.needle is not present at the cited location")


def main() -> int:
    args = parse_args()
    payload = load_report(args.report)
    claims = payload.get("claims")
    if not isinstance(claims, list) or not claims:
        fail("claims must be a non-empty list")

    evidence_count = 0
    for claim_index, claim in enumerate(claims):
        if not isinstance(claim, dict):
            fail(f"claims[{claim_index}] must be an object")
        name = claim.get("claim")
        status = claim.get("status")
        evidence = claim.get("evidence", [])
        if not isinstance(name, str) or not name:
            fail(f"claims[{claim_index}].claim is required")
        if status not in ALLOWED_STATUSES:
            fail(f"claims[{claim_index}].status is invalid")
        if not isinstance(evidence, list):
            fail(f"claims[{claim_index}].evidence must be a list")
        if status == "unknown" and evidence:
            fail(f"claims[{claim_index}] is unknown but includes evidence")
        if status == "unknown" and claim.get("value") is not None:
            fail(f"claims[{claim_index}] is unknown but has a value")
        if status != "unknown" and not evidence:
            fail(f"claims[{claim_index}] needs evidence")
        literal_values: list[str] = []
        value = claim.get("value")
        if isinstance(value, str) and value:
            literal_values = [value]
        elif isinstance(value, list) and all(isinstance(item, str) and item for item in value):
            literal_values = value
        if status in {"observed", "candidate"} and not literal_values:
            fail(f"claims[{claim_index}] needs a non-empty literal value")
        cited_needles = [
            item.get("needle") for item in evidence if isinstance(item, dict)
        ]
        if status in {"observed", "candidate"}:
            for literal in literal_values:
                if not any(literal in needle for needle in cited_needles if isinstance(needle, str)):
                    fail(
                        f"claims[{claim_index}].value is not literal in any evidence needle; "
                        "use correlated for derived values"
                    )
        for evidence_index, item in enumerate(evidence):
            verify_evidence_item(item, claim_index, evidence_index)
            evidence_count += 1

    report_digest = hashlib.sha256(args.report.read_bytes()).hexdigest()
    print(
        json.dumps(
            {
                "valid": True,
                "claims": len(claims),
                "evidence_items": evidence_count,
                "report_sha256": report_digest,
            },
            separators=(",", ":"),
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
