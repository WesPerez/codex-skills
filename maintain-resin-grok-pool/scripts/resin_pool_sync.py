#!/usr/bin/env python3
"""Validate configured proxy sources and atomically sync a Resin subscription."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Mapping

from proxy_probe import atomic_write, reselect_validation_artifacts, validation_from_config


OWNER = "maintain-resin-grok-pool"
STATE_VERSION = 1


class SyncError(RuntimeError):
    pass


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def safe_message(exc: BaseException) -> str:
    if isinstance(exc, SyncError):
        return str(exc)
    if isinstance(exc, urllib.error.HTTPError):
        return f"Admin API HTTP {exc.code}"
    return exc.__class__.__name__


def load_json(path: Path, *, require_private: bool = True) -> dict[str, Any]:
    if not path.is_file():
        raise SyncError(f"missing JSON file: {path}")
    if require_private and path.stat().st_mode & 0o077:
        raise SyncError(f"JSON file must use mode 0600: {path}")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SyncError(f"invalid JSON file: {path}") from exc
    if not isinstance(value, dict):
        raise SyncError(f"JSON root must be an object: {path}")
    return value


def write_json(path: Path, value: Mapping[str, Any]) -> None:
    payload = (json.dumps(value, sort_keys=True, indent=2) + "\n").encode("utf-8")
    atomic_write(path, payload, mode=0o600)


def load_token(path: Path) -> str:
    if not path.is_file() or path.stat().st_mode & 0o077:
        raise SyncError("admin token file must exist with mode 0600")
    token = path.read_text(encoding="utf-8").strip()
    if not token:
        raise SyncError("admin token file is empty")
    return token


class ResinClient:
    def __init__(self, base_url: str, token: str, timeout: float = 20.0) -> None:
        parsed = urllib.parse.urlsplit(base_url.rstrip("/"))
        if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.path not in ("", "/"):
            raise SyncError("invalid Resin base URL")
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout
        self.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(self, method: str, path: str, body: Mapping[str, Any] | None = None) -> Any:
        data = None
        headers = {
            "Accept": "application/json",
            "Authorization": f"Bearer {self.token}",
            "User-Agent": "resin-pool-maintainer/1",
        }
        if body is not None:
            data = json.dumps(body, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=self.timeout) as response:
                raw = response.read(2 * 1024 * 1024)
                if not raw:
                    return None
                return json.loads(raw)
        except urllib.error.HTTPError as exc:
            raise SyncError(f"Admin API HTTP {exc.code} for {method} {path.split('?', 1)[0]}") from None
        except (urllib.error.URLError, TimeoutError, OSError, json.JSONDecodeError) as exc:
            raise SyncError(f"Admin API request failed for {method} {path.split('?', 1)[0]}") from exc


def get_page_items(payload: Any, label: str) -> list[dict[str, Any]]:
    if not isinstance(payload, dict) or not isinstance(payload.get("items"), list):
        raise SyncError(f"invalid {label} list response")
    return [row for row in payload["items"] if isinstance(row, dict)]


def find_subscription(client: ResinClient, name: str) -> dict[str, Any] | None:
    query = urllib.parse.urlencode({"limit": 100, "offset": 0, "keyword": name})
    rows = get_page_items(client.request("GET", f"/api/v1/subscriptions?{query}"), "subscription")
    exact = [row for row in rows if row.get("name") == name]
    if len(exact) > 1:
        raise SyncError("multiple exact Resin subscriptions found")
    return exact[0] if exact else None


def get_platform(client: ResinClient, platform_id: str, expected_name: str) -> dict[str, Any]:
    row = client.request("GET", f"/api/v1/platforms/{urllib.parse.quote(platform_id, safe='')}")
    if not isinstance(row, dict) or row.get("id") != platform_id or row.get("name") != expected_name:
        raise SyncError("Resin platform identity mismatch")
    return row


def sqlite_backup(source: Path, destination: Path) -> dict[str, Any]:
    if not source.is_file():
        raise SyncError(f"backup source missing: {source}")
    destination.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    quoted = str(destination).replace("'", "''")
    command = ["sqlite3", "-readonly", str(source), ".timeout 10000", f".backup '{quoted}'"]
    completed = subprocess.run(command, capture_output=True, text=True, timeout=60, check=False)
    if completed.returncode != 0 or not destination.is_file():
        raise SyncError(f"SQLite backup failed: {source.name}")
    os.chmod(destination, 0o600)
    try:
        uri_path = urllib.parse.quote(str(destination), safe="/")
        with sqlite3.connect(f"file:{uri_path}?mode=ro&immutable=1", uri=True, timeout=5) as db:
            row = db.execute("PRAGMA integrity_check").fetchone()
    except sqlite3.Error as exc:
        raise SyncError(f"SQLite backup verification failed: {source.name}") from exc
    if not row or row[0] != "ok":
        raise SyncError(f"SQLite backup integrity check failed: {source.name}")
    return {
        "source": str(source),
        "path": str(destination),
        "size": destination.stat().st_size,
        "sha256": sha256_file(destination),
        "integrity_check": "ok",
    }


def create_backups(config: Mapping[str, Any], run_dir: Path) -> list[dict[str, Any]]:
    resin = config.get("resin") or {}
    paths = resin.get("backup_db_paths") or []
    if not isinstance(paths, list) or not paths:
        raise SyncError("resin.backup_db_paths must list the live state databases")
    backup_dir: Path | None = None
    for attempt in range(100):
        candidate = run_dir / ("backup" if attempt == 0 else f"backup-retry-{attempt:02d}")
        try:
            candidate.mkdir(mode=0o700)
            backup_dir = candidate
            break
        except FileExistsError:
            if candidate.is_symlink() or not candidate.is_dir() or candidate.stat().st_mode & 0o077:
                raise SyncError("existing backup path is not a private directory") from None
            if not any(candidate.iterdir()):
                backup_dir = candidate
                break
    if backup_dir is None:
        raise SyncError("unable to allocate a backup directory")
    backups: list[dict[str, Any]] = []
    for index, raw in enumerate(paths, start=1):
        source = Path(str(raw)).resolve()
        destination = backup_dir / f"{index:02d}-{source.name}"
        backups.append(sqlite_backup(source, destination))
    return backups


def new_run_dir(state_dir: Path) -> Path:
    runs = state_dir / "runs"
    runs.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state_dir, 0o700)
    os.chmod(runs, 0o700)
    base = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    for suffix in range(100):
        name = base if suffix == 0 else f"{base}-{suffix:02d}"
        path = runs / name
        try:
            path.mkdir(mode=0o700)
            return path
        except FileExistsError:
            continue
    raise SyncError("unable to allocate run directory")


def read_previous_state(state_dir: Path) -> dict[str, Any]:
    path = state_dir / "state.json"
    if not path.exists():
        return {}
    return load_json(path)


def fail_closed_guards(config: Mapping[str, Any], report: Mapping[str, Any], previous: Mapping[str, Any]) -> None:
    safety = config.get("safety") or {}
    selected = int(report.get("selected_count") or 0)
    passed = int(report.get("passed_count") or 0)
    minimum = int(safety.get("min_selected", 20))
    min_passed = int(safety.get("min_passed", minimum))
    if selected < minimum or passed < min_passed:
        raise SyncError(f"fail-closed: selected={selected}, passed={passed}, minimum={minimum}")
    previous_selected = int(previous.get("selected_count") or 0)
    ratio = float(safety.get("min_ratio_to_previous", 0.5))
    if previous_selected > 0 and selected < int(previous_selected * ratio):
        raise SyncError(
            f"fail-closed: selected count {selected} is below previous ratio threshold"
        )


def subscription_patch_from_config(config: Mapping[str, Any], content: str) -> dict[str, Any]:
    resin = config.get("resin") or {}
    return {
        "content": content,
        "update_interval": str(resin.get("update_interval", "24h")),
        "enabled": True,
        "ephemeral": True,
        "incremental_alive_nodes": False,
        "ephemeral_node_evict_delay": str(resin.get("ephemeral_node_evict_delay", "6h")),
    }


def create_subscription(client: ResinClient, config: Mapping[str, Any], content: str) -> dict[str, Any]:
    resin = config.get("resin") or {}
    body = {
        "name": str(resin["subscription_name"]),
        "source_type": "local",
        **subscription_patch_from_config(config, content),
    }
    row = client.request("POST", "/api/v1/subscriptions", body)
    if not isinstance(row, dict) or not row.get("id"):
        raise SyncError("invalid subscription create response")
    return row


def update_subscription(client: ResinClient, subscription_id: str, patch: Mapping[str, Any]) -> dict[str, Any]:
    row = client.request(
        "PATCH",
        f"/api/v1/subscriptions/{urllib.parse.quote(subscription_id, safe='')}",
        patch,
    )
    if not isinstance(row, dict) or row.get("id") != subscription_id:
        raise SyncError("invalid subscription update response")
    return row


def refresh_subscription(client: ResinClient, subscription_id: str) -> None:
    client.request(
        "POST",
        f"/api/v1/subscriptions/{urllib.parse.quote(subscription_id, safe='')}/actions/refresh",
        {},
    )


def verify_subscription(
    client: ResinClient,
    subscription_id: str,
    expected_digest: str,
    timeout: float = 30.0,
) -> dict[str, Any]:
    deadline = time.monotonic() + timeout
    last: dict[str, Any] | None = None
    while time.monotonic() < deadline:
        row = client.request(
            "GET", f"/api/v1/subscriptions/{urllib.parse.quote(subscription_id, safe='')}"
        )
        if isinstance(row, dict):
            last = row
            content = str(row.get("content") or "").encode("utf-8")
            if sha256_bytes(content) == expected_digest and int(row.get("node_count") or 0) > 0:
                if not row.get("last_error"):
                    return row
        time.sleep(1)
    raise SyncError("subscription verification timed out")


def restore_subscription(
    client: ResinClient,
    config: Mapping[str, Any],
    before: Mapping[str, Any] | None,
    created_id: str | None,
) -> dict[str, Any]:
    result: dict[str, Any] = {"attempted": True}
    try:
        if created_id:
            client.request(
                "DELETE",
                f"/api/v1/subscriptions/{urllib.parse.quote(created_id, safe='')}",
            )
            result["created_subscription_removed"] = True
        elif before:
            subscription_id = str(before["id"])
            patch = {
                "content": str(before.get("content") or ""),
                "update_interval": str(before.get("update_interval") or "24h"),
                "enabled": bool(before.get("enabled")),
                "ephemeral": bool(before.get("ephemeral")),
                "incremental_alive_nodes": bool(before.get("incremental_alive_nodes")),
                "ephemeral_node_evict_delay": str(before.get("ephemeral_node_evict_delay") or "72h"),
            }
            update_subscription(client, subscription_id, patch)
            refresh_subscription(client, subscription_id)
            result["subscription_restored"] = True
    except Exception as exc:
        result["subscription_restored"] = False
        result["error"] = safe_message(exc)
    return result


def prune_owned_runs(state_dir: Path, keep: int, current: Path) -> list[str]:
    runs_dir = (state_dir / "runs").resolve()
    candidates: list[Path] = []
    for path in runs_dir.iterdir():
        if not path.is_dir() or path.resolve().parent != runs_dir or path.resolve() == current.resolve():
            continue
        manifest = path / "manifest.json"
        try:
            value = load_json(manifest)
        except SyncError:
            continue
        if value.get("owner") == OWNER:
            candidates.append(path)
    candidates.sort(key=lambda item: item.name, reverse=True)
    removed: list[str] = []
    for path in candidates[max(0, keep - 1) :]:
        shutil.rmtree(path)
        removed.append(path.name)
    return removed


@contextlib.contextmanager
def exclusive_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    fd = os.open(path, os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        os.close(fd)
        raise SyncError("another pool-maintenance run is active") from exc
    try:
        yield
    finally:
        fcntl.flock(fd, fcntl.LOCK_UN)
        os.close(fd)


def load_validated_run(
    config: Mapping[str, Any],
    config_path: Path,
    state_dir: Path,
    raw_run_dir: str,
    *,
    require_config_hash: bool = True,
) -> tuple[Path, dict[str, Any], dict[str, Any], Path, Path]:
    runs_dir = (state_dir / "runs").resolve()
    run_dir = Path(raw_run_dir).resolve()
    if run_dir.parent != runs_dir or not run_dir.is_dir():
        raise SyncError("validated run must be a direct child of the configured runs directory")
    manifest_path = run_dir / "manifest.json"
    report_file = run_dir / "validation-report.json"
    output_file = run_dir / "validated-proxies.txt"
    manifest = load_json(manifest_path)
    report = load_json(report_file)
    if not output_file.is_file() or output_file.stat().st_mode & 0o077:
        raise SyncError("validated proxy artifact is missing or not private")
    if manifest.get("owner") != OWNER or manifest.get("status") != "validated_only":
        raise SyncError("validated run manifest is not eligible for apply")
    if require_config_hash and manifest.get("config_sha256") != sha256_file(config_path):
        raise SyncError("validated run config hash mismatch")
    content_digest = sha256_file(output_file)
    if report.get("output_sha256") != content_digest:
        raise SyncError("validated proxy artifact hash mismatch")
    validation = manifest.get("validation") or {}
    if validation.get("output_sha256") != content_digest:
        raise SyncError("validated run manifest hash mismatch")
    created_raw = str(report.get("created_at") or "").replace("Z", "+00:00")
    try:
        created_at = dt.datetime.fromisoformat(created_raw)
    except ValueError as exc:
        raise SyncError("validated report timestamp is invalid") from exc
    if created_at.tzinfo is None:
        created_at = created_at.replace(tzinfo=dt.timezone.utc)
    max_age = int((config.get("safety") or {}).get("max_validation_age_seconds", 21600))
    age = (dt.datetime.now(dt.timezone.utc) - created_at.astimezone(dt.timezone.utc)).total_seconds()
    if age < 0 or age > max_age:
        raise SyncError("validated run is stale")
    return run_dir, manifest, report, output_file, report_file


def run(args: argparse.Namespace) -> int:
    config_path = Path(args.config).resolve()
    config = load_json(config_path)
    if int(config.get("version") or 0) != 1:
        raise SyncError("unsupported config version")
    state_dir = Path(str(config.get("state_dir") or "/var/lib/resin-pool-maintainer")).resolve()
    lock_path = Path(str(config.get("lock_file") or "/run/lock/resin-pool-maintainer.lock"))

    with exclusive_lock(lock_path):
        if args.command == "reselect":
            run_dir, manifest, _, output_file, report_file = load_validated_run(
                config,
                config_path,
                state_dir,
                args.validated_run,
                require_config_hash=False,
            )
            report = reselect_validation_artifacts(config, output_file, report_file)
            previous = read_previous_state(state_dir)
            fail_closed_guards(config, report, previous)
            content_digest = sha256_file(output_file)
            manifest.update(
                {
                    "status": "validated_only",
                    "config_sha256": sha256_file(config_path),
                    "reselected_at": utc_now(),
                    "validation": {
                        "input_count": report["input_count"],
                        "passed_count": report["passed_count"],
                        "selected_count": report["selected_count"],
                        "unique_egress_count": report["unique_egress_count"],
                        "output_sha256": content_digest,
                    },
                }
            )
            write_json(run_dir / "manifest.json", manifest)
            print(json.dumps({"status": "reselected", **manifest["validation"]}, sort_keys=True))
            return 0
        if args.command == "apply":
            run_dir, manifest, report, output_file, report_file = load_validated_run(
                config, config_path, state_dir, args.validated_run
            )
            manifest.update({"status": "running", "apply_started_at": utc_now()})
            write_json(run_dir / "manifest.json", manifest)
        else:
            run_dir = new_run_dir(state_dir)
            manifest = {
                "owner": OWNER,
                "version": STATE_VERSION,
                "started_at": utc_now(),
                "status": "running",
                "config_sha256": sha256_file(config_path),
            }
            write_json(run_dir / "manifest.json", manifest)
            output_file = run_dir / "validated-proxies.txt"
            report_file = run_dir / "validation-report.json"
            report = {}
        try:
            if args.command != "apply":
                report = validation_from_config(config, output_file, report_file)
            previous = read_previous_state(state_dir)
            fail_closed_guards(config, report, previous)
            content_bytes = output_file.read_bytes()
            content = content_bytes.decode("utf-8")
            content_digest = sha256_bytes(content_bytes)
            resin = config.get("resin") or {}
            max_body = int(resin.get("max_api_body_bytes", 900_000))
            if len(content_bytes) > max_body:
                raise SyncError("validated subscription exceeds Resin API body safety limit")

            manifest["validation"] = {
                "input_count": report["input_count"],
                "passed_count": report["passed_count"],
                "selected_count": report["selected_count"],
                "unique_egress_count": report["unique_egress_count"],
                "output_sha256": content_digest,
            }
            if args.command == "validate":
                manifest.update({"status": "validated_only", "completed_at": utc_now()})
                write_json(run_dir / "manifest.json", manifest)
                print(json.dumps({"status": "validated_only", **manifest["validation"]}, sort_keys=True))
                return 0

            if not args.confirm_production_write:
                raise SyncError("production sync requires --confirm-production-write")
            token = load_token(Path(args.admin_token_file))
            client = ResinClient(
                str(resin.get("base_url") or "http://172.17.0.1:10833"),
                token,
                timeout=float(resin.get("api_timeout_seconds", 20)),
            )
            subscription_name = str(resin.get("subscription_name") or "managed-grok-public-pool")
            platform_id = str(resin.get("platform_id") or "")
            platform_name = str(resin.get("platform_name") or "GrokEU")
            managed_regex = str(resin.get("managed_regex") or f"^{subscription_name}/")
            if not platform_id:
                raise SyncError("resin.platform_id is required")

            before_sub = find_subscription(client, subscription_name)
            before_platform = get_platform(client, platform_id, platform_name)
            before_filters = list(before_platform.get("regex_filters") or [])
            before_regions = list(before_platform.get("region_filters") or [])
            configured_filters = resin.get("platform_regex_filters")
            if configured_filters is None:
                if managed_regex not in before_filters:
                    raise SyncError(
                        "resin.platform_regex_filters is required when adding a source; Resin regex filters use AND semantics"
                    )
                desired_filters = before_filters
            elif isinstance(configured_filters, list) and all(isinstance(item, str) for item in configured_filters):
                desired_filters = list(dict.fromkeys(item.strip() for item in configured_filters if item.strip()))
                if not desired_filters:
                    raise SyncError("resin.platform_regex_filters must not be empty")
            else:
                raise SyncError("resin.platform_regex_filters must be a string array")
            configured_regions = resin.get("region_filters")
            if configured_regions is None:
                desired_regions = before_regions
            elif isinstance(configured_regions, list) and all(isinstance(item, str) for item in configured_regions):
                desired_regions = list(dict.fromkeys(item.strip().lower() for item in configured_regions if item.strip()))
            else:
                raise SyncError("resin.region_filters must be a string array")
            existing_digest = ""
            if before_sub is not None:
                existing_digest = sha256_bytes(str(before_sub.get("content") or "").encode("utf-8"))
            if (
                existing_digest == content_digest
                and desired_filters == before_filters
                and desired_regions == before_regions
            ):
                state = {
                    "owner": OWNER,
                    "version": STATE_VERSION,
                    "updated_at": utc_now(),
                    "selected_count": report["selected_count"],
                    "passed_count": report["passed_count"],
                    "content_sha256": content_digest,
                    "subscription_id": before_sub.get("id") if before_sub else "",
                }
                write_json(state_dir / "state.json", state)
                manifest.update({"status": "no_change", "completed_at": utc_now()})
                write_json(run_dir / "manifest.json", manifest)
                removed = prune_owned_runs(state_dir, int(config.get("retain_runs", 7)), run_dir)
                print(
                    json.dumps(
                        {"status": "no_change", **manifest["validation"], "pruned_runs": len(removed)},
                        sort_keys=True,
                    )
                )
                return 0

            manifest["backups"] = create_backups(config, run_dir)
            write_json(run_dir / "manifest.json", manifest)
            created_id: str | None = None
            platform_patch_attempted = False
            try:
                patch = subscription_patch_from_config(config, content)
                if before_sub is None:
                    current_sub = create_subscription(client, config, content)
                    created_id = str(current_sub["id"])
                else:
                    current_sub = update_subscription(client, str(before_sub["id"]), patch)
                subscription_id = str(current_sub["id"])
                refresh_subscription(client, subscription_id)
                verified_sub = verify_subscription(client, subscription_id, content_digest)

                if desired_filters != before_filters or desired_regions != before_regions:
                    platform_patch: dict[str, Any] = {}
                    if desired_filters != before_filters:
                        platform_patch["regex_filters"] = desired_filters
                    if desired_regions != before_regions:
                        platform_patch["region_filters"] = desired_regions
                    # A failed response can arrive after Resin committed the change.
                    # From this point onward rollback must restore the prior filters.
                    platform_patch_attempted = True
                    updated_platform = client.request(
                        "PATCH",
                        f"/api/v1/platforms/{urllib.parse.quote(platform_id, safe='')}",
                        platform_patch,
                    )
                    if (
                        not isinstance(updated_platform, dict)
                        or list(updated_platform.get("regex_filters") or []) != desired_filters
                        or list(updated_platform.get("region_filters") or []) != desired_regions
                    ):
                        raise SyncError("platform filter update verification failed")
                final_platform = get_platform(client, platform_id, platform_name)
                if list(final_platform.get("regex_filters") or []) != desired_filters:
                    raise SyncError("platform regex filters do not match the locked configuration")
                if list(final_platform.get("region_filters") or []) != desired_regions:
                    raise SyncError("platform region filters do not match the locked configuration")

                state = {
                    "owner": OWNER,
                    "version": STATE_VERSION,
                    "updated_at": utc_now(),
                    "selected_count": report["selected_count"],
                    "passed_count": report["passed_count"],
                    "content_sha256": content_digest,
                    "subscription_id": subscription_id,
                    "node_count": int(verified_sub.get("node_count") or 0),
                    "platform_id": platform_id,
                }
                write_json(state_dir / "state.json", state)
                manifest.update(
                    {
                        "status": "completed",
                        "completed_at": utc_now(),
                        "subscription_id": subscription_id,
                        "node_count": state["node_count"],
                        "platform_filter_added": desired_filters != before_filters,
                        "platform_regions_changed": desired_regions != before_regions,
                    }
                )
                write_json(run_dir / "manifest.json", manifest)
                removed = prune_owned_runs(state_dir, int(config.get("retain_runs", 7)), run_dir)
                print(
                    json.dumps(
                        {
                            "status": "completed",
                            **manifest["validation"],
                            "node_count": state["node_count"],
                            "platform_routable_node_count": int(final_platform.get("routable_node_count") or 0),
                            "pruned_runs": len(removed),
                        },
                        sort_keys=True,
                    )
                )
                return 0
            except Exception as exc:
                rollback: dict[str, Any] = {}
                if platform_patch_attempted:
                    try:
                        client.request(
                            "PATCH",
                            f"/api/v1/platforms/{urllib.parse.quote(platform_id, safe='')}",
                            {
                                "regex_filters": before_filters,
                                "region_filters": before_regions,
                            },
                        )
                        rollback["platform_restored"] = True
                    except Exception as rollback_exc:
                        rollback["platform_restored"] = False
                        rollback["platform_error"] = safe_message(rollback_exc)
                rollback.update(restore_subscription(client, config, before_sub, created_id))
                manifest.update(
                    {
                        "status": "rolled_back" if all(
                            value is not False for key, value in rollback.items() if key.endswith("restored")
                        ) else "rollback_incomplete",
                        "completed_at": utc_now(),
                        "error": safe_message(exc),
                        "rollback": rollback,
                    }
                )
                write_json(run_dir / "manifest.json", manifest)
                raise
        except Exception as exc:
            if manifest.get("status") == "running":
                manifest.update({"status": "failed_closed", "completed_at": utc_now(), "error": safe_message(exc)})
                write_json(run_dir / "manifest.json", manifest)
            raise


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    validate = sub.add_parser("validate", help="validate sources without changing Resin")
    validate.add_argument("--config", required=True)
    run_cmd = sub.add_parser("run", help="validate and sync through the Resin Admin API")
    run_cmd.add_argument("--config", required=True)
    run_cmd.add_argument("--admin-token-file", required=True)
    run_cmd.add_argument("--confirm-production-write", action="store_true")
    apply_cmd = sub.add_parser("apply", help="apply a fresh hash-locked validation run")
    apply_cmd.add_argument("--config", required=True)
    apply_cmd.add_argument("--validated-run", required=True)
    apply_cmd.add_argument("--admin-token-file", required=True)
    apply_cmd.add_argument("--confirm-production-write", action="store_true")
    reselect_cmd = sub.add_parser("reselect", help="reselect from a hash-locked validation report")
    reselect_cmd.add_argument("--config", required=True)
    reselect_cmd.add_argument("--validated-run", required=True)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    return run(args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (SyncError, ValueError, OSError) as exc:
        print(json.dumps({"status": "error", "error": safe_message(exc)}, sort_keys=True), file=sys.stderr)
        raise SystemExit(2)
