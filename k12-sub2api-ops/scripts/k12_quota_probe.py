#!/usr/bin/env python3
"""Read-only quota probe for K12/OpenAI OAuth account bundles.

The script never refreshes credentials, sends a generation request, or prints
tokens, emails, account IDs, response bodies, or request headers.
"""

from __future__ import annotations

import argparse
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
import datetime as dt
from email.utils import parsedate_to_datetime
import hashlib
import json
from pathlib import Path
import random
import re
import ssl
import sys
import time
from typing import Any
import urllib.error
import urllib.request

from k12_bundle_tool import ToolError, account_items, load_json_docs


QUOTA_URL = "https://chatgpt.com/backend-api/wham/usage"
CONCLUSIVE_CATEGORIES = {
    "usable_now",
    "current_quota_exhausted",
    "invalid_or_revoked",
    "deactivated",
}
KNOWN_REASONS = (
    "workspace_member_credits_depleted",
    "usage_limit_reached",
    "spend_control_reached",
    "token_invalidated",
    "account_deactivated",
)
EXHAUSTED_REASONS = {
    "workspace_member_credits_depleted",
    "usage_limit_reached",
    "spend_control_reached",
}
QUOTA_FILE_SUFFIXES = {".json", ".jsonl", ".txt"}


@dataclass(frozen=True)
class Credential:
    token: str
    token_sha256: str
    account_id: str | None


@dataclass(frozen=True)
class ProbeResult:
    category: str
    reason: str
    http_status: int | None


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def credentials_from_account(account: dict[str, Any]) -> tuple[str | None, str | None, str | None]:
    credentials = account.get("credentials")
    if not isinstance(credentials, dict):
        credentials = account
    token = credentials.get("access_token") or account.get("access_token")
    account_id = credentials.get("chatgpt_account_id") or account.get("chatgpt_account_id")
    email = credentials.get("email") or account.get("email")
    return (
        str(token) if token else None,
        str(account_id) if account_id else None,
        str(email).strip().lower() if email else None,
    )


def load_json_lines(path: Path) -> list[dict[str, Any]]:
    try:
        text = path.read_text(encoding="utf-8-sig")
    except UnicodeDecodeError as exc:
        raise ToolError(f"{path}: not UTF-8 JSONL") from exc
    docs: list[dict[str, Any]] = []
    for line_no, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped:
            continue
        try:
            data = json.loads(stripped)
        except json.JSONDecodeError as exc:
            raise ToolError(f"{path}:{line_no}: invalid JSONL: {exc}") from exc
        docs.append({"source": f"{path}:{line_no}", "data": data})
    if not docs:
        raise ToolError(f"{path}: empty JSONL")
    return docs


def looks_like_json_text(path: Path) -> bool:
    try:
        with path.open("r", encoding="utf-8-sig") as handle:
            while chunk := handle.read(4096):
                stripped = chunk.lstrip()
                if stripped:
                    return stripped[0] in "[{"
    except (OSError, UnicodeDecodeError):
        return False
    return False


def load_quota_docs(path: Path) -> list[dict[str, Any]]:
    if path.is_dir():
        docs: list[dict[str, Any]] = []
        for item in sorted(candidate for candidate in path.rglob("*") if candidate.is_file()):
            if item.suffix.lower() not in QUOTA_FILE_SUFFIXES:
                continue
            if item.suffix.lower() == ".txt" and not looks_like_json_text(item):
                continue
            docs.extend(load_quota_docs(item))
        if not docs:
            raise ToolError(f"{path}: no JSON/TXT/JSONL account documents found")
        return docs

    try:
        return load_json_docs(path)
    except ToolError:
        if path.suffix.lower() in {".jsonl", ".txt"}:
            return load_json_lines(path)
        raise


def quota_account_items(doc: dict[str, Any]) -> list[tuple[str, dict[str, Any], str]]:
    items = account_items(doc)
    if items:
        return items
    data = doc.get("data")
    if not isinstance(data, dict):
        return []
    credentials = data.get("credentials")
    if not isinstance(credentials, dict):
        credentials = data
    if credentials.get("access_token") or data.get("access_token"):
        return [(str(doc.get("source") or "unknown"), data, "quota_account")]
    return []


def load_inputs(paths: list[Path]) -> tuple[dict[str, Any], dict[str, Credential], dict[str, set[str]]]:
    per_input: dict[str, Any] = {}
    credentials: dict[str, Credential] = {}
    probe_keys_by_input: dict[str, set[str]] = {}

    for path in paths:
        label = str(path)
        docs = load_quota_docs(path)
        raw_records = 0
        missing_tokens = 0
        token_hashes: set[str] = set()
        probe_keys: set[str] = set()
        email_hashes: set[str] = set()
        account_id_hashes: set[str] = set()

        for doc in docs:
            for _source, account, _kind in quota_account_items(doc):
                raw_records += 1
                token, account_id, email = credentials_from_account(account)
                if email:
                    email_hashes.add(sha256_text(email))
                if account_id:
                    account_id_hashes.add(sha256_text(account_id))
                if not token:
                    missing_tokens += 1
                    continue
                token_sha = sha256_text(token)
                probe_key = sha256_text(f"{token_sha}\0{account_id or ''}")
                token_hashes.add(token_sha)
                probe_keys.add(probe_key)
                credentials.setdefault(probe_key, Credential(token, token_sha, account_id))

        per_input[label] = {
            "records": raw_records,
            "unique_access_tokens": len(token_hashes),
            "unique_credentials": len(probe_keys),
            "duplicate_records": max(0, raw_records - missing_tokens - len(probe_keys)),
            "missing_access_token": missing_tokens,
            "unique_emails": len(email_hashes),
            "unique_chatgpt_account_ids": len(account_id_hashes),
        }
        probe_keys_by_input[label] = probe_keys

    if not any(row["records"] for row in per_input.values()):
        raise ToolError("no supported account records found")
    if not credentials:
        raise ToolError("no access_token values found")
    return per_input, credentials, probe_keys_by_input


def body_reason(data: Any) -> str:
    strings: set[str] = set()

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            for nested in value.values():
                visit(nested)
        elif isinstance(value, list):
            for nested in value:
                visit(nested)
        elif isinstance(value, str):
            strings.add(value.strip().lower())

    visit(data)
    for reason in KNOWN_REASONS:
        if reason in strings:
            return reason
    return "unspecified"


def quota_reason(data: dict[str, Any]) -> str:
    reached_type = data.get("rate_limit_reached_type")
    if isinstance(reached_type, dict):
        value = reached_type.get("type")
        if isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9_.:-]{1,80}", value):
            return value
    spend_control = data.get("spend_control")
    if isinstance(spend_control, dict) and spend_control.get("reached") is True:
        return "spend_control_reached"
    return "unspecified"


def classify_response(status: int, body: bytes) -> ProbeResult:
    try:
        data = json.loads(body.decode("utf-8", errors="replace"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        data = None

    if status == 200:
        if not isinstance(data, dict):
            return ProbeResult("inconclusive", "invalid_json", status)
        rate_limit = data.get("rate_limit")
        spend_control = data.get("spend_control")
        spend_reached = isinstance(spend_control, dict) and spend_control.get("reached") is True
        if spend_reached:
            return ProbeResult("current_quota_exhausted", "spend_control_reached", status)
        if isinstance(rate_limit, dict):
            if rate_limit.get("allowed") is False or rate_limit.get("limit_reached") is True:
                return ProbeResult("current_quota_exhausted", quota_reason(data), status)
            if rate_limit.get("allowed") is True and rate_limit.get("limit_reached") is not True:
                return ProbeResult("usable_now", "allowed", status)
        return ProbeResult("inconclusive", "missing_rate_limit_state", status)

    reason = body_reason(data)
    if status == 401:
        if reason == "account_deactivated":
            return ProbeResult("deactivated", reason, status)
        return ProbeResult("invalid_or_revoked", reason, status)
    if status == 402:
        return ProbeResult("deactivated", reason, status)
    if status == 429 and reason in EXHAUSTED_REASONS:
        return ProbeResult("current_quota_exhausted", reason, status)
    if status == 429:
        return ProbeResult("request_rate_limited", reason, status)
    if 500 <= status <= 599:
        return ProbeResult("upstream_error", f"http_{status}", status)
    return ProbeResult("unexpected_http", f"http_{status}", status)


def retry_delay(headers: Any, attempt: int) -> float:
    retry_after = headers.get("Retry-After") if headers is not None else None
    if retry_after:
        try:
            return min(10.0, max(0.0, float(retry_after)))
        except ValueError:
            try:
                retry_at = parsedate_to_datetime(retry_after)
                if retry_at.tzinfo is None:
                    retry_at = retry_at.replace(tzinfo=dt.timezone.utc)
                seconds = (retry_at - dt.datetime.now(dt.timezone.utc)).total_seconds()
                return min(10.0, max(0.0, seconds))
            except (TypeError, ValueError, OverflowError):
                pass
    return min(3.0, 0.5 * (2**attempt) + random.uniform(0.0, 0.25))


def build_opener(proxy: str | None) -> urllib.request.OpenerDirector:
    handlers: list[Any] = [urllib.request.HTTPSHandler(context=ssl.create_default_context())]
    if proxy:
        handlers.insert(0, urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    return urllib.request.build_opener(*handlers)


def probe_credential(
    credential: Credential,
    timeout: float,
    retries: int,
    proxy: str | None,
) -> ProbeResult:
    request = urllib.request.Request(
        QUOTA_URL,
        headers={
            "Authorization": f"Bearer {credential.token}",
            "Accept": "application/json",
            "User-Agent": "k12-quota-probe/1.0",
            **({"chatgpt-account-id": credential.account_id} if credential.account_id else {}),
        },
    )

    for attempt in range(retries + 1):
        retry_headers = None
        try:
            with build_opener(proxy).open(request, timeout=timeout) as response:
                body = response.read(262_144)
                result = classify_response(response.status, body)
        except urllib.error.HTTPError as exc:
            body = exc.read(262_144)
            result = classify_response(exc.code, body)
            retry_headers = exc.headers
        except (TimeoutError, urllib.error.URLError, OSError):
            if attempt < retries:
                time.sleep(retry_delay(None, attempt))
                continue
            return ProbeResult("network_error", "request_failed", None)

        if result.category in {"request_rate_limited", "upstream_error"} and attempt < retries:
            time.sleep(retry_delay(retry_headers, attempt))
            continue
        return result

    return ProbeResult("network_error", "retry_exhausted", None)


def count_results(probe_keys: set[str], results: dict[str, ProbeResult]) -> dict[str, Any]:
    categories = Counter(results[key].category for key in probe_keys if key in results)
    reasons = Counter(results[key].reason for key in probe_keys if key in results)
    return {
        "completed": sum(categories.values()),
        "categories": dict(sorted(categories.items())),
        "reasons": dict(sorted(reasons.items())),
    }


def build_report(
    paths: list[Path],
    per_input: dict[str, Any],
    credentials: dict[str, Credential],
    probe_keys_by_input: dict[str, set[str]],
    results: dict[str, ProbeResult],
    elapsed: float,
    offline: bool,
) -> dict[str, Any]:
    all_probe_keys = set(credentials)
    all_token_hashes = {credential.token_sha256 for credential in credentials.values()}
    for label in per_input:
        per_input[label]["probe"] = count_results(probe_keys_by_input[label], results)

    return {
        "checked_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "mode": "offline" if offline else "quota_probe",
        "endpoint": None if offline else QUOTA_URL,
        "inputs": per_input,
        "combined": {
            "input_count": len(paths),
            "records": sum(row["records"] for row in per_input.values()),
            "unique_access_tokens": len(all_token_hashes),
            "unique_credentials": len(all_probe_keys),
            "duplicate_records": sum(row["records"] - row["missing_access_token"] for row in per_input.values())
            - len(all_probe_keys),
            "missing_access_token": sum(row["missing_access_token"] for row in per_input.values()),
            "probe": count_results(all_probe_keys, results),
        },
        "elapsed_seconds": round(elapsed, 2),
        "privacy": "No tokens, emails, account IDs, headers, or response bodies are included.",
    }


def print_human(report: dict[str, Any]) -> None:
    combined = report["combined"]
    print(f"Checked at: {report['checked_at']}")
    print(f"Mode: {report['mode']}")
    print(
        "Combined: "
        f"records={combined['records']} unique_access_tokens={combined['unique_access_tokens']} "
        f"unique_credentials={combined['unique_credentials']} "
        f"duplicate_records={combined['duplicate_records']} missing_access_token={combined['missing_access_token']}"
    )
    if report["mode"] == "quota_probe":
        print("Quota results (unique credentials):")
        categories = combined["probe"]["categories"]
        for category in [
            "usable_now",
            "current_quota_exhausted",
            "invalid_or_revoked",
            "deactivated",
            "request_rate_limited",
            "upstream_error",
            "network_error",
            "inconclusive",
            "unexpected_http",
        ]:
            print(f"  {category}: {categories.get(category, 0)}")
        reasons = combined["probe"]["reasons"]
        if reasons:
            print(f"Reasons: {json.dumps(reasons, sort_keys=True)}")
    print("Inputs:")
    for label, row in report["inputs"].items():
        line = (
            f"  {label}: records={row['records']} unique_access_tokens={row['unique_access_tokens']} "
            f"unique_credentials={row['unique_credentials']} "
            f"unique_emails={row['unique_emails']} "
            f"unique_chatgpt_account_ids={row['unique_chatgpt_account_ids']}"
        )
        if report["mode"] == "quota_probe":
            categories = row["probe"]["categories"]
            inconclusive = sum(count for category, count in categories.items() if category not in CONCLUSIVE_CATEGORIES)
            line += (
                f" usable_now={categories.get('usable_now', 0)}"
                f" current_quota_exhausted={categories.get('current_quota_exhausted', 0)}"
                f" invalid_or_revoked={categories.get('invalid_or_revoked', 0)}"
                f" deactivated={categories.get('deactivated', 0)}"
                f" inconclusive={inconclusive}"
                f" completed={row['probe']['completed']}"
            )
        print(line)
    print(f"Elapsed seconds: {report['elapsed_seconds']}")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Read-only K12/OpenAI OAuth quota count without generation requests or secret output."
    )
    parser.add_argument("paths", nargs="+", help="JSON/TXT bundle, archive, or directory")
    parser.add_argument("--workers", type=int, default=10, help="Concurrent requests (default: 10)")
    parser.add_argument("--timeout", type=float, default=15.0, help="Per-request timeout seconds (default: 15)")
    parser.add_argument("--retries", type=int, default=1, help="Retries for 429, 5xx, and network errors (default: 1)")
    parser.add_argument("--proxy", help="Optional per-run HTTP(S) proxy URL")
    parser.add_argument("--offline", action="store_true", help="Inspect inputs without network requests")
    parser.add_argument("--json", action="store_true", help="Print a machine-readable summary")
    args = parser.parse_args(argv)
    if not 1 <= args.workers <= 32:
        parser.error("--workers must be between 1 and 32")
    if not 1 <= args.timeout <= 120:
        parser.error("--timeout must be between 1 and 120 seconds")
    if not 0 <= args.retries <= 3:
        parser.error("--retries must be between 0 and 3")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv or sys.argv[1:])
    started = time.monotonic()
    try:
        paths = [Path(value) for value in args.paths]
        per_input, credentials, probe_keys_by_input = load_inputs(paths)
    except (ToolError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    results: dict[str, ProbeResult] = {}
    if not args.offline:
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            futures = {
                executor.submit(
                    probe_credential,
                    credential,
                    args.timeout,
                    args.retries,
                    args.proxy,
                ): probe_key
                for probe_key, credential in credentials.items()
            }
            for future in as_completed(futures):
                probe_key = futures[future]
                try:
                    results[probe_key] = future.result()
                except Exception:
                    results[probe_key] = ProbeResult("inconclusive", "worker_error", None)

    report = build_report(
        paths,
        per_input,
        credentials,
        probe_keys_by_input,
        results,
        time.monotonic() - started,
        args.offline,
    )
    if args.json:
        print(json.dumps(report, ensure_ascii=True, indent=2, sort_keys=True))
    else:
        print_human(report)

    if args.offline:
        return 0
    categories = set(report["combined"]["probe"]["categories"])
    return 0 if categories <= CONCLUSIVE_CATEGORIES else 1


if __name__ == "__main__":
    raise SystemExit(main())
