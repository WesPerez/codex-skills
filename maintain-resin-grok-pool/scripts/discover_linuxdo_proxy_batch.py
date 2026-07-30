#!/usr/bin/env python3
"""Refresh a small deterministic proxy sample from recent public LINUX DO topics."""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import email.utils
import hashlib
import html.parser
import importlib.util
import json
import math
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.parse
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence

from proxy_probe import ProxySpec, atomic_write, parse_proxy_line


OWNER = "maintain-resin-grok-pool"
VERSION = 1
AUTHOR_RE = re.compile(r"^[A-Za-z0-9_][A-Za-z0-9_-]{0,63}$")
TOPIC_LINK_RE = re.compile(
    r"\[(?P<title>[^\]\r\n]+)\]\(https?://linux\.do/t/(?:topic/)?(?P<id>[0-9]+)(?:/[0-9]+)?\)"
)
DECLARED_NODES_RE = re.compile(r"(?P<count>[0-9]{3,})\s*个\s*HTTP\s*代理", re.IGNORECASE)
TTL_RE = re.compile(r"(?P<days>[1-9][0-9]?)\s*天\s*有效")
READER_MARKER = "Markdown Content:"
DEFAULT_PATHS = ("direct",)
DEFAULT_RATE_LIMIT_WAIT_SECONDS = 30.0
DEFAULT_RATE_LIMIT_WAIT_BUDGET_SECONDS = 60.0
MAX_SAME_PATH_RATE_LIMIT_WAITS = 2
NESTED_RATE_LIMIT_RE = re.compile(
    r"(?im)^Warning:\s*Target URL returned error 429\b|"
    r"You(?:'|\u2019)ve performed this action too many times, please try again later\."
)


class DiscoveryError(RuntimeError):
    pass


class DiscoveryUnavailable(DiscoveryError):
    pass


class DiscoveryDeferred(DiscoveryUnavailable):
    pass


@dataclasses.dataclass(frozen=True)
class NetworkPath:
    label: str
    proxy: str = ""


@dataclasses.dataclass(frozen=True)
class Attachment:
    short_url: str
    filename: str


@dataclasses.dataclass(frozen=True)
class Topic:
    topic_id: int
    title: str
    created_at: dt.datetime
    expires_at: dt.datetime
    declared_nodes: int
    attachments: tuple[Attachment, ...]


@dataclasses.dataclass
class WaitBudget:
    total_seconds: float
    spent_seconds: float = 0.0

    @property
    def remaining_seconds(self) -> float:
        return max(0.0, self.total_seconds - self.spent_seconds)

    def wait(self, seconds: float, sleeper: Callable[[float], None]) -> bool:
        if seconds <= 0 or seconds > self.remaining_seconds + 1e-9:
            return False
        sleeper(seconds)
        self.spent_seconds += seconds
        return True


class CookedParser(html.parser.HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.text: list[str] = []
        self.attachments: list[Attachment] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag != "a":
            return
        values = {key: value or "" for key, value in attrs}
        href = values.get("href", "")
        if "/uploads/short-url/" not in href:
            return
        short = href.split("/uploads/short-url/", 1)[1].split("?", 1)[0].split("#", 1)[0]
        if short:
            self.attachments.append(Attachment(short_url=short, filename=""))

    def handle_data(self, data: str) -> None:
        value = data.strip()
        if value:
            self.text.append(value)


def parse_timestamp(value: Any) -> dt.datetime:
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError as exc:
        raise DiscoveryError("invalid topic timestamp") from exc
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def safe_error(exc: BaseException) -> str:
    if isinstance(exc, DiscoveryError):
        return str(exc)
    return exc.__class__.__name__


def parse_network_path(raw: str) -> NetworkPath:
    value = raw.strip()
    if value == "direct":
        return NetworkPath("direct", "")
    label, separator, proxy = value.partition("=")
    if not separator or not re.fullmatch(r"[A-Za-z0-9_-]{1,32}", label):
        raise DiscoveryError("network path must be direct or label=proxy-url")
    parsed = urllib.parse.urlsplit(proxy)
    if parsed.scheme not in {"http", "socks5h"} or not parsed.hostname or parsed.username or parsed.password:
        raise DiscoveryError("network path proxy must be credential-free HTTP or SOCKS5H")
    if parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise DiscoveryError("network path proxy must not contain a path or query")
    return NetworkPath(label, proxy.rstrip("/"))


def prefer_network_path(paths: Sequence[NetworkPath], label: str) -> tuple[NetworkPath, ...]:
    preferred = [item for item in paths if item.label == label]
    return tuple(preferred + [item for item in paths if item.label != label])


def validate_network_paths(paths: Sequence[NetworkPath]) -> None:
    if len({item.label for item in paths}) != len(paths):
        raise DiscoveryError("network path labels must be unique")
    if len({item.proxy for item in paths}) != len(paths):
        raise DiscoveryError("network paths must use distinct proxy routes")


def extract_reader_markdown(raw: str) -> str:
    marker = raw.find(READER_MARKER)
    if marker < 0:
        raise DiscoveryUnavailable("reader response is missing Markdown Content")
    return raw[marker + len(READER_MARKER) :].lstrip()


def parse_reader_json(raw: str) -> dict[str, Any]:
    content = extract_reader_markdown(raw)
    start = content.find("{")
    if start < 0:
        raise DiscoveryUnavailable("reader response has no JSON object")
    try:
        payload, _ = json.JSONDecoder().raw_decode(content[start:])
    except json.JSONDecodeError as exc:
        raise DiscoveryUnavailable("reader JSON is invalid") from exc
    if not isinstance(payload, dict):
        raise DiscoveryUnavailable("reader JSON root is invalid")
    return payload


def discover_topic_ids(author_markdown: str, minimum_nodes: int, maximum: int) -> list[int]:
    found: list[tuple[int, int]] = []
    seen: set[int] = set()
    for match in TOPIC_LINK_RE.finditer(author_markdown):
        topic_id = int(match.group("id"))
        title = match.group("title")
        declared = DECLARED_NODES_RE.search(title)
        if topic_id in seen or declared is None or int(declared.group("count")) < minimum_nodes:
            continue
        seen.add(topic_id)
        found.append((topic_id, int(declared.group("count"))))
    found.sort(key=lambda item: item[0], reverse=True)
    return [topic_id for topic_id, _ in found[:maximum]]


def discover_category_topic_ids(payload: Mapping[str, Any], minimum_nodes: int) -> list[int]:
    topic_list = payload.get("topic_list")
    topics = topic_list.get("topics") if isinstance(topic_list, Mapping) else None
    if not isinstance(topics, list):
        raise DiscoveryUnavailable("category JSON is missing topics")
    found: list[tuple[dt.datetime, int]] = []
    for item in topics:
        if not isinstance(item, Mapping):
            continue
        topic_id = int(item.get("id") or 0)
        title = str(item.get("title") or item.get("fancy_title") or "")
        declared = DECLARED_NODES_RE.search(title)
        if topic_id < 1 or declared is None or int(declared.group("count")) < minimum_nodes:
            continue
        try:
            created_at = parse_timestamp(item.get("created_at"))
        except DiscoveryError:
            continue
        found.append((created_at, topic_id))
    found.sort(reverse=True)
    return [topic_id for _, topic_id in found]


def parse_topic(payload: Mapping[str, Any]) -> Topic:
    stream = payload.get("post_stream")
    posts = stream.get("posts") if isinstance(stream, Mapping) else None
    if not isinstance(posts, list):
        raise DiscoveryUnavailable("topic JSON is missing posts")
    first = next(
        (
            item
            for item in posts
            if isinstance(item, Mapping) and int(item.get("post_number") or 0) == 1
        ),
        None,
    )
    if not isinstance(first, Mapping):
        raise DiscoveryUnavailable("topic JSON is missing post 1")
    topic_id = int(payload.get("id") or first.get("topic_id") or 0)
    title = str(payload.get("title") or "")
    created_at = parse_timestamp(first.get("created_at") or payload.get("created_at"))
    cooked = str(first.get("cooked") or "")
    parser = CookedParser()
    parser.feed(cooked)
    text = " ".join(parser.text)
    ttl_match = TTL_RE.search(text)
    declared_match = DECLARED_NODES_RE.search(title) or DECLARED_NODES_RE.search(text)
    if topic_id < 1 or not title or ttl_match is None or declared_match is None:
        raise DiscoveryUnavailable("topic lacks an HTTP proxy count or validity window")
    attachments: list[Attachment] = []
    seen_short: set[str] = set()
    for attachment in parser.attachments:
        if attachment.short_url in seen_short or not attachment.short_url.lower().endswith(".txt"):
            continue
        seen_short.add(attachment.short_url)
        attachments.append(attachment)
    if not attachments:
        raise DiscoveryUnavailable("topic has no public text attachments")
    ttl_days = int(ttl_match.group("days"))
    return Topic(
        topic_id=topic_id,
        title=title,
        created_at=created_at,
        expires_at=created_at + dt.timedelta(days=ttl_days),
        declared_nodes=int(declared_match.group("count")),
        attachments=tuple(attachments),
    )


def load_discourse_helper(path: Path):
    if not path.is_file():
        raise DiscoveryError("Discourse upload helper is missing")
    spec = importlib.util.spec_from_file_location("discourse_public_upload_for_pool", path)
    if spec is None or spec.loader is None:
        raise DiscoveryError("unable to load Discourse upload helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_response_headers(path: Path) -> dict[str, str]:
    headers: dict[str, str] = {}
    for line in path.read_text(encoding="iso-8859-1", errors="replace").splitlines():
        if ":" not in line:
            if line.startswith("HTTP/"):
                headers = {}
            continue
        name, value = line.split(":", 1)
        headers[name.strip().lower()] = value.strip()
    return headers


def parse_retry_after(value: str, now: dt.datetime | None = None) -> float | None:
    raw = value.strip()
    if not raw:
        return None
    if re.fullmatch(r"[0-9]+(?:\.[0-9]+)?", raw):
        seconds = float(raw)
        return seconds if math.isfinite(seconds) and seconds > 0 else None
    try:
        parsed = email.utils.parsedate_to_datetime(raw)
    except (TypeError, ValueError, OverflowError):
        return None
    if parsed is None:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    reference = now or dt.datetime.now(dt.timezone.utc)
    seconds = (parsed.astimezone(dt.timezone.utc) - reference.astimezone(dt.timezone.utc)).total_seconds()
    return max(1.0, math.ceil(seconds)) if seconds > 0 else None


def is_nested_rate_limit(raw: str) -> bool:
    return bool(NESTED_RATE_LIMIT_RE.search(raw[:64 * 1024]))


def read_small_text(path: Path, max_bytes: int) -> str:
    if not path.is_file():
        return ""
    with path.open("rb") as handle:
        raw = handle.read(min(max_bytes, 64 * 1024) + 1)
    return raw.decode("utf-8", errors="replace")


def validate_download_length(path: Path, headers: Mapping[str, str]) -> bool:
    raw = headers.get("content-length", "").strip()
    if not raw:
        return True
    try:
        expected = int(raw)
    except ValueError:
        return False
    return expected >= 0 and path.is_file() and path.stat().st_size == expected


def curl_get(
    url: str,
    destination: Path,
    network_path: NetworkPath,
    timeout: float,
    max_bytes: int,
) -> tuple[int, dict[str, str], bool]:
    header_path = destination.with_suffix(destination.suffix + ".headers")
    command = [
        "/usr/bin/curl",
        "--silent",
        "--show-error",
        "--connect-timeout",
        str(min(timeout, 10.0)),
        "--max-time",
        str(timeout),
        "--max-filesize",
        str(max_bytes),
        "--output",
        str(destination),
        "--dump-header",
        str(header_path),
        "--write-out",
        "%{http_code}",
    ]
    if network_path.proxy:
        command.extend(("--proxy", network_path.proxy))
    command.append(url)
    completed = subprocess.run(command, capture_output=True, text=True, timeout=timeout + 5, check=False)
    try:
        status = int((completed.stdout or "0").strip()[-3:])
    except ValueError:
        status = 0
    headers = parse_response_headers(header_path) if header_path.is_file() else {}
    if destination.is_file() and destination.stat().st_size > max_bytes:
        destination.unlink()
        raise DiscoveryUnavailable("download exceeded the configured size limit")
    if completed.returncode != 0 and status == 0:
        return 0, headers, False
    if completed.returncode != 0:
        destination.unlink(missing_ok=True)
        return status, headers, False
    if 200 <= status < 300 and not validate_download_length(destination, headers):
        destination.unlink(missing_ok=True)
        return status, headers, False
    return status, headers, True


def fetch_bounded(
    url: str,
    destination: Path,
    paths: Sequence[NetworkPath],
    timeout: float,
    max_bytes: int,
    wait_budget: WaitBudget | None = None,
    wait_seconds: float = DEFAULT_RATE_LIMIT_WAIT_SECONDS,
    sleeper: Callable[[float], None] = time.sleep,
) -> str:
    if len(paths) < 1 or len(paths) > 3:
        raise DiscoveryError("anonymous network path budget must be between one and three")
    budget = wait_budget or WaitBudget(DEFAULT_RATE_LIMIT_WAIT_BUDGET_SECONDS)
    last_status = 0
    for network_path in paths:
        same_path_waits = 0
        while True:
            destination.unlink(missing_ok=True)
            destination.with_suffix(destination.suffix + ".headers").unlink(missing_ok=True)
            status, headers, transport_ok = curl_get(url, destination, network_path, timeout, max_bytes)
            last_status = status
            body = read_small_text(destination, max_bytes) if destination.is_file() else ""
            rate_limited = status == 429 or (
                transport_ok and 200 <= status < 300 and is_nested_rate_limit(body)
            )
            if transport_ok and 200 <= status < 300 and destination.is_file() and not rate_limited:
                return network_path.label
            if not rate_limited:
                if status in {400, 401, 404, 410}:
                    raise DiscoveryUnavailable(f"anonymous fetch stopped at hard HTTP {status}")
                break

            retry_after = parse_retry_after(headers.get("retry-after", ""))
            if retry_after is not None:
                if same_path_waits >= MAX_SAME_PATH_RATE_LIMIT_WAITS:
                    raise DiscoveryDeferred(
                        "anonymous fetch remained rate limited with Retry-After on the same path"
                    )
                if not budget.wait(retry_after, sleeper):
                    raise DiscoveryDeferred(
                        "anonymous fetch Retry-After exceeds the remaining discovery wait budget"
                    )
                same_path_waits += 1
                continue
            if (
                same_path_waits < MAX_SAME_PATH_RATE_LIMIT_WAITS
                and budget.wait(wait_seconds, sleeper)
            ):
                same_path_waits += 1
                continue
            break
    raise DiscoveryUnavailable(f"anonymous fetch failed after bounded paths (HTTP {last_status})")


def pick_attachments(topic: Topic, count: int, day_key: str) -> tuple[Attachment, ...]:
    count = min(max(1, count), len(topic.attachments))
    seed = int(hashlib.sha256(f"{day_key}:{topic.topic_id}".encode()).hexdigest(), 16)
    start = seed % len(topic.attachments)
    stride = max(1, len(topic.attachments) // count)
    selected: list[Attachment] = []
    index = start
    while len(selected) < count:
        candidate = topic.attachments[index % len(topic.attachments)]
        if candidate not in selected:
            selected.append(candidate)
        index += stride
    return tuple(selected)


def ranked_sample(
    topic_specs: Mapping[int, Mapping[str, ProxySpec]],
    sample_size: int,
    seed: str,
) -> list[ProxySpec]:
    if sample_size < 1 or not topic_specs:
        return []
    topic_ids = sorted(topic_specs, reverse=True)
    selected: dict[str, ProxySpec] = {}
    base = sample_size // len(topic_ids)
    remainder = sample_size % len(topic_ids)
    for index, topic_id in enumerate(topic_ids):
        quota = base + (1 if index < remainder else 0)
        ranked = sorted(
            topic_specs[topic_id].values(),
            key=lambda spec: hashlib.sha256(f"{seed}:{topic_id}:{spec.canonical}".encode()).digest(),
        )
        for spec in ranked:
            if len([key for key in selected if key.startswith(f"{topic_id}:")]) >= quota:
                break
            if any(value.canonical == spec.canonical for value in selected.values()):
                continue
            selected[f"{topic_id}:{spec.fingerprint}"] = spec
    if len(selected) < sample_size:
        remaining: list[tuple[bytes, int, ProxySpec]] = []
        seen = {spec.canonical for spec in selected.values()}
        for topic_id in topic_ids:
            for spec in topic_specs[topic_id].values():
                if spec.canonical in seen:
                    continue
                score = hashlib.sha256(f"{seed}:fill:{topic_id}:{spec.canonical}".encode()).digest()
                remaining.append((score, topic_id, spec))
        remaining.sort(key=lambda item: (item[0], item[1]))
        for _, topic_id, spec in remaining:
            if len(selected) >= sample_size:
                break
            if spec.canonical in seen:
                continue
            seen.add(spec.canonical)
            selected[f"{topic_id}:{spec.fingerprint}"] = spec
    return list(selected.values())[:sample_size]


def parse_proxy_file(path: Path) -> tuple[dict[str, ProxySpec], int]:
    specs: dict[str, ProxySpec] = {}
    rejected = 0
    for raw in path.read_text(encoding="utf-8-sig", errors="replace").splitlines():
        try:
            spec = parse_proxy_line(raw)
        except (TypeError, ValueError):
            rejected += 1
            continue
        if spec is not None:
            specs.setdefault(spec.canonical, spec)
    return specs, rejected


def existing_manifest(path: Path) -> dict[str, Any] | None:
    if not path.is_file() or path.stat().st_mode & 0o077:
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def has_existing_source(output: Path, manifest_path: Path, manifest: Mapping[str, Any] | None) -> bool:
    if manifest is None:
        return False
    content_file = manifest.get("content_file")
    if isinstance(content_file, str) and Path(content_file).name == content_file:
        generation = manifest_path.parent / content_file
        if generation.is_file() and not generation.is_symlink() and not generation.stat().st_mode & 0o077:
            return True
    return output.is_file() and not output.is_symlink() and not output.stat().st_mode & 0o077


def publish_source_generation(
    output: Path,
    manifest_path: Path,
    payload: bytes,
    manifest: Mapping[str, Any],
) -> bool:
    if output.parent != manifest_path.parent:
        raise DiscoveryError("output and manifest must share a directory")
    digest = hashlib.sha256(payload).hexdigest()
    generation = output.with_name(f"{output.stem}.{digest}{output.suffix}")
    if generation.exists():
        if not generation.is_file() or generation.read_bytes() != payload:
            raise DiscoveryError("existing source generation does not match its content hash")
        os.chmod(generation, 0o600)
    else:
        atomic_write(generation, payload, mode=0o600)
    published = dict(manifest)
    published["content_file"] = generation.name
    atomic_write(
        manifest_path,
        (json.dumps(published, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8"),
        mode=0o600,
    )
    try:
        atomic_write(output, payload, mode=0o600)
    except OSError:
        return False
    return True


def recover_legacy_source_generation(output: Path, manifest_path: Path) -> bool:
    manifest = existing_manifest(manifest_path)
    if manifest is None or manifest.get("content_file") not in (None, "") or not output.is_file():
        return False
    if output.stat().st_mode & 0o077:
        return False
    data = output.read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    if (
        manifest.get("owner") != OWNER
        or not isinstance(manifest.get("source_id"), str)
        or manifest.get("content_sha256") != digest
        or int(manifest.get("line_count") or 0) != len(data.decode("utf-8-sig", "replace").splitlines())
    ):
        return False
    generation = output.with_name(f"{output.stem}.{digest}{output.suffix}")
    if not generation.exists():
        atomic_write(generation, data, mode=0o600)
    else:
        if not generation.is_file() or generation.read_bytes() != data:
            raise DiscoveryError("existing legacy source generation does not match its hash")
        os.chmod(generation, 0o600)
    updated = dict(manifest)
    updated["content_file"] = generation.name
    atomic_write(
        manifest_path,
        (json.dumps(updated, ensure_ascii=True, indent=2, sort_keys=True) + "\n").encode("utf-8"),
        mode=0o600,
    )
    return True


def prune_source_generations(output: Path, manifest: Mapping[str, Any]) -> None:
    keep = str(manifest.get("content_file") or "")
    pattern = f"{output.stem}.*{output.suffix}"
    generation_re = re.compile(
        rf"^{re.escape(output.stem)}\.[0-9a-f]{{64}}{re.escape(output.suffix)}$"
    )
    for path in output.parent.glob(pattern):
        if (
            path.name == keep
            or not generation_re.fullmatch(path.name)
            or not path.is_file()
            or path.is_symlink()
        ):
            continue
        path.unlink()


def refresh(args: argparse.Namespace) -> dict[str, Any]:
    if not AUTHOR_RE.fullmatch(args.author):
        raise DiscoveryError("invalid LINUX DO author")
    paths = tuple(parse_network_path(item) for item in (args.network_path or DEFAULT_PATHS))
    validate_network_paths(paths)
    now = dt.datetime.now(dt.timezone.utc)
    day_key = now.date().isoformat()
    wait_budget = WaitBudget(args.rate_limit_wait_budget)
    output = Path(args.output).resolve()
    manifest_path = Path(args.manifest).resolve()
    helper = load_discourse_helper(Path(args.discourse_helper).resolve())
    cdn_root = args.cdn_root.rstrip("/")
    author_url = f"https://r.jina.ai/http://linux.do/u/{args.author}/activity/topics"
    with tempfile.TemporaryDirectory(prefix="linuxdo-discovery-", dir=str(output.parent)) as temp_raw:
        temp = Path(temp_raw)
        index_audit: list[dict[str, Any]] = []
        discovered_ids: set[int] = set()
        current_paths = paths
        author_path = "unavailable"
        author_file = temp / "author.txt"
        try:
            author_path = fetch_bounded(
                author_url,
                author_file,
                current_paths,
                args.timeout,
                args.max_reader_bytes,
                wait_budget,
                args.rate_limit_wait_seconds,
            )
            author_markdown = extract_reader_markdown(author_file.read_text(encoding="utf-8", errors="replace"))
            author_ids = discover_topic_ids(
                author_markdown, args.minimum_declared_nodes, args.max_topic_lookups
            )
            discovered_ids.update(author_ids)
            current_paths = prefer_network_path(paths, author_path)
            index_audit.append(
                {"kind": "author_topics", "status": "loaded", "path": author_path, "candidate_count": len(author_ids)}
            )
        except DiscoveryDeferred:
            raise
        except DiscoveryUnavailable as exc:
            index_audit.append(
                {"kind": "author_topics", "status": "unavailable", "reason": safe_error(exc)}
            )

        category_file = temp / "category.txt"
        try:
            category_path = fetch_bounded(
                args.category_index_url,
                category_file,
                current_paths,
                args.timeout,
                args.max_reader_bytes,
                wait_budget,
                args.rate_limit_wait_seconds,
            )
            category_ids = discover_category_topic_ids(
                parse_reader_json(category_file.read_text(encoding="utf-8", errors="replace")),
                args.minimum_declared_nodes,
            )
            discovered_ids.update(category_ids)
            current_paths = prefer_network_path(paths, category_path)
            index_audit.append(
                {
                    "kind": "category_latest",
                    "status": "loaded",
                    "path": category_path,
                    "candidate_count": len(category_ids),
                }
            )
        except DiscoveryDeferred:
            raise
        except DiscoveryUnavailable as exc:
            index_audit.append(
                {"kind": "category_latest", "status": "unavailable", "reason": safe_error(exc)}
            )
        topic_ids = sorted(discovered_ids, reverse=True)[: args.max_topic_lookups]
        if not topic_ids:
            raise DiscoveryUnavailable("public indexes yielded no large HTTP proxy topics")
        discovered_topics: list[Topic] = []
        topic_paths: dict[int, str] = {}
        for topic_id in topic_ids:
            topic_file = temp / f"topic-{topic_id}.txt"
            try:
                path_label = fetch_bounded(
                    f"https://r.jina.ai/http://linux.do/t/{topic_id}.json",
                    topic_file,
                    current_paths,
                    args.timeout,
                    args.max_reader_bytes,
                    wait_budget,
                    args.rate_limit_wait_seconds,
                )
                topic = parse_topic(parse_reader_json(topic_file.read_text(encoding="utf-8", errors="replace")))
            except DiscoveryDeferred:
                raise
            except DiscoveryUnavailable:
                continue
            if topic.expires_at <= now:
                continue
            discovered_topics.append(topic)
            topic_paths[topic.topic_id] = path_label
            current_paths = prefer_network_path(paths, path_label)
        topics = sorted(discovered_topics, key=lambda item: (item.created_at, item.topic_id), reverse=True)[
            : args.max_topics
        ]
        if not topics:
            raise DiscoveryUnavailable("no recent unexpired HTTP proxy topic was found")

        topic_specs: dict[int, dict[str, ProxySpec]] = {}
        topic_audit: list[dict[str, Any]] = []
        for topic in topics:
            selected_attachments = pick_attachments(topic, args.max_attachments_per_topic, day_key)
            specs: dict[str, ProxySpec] = {}
            rejected = 0
            download_paths: set[str] = set()
            attachment_hashes: list[str] = []
            for index, attachment in enumerate(selected_attachments, start=1):
                _, cdn_url = helper.build_public_url(attachment.short_url, cdn_root)
                attachment_file = temp / f"topic-{topic.topic_id}-attachment-{index}.txt"
                path_label = fetch_bounded(
                    cdn_url,
                    attachment_file,
                    current_paths,
                    args.timeout,
                    args.max_attachment_bytes,
                    wait_budget,
                    args.rate_limit_wait_seconds,
                )
                download_paths.add(path_label)
                current_paths = prefer_network_path(paths, path_label)
                parsed, rejected_count = parse_proxy_file(attachment_file)
                specs.update(parsed)
                rejected += rejected_count
                attachment_hashes.append(hashlib.sha256(attachment_file.read_bytes()).hexdigest())
            if specs:
                topic_specs[topic.topic_id] = specs
            topic_audit.append(
                {
                    "topic_id": topic.topic_id,
                    "topic_url": f"https://linux.do/t/topic/{topic.topic_id}",
                    "created_at": topic.created_at.isoformat(),
                    "expires_at": topic.expires_at.isoformat(),
                    "declared_nodes": topic.declared_nodes,
                    "attachment_count": len(topic.attachments),
                    "downloaded_attachments": len(selected_attachments),
                    "parsed_unique": len(specs),
                    "rejected_lines": rejected,
                    "reader_path": topic_paths[topic.topic_id],
                    "download_paths": sorted(download_paths),
                    "attachment_sha256": sorted(attachment_hashes),
                }
            )
        sampled = ranked_sample(topic_specs, args.sample_size, day_key)
        if len(sampled) < args.minimum_sample_size:
            raise DiscoveryUnavailable("recent topics did not yield enough parseable proxies")
        payload = "".join(f"{spec.canonical}\n" for spec in sampled).encode("utf-8")
        digest = hashlib.sha256(payload).hexdigest()
        expires_at = min(topic.expires_at for topic in topics if topic.topic_id in topic_specs)
        manifest = {
            "version": VERSION,
            "owner": OWNER,
            "source_id": args.source_id,
            "generated_at": now.isoformat(),
            "expires_at": expires_at.isoformat(),
            "content_sha256": digest,
            "line_count": len(sampled),
            "author": args.author,
            "author_path": author_path,
            "rate_limit_wait_seconds": wait_budget.spent_seconds,
            "indexes": index_audit,
            "topics": sorted(topic_audit, key=lambda item: (item["created_at"], item["topic_id"]), reverse=True),
        }
        previous = existing_manifest(manifest_path)
        status = "no_change" if previous and previous.get("content_sha256") == digest else "updated"
        compatibility_output_updated = True
        if not args.dry_run:
            compatibility_output_updated = publish_source_generation(
                output, manifest_path, payload, manifest
            )
            published_manifest = existing_manifest(manifest_path)
            if published_manifest is not None:
                prune_source_generations(output, published_manifest)
        return {
            "status": status if not args.dry_run else "dry_run",
            "topic_count": len(topic_specs),
            "line_count": len(sampled),
            "expires_at": expires_at.isoformat(),
            "rate_limit_wait_seconds": wait_budget.spent_seconds,
            "compatibility_output_updated": compatibility_output_updated,
        }


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--author", default="cjb0617")
    parser.add_argument(
        "--category-index-url",
        default="https://r.jina.ai/http://linux.do/c/welfare/36/l/latest.json",
    )
    parser.add_argument("--source-id", default="linuxdo-current-public-batches")
    parser.add_argument("--output", required=True)
    parser.add_argument("--manifest", required=True)
    parser.add_argument("--cdn-root", default="https://cdn3.ldstatic.com/original/4X")
    parser.add_argument(
        "--discourse-helper",
        default="/root/.codex/skills/linux-do-research/scripts/discourse_public_upload.py",
    )
    parser.add_argument("--network-path", action="append")
    parser.add_argument("--sample-size", type=int, default=500)
    parser.add_argument("--minimum-sample-size", type=int, default=100)
    parser.add_argument("--minimum-declared-nodes", type=int, default=1000)
    parser.add_argument("--max-topics", type=int, default=3)
    parser.add_argument("--max-topic-lookups", type=int, default=6)
    parser.add_argument("--max-attachments-per-topic", type=int, default=2)
    parser.add_argument("--max-reader-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--max-attachment-bytes", type=int, default=1024 * 1024)
    parser.add_argument("--timeout", type=float, default=30.0)
    parser.add_argument(
        "--rate-limit-wait-seconds",
        type=float,
        default=DEFAULT_RATE_LIMIT_WAIT_SECONDS,
    )
    parser.add_argument(
        "--rate-limit-wait-budget",
        type=float,
        default=DEFAULT_RATE_LIMIT_WAIT_BUDGET_SECONDS,
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if not (1 <= args.max_topics <= 3 and args.max_topics <= args.max_topic_lookups <= 10):
        raise DiscoveryError("topic limits are invalid")
    if not (1 <= args.max_attachments_per_topic <= 2):
        raise DiscoveryError("attachment limit must be one or two per topic")
    if not (1 <= args.minimum_sample_size <= args.sample_size <= 3000):
        raise DiscoveryError("sample size limits are invalid")
    if args.timeout <= 0 or args.timeout > 60:
        raise DiscoveryError("timeout must be in (0, 60]")
    if args.rate_limit_wait_seconds <= 0 or args.rate_limit_wait_seconds > 60:
        raise DiscoveryError("rate-limit wait seconds must be in (0, 60]")
    if args.rate_limit_wait_budget < 0 or args.rate_limit_wait_budget > 60:
        raise DiscoveryError("rate-limit wait budget must be in [0, 60]")
    output = Path(args.output).resolve()
    manifest = Path(args.manifest).resolve()
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(output.parent, 0o700)
    recover_legacy_source_generation(output, manifest)
    try:
        result = refresh(args)
    except DiscoveryUnavailable as exc:
        existing = existing_manifest(manifest)
        print(
            json.dumps(
                {
                    "status": "retained" if existing else "unavailable",
                    "reason": safe_error(exc),
                    "has_existing_source": has_existing_source(output, manifest, existing),
                },
                ensure_ascii=True,
                sort_keys=True,
            )
        )
        return 0
    print(json.dumps(result, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DiscoveryError, OSError, ValueError, subprocess.SubprocessError) as exc:
        print(json.dumps({"status": "error", "error": safe_error(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(2)
