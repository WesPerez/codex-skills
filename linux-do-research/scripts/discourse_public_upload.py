#!/usr/bin/env python3
"""Resolve and optionally probe a public Discourse short upload URL."""

from __future__ import annotations

import argparse
import ipaddress
import json
import socket
import urllib.error
import urllib.parse
import urllib.request


ALPHABET = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
MAX_RESPONSE_BYTES = 4096


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def decode_base62_sha1(value: str) -> str:
    token = value.strip()
    if not token or len(token) > 27 or any(char not in ALPHABET for char in token):
        raise ValueError("invalid Discourse Base62 SHA-1")
    number = 0
    for char in token:
        number = number * 62 + ALPHABET.index(char)
    digest = f"{number:040x}"
    if len(digest) != 40:
        raise ValueError("decoded value is not a SHA-1")
    return digest


def parse_short_upload(value: str) -> tuple[str, str]:
    raw = value.strip()
    if raw.startswith("upload://"):
        raw = raw[len("upload://") :]
    elif "/uploads/short-url/" in raw:
        raw = raw.split("/uploads/short-url/", 1)[1]
    raw = raw.split("?", 1)[0].split("#", 1)[0]
    token, marker, extension = raw.partition(".")
    if not marker or not extension or not extension.replace("-", "").replace("_", "").isalnum():
        raise ValueError("short upload must include a safe extension")
    return token, extension.lower()


def require_public_https(url: str) -> None:
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
        raise ValueError("CDN root must be a public HTTPS URL")
    infos = socket.getaddrinfo(parsed.hostname, parsed.port or 443, type=socket.SOCK_STREAM)
    addresses = {item[4][0] for item in infos}
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise ValueError("CDN root resolved to a non-public address")


def build_public_url(short_upload: str, cdn_root: str) -> tuple[str, str]:
    token, extension = parse_short_upload(short_upload)
    digest = decode_base62_sha1(token)
    root = cdn_root.rstrip("/")
    require_public_https(root)
    url = f"{root}/{digest[0]}/{digest[1]}/{digest[2]}/{digest}.{extension}"
    return digest, url


def probe_head(url: str, timeout: float) -> dict[str, object]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirectHandler())
    request = urllib.request.Request(
        url,
        method="HEAD",
        headers={"User-Agent": "linux-do-research/1", "Accept": "*/*"},
    )
    try:
        with opener.open(request, timeout=timeout) as response:
            response.read(MAX_RESPONSE_BYTES)
            return {
                "status": int(response.status),
                "final_url": response.geturl(),
                "content_type": response.headers.get("Content-Type"),
                "content_length": response.headers.get("Content-Length"),
                "last_modified": response.headers.get("Last-Modified"),
            }
    except urllib.error.HTTPError as exc:
        return {"status": int(exc.code or 0), "final_url": url}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("short_upload")
    parser.add_argument(
        "--cdn-root",
        required=True,
        help="Public CDN original/4X root verified for the target forum",
    )
    parser.add_argument("--probe", action="store_true")
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    digest, url = build_public_url(args.short_upload, args.cdn_root)
    result: dict[str, object] = {"sha1": digest, "url": url}
    if args.probe:
        result["probe"] = probe_head(url, args.timeout)
    print(json.dumps(result, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
