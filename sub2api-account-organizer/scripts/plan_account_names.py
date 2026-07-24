#!/usr/bin/env python3
"""Build and verify reversible Sub2API account-name organization plans.

The script only consumes redacted admin API responses. It never connects to a
database or API and never writes credentials or raw endpoint URLs into a plan.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit, urlunsplit


PLAN_VERSION = 7
SUPPORTED_PLAN_VERSIONS = {6, PLAN_VERSION}
POLICY_SCHEMA_VERSION = 1
MAX_ACCOUNT_NAME_LENGTH = 100
MANAGED_PREFIX_RE = re.compile(
    r"^(?:\[@url:[^\]\r\n]{1,64}\]\s+|!S2:\d{5}:\d{2}:[0-9a-f]{10}\s+|![0-9A-Z]{2}-)"
)
BASE36_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ"
PLATFORM_FIXED_PREFIXES = {"grok": "zzzz-"}
DEFAULT_POLICY_PATH = Path(__file__).resolve().parents[1] / "local" / "sort-policy.json"
POLICY_KEYS = {
    "schema_version",
    "exclude_platforms",
    "order_markers",
    "name_buckets",
    "model_buckets",
    "route_buckets",
}


class PlanError(ValueError):
    pass


def read_json(path: str) -> Any:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json_0600(path: str, payload: Any) -> None:
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    fd = os.open(target, flags, 0o600)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, ensure_ascii=False, indent=2, sort_keys=True)
            handle.write("\n")
    finally:
        try:
            os.chmod(target, 0o600)
        except FileNotFoundError:
            pass


def unwrap_accounts(payload: Any) -> list[dict[str, Any]]:
    if isinstance(payload, list):
        items = payload
    elif isinstance(payload, dict):
        for key in ("items", "accounts"):
            if isinstance(payload.get(key), list):
                items = payload[key]
                break
        else:
            nested = payload.get("data")
            if nested is payload:
                raise PlanError("recursive data wrapper")
            if nested is not None:
                return unwrap_accounts(nested)
            raise PlanError("cannot find an account array in input JSON")
    else:
        raise PlanError("account input must be a JSON array or API response object")

    result: list[dict[str, Any]] = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise PlanError(f"account at index {index} is not an object")
        result.append(item)
    return result


def account_id(account: dict[str, Any]) -> int:
    value = account.get("id")
    if isinstance(value, bool):
        raise PlanError("boolean account id is invalid")
    try:
        parsed = int(value)
    except (TypeError, ValueError) as exc:
        raise PlanError(f"invalid account id: {value!r}") from exc
    if parsed <= 0:
        raise PlanError(f"account id must be positive: {parsed}")
    return parsed


def string_map(value: Any) -> dict[str, Any]:
    return value if isinstance(value, dict) else {}


def string_value(value: Any) -> str:
    return value.strip() if isinstance(value, str) else ""


def truthy(value: Any) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, (int, float)):
        return value != 0
    if isinstance(value, str):
        return value.strip().lower() in {"1", "true", "yes", "on"}
    return False


def safe_label(raw: str, fallback: str) -> str:
    label = unicodedata.normalize("NFKC", raw or fallback)
    label = re.sub(r"[\]\[\r\n\t/\\]+", "-", label)
    label = re.sub(r"\s+", "-", label).strip("-._:")
    if not label:
        label = fallback
    return label[:32]


def normalize_url(raw: str, fallback_label: str) -> tuple[str, str]:
    raw = raw.strip()
    try:
        parsed = urlsplit(raw)
        hostname = parsed.hostname
    except ValueError:
        parsed = None
        hostname = None

    if parsed is None or not parsed.scheme or not hostname:
        normalized = "opaque:" + raw.casefold()
        return normalized, safe_label(fallback_label + "-custom", fallback_label)

    scheme = parsed.scheme.lower()
    host = hostname.rstrip(".").lower()
    try:
        host = host.encode("idna").decode("ascii")
    except UnicodeError:
        pass
    try:
        port = parsed.port
    except ValueError as exc:
        raise PlanError(f"invalid port in base URL for {fallback_label}") from exc
    default_port = (scheme == "http" and port == 80) or (scheme == "https" and port == 443)
    if ":" in host and not host.startswith("["):
        host_for_netloc = f"[{host}]"
    else:
        host_for_netloc = host
    netloc = host_for_netloc if port is None or default_port else f"{host_for_netloc}:{port}"
    path = parsed.path.rstrip("/") or "/"
    # Query parameters are not part of a base endpoint category. They often
    # contain deployment options or credentials and must not split one relay.
    normalized = urlunsplit((scheme, netloc, path, "", ""))
    return normalized, safe_label(netloc, fallback_label)


def default_endpoint_key(platform: str, account_type: str) -> tuple[str, str]:
    label = safe_label(f"{platform}-{account_type}-default", "unknown-default")
    return f"default:{platform}:{account_type}", label


def effective_endpoint(
    account: dict[str, Any],
    by_id: dict[int, dict[str, Any]],
    overrides: dict[int, str],
    stack: set[int] | None = None,
) -> tuple[str, str]:
    aid = account_id(account)
    if aid in overrides:
        label = safe_label(overrides[aid], "manual")
        return "manual:" + unicodedata.normalize("NFKC", overrides[aid]).casefold(), label

    parent_value = account.get("parent_account_id")
    if parent_value not in (None, "", 0, "0"):
        try:
            parent_id = int(parent_value)
        except (TypeError, ValueError) as exc:
            raise PlanError(f"account {aid} has invalid parent_account_id") from exc
        if parent_id not in by_id:
            raise PlanError(f"account {aid} references missing parent account {parent_id}")
        stack = set() if stack is None else set(stack)
        if aid in stack:
            raise PlanError(f"parent account cycle includes {aid}")
        stack.add(aid)
        return effective_endpoint(by_id[parent_id], by_id, overrides, stack)

    platform = string_value(account.get("platform")).lower() or "unknown"
    account_type = string_value(account.get("type")).lower() or "unknown"
    credentials = string_map(account.get("credentials"))
    extra = string_map(account.get("extra"))
    fallback = f"{platform}-{account_type}"

    if platform in {"anthropic", "claude"} and account_type in {"oauth", "setup-token", "setup_token"}:
        if truthy(extra.get("custom_base_url_enabled")):
            custom = string_value(extra.get("custom_base_url"))
            if custom:
                return normalize_url(custom, fallback)
        return default_endpoint_key(platform, account_type)

    # These OAuth routes intentionally ignore a stored base_url at runtime.
    if platform == "openai" and account_type != "apikey":
        return default_endpoint_key(platform, account_type)
    if platform == "grok" and account_type == "oauth":
        return default_endpoint_key("grok-cli", account_type)

    base_url = string_value(credentials.get("base_url"))
    if base_url:
        return normalize_url(base_url, fallback)
    return default_endpoint_key(platform, account_type)


def strip_managed_prefix(name: str, platform: str = "") -> str:
    base_name = MANAGED_PREFIX_RE.sub("", name, count=1)
    fixed_prefix = PLATFORM_FIXED_PREFIXES.get(platform.casefold())
    if fixed_prefix and base_name.startswith(fixed_prefix):
        return base_name[len(fixed_prefix):]
    return base_name


def account_guard(account: dict[str, Any]) -> str:
    group_ids = account.get("group_ids")
    if not isinstance(group_ids, list):
        group_ids = []
    normalized_group_ids: list[int] = []
    for value in group_ids:
        try:
            normalized_group_ids.append(int(value))
        except (TypeError, ValueError):
            continue
    projection = {
        "id": account_id(account),
        "platform": account.get("platform"),
        "type": account.get("type"),
        "priority": account.get("priority"),
        "status": account.get("status"),
        "schedulable": account.get("schedulable"),
        "group_ids": sorted(set(normalized_group_ids)),
        "proxy_id": account.get("proxy_id"),
        "parent_account_id": account.get("parent_account_id"),
        "quota_dimension": account.get("quota_dimension"),
        "concurrency": account.get("concurrency"),
        "rate_multiplier": account.get("rate_multiplier"),
    }
    encoded = json.dumps(projection, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def load_overrides(path: str | None) -> dict[int, str]:
    if not path:
        return {}
    raw = read_json(path)
    if not isinstance(raw, dict):
        raise PlanError("overrides must be a JSON object mapping account id to label")
    result: dict[int, str] = {}
    for key, value in raw.items():
        try:
            aid = int(key)
        except (TypeError, ValueError) as exc:
            raise PlanError(f"invalid override account id: {key!r}") from exc
        if aid <= 0 or not isinstance(value, str) or not value.strip():
            raise PlanError(f"invalid override for account {key!r}")
        result[aid] = value.strip()
    return result


def policy_string_list(value: Any, field: str) -> list[str]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PlanError(f"sort policy field {field!r} must be an array")
    result: list[str] = []
    seen: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, str) or not item.strip():
            raise PlanError(f"sort policy field {field!r} has an invalid item at index {index}")
        normalized = unicodedata.normalize("NFKC", item).strip()
        folded = normalized.casefold()
        if folded in seen:
            raise PlanError(f"sort policy field {field!r} contains duplicate value {normalized!r}")
        seen.add(folded)
        result.append(normalized)
    return result


def policy_label(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise PlanError(f"sort policy field {field!r} must be a non-empty string")
    normalized = unicodedata.normalize("NFKC", value).strip()
    if len(normalized) > 32 or any(character in normalized for character in "\r\n\t"):
        raise PlanError(f"sort policy field {field!r} has an invalid label")
    return normalized


def normalize_policy_hostname(value: str) -> str:
    normalized = unicodedata.normalize("NFKC", value).strip().casefold().rstrip(".")
    if not normalized or any(character in normalized for character in "/:@?#[]"):
        raise PlanError(f"sort policy hostname must not contain a scheme, path, port, or credentials: {value!r}")
    try:
        ascii_host = normalized.encode("idna").decode("ascii")
    except UnicodeError as exc:
        raise PlanError(f"invalid sort policy hostname: {value!r}") from exc
    if len(ascii_host) > 253 or not re.fullmatch(r"[a-z0-9.-]+", ascii_host):
        raise PlanError(f"invalid sort policy hostname: {value!r}")
    labels = ascii_host.split(".")
    if any(not label or len(label) > 63 or label.startswith("-") or label.endswith("-") for label in labels):
        raise PlanError(f"invalid sort policy hostname: {value!r}")
    return ascii_host


def normalize_model_buckets(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PlanError("model_buckets must be an array")
    result: list[dict[str, Any]] = []
    seen_labels: set[str] = set()
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise PlanError(f"model_buckets item {index} must be an object")
        unknown = set(item) - {
            "label",
            "model_mapping_key_prefixes",
            "platforms",
            "account_types",
        }
        if unknown:
            raise PlanError(f"model_buckets item {index} has unknown fields: {sorted(unknown)}")
        label = policy_label(item.get("label"), f"model_buckets[{index}].label")
        folded_label = label.casefold()
        if folded_label in seen_labels:
            raise PlanError(f"duplicate model bucket label: {label!r}")
        seen_labels.add(folded_label)
        prefixes = policy_string_list(
            item.get("model_mapping_key_prefixes"),
            f"model_buckets[{index}].model_mapping_key_prefixes",
        )
        if not prefixes:
            raise PlanError(f"model bucket {label!r} must contain at least one key prefix")
        platforms = [
            platform.casefold()
            for platform in policy_string_list(
                item.get("platforms"), f"model_buckets[{index}].platforms"
            )
        ]
        account_types = [
            account_type.casefold()
            for account_type in policy_string_list(
                item.get("account_types"), f"model_buckets[{index}].account_types"
            )
        ]
        result.append(
            {
                "label": label,
                "model_mapping_key_prefixes": [prefix.casefold() for prefix in prefixes],
                "platforms": platforms,
                "account_types": account_types,
            }
        )
    return result


def normalize_route_buckets(value: Any) -> list[dict[str, Any]]:
    if value is None:
        return []
    if not isinstance(value, list):
        raise PlanError("route_buckets must be an array")
    result: list[dict[str, Any]] = []
    seen_labels: set[str] = set()
    seen_hostnames: dict[str, str] = {}
    for index, item in enumerate(value):
        if not isinstance(item, dict):
            raise PlanError(f"route_buckets item {index} must be an object")
        unknown = set(item) - {"label", "hostnames"}
        if unknown:
            raise PlanError(f"route_buckets item {index} has unknown fields: {sorted(unknown)}")
        label = policy_label(item.get("label"), f"route_buckets[{index}].label")
        folded_label = label.casefold()
        if folded_label in seen_labels:
            raise PlanError(f"duplicate route bucket label: {label!r}")
        seen_labels.add(folded_label)
        hostnames = [
            normalize_policy_hostname(host)
            for host in policy_string_list(item.get("hostnames"), f"route_buckets[{index}].hostnames")
        ]
        if not hostnames:
            raise PlanError(f"route bucket {label!r} must contain at least one hostname")
        for hostname in hostnames:
            previous = seen_hostnames.get(hostname)
            if previous is not None:
                raise PlanError(
                    f"route hostname {hostname!r} appears in both {previous!r} and {label!r}"
                )
            seen_hostnames[hostname] = label
        result.append({"label": label, "hostnames": hostnames})
    return result


def empty_sort_policy() -> dict[str, Any]:
    return {
        "schema_version": POLICY_SCHEMA_VERSION,
        "exclude_platforms": [],
        "order_markers": [],
        "name_buckets": [],
        "model_buckets": [],
        "route_buckets": [],
        "source": None,
        "sha256": None,
    }


def load_sort_policy(path: Path) -> dict[str, Any]:
    raw_bytes = path.read_bytes()
    raw = json.loads(raw_bytes)
    if not isinstance(raw, dict):
        raise PlanError("sort policy must be a JSON object")
    unknown = set(raw) - POLICY_KEYS
    if unknown:
        raise PlanError(f"sort policy has unknown fields: {sorted(unknown)}")
    if raw.get("schema_version") != POLICY_SCHEMA_VERSION:
        raise PlanError(f"sort policy schema_version must be {POLICY_SCHEMA_VERSION}")
    policy = empty_sort_policy()
    policy.update(
        {
            "exclude_platforms": normalize_platforms(
                policy_string_list(raw.get("exclude_platforms"), "exclude_platforms")
            ),
            "order_markers": normalize_markers(
                policy_string_list(raw.get("order_markers"), "order_markers")
            ),
            "name_buckets": normalize_markers(
                policy_string_list(raw.get("name_buckets"), "name_buckets")
            ),
            "model_buckets": normalize_model_buckets(raw.get("model_buckets")),
            "route_buckets": normalize_route_buckets(raw.get("route_buckets")),
            "source": str(path.resolve()),
            "sha256": hashlib.sha256(raw_bytes).hexdigest(),
        }
    )
    return policy


def resolve_sort_policy(path: str | None, no_policy: bool) -> dict[str, Any]:
    if no_policy:
        return empty_sort_policy()
    target = Path(path).expanduser() if path else DEFAULT_POLICY_PATH
    if not target.exists():
        if path:
            raise PlanError(f"explicit sort policy does not exist: {target}")
        return empty_sort_policy()
    if not target.is_file():
        raise PlanError(f"sort policy is not a regular file: {target}")
    return load_sort_policy(target)


def marker_rank(name: str, order_markers: list[str]) -> tuple[int, list[str]]:
    folded = unicodedata.normalize("NFKC", name).casefold()
    matches = [
        marker
        for marker in order_markers
        if unicodedata.normalize("NFKC", marker).casefold() in folded
    ]
    if not matches:
        return len(order_markers), []
    first = min(order_markers.index(marker) for marker in matches)
    return first, matches


def normalize_platforms(values: list[str] | None) -> list[str]:
    return sorted({value.strip().casefold() for value in (values or []) if value.strip()})


def normalize_markers(values: list[str] | None) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for value in values or []:
        marker = unicodedata.normalize("NFKC", value).strip()
        folded = marker.casefold()
        if not marker or folded in seen:
            continue
        seen.add(folded)
        result.append(marker)
    return result


def name_bucket_rank(name: str, name_buckets: list[str]) -> tuple[int, list[str]]:
    folded = unicodedata.normalize("NFKC", name).casefold()
    matches = [
        bucket
        for bucket in name_buckets
        if unicodedata.normalize("NFKC", bucket).casefold() in folded
    ]
    if not matches:
        return len(name_buckets), []
    first = min(name_buckets.index(bucket) for bucket in matches)
    return first, matches


def model_mapping_guard(account: dict[str, Any]) -> str:
    mapping = string_map(string_map(account.get("credentials")).get("model_mapping"))
    encoded = json.dumps(mapping, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def model_bucket_rank(
    account: dict[str, Any], model_buckets: list[dict[str, Any]]
) -> tuple[int, list[str]]:
    mapping = string_map(string_map(account.get("credentials")).get("model_mapping"))
    platform = string_value(account.get("platform")).casefold()
    account_type = string_value(account.get("type")).casefold()
    usable_keys = [
        unicodedata.normalize("NFKC", key).casefold()
        for key, target in mapping.items()
        if isinstance(key, str) and isinstance(target, str) and target.strip()
    ]
    matches = [
        bucket["label"]
        for bucket in model_buckets
        if (not bucket["platforms"] or platform in bucket["platforms"])
        and (not bucket["account_types"] or account_type in bucket["account_types"])
        and any(
            key.startswith(prefix)
            for key in usable_keys
            for prefix in bucket["model_mapping_key_prefixes"]
        )
    ]
    if not matches:
        return len(model_buckets), []
    matched_labels = {label.casefold() for label in matches}
    first = min(
        index
        for index, bucket in enumerate(model_buckets)
        if bucket["label"].casefold() in matched_labels
    )
    return first, matches


def route_bucket_rank(
    endpoint_key: str, route_buckets: list[dict[str, Any]]
) -> tuple[int, list[str]]:
    try:
        hostname = urlsplit(endpoint_key).hostname
    except ValueError:
        hostname = None
    normalized_host = hostname.casefold().rstrip(".") if hostname else ""
    matches = [
        bucket["label"]
        for bucket in route_buckets
        if normalized_host and normalized_host in bucket["hostnames"]
    ]
    if not matches:
        return len(route_buckets), []
    matched_labels = {label.casefold() for label in matches}
    first = min(
        index
        for index, bucket in enumerate(route_buckets)
        if bucket["label"].casefold() in matched_labels
    )
    return first, matches


def base36_digit(value: int) -> str:
    if not 0 <= value < len(BASE36_ALPHABET):
        raise PlanError(f"compact ordering value out of range: {value}")
    return BASE36_ALPHABET[value]


def build_plan(
    accounts: list[dict[str, Any]],
    overrides: dict[int, str],
    exclude_platforms: list[str] | None = None,
    order_markers: list[str] | None = None,
    name_buckets: list[str] | None = None,
    model_buckets: list[dict[str, Any]] | None = None,
    route_buckets: list[dict[str, Any]] | None = None,
    policy_source: str | None = None,
    policy_sha256: str | None = None,
) -> dict[str, Any]:
    excluded_platforms = normalize_platforms(exclude_platforms)
    markers = normalize_markers(order_markers)
    buckets = normalize_markers(name_buckets)
    model_rules = normalize_model_buckets(model_buckets)
    route_rules = normalize_route_buckets(route_buckets)
    by_id: dict[int, dict[str, Any]] = {}
    ignored_deleted: list[int] = []
    for account in accounts:
        aid = account_id(account)
        if aid in by_id:
            raise PlanError(f"duplicate account id in input: {aid}")
        if account.get("deleted_at") not in (None, ""):
            ignored_deleted.append(aid)
            continue
        name = account.get("name")
        if not isinstance(name, str) or not name.strip():
            raise PlanError(f"account {aid} has an empty or invalid name")
        by_id[aid] = account

    unknown_overrides = sorted(set(overrides) - set(by_id))
    if unknown_overrides:
        raise PlanError(f"override ids are missing or deleted: {unknown_overrides}")

    excluded_ids = sorted(
        aid
        for aid, account in by_id.items()
        if string_value(account.get("platform")).casefold() in excluded_platforms
    )

    groups: dict[str, dict[str, Any]] = {}
    candidates: list[dict[str, Any]] = []
    for aid in sorted(by_id):
        account = by_id[aid]
        platform = string_value(account.get("platform")).casefold()
        if platform in excluded_platforms:
            continue
        endpoint_key, label = effective_endpoint(account, by_id, overrides)
        digest = hashlib.sha256(endpoint_key.encode("utf-8")).hexdigest()
        fixed_prefix = PLATFORM_FIXED_PREFIXES.get(platform)
        group = groups.setdefault(
            digest,
            {
                "group_key_sha256": digest,
                "label": label,
                "account_ids": [],
                "marker_ranks": set(),
                "matched_markers": set(),
                "bucket_ranks": set(),
                "matched_name_buckets": set(),
                "model_bucket_ranks": set(),
                "matched_model_buckets": set(),
                "route_bucket_ranks": set(),
                "matched_route_buckets": set(),
                "fixed_prefix": fixed_prefix,
            },
        )
        if group["fixed_prefix"] != fixed_prefix:
            raise PlanError(
                f"route group {label!r} mixes incompatible platform prefix policies"
            )
        group["account_ids"].append(aid)
        old_name = account["name"]
        base_name = strip_managed_prefix(old_name, platform)
        if not base_name.strip():
            raise PlanError(f"account {aid} has no base name after removing the managed prefix")
        item_marker_rank, item_matches = marker_rank(base_name, markers)
        item_bucket_rank, bucket_matches = name_bucket_rank(base_name, buckets)
        item_model_rank, model_matches = model_bucket_rank(account, model_rules)
        item_route_rank, route_matches = route_bucket_rank(endpoint_key, route_rules)
        group["marker_ranks"].add(item_marker_rank)
        group["matched_markers"].update(item_matches)
        group["bucket_ranks"].add(item_bucket_rank)
        group["matched_name_buckets"].update(bucket_matches)
        group["model_bucket_ranks"].add(item_model_rank)
        group["matched_model_buckets"].update(model_matches)
        group["route_bucket_ranks"].add(item_route_rank)
        group["matched_route_buckets"].update(route_matches)
        candidates.append(
            {
                "id": aid,
                "account": account,
                "old_name": old_name,
                "base_name": base_name,
                "group_key_sha256": digest,
                "group_label": label,
                "classification_source": "manual" if endpoint_key.startswith("manual:") else "runtime",
                "fixed_prefix": fixed_prefix,
                "marker_rank": item_marker_rank,
                "matched_markers": item_matches,
                "name_bucket_rank": item_bucket_rank,
                "matched_name_buckets": bucket_matches,
                "model_bucket_rank": item_model_rank,
                "matched_model_buckets": model_matches,
                "route_bucket_rank": item_route_rank,
                "matched_route_buckets": route_matches,
                "model_mapping_sha256": model_mapping_guard(account),
            }
        )

    if model_rules:
        for group in groups.values():
            if len(group["model_bucket_ranks"]) > 1:
                raise PlanError(
                    f"route group {group['label']!r} mixes model-priority tiers; "
                    "global model priority and URL continuity cannot both be preserved"
                )

    ordered_groups = sorted(
        groups.values(),
        key=lambda item: (
            item["fixed_prefix"] is not None,
            item["fixed_prefix"] or "",
            min(item["model_bucket_ranks"], default=len(model_rules)),
            min(item["route_bucket_ranks"], default=len(route_rules)),
            min(item["bucket_ranks"], default=len(buckets)),
            min(item["marker_ranks"], default=len(markers)),
            item["label"].casefold(),
            item["group_key_sha256"],
        ),
    )
    compact_ordering = bool(markers or buckets or model_rules or route_rules)
    if compact_ordering and len(ordered_groups) > len(BASE36_ALPHABET):
        raise PlanError(
            f"compact ordering supports at most {len(BASE36_ALPHABET)} URL groups; "
            f"found {len(ordered_groups)}"
        )
    if compact_ordering and len(markers) >= len(BASE36_ALPHABET):
        raise PlanError(
            f"compact marker ordering supports at most {len(BASE36_ALPHABET) - 1} markers; "
            f"found {len(markers)}"
        )
    item_order_count = (len(buckets) + 1) * (len(markers) + 1)
    if compact_ordering and item_order_count > len(BASE36_ALPHABET):
        raise PlanError(
            "compact ordering has too many name-bucket/marker combinations: "
            f"{item_order_count} > {len(BASE36_ALPHABET)}"
        )
    group_orders: dict[str, int] = {}
    for display_order, group in enumerate(ordered_groups, start=1):
        group_orders[group["group_key_sha256"]] = display_order
        group["display_order"] = display_order
        group["name_bucket_rank"] = min(group.pop("bucket_ranks"), default=len(buckets))
        group["marker_rank"] = min(group.pop("marker_ranks"), default=len(markers))
        group["model_bucket_rank"] = min(
            group.pop("model_bucket_ranks"), default=len(model_rules)
        )
        group["route_bucket_rank"] = min(
            group.pop("route_bucket_ranks"), default=len(route_rules)
        )
        group["matched_markers"] = [
            marker for marker in markers if marker in group["matched_markers"]
        ]
        group["matched_name_buckets"] = [
            bucket for bucket in buckets if bucket in group["matched_name_buckets"]
        ]
        group["matched_model_buckets"] = [
            bucket["label"]
            for bucket in model_rules
            if bucket["label"] in group["matched_model_buckets"]
        ]
        group["matched_route_buckets"] = [
            bucket["label"]
            for bucket in route_rules
            if bucket["label"] in group["matched_route_buckets"]
        ]

    rows: list[dict[str, Any]] = []
    for candidate in candidates:
        aid = candidate["id"]
        account = candidate.pop("account")
        digest = candidate["group_key_sha256"]
        base_name = candidate["base_name"]
        if candidate["fixed_prefix"]:
            prefix = candidate["fixed_prefix"]
        elif compact_ordering:
            combined_item_order = (
                candidate["name_bucket_rank"] * (len(markers) + 1)
                + candidate["marker_rank"]
            )
            prefix = (
                "!"
                + base36_digit(group_orders[digest] - 1)
                + base36_digit(combined_item_order)
                + "-"
            )
        else:
            prefix = f"[@url:{candidate['group_label']}:{digest[:10]}] "
        available = MAX_ACCOUNT_NAME_LENGTH - len(prefix)
        if available <= 3:
            raise PlanError(f"managed prefix leaves no room for account {aid}")
        if len(base_name) > available:
            new_name = prefix + base_name[: available - 3] + "..."
            truncated = True
        else:
            new_name = prefix + base_name
            truncated = False
        rows.append(
            {
                "id": aid,
                "old_name": candidate["old_name"],
                "new_name": new_name,
                "base_name": base_name,
                "group_key_sha256": digest,
                "group_label": candidate["group_label"],
                "display_order": group_orders[digest],
                "marker_rank": candidate["marker_rank"],
                "matched_markers": candidate["matched_markers"],
                "name_bucket_rank": candidate["name_bucket_rank"],
                "matched_name_buckets": candidate["matched_name_buckets"],
                "model_bucket_rank": candidate["model_bucket_rank"],
                "matched_model_buckets": candidate["matched_model_buckets"],
                "route_bucket_rank": candidate["route_bucket_rank"],
                "matched_route_buckets": candidate["matched_route_buckets"],
                "model_mapping_sha256": candidate["model_mapping_sha256"],
                "classification_source": candidate["classification_source"],
                "fixed_prefix": candidate["fixed_prefix"],
                "guard_sha256": account_guard(account),
                "truncated": truncated,
            }
        )

    group_list = ordered_groups
    display_ids_by_group: dict[str, list[int]] = {}
    for row in sorted(rows, key=lambda item: (item["new_name"], item["id"])):
        display_ids_by_group.setdefault(row["group_key_sha256"], []).append(row["id"])
    for group in group_list:
        group["account_ids"].sort()
        group["display_account_ids"] = display_ids_by_group[group["group_key_sha256"]]
        group["count"] = len(group["account_ids"])

    changes = [row for row in rows if row["old_name"] != row["new_name"]]
    source_projection = [
        {
            "id": row["id"],
            "old_name": row["old_name"],
            "guard_sha256": row["guard_sha256"],
            "model_mapping_sha256": row["model_mapping_sha256"],
        }
        for row in rows
    ]
    source_hash = hashlib.sha256(
        json.dumps(source_projection, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    ).hexdigest()
    return {
        "schema_version": PLAN_VERSION,
        "operation": "sub2api-account-name-organize",
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "source_account_count": len(by_id),
        "account_count": len(rows),
        "excluded_count": len(excluded_ids),
        "excluded_account_ids": excluded_ids,
        "excluded_platforms": excluded_platforms,
        "order_markers": markers,
        "name_buckets": buckets,
        "model_buckets": model_rules,
        "route_buckets": route_rules,
        "policy_source": policy_source,
        "policy_sha256": policy_sha256,
        "platform_fixed_prefixes": dict(sorted(PLATFORM_FIXED_PREFIXES.items())),
        "changed_count": len(changes),
        "group_count": len(group_list),
        "ignored_deleted_ids": sorted(ignored_deleted),
        "source_sha256": source_hash,
        "managed_prefix": (
            "!<URL组base36一位><组内标记base36一位>-"
            if compact_ordering
            else "[@url:<safe-label>:<url-hash-10>] "
        ),
        "groups": group_list,
        "verification_rows": rows,
        "changes": changes,
    }


def verify_plan(plan: dict[str, Any], accounts: list[dict[str, Any]], expect: str) -> dict[str, Any]:
    if expect not in {"before", "after"}:
        raise PlanError(f"unsupported verification expectation: {expect!r}")
    verification_rows = plan.get("verification_rows")
    if (
        plan.get("schema_version") not in SUPPORTED_PLAN_VERSIONS
        or not isinstance(plan.get("changes"), list)
        or not isinstance(verification_rows, list)
    ):
        raise PlanError("unsupported or malformed plan")
    by_id: dict[int, dict[str, Any]] = {}
    for account in accounts:
        aid = account_id(account)
        if aid in by_id:
            raise PlanError(f"duplicate account id in verification input: {aid}")
        if account.get("deleted_at") in (None, ""):
            by_id[aid] = account

    errors: list[dict[str, Any]] = []
    checked = 0
    expected_field = "old_name" if expect == "before" else "new_name"
    excluded_platforms = normalize_platforms(plan.get("excluded_platforms"))
    eligible_ids = {
        aid
        for aid, account in by_id.items()
        if string_value(account.get("platform")).casefold() not in excluded_platforms
    }
    planned_ids_list = [int(row["id"]) for row in verification_rows]
    planned_ids = set(planned_ids_list)
    if len(planned_ids) != len(planned_ids_list):
        raise PlanError("plan contains duplicate verification account ids")
    for aid in sorted(eligible_ids - planned_ids):
        errors.append({"id": aid, "reason": "unexpected_active_account"})

    for row in verification_rows:
        aid = int(row["id"])
        account = by_id.get(aid)
        if account is None:
            errors.append({"id": aid, "reason": "missing"})
            continue
        if account.get("name") != row.get(expected_field):
            errors.append({"id": aid, "reason": "name_mismatch"})
            continue
        if account_guard(account) != row.get("guard_sha256"):
            errors.append({"id": aid, "reason": "protected_fields_changed"})
            continue
        if plan.get("schema_version") >= 7 and model_mapping_guard(account) != row.get(
            "model_mapping_sha256"
        ):
            errors.append({"id": aid, "reason": "model_mapping_changed"})
            continue
        if row.get("classification_source") != "manual":
            try:
                endpoint_key, _ = effective_endpoint(account, by_id, {})
            except PlanError:
                errors.append({"id": aid, "reason": "route_unverifiable"})
                continue
            route_hash = hashlib.sha256(endpoint_key.encode("utf-8")).hexdigest()
            if route_hash != row.get("group_key_sha256"):
                errors.append({"id": aid, "reason": "route_changed"})
                continue
        checked += 1
    return {"ok": not errors, "expect": expect, "checked": checked, "errors": errors}


def command_plan(args: argparse.Namespace) -> int:
    accounts = unwrap_accounts(read_json(args.input))
    policy = resolve_sort_policy(args.policy, args.no_policy)
    plan = build_plan(
        accounts,
        load_overrides(args.overrides),
        exclude_platforms=(
            args.exclude_platform
            if args.exclude_platform is not None
            else policy["exclude_platforms"]
        ),
        order_markers=(
            args.order_marker if args.order_marker is not None else policy["order_markers"]
        ),
        name_buckets=(
            args.name_bucket if args.name_bucket is not None else policy["name_buckets"]
        ),
        model_buckets=policy["model_buckets"],
        route_buckets=policy["route_buckets"],
        policy_source=policy["source"],
        policy_sha256=policy["sha256"],
    )
    write_json_0600(args.output, plan)
    summary = {
        "account_count": plan["account_count"],
        "excluded_count": plan["excluded_count"],
        "changed_count": plan["changed_count"],
        "group_count": plan["group_count"],
        "truncated_count": sum(1 for row in plan["changes"] if row["truncated"]),
        "output": str(Path(args.output).resolve()),
        "policy_source": plan["policy_source"],
        "policy_sha256": plan["policy_sha256"],
    }
    print(json.dumps(summary, ensure_ascii=False, sort_keys=True))
    return 0


def command_verify(args: argparse.Namespace) -> int:
    plan = read_json(args.plan)
    accounts = unwrap_accounts(read_json(args.accounts))
    result = verify_plan(plan, accounts, args.expect)
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["ok"] else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    plan_parser = subparsers.add_parser("plan", help="build a reversible organization plan")
    plan_parser.add_argument("--input", required=True, help="redacted accounts JSON, or - for stdin")
    plan_parser.add_argument("--output", required=True, help="plan JSON path (written mode 0600)")
    plan_parser.add_argument("--overrides", help="optional JSON mapping account ids to manual labels")
    policy_group = plan_parser.add_mutually_exclusive_group()
    policy_group.add_argument("--policy", help="explicit JSON sort policy path")
    policy_group.add_argument(
        "--no-policy",
        action="store_true",
        help="ignore the optional default local/sort-policy.json",
    )
    plan_parser.add_argument(
        "--exclude-platform",
        action="append",
        default=None,
        help="platform to leave unchanged; repeatable",
    )
    plan_parser.add_argument(
        "--order-marker",
        action="append",
        default=None,
        help="name substring order for URL groups and members; repeatable",
    )
    plan_parser.add_argument(
        "--name-bucket",
        action="append",
        default=None,
        help="higher-level original-name substring bucket; repeatable",
    )
    plan_parser.set_defaults(func=command_plan)

    verify_parser = subparsers.add_parser("verify", help="verify names and protected fields")
    verify_parser.add_argument("--plan", required=True)
    verify_parser.add_argument("--accounts", required=True, help="fresh redacted accounts JSON")
    verify_parser.add_argument("--expect", choices=("before", "after"), required=True)
    verify_parser.set_defaults(func=command_verify)
    return parser


def main() -> int:
    try:
        args = build_parser().parse_args()
        return int(args.func(args))
    except (OSError, json.JSONDecodeError, PlanError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
