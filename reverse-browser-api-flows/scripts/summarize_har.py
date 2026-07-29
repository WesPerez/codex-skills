#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
from urllib.parse import parse_qsl, urlsplit


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Summarize a HAR without printing credential values or request bodies"
    )
    parser.add_argument("har", type=Path)
    parser.add_argument("--host", action="append", default=[])
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    with args.har.open("r", encoding="utf-8") as har_file:
        payload = json.load(har_file)
    entries = payload.get("log", {}).get("entries", [])
    if not isinstance(entries, list):
        raise SystemExit("HAR is missing log.entries")

    allowed_hosts = {host.lower() for host in args.host}
    output = []
    for entry in entries:
        request = entry.get("request", {})
        response = entry.get("response", {})
        url = request.get("url")
        if not isinstance(url, str):
            continue
        parts = urlsplit(url)
        if allowed_hosts and parts.hostname not in allowed_hosts:
            continue
        query_names = sorted({name for name, _ in parse_qsl(parts.query, keep_blank_values=True)})
        request_headers = sorted(
            {
                str(header.get("name", "")).lower()
                for header in request.get("headers", [])
                if header.get("name")
            }
        )
        response_headers = sorted(
            {
                str(header.get("name", "")).lower()
                for header in response.get("headers", [])
                if header.get("name")
            }
        )
        post_data = request.get("postData") if isinstance(request.get("postData"), dict) else {}
        content = response.get("content") if isinstance(response.get("content"), dict) else {}
        output.append(
            {
                "started": entry.get("startedDateTime"),
                "method": request.get("method"),
                "scheme": parts.scheme,
                "host": parts.hostname,
                "path": parts.path,
                "query_names": query_names,
                "status": response.get("status"),
                "request_header_names": request_headers,
                "response_header_names": response_headers,
                "request_mime_type": post_data.get("mimeType"),
                "response_mime_type": content.get("mimeType"),
                "response_size": content.get("size"),
            }
        )

    print(json.dumps(output, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
