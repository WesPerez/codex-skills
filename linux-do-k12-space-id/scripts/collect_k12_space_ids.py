#!/usr/bin/env python3
"""Collect source-marked K12 workspace IDs from public LINUX DO reader pages."""

from __future__ import annotations

import argparse
import base64
import json
import re
import shutil
import subprocess
import sys
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from typing import Iterable


DEFAULT_PROXY = "http://127.0.0.1:10808"
DEFAULT_AGGREGATOR_TOPIC = 2514402
UUID_RE = re.compile(
    r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b",
    re.I,
)
TOPIC_RE = re.compile(r"https?://linux\.do/t/topic/(\d+)", re.I)
TITLE_RE = re.compile(r"(?m)^Title:\s*(.+)$")
PUBLISHED_RE = re.compile(r"(?m)^Published Time:\s*(.+)$")
PRIVATE_RE = re.compile(r"Page Not Found|doesn.?t exist or is private", re.I)
STATUS_WORDS = (
    "已失效",
    "失效",
    "结束",
    "已结束",
    "deactivated_workspace",
    "Payment Required",
    "429",
    "不能用",
    "用不了了",
)
STRONG_ID_WORDS = re.compile(r"空间|工作区|workspace|space\s*id|sub2api[_-]", re.I)
WEAK_OR_ACCOUNT_WORDS = re.compile(
    r"access_token|chatgpt_account_id|chatgpt_user_id|user_id|request id|cf-ray|auth error|session_id",
    re.I,
)


@dataclass
class TopicResult:
    topic_id: int
    url: str
    title: str = ""
    published: str = ""
    status: str = "ok"
    ids: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    discovery_sources: list[str] = field(default_factory=list)


def reader_url(topic_id: int) -> str:
    return f"https://r.jina.ai/http://linux.do/t/topic/{topic_id}"


def fetch(url: str, proxy: str, timeout: int, direct_timeout: int) -> tuple[str, str]:
    curl = shutil.which("curl.exe") or shutil.which("curl")
    if curl:
        command = [curl, "-sS", "-L", "--max-time", str(timeout)]
        if proxy:
            command.extend(["-x", proxy])
        command.append(url)
        proc = subprocess.run(command, capture_output=True, text=True, encoding="utf-8", errors="replace")
        if proc.returncode == 0 and proc.stdout:
            return proc.stdout, "proxy-curl" if proxy else "direct-curl"
        message = (proc.stderr or proc.stdout or "").strip()
        proxy_dead = any(x in message.lower() for x in ("connection refused", "proxy", "10061"))
        if proxy_dead and proxy:
            direct_cmd = [curl, "-sS", "-L", "--max-time", str(direct_timeout), url]
            direct = subprocess.run(
                direct_cmd, capture_output=True, text=True, encoding="utf-8", errors="replace"
            )
            if direct.returncode == 0 and direct.stdout:
                return direct.stdout, "direct-curl-fallback"
            return f"FETCH_ERROR: {direct.stderr or direct.stdout}", "failed"
        if message:
            return f"FETCH_ERROR: {message}", "proxy-curl-error"

    headers = {"User-Agent": "Mozilla/5.0"}
    handlers: list[urllib.request.BaseHandler] = []
    if proxy:
        handlers.append(urllib.request.ProxyHandler({"http": proxy, "https": proxy}))
    opener = urllib.request.build_opener(*handlers)
    req = urllib.request.Request(url, headers=headers)
    try:
        with opener.open(req, timeout=timeout) as resp:
            return resp.read().decode("utf-8", errors="replace"), "proxy"
    except Exception as exc:
        message = str(exc)
        proxy_dead = any(x in message.lower() for x in ("connection refused", "proxy", "10061"))
        if not proxy_dead:
            return f"FETCH_ERROR: {message}", "proxy-error"
    direct = urllib.request.build_opener()
    try:
        with direct.open(req, timeout=direct_timeout) as resp:
            return resp.read().decode("utf-8", errors="replace"), "direct-fallback"
    except Exception as exc:
        return f"FETCH_ERROR: {exc}", "failed"


def unique(seq: Iterable[str]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for item in seq:
        key = item.lower()
        if key not in seen:
            seen.add(key)
            out.append(key)
    return out


def decode_obfuscated_base64(text: str) -> list[str]:
    normalized = text.replace("编码或解码", "")
    chunks = re.findall(r"[A-Za-z0-9+/=]{48,}", normalized)
    found: list[str] = []
    for chunk in chunks:
        padded = chunk + ("=" * ((4 - len(chunk) % 4) % 4))
        try:
            decoded = base64.b64decode(padded, validate=False).decode("utf-8", errors="ignore")
        except Exception:
            continue
        found.extend(m.group(0).lower() for m in UUID_RE.finditer(decoded))
    return unique(found)


def extract_space_ids(text: str, title: str) -> tuple[list[str], list[str]]:
    title_is_space_topic = bool(STRONG_ID_WORDS.search(title))
    ids: list[str] = []
    notes: list[str] = []
    for match in UUID_RE.finditer(text):
        value = match.group(0).lower()
        context = text[max(0, match.start() - 400) : match.end() + 400]
        context_is_strong = bool(STRONG_ID_WORDS.search(context))
        context_is_account = bool(WEAK_OR_ACCOUNT_WORDS.search(context))
        if context_is_account and not context_is_strong:
            continue
        if title_is_space_topic or context_is_strong:
            ids.append(value)
            if "sub2api_" in context.lower() and not re.search(r"空间|工作区|workspace", context, re.I):
                notes.append("generic sub2api filename-derived UUID; verify if strict workspace-only output is required")
    decoded = decode_obfuscated_base64(text)
    if decoded:
        if title_is_space_topic:
            ids.extend(decoded)
            notes.append("decoded base64-like visible post text")
        else:
            notes.append("base64-like text decoded but title/context did not confirm space IDs")
    return unique(ids), notes


def extract_topic_ids(text: str) -> list[int]:
    return unique(str(int(m.group(1))) for m in TOPIC_RE.finditer(text))  # type: ignore[return-value]


def parse_topic(topic_id: int, text: str, method: str) -> TopicResult:
    result = TopicResult(topic_id=topic_id, url=f"https://linux.do/t/topic/{topic_id}")
    title_match = TITLE_RE.search(text)
    published_match = PUBLISHED_RE.search(text)
    result.title = title_match.group(1).strip() if title_match else ""
    result.published = published_match.group(1).strip() if published_match else ""
    if text.startswith("FETCH_ERROR"):
        result.status = method
        result.notes.append(text[:180])
        return result
    if PRIVATE_RE.search(text):
        result.status = "private-or-not-found"
        return result
    if not result.title and len(text.strip()) < 80:
        result.status = "empty"
    result.ids, extraction_notes = extract_space_ids(text, result.title)
    result.notes.extend(extraction_notes)
    for word in STATUS_WORDS:
        if word.lower() in text.lower():
            result.notes.append(f"status word: {word}")
    return result


def parse_published(value: str) -> datetime | None:
    if not value:
        return None
    normalized = value.strip().replace("Z", "+00:00")
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        try:
            parsed = parsedate_to_datetime(value)
        except (TypeError, ValueError):
            return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def sort_key(item: TopicResult) -> tuple[bool, datetime, int]:
    parsed = parse_published(item.published)
    return (parsed is not None, parsed or datetime.min.replace(tzinfo=timezone.utc), item.topic_id)


def main() -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    if hasattr(sys.stderr, "reconfigure"):
        sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser()
    parser.add_argument("--limit", type=int, default=30)
    parser.add_argument("--proxy", default=DEFAULT_PROXY)
    parser.add_argument("--timeout", type=int, default=35)
    parser.add_argument("--direct-timeout", type=int, default=15)
    parser.add_argument("--seed-topic", type=int, default=DEFAULT_AGGREGATOR_TOPIC)
    parser.add_argument("--extra-id", action="append", type=int, default=[])
    parser.add_argument("--candidate-id", action="append", type=int, default=[])
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    discovery: dict[str, object]
    candidate_origins: dict[str, list[str]] = {}
    if args.candidate_id:
        candidate_ids = unique(str(i) for i in args.candidate_id)
        for value in candidate_ids:
            candidate_origins[value] = ["explicit-candidate"]
        discovery = {
            "mode": "explicit-candidates",
            "seed_topic": None,
            "seed_candidates_found": 0,
            "seed_candidates_selected": 0,
            "extra_search_ids": [],
            "explicit_candidate_ids": [int(value) for value in candidate_ids],
        }
    else:
        seed_text, _ = fetch(reader_url(args.seed_topic), args.proxy, args.timeout, args.direct_timeout)
        seed_ids = extract_topic_ids(seed_text)
        selected_seed_ids = sorted(seed_ids, key=lambda x: int(x), reverse=True)[: args.limit]
        extra_ids = unique(str(i) for i in args.extra_id)
        candidate_ids = unique([*selected_seed_ids, *extra_ids])
        for value in selected_seed_ids:
            candidate_origins.setdefault(value, []).append("seed-topic")
        for value in extra_ids:
            candidate_origins.setdefault(value, []).append("extra-search")
        discovery = {
            "mode": "seed-plus-extra-search",
            "seed_topic": args.seed_topic,
            "seed_candidates_found": len(seed_ids),
            "seed_candidates_selected": len(selected_seed_ids),
            "extra_search_ids": [int(value) for value in extra_ids],
            "explicit_candidate_ids": [],
        }

    results: list[TopicResult] = []
    for raw_id in candidate_ids:
        topic_id = int(raw_id)
        text, method = fetch(reader_url(topic_id), args.proxy, args.timeout, args.direct_timeout)
        result = parse_topic(topic_id, text, method)
        result.discovery_sources = candidate_origins.get(raw_id, ["unknown"])
        results.append(result)

    results = sorted(results, key=sort_key, reverse=True)
    id_sources: dict[str, list[str]] = {}
    for idx, item in enumerate(results, start=1):
        label = f"S{idx}"
        for value in item.ids:
            id_sources.setdefault(value, []).append(label)

    payload = {
        "discovery": discovery,
        "sources": [item.__dict__ for item in results],
        "ids": [{"id": value, "sources": labels} for value, labels in sorted(id_sources.items())],
    }
    if args.json:
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    print("Discovery coverage:")
    print(json.dumps(discovery, ensure_ascii=False))
    print()
    print("Sources:")
    for idx, item in enumerate(results, start=1):
        origins = ",".join(item.discovery_sources)
        print(f"S{idx}: {item.published or 'unknown-time'} [{origins}] {item.url} {item.title or item.status}")
        if item.status != "ok" or item.notes:
            note = "; ".join([item.status] + item.notes)
            print(f"    note: {note}")
    print()
    print("IDs:")
    if not id_sources:
        print("none")
    else:
        for value, labels in sorted(id_sources.items()):
            print(f"{value} | {', '.join(labels)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
