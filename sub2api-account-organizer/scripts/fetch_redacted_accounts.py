#!/usr/bin/env python3
"""Fetch every non-deleted Sub2API account through the redacted admin list API."""

from __future__ import annotations

import argparse
import json
import os
import ssl
import sys
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urljoin
from urllib.request import Request, urlopen


SENSITIVE_CREDENTIAL_KEYS = {
    "access_token",
    "refresh_token",
    "id_token",
    "agent_private_key",
    "api_key",
    "session_key",
    "cookie",
    "aws_secret_access_key",
    "aws_session_token",
    "service_account_json",
    "service_account",
    "private_key",
}


def find_sensitive_key(value: Any, path: str = "$") -> str | None:
    if isinstance(value, dict):
        for key, child in value.items():
            key_text = str(key)
            if key_text in SENSITIVE_CREDENTIAL_KEYS:
                return f"{path}.{key_text}"
            found = find_sensitive_key(child, f"{path}.{key_text}")
            if found:
                return found
    elif isinstance(value, list):
        for index, child in enumerate(value):
            found = find_sensitive_key(child, f"{path}[{index}]")
            if found:
                return found
    return None


def write_json_0600(path: str, payload: Any) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
    finally:
        try:
            os.chmod(target, 0o600)
        except FileNotFoundError:
            pass


def auth_headers() -> dict[str, str]:
    api_key = os.environ.get("SUB2API_ADMIN_API_KEY", "").strip()
    jwt = os.environ.get("SUB2API_JWT", "").strip()
    if api_key:
        return {"x-api-key": api_key}
    if jwt:
        return {"Authorization": f"Bearer {jwt}"}
    raise ValueError("missing SUB2API_ADMIN_API_KEY or SUB2API_JWT")


def request_json(url: str, headers: dict[str, str], timeout: float, context: ssl.SSLContext) -> dict[str, Any]:
    request = Request(url, headers={**headers, "Accept": "application/json"}, method="GET")
    with urlopen(request, timeout=timeout, context=context) as response:
        raw = response.read()
    payload = json.loads(raw)
    if not isinstance(payload, dict):
        raise ValueError("admin API returned a non-object response")
    if payload.get("code") not in (0, "0", None):
        raise ValueError(f"admin API error code {payload.get('code')!r}")
    data = payload.get("data", payload)
    if not isinstance(data, dict):
        raise ValueError("admin API data is not an object")
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="redacted JSON output (mode 0600)")
    parser.add_argument("--page-size", type=int, default=500)
    parser.add_argument("--timeout", type=float, default=20.0)
    parser.add_argument("--platform")
    parser.add_argument("--type", dest="account_type")
    parser.add_argument("--status")
    parser.add_argument("--group")
    args = parser.parse_args()

    try:
        if not 1 <= args.page_size <= 1000:
            raise ValueError("page-size must be between 1 and 1000")
        base_url = os.environ.get("SUB2API_BASE_URL", "").strip().rstrip("/") + "/"
        if base_url == "/":
            raise ValueError("missing SUB2API_BASE_URL")
        headers = auth_headers()
        context = ssl.create_default_context()
        all_accounts: list[dict[str, Any]] = []
        total: int | None = None
        page = 1
        while True:
            query = {
                "page": page,
                "page_size": args.page_size,
                "sort_by": "id",
                "sort_order": "asc",
            }
            for key, value in (
                ("platform", args.platform),
                ("type", args.account_type),
                ("status", args.status),
                ("group", args.group),
            ):
                if value:
                    query[key] = value
            endpoint = urljoin(base_url, "api/v1/admin/accounts") + "?" + urlencode(query)
            data = request_json(endpoint, headers, args.timeout, context)
            items = data.get("items")
            if not isinstance(items, list):
                raise ValueError("admin API page has no items array")
            if total is None:
                total = int(data.get("total", len(items)))
            for item in items:
                if not isinstance(item, dict):
                    raise ValueError("admin API returned a non-object account")
                sensitive_path = find_sensitive_key(item)
                if sensitive_path:
                    raise ValueError(
                        "admin API response contains an unredacted sensitive credential key "
                        f"at {sensitive_path}"
                    )
                all_accounts.append(item)
            if not items or len(all_accounts) >= total:
                break
            page += 1
            if page > 100000:
                raise ValueError("pagination guard exceeded")

        unique_ids = {item.get("id") for item in all_accounts}
        if len(unique_ids) != len(all_accounts):
            raise ValueError("admin API pagination returned duplicate account ids")
        write_json_0600(
            args.output,
            {
                "source": "Sub2API redacted admin accounts API",
                "count": len(all_accounts),
                "items": all_accounts,
            },
        )
        print(json.dumps({"count": len(all_accounts), "output": str(Path(args.output).resolve())}, sort_keys=True))
        return 0
    except (ValueError, OSError, HTTPError, URLError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
