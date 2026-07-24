#!/usr/bin/env python3
"""Read-only, secret-safe aggregation for Nginx/V2Ray WS evidence."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import math
import os
import re
import sys
from pathlib import Path
from typing import Any, Iterable


SCHEMA = "proxy443-ws-evidence.v1"
NGINX_TS = re.compile(r"\[([^\]]+)\]")
ERROR_TS = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})")
ISO_TS = re.compile(r"\b(\d{4}-\d{2}-\d{2}T[^\s]+)")
KV_STATUS = re.compile(r"\bstatus=(\d{3})\b", re.I)
KV_DURATION = re.compile(
    r"\b(?:duration|request_time|upstream_response_time)=(\d+(?:\.\d+)?)(ms|s)?\b",
    re.I,
)
COMBINED = re.compile(
    r'^\s*(?P<source>\S+)\s+\S+\s+\S+\s+\[(?P<ts>[^\]]+)\]\s+"(?P<request>[^"]*)"\s+(?P<status>\d{3})\b'
)
UUID_RE = re.compile(
    r"(?i)\b[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\b"
)
LONG_HEX_RE = re.compile(r"(?i)\b[0-9a-f]{32,}\b")
SENSITIVE_NAME_RE = re.compile(r"(?i)(?:token|secret|password|passwd|api[_-]?key|uuid)[^/]*")
LONG_TOKEN_RE = re.compile(r"(?i)\b[A-Za-z0-9_-]{40,}\b")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Aggregate redacted WS access/error evidence without changing the host."
    )
    parser.add_argument("--access-log", action="append", default=[])
    parser.add_argument("--error-log", action="append", default=[])
    parser.add_argument("--ss-file")
    parser.add_argument("--backend-port", type=int)
    parser.add_argument("--since", help="ISO-8601 timestamp or epoch seconds")
    parser.add_argument("--until", help="ISO-8601 timestamp or epoch seconds")
    parser.add_argument("--max-bytes", type=int, default=32 * 1024 * 1024)
    parser.add_argument("--max-lines", type=int, default=200_000)
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        if re.fullmatch(r"\d+(?:\.\d+)?", value):
            return dt.datetime.fromtimestamp(float(value), tz=dt.timezone.utc)
        normalized = value.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(normalized)
        if parsed.tzinfo is None:
            parsed = parsed.replace(tzinfo=dt.timezone.utc)
        return parsed
    except ValueError as exc:
        raise ValueError(f"invalid timestamp: {value}") from exc


def parse_log_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    for fmt in ("%d/%b/%Y:%H:%M:%S %z", "%Y-%m-%dT%H:%M:%S%z", "%Y/%m/%d %H:%M:%S"):
        try:
            parsed = dt.datetime.strptime(value, fmt)
            return parsed if parsed.tzinfo else parsed.replace(tzinfo=dt.timezone.utc)
        except ValueError:
            pass
    try:
        return parse_time(value)
    except ValueError:
        return None


def timestamp_text_from_line(line: str) -> str | None:
    for pattern in (ISO_TS, ERROR_TS):
        match = pattern.search(line)
        if match and parse_log_time(match.group(1)) is not None:
            return match.group(1)
    for match in NGINX_TS.finditer(line):
        if parse_log_time(match.group(1)) is not None:
            return match.group(1)
    return None


def in_window(timestamp: dt.datetime | None, since: dt.datetime | None, until: dt.datetime | None) -> bool:
    if timestamp is None:
        return True
    if since and timestamp < since:
        return False
    if until and timestamp > until:
        return False
    return True


def read_tail(path: str, max_bytes: int, max_lines: int) -> tuple[list[str], bool, str | None]:
    try:
        size = os.path.getsize(path)
        truncated = size > max_bytes
        with open(path, "rb") as handle:
            if truncated:
                handle.seek(-max_bytes, os.SEEK_END)
            data = handle.read(max_bytes)
        lines = data.decode("utf-8", errors="replace").splitlines()
        if len(lines) > max_lines:
            lines = lines[-max_lines:]
            truncated = True
        return lines, truncated, None
    except OSError as exc:
        return [], False, f"cannot read input: {exc.__class__.__name__}"


def display_path(path: str) -> dict[str, str]:
    # Keep correlation without exposing a token-bearing directory name.
    safe_name = UUID_RE.sub("<uuid>", Path(path).name)
    safe_name = LONG_HEX_RE.sub("<hex>", safe_name)
    safe_name = SENSITIVE_NAME_RE.sub("<sensitive>", safe_name)
    safe_name = LONG_TOKEN_RE.sub("<token>", safe_name)
    digest = hashlib.sha256(os.fsencode(path)).hexdigest()[:16]
    return {"name": safe_name, "sha256": digest}


def fingerprint(value: str, salt: bytes) -> str:
    return hashlib.sha256(salt + value.encode("utf-8", errors="replace")).hexdigest()[:12]


def parse_duration(match: re.Match[str] | None) -> float | None:
    if not match:
        return None
    value = float(match.group(1))
    unit = (match.group(2) or "s").lower()
    return value if unit == "ms" else value * 1000.0


def extract_access(line: str) -> dict[str, Any] | None:
    status_match = KV_STATUS.search(line)
    duration_match = KV_DURATION.search(line)
    source = None
    request = None
    timestamp_text = None
    if status_match:
        source_match = re.search(r"\b(?:remote_addr|client|source)=(\S+)", line, re.I)
        source = source_match.group(1) if source_match else (line.split()[0] if line.split() else None)
        request_match = re.search(r'\b(?:request|uri)="([^"]*)"', line, re.I)
        request = request_match.group(1) if request_match else None
        timestamp_text = timestamp_text_from_line(line)
    else:
        combined = COMBINED.search(line)
        if not combined:
            return None
        source = combined.group("source")
        request = combined.group("request")
        status_match = re.match(r"(\d{3})", combined.group("status"))
        timestamp_text = combined.group("ts")
    status = int(status_match.group(1)) if status_match else None
    if status is None:
        return None
    path_value = None
    if request:
        parts = request.split()
        if len(parts) >= 2:
            path_value = parts[1].split("?", 1)[0]
    return {
        "status": status,
        "duration_ms": parse_duration(duration_match),
        "source": source,
        "path": path_value,
        "timestamp": parse_log_time(timestamp_text),
    }


def classify_error(line: str) -> list[str]:
    lowered = line.lower()
    labels: list[str] = []
    patterns = (
        ("limit_conn", r"limiting connections|limit_conn"),
        ("limit_req", r"limiting requests|limit_req"),
        ("upstream_fail", r"connect\(\).*failed|connection refused|upstream timed out|upstream.*(?:failed|reset)"),
        ("tls_error", r"ssl_do_handshake|ssl.*handshake|tls.*handshake|no shared cipher"),
        ("client_abort", r"reset by peer|client prematurely closed|broken pipe|\b499\b"),
        ("dns_error", r"dns|resolver|name resolution|no such host"),
    )
    for label, pattern in patterns:
        if re.search(pattern, lowered):
            labels.append(label)
    return labels


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = max(0, min(len(ordered) - 1, math.ceil(len(ordered) * fraction) - 1))
    return round(ordered[index], 3)


def parse_ss(lines: Iterable[str], backend_port: int | None) -> dict[str, Any]:
    result: dict[str, Any] = {"established_443": 0, "established_backend": None, "lines": 0}
    backend_count = 0
    for line in lines:
        fields = line.split()
        if not fields or fields[0].upper() not in {"ESTAB", "ESTABLISHED"}:
            continue
        result["lines"] += 1
        if len(fields) < 2:
            continue
        local = fields[-2]
        port_match = re.search(r":(\d+)$", local.replace("]", ""))
        if not port_match:
            continue
        port = int(port_match.group(1))
        if port == 443:
            result["established_443"] += 1
        if backend_port is not None and port == backend_port:
            backend_count += 1
    if backend_port is not None:
        result["established_backend"] = backend_count
    return result


def new_access() -> dict[str, Any]:
    return {
        "lines_seen": 0,
        "records": 0,
        "status": {},
        "duration_ms": [],
        "zero_duration_503": 0,
        "short_sessions_le_5s": 0,
        "unparsed_timestamp": 0,
        "sources": {},
        "paths": {},
    }


def analyze(
    access_paths: list[str],
    error_paths: list[str],
    ss_path: str | None,
    backend_port: int | None,
    since: dt.datetime | None,
    until: dt.datetime | None,
    max_bytes: int,
    max_lines: int,
) -> dict[str, Any]:
    salt = os.urandom(16)
    access = new_access()
    errors: dict[str, int] = {}
    gaps: list[str] = []
    inputs: list[dict[str, Any]] = []

    for path in access_paths:
        lines, truncated, error = read_tail(path, max_bytes, max_lines)
        inputs.append({"kind": "access", **display_path(path), "truncated": truncated})
        if error:
            gaps.append(error)
            continue
        if truncated:
            gaps.append(f"access input truncated: {display_path(path)['name']}")
        for line in lines:
            access["lines_seen"] += 1
            record = extract_access(line)
            if not record or not in_window(record["timestamp"], since, until):
                continue
            access["records"] += 1
            key = str(record["status"])
            access["status"][key] = access["status"].get(key, 0) + 1
            duration = record["duration_ms"]
            if duration is not None:
                access["duration_ms"].append(duration)
                if record["status"] == 101 and duration <= 5000:
                    access["short_sessions_le_5s"] += 1
            if record["status"] == 503 and duration is not None and duration <= 1.0:
                access["zero_duration_503"] += 1
            if record["timestamp"] is None:
                access["unparsed_timestamp"] += 1
            if record["source"]:
                source_key = fingerprint(record["source"], salt)
                access["sources"][source_key] = access["sources"].get(source_key, 0) + 1
            if record["path"]:
                path_key = fingerprint(record["path"], salt)
                access["paths"][path_key] = access["paths"].get(path_key, 0) + 1

    for path in error_paths:
        lines, truncated, error = read_tail(path, max_bytes, max_lines)
        inputs.append({"kind": "error", **display_path(path), "truncated": truncated})
        if error:
            gaps.append(error)
            continue
        if truncated:
            gaps.append(f"error input truncated: {display_path(path)['name']}")
        for line in lines:
            timestamp = parse_log_time(timestamp_text_from_line(line))
            if not in_window(timestamp, since, until):
                continue
            labels = classify_error(line)
            if timestamp is None:
                gaps.append("one or more error lines had no parseable timestamp")
            for label in labels:
                errors[label] = errors.get(label, 0) + 1

    for key in ("status", "sources", "paths"):
        access[key] = dict(sorted(access[key].items(), key=lambda item: (-item[1], item[0])))
    durations = access.pop("duration_ms")
    access["duration_p50_ms"] = percentile(durations, 0.50)
    access["duration_p95_ms"] = percentile(durations, 0.95)
    total_records = access["records"]
    access["status_503_ratio"] = round(access["status"].get("503", 0) / max(1, total_records), 6)
    access["status_502_504_ratio"] = round(
        (access["status"].get("502", 0) + access["status"].get("504", 0)) / max(1, total_records),
        6,
    )
    access["zero_duration_503_ratio"] = round(
        access["zero_duration_503"] / max(1, access["status"].get("503", 0)),
        6,
    )
    access["top_sources"] = [
        {"fingerprint": key, "records": value} for key, value in list(access["sources"].items())[:10]
    ]
    access["path_fingerprints"] = [
        {"fingerprint": key, "records": value} for key, value in list(access["paths"].items())[:10]
    ]
    access.pop("sources")
    access.pop("paths")

    status = access["status"]
    status_101 = status.get("101", 0)
    status_503 = status.get("503", 0)
    status_502_504 = status.get("502", 0) + status.get("504", 0)
    findings: list[dict[str, Any]] = []
    if errors.get("limit_conn", 0) or errors.get("limit_req", 0):
        if status_503 or status.get("429", 0):
            findings.append({
                "bucket": "edge_limit",
                "level": "warn",
                "confidence": 0.95,
                "evidence": {"limit_error_lines": errors.get("limit_conn", 0) + errors.get("limit_req", 0), "status_503": status_503, "status_429": status.get("429", 0)},
            })
    if errors.get("upstream_fail", 0) and status_502_504:
        findings.append({
            "bucket": "upstream_unavailable",
            "level": "warn",
            "confidence": 0.9,
            "evidence": {"upstream_error_lines": errors["upstream_fail"], "status_502_504": status_502_504},
        })
    if errors.get("tls_error", 0):
        findings.append({"bucket": "tls_edge", "level": "warn", "confidence": 0.8, "evidence": {"tls_error_lines": errors["tls_error"]}})
    if status_503 and not errors.get("limit_conn", 0) and not errors.get("upstream_fail", 0):
        findings.append({
            "bucket": "edge_reject_unknown",
            "level": "info",
            "confidence": 0.45,
            "evidence": {"status_503": status_503, "zero_duration_503": access["zero_duration_503"]},
        })
    if access["short_sessions_le_5s"] >= 10 and status_101:
        ratio = access["short_sessions_le_5s"] / max(1, len(durations))
        if ratio >= 0.5:
            findings.append({
                "bucket": "client_churn",
                "level": "info",
                "confidence": round(min(0.9, ratio), 3),
                "evidence": {"short_sessions_le_5s": access["short_sessions_le_5s"], "duration_samples": len(durations)},
            })
    if not access["records"] and not errors:
        gaps.append("no parseable access or error evidence")
        findings.append({"bucket": "insufficient_evidence", "level": "info", "confidence": 1.0, "evidence": {}})

    connections = None
    if ss_path:
        lines, truncated, error = read_tail(ss_path, max_bytes, max_lines)
        inputs.append({"kind": "ss", **display_path(ss_path), "truncated": truncated})
        if error:
            gaps.append(error)
        else:
            connections = parse_ss(lines, backend_port)
            if truncated:
                gaps.append(f"ss input truncated: {display_path(ss_path)['name']}")

    generated = dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")
    return {
        "schema": SCHEMA,
        "generated_at": generated,
        "mode": {"read_only": True, "network_probe": False, "raw_lines_emitted": False},
        "window": {"since": since.isoformat() if since else None, "until": until.isoformat() if until else None},
        "inputs": inputs,
        "access": access,
        "errors": dict(sorted(errors.items())),
        "connections": connections,
        "findings": findings,
        "gaps": sorted(set(gaps)),
        "forbidden_actions_not_taken": ["config_write", "service_reload", "service_restart", "public_probe", "credential_export"],
    }


def text_report(report: dict[str, Any]) -> str:
    access = report["access"]
    status = access["status"]
    lines = [
        f"schema: {report['schema']}",
        f"records: {access['records']} status_101={status.get('101', 0)} status_503={status.get('503', 0)}",
        f"status_503_ratio={access['status_503_ratio']} zero_duration_503={access['zero_duration_503']} zero_duration_503_ratio={access['zero_duration_503_ratio']}",
        f"duration_p50_ms={access['duration_p50_ms']} duration_p95_ms={access['duration_p95_ms']}",
        f"error_labels: {json.dumps(report['errors'], sort_keys=True, ensure_ascii=False)}",
        f"findings: {', '.join(item['bucket'] for item in report['findings']) or 'none'}",
        f"gaps: {len(report['gaps'])}",
        "read_only: true; raw_lines_emitted: false; config/service/network writes: none",
    ]
    return "\n".join(lines)


def self_test() -> int:
    access_lines = [
        '203.0.113.9 - - [25/Jul/2026:06:00:00 +0800] "GET /private-token?uuid=synthetic-credential-123 HTTP/1.1" 101 0 request_time=0.100',
        '203.0.113.9 - - [25/Jul/2026:06:00:01 +0800] "GET /private-token HTTP/1.1" 101 0 request_time=0.200',
        '203.0.113.9 - - [25/Jul/2026:06:00:02 +0800] "GET /private-token HTTP/1.1" 503 0 request_time=0.000',
    ] * 5
    error_lines = [
        '2026/07/25 06:00:02 [error] limiting connections by zone "ws_secret_zone"',
        '2026/07/25 06:00:03 [error] connect() failed (111: Connection refused) while connecting to upstream',
    ]
    report = _analyze_lines_for_test(access_lines, error_lines)
    serialized = json.dumps(report, ensure_ascii=False)
    assert report["access"]["status"]["101"] == 10
    assert report["access"]["status"]["503"] == 5
    assert report["errors"]["limit_conn"] == 1
    assert report["errors"]["upstream_fail"] == 1
    assert "one or more error lines had no parseable timestamp" not in report["gaps"]
    assert "private-token" not in serialized
    assert "synthetic-credential-123" not in serialized
    print("PASS analyze_ws_logs self-test")
    return 0


def _analyze_lines_for_test(access_lines: list[str], error_lines: list[str]) -> dict[str, Any]:
    import tempfile

    with tempfile.TemporaryDirectory(prefix="proxy443-self-test-") as directory:
        access_path = Path(directory) / "access.log"
        error_path = Path(directory) / "error.log"
        access_path.write_text("\n".join(access_lines) + "\n", encoding="utf-8")
        error_path.write_text("\n".join(error_lines) + "\n", encoding="utf-8")
        return analyze([str(access_path)], [str(error_path)], None, None, None, None, 1024 * 1024, 1000)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    if args.self_test:
        return self_test()
    if not args.access_log and not args.error_log and not args.ss_file:
        print("provide --access-log, --error-log, or --ss-file (or use --self-test)", file=sys.stderr)
        return 2
    if args.max_bytes <= 0 or args.max_lines <= 0:
        print("--max-bytes and --max-lines must be positive", file=sys.stderr)
        return 2
    try:
        since = parse_time(args.since)
        until = parse_time(args.until)
        if since and until and since > until:
            raise ValueError("--since must not be after --until")
        report = analyze(args.access_log, args.error_log, args.ss_file, args.backend_port, since, until, args.max_bytes, args.max_lines)
    except ValueError as exc:
        print(str(exc), file=sys.stderr)
        return 2
    if args.format == "json":
        print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2))
    else:
        print(text_report(report))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
