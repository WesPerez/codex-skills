#!/usr/bin/env python3
"""Exact, resumable handling for a reviewed Grok OAuth revoked-token batch.

The manifest and validation artifact lock the scope. Validation and status do
not mutate production; every production mutation needs explicit acknowledgement.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import importlib.util
import inspect
import io
import json
import os
from pathlib import Path
import secrets
import stat
import subprocess
import sys
from types import ModuleType
from typing import Any


OFFICIAL_BASE = "https://cli-chat-proxy.grok.com/v1"
WRITE_PHASES = frozenset({"backup", "delete", "remint", "reverify"})
PHASES = ("validate", "backup", "delete", "remint", "reverify", "status")


class ReconcileError(RuntimeError):
    """A deliberately redacted operational failure."""


def now() -> str:
    return dt.datetime.now(dt.timezone.utc).isoformat().replace("+00:00", "Z")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_json(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def require_private(path: Path, *, label: str, directory: bool = False) -> None:
    if (path.is_dir() if directory else path.is_file()) is False:
        raise ReconcileError(f"{label} is unavailable")
    if os.name != "nt" and stat.S_IMODE(path.stat().st_mode) & 0o077:
        raise ReconcileError(f"{label} permissions are unsafe")


def atomic_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    temp = path.with_name(f".{path.name}.{secrets.token_hex(6)}.tmp")
    try:
        temp.write_text(json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        temp.chmod(0o600)
        os.replace(temp, path)
        path.chmod(0o600)
    finally:
        temp.unlink(missing_ok=True)


@contextlib.contextmanager
def batch_lock(batch: Path):
    path = batch / ".reconcile.lock"
    with path.open("a+", encoding="utf-8") as handle:
        path.chmod(0o600)
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise ReconcileError("another reconciliation phase is already running for this batch") from exc
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def safe_path(value: Any, *, project: Path, batch: Path, label: str, must_exist: bool = True) -> Path:
    if not isinstance(value, str) or not value.strip():
        raise ReconcileError(f"{label} path is missing")
    candidate = Path(value).expanduser()
    runs = (project / "private" / "runs").resolve()
    choices = [candidate] if candidate.is_absolute() else [project / candidate, runs / candidate, batch / candidate]
    path = next((item.resolve() for item in choices if not must_exist or item.is_file()), choices[0].resolve())
    roots = (runs, batch)
    if not any(path == root or root in path.parents for root in roots):
        raise ReconcileError(f"{label} path is outside private runs or the batch")
    if must_exist and not path.is_file():
        raise ReconcileError(f"{label} file is unavailable")
    if must_exist:
        require_private(path, label=label)
    return path


def relative_private_path(path: Path, project: Path) -> str:
    try:
        return str(path.resolve().relative_to(project.resolve()))
    except ValueError as exc:
        raise ReconcileError("artifact path is outside project") from exc


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ReconcileError(f"{label} is invalid") from exc
    if not isinstance(value, dict):
        raise ReconcileError(f"{label} must be a JSON object")
    return value


def ids(value: Any, label: str) -> list[int]:
    if not isinstance(value, list):
        raise ReconcileError(f"{label} must be an ID list")
    try:
        result = [int(item) for item in value]
    except (TypeError, ValueError) as exc:
        raise ReconcileError(f"{label} contains an invalid ID") from exc
    if any(item <= 0 for item in result) or len(result) != len(set(result)):
        raise ReconcileError(f"{label} must contain unique positive IDs")
    return result


def load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise ReconcileError("project integration module is unavailable")
    module = importlib.util.module_from_spec(spec)
    try:
        spec.loader.exec_module(module)
    except Exception as exc:  # project module may reject unsafe/missing runtime files
        raise ReconcileError("project integration module could not be loaded") from exc
    return module


def add_import_path(path: Path) -> None:
    value = str(path.resolve())
    if value not in sys.path:
        sys.path.insert(0, value)


def load_bridge_module(path: Path, values: dict[str, str]) -> ModuleType:
    """Bridge constants must be loaded from the reviewed private bridge.env."""
    before = {key: os.environ.get(key) for key in values}
    try:
        os.environ.update(values)
        return load_module("reconcile_revoked_bridge", path)
    finally:
        for key, previous in before.items():
            if previous is None:
                os.environ.pop(key, None)
            else:
                os.environ[key] = previous


class Context:
    def __init__(self, project: Path, batch: Path, manifest_path: Path, manifest: dict[str, Any], runtime: dict[str, str], bridge_env: dict[str, str]):
        self.project = project
        self.batch = batch
        self.manifest_path = manifest_path
        self.manifest = manifest
        self.runtime = runtime
        self.bridge_env = bridge_env
        self._bridge: ModuleType | None = None
        self._register: ModuleType | None = None

    @property
    def target_group(self) -> dict[str, Any]:
        return self.manifest["environment"]["target_group"]

    @property
    def target_group_id(self) -> int:
        return int(self.target_group["id"])

    @property
    def delete_ids(self) -> list[int]:
        return ids(self.manifest["delete"].get("candidate_ids"), "delete.candidate_ids")

    @property
    def recover_ids(self) -> list[int]:
        return ids(self.manifest["recover"].get("candidate_ids"), "recover.candidate_ids")

    @property
    def bridge(self) -> ModuleType:
        if self._bridge is None:
            self._bridge = load_bridge_module(self.project / "bridge" / "bridge.py", self.bridge_env)
        return self._bridge

    @property
    def register(self) -> ModuleType:
        if self._register is None:
            self._register = load_module("reconcile_revoked_register", self.project / "scripts" / "register_and_import.py")
        return self._register


def load_context(args: argparse.Namespace) -> Context:
    project = Path(args.project_dir).expanduser().resolve()
    if not project.is_dir():
        raise ReconcileError("project directory is unavailable")
    add_import_path(project)
    private = project / "private"
    require_private(private, label="project private directory", directory=True)
    batch = Path(args.batch_dir).expanduser().resolve()
    runs = (private / "runs").resolve()
    if not batch.is_dir() or not (batch == runs or runs in batch.parents):
        raise ReconcileError("batch directory must be inside project/private/runs")
    require_private(batch, label="batch directory", directory=True)
    manifest_path = batch / "manifest.json"
    require_private(manifest_path, label="batch manifest")
    manifest = load_json(manifest_path, "batch manifest")
    environment = manifest.get("environment")
    if not isinstance(environment, dict) or environment.get("name") != "production":
        raise ReconcileError("manifest environment must be production")
    target = environment.get("target_group")
    if not isinstance(target, dict) or not isinstance(target.get("id"), int) or target["id"] <= 0:
        raise ReconcileError("manifest target group is incomplete")
    if target.get("platform") != "grok" or not str(target.get("name") or "").strip():
        raise ReconcileError("manifest target group must be Grok")
    runtime_path = private / "runtime.env"
    bridge_path = private / "bridge.env"
    require_private(runtime_path, label="runtime config")
    require_private(bridge_path, label="bridge config")
    register = load_module("reconcile_revoked_env", project / "scripts" / "register_and_import.py")
    try:
        runtime = register.load_env(runtime_path)
        bridge_env = register.load_env(bridge_path)
    except Exception as exc:
        raise ReconcileError("private runtime configuration is invalid") from exc
    return Context(project, batch, manifest_path, manifest, runtime, bridge_env)


def assert_source(ctx: Context) -> Path:
    source = ctx.manifest.get("source_audit")
    if not isinstance(source, dict):
        raise ReconcileError("source_audit is missing")
    path = safe_path(source.get("path"), project=ctx.project, batch=ctx.batch, label="source audit")
    expected = str(source.get("sha256") or "").lower()
    if len(expected) != 64 or sha256_file(path) != expected:
        raise ReconcileError("source audit hash does not match manifest")
    return path


def assert_backup(ctx: Context) -> Path:
    backup = ctx.manifest.get("backup")
    if not isinstance(backup, dict):
        raise ReconcileError("backup metadata is missing")
    if backup.get("pg_restore_list_verified") is not True:
        raise ReconcileError("backup pg_restore verification is missing")
    path = safe_path(backup.get("path"), project=ctx.project, batch=ctx.batch, label="backup")
    expected = str(backup.get("sha256") or "").lower()
    if len(expected) != 64 or sha256_file(path) != expected:
        raise ReconcileError("backup hash does not match manifest")
    with path.open("rb") as handle:
        signature = handle.read(5)
    if backup.get("format") != "postgres-custom" or signature != b"PGDMP":
        raise ReconcileError("backup is not a PostgreSQL custom-format archive")
    if int(backup.get("bytes") or 0) != path.stat().st_size:
        raise ReconcileError("backup size does not match manifest")
    return path


def assert_backup_ready(ctx: Context) -> Path:
    path = assert_backup(ctx)
    proof_path = ctx.batch / "backup-results.json"
    require_private(proof_path, label="backup result")
    proof = load_json(proof_path, "backup result")
    backup = ctx.manifest["backup"]
    if (
        proof.get("status") != "completed"
        or proof.get("sha256") != backup.get("sha256")
        or proof.get("path") != backup.get("path")
        or int(proof.get("bytes") or 0) != path.stat().st_size
        or proof.get("pg_restore_list_verified") is not True
    ):
        raise ReconcileError("backup result does not prove the current recovery point")
    return path


def assert_delete_complete(ctx: Context) -> None:
    if not ctx.delete_ids:
        return
    path = ctx.batch / "delete-results.json"
    require_private(path, label="delete result")
    result = load_json(path, "delete result")
    rows = result.get("results")
    completed = {
        int(row.get("account_id") or 0)
        for row in rows or []
        if isinstance(row, dict)
        and row.get("post_delete_get_http_status") == 404
        and row.get("delete_http_status") in (200, 204, 404)
    }
    if (
        result.get("status") != "completed"
        or completed != set(ctx.delete_ids)
        or result.get("remaining_group_bindings") != 0
    ):
        raise ReconcileError("delete phase is not complete for the locked candidate set")


def account_rows(ctx: Context, account_ids: list[int]) -> dict[int, dict[str, Any]]:
    if not account_ids:
        return {}
    sql_ids = ",".join(str(value) for value in account_ids)
    query = (
        "select coalesce(json_agg(json_build_object("
        "'id',a.id,'platform',a.platform,'type',a.type,'status',a.status,"
        "'error_message',coalesce(a.error_message,''),"
        "'schedulable',a.schedulable,'official_base',"
        f"coalesce(a.credentials->>'base_url','')={ctx.bridge._sql_literal(OFFICIAL_BASE)},"
        "'group_ids',coalesce((select json_agg(ag.group_id order by ag.group_id) "
        "from account_groups ag where ag.account_id=a.id),'[]'::json)) order by a.id),"
        "'[]'::json) from accounts a where a.deleted_at is null and a.id in (" + sql_ids + ")"
    )
    raw = ctx.bridge._psql_json(query)
    if not isinstance(raw, list):
        raise ReconcileError("target account query returned an invalid result")
    rows = {int(row.get("id")): row for row in raw if isinstance(row, dict) and int(row.get("id") or 0) > 0}
    if set(rows) != set(account_ids):
        raise ReconcileError("target account query did not resolve the exact live set")
    return rows


def assert_grok_rows(
    ctx: Context,
    account_ids: list[int],
    *,
    allowed_statuses: frozenset[str],
    expected_schedulable: bool | None,
    require_clear_error: bool = False,
) -> dict[int, dict[str, Any]]:
    if int(ctx.bridge.SUB2API_GROK_GROUP_ID) != ctx.target_group_id:
        raise ReconcileError("manifest target group does not match bridge configuration")
    rows = account_rows(ctx, account_ids)
    expected_groups = [ctx.target_group_id]
    for row in rows.values():
        if (
            row.get("platform") != "grok" or row.get("type") != "oauth"
            or row.get("status") not in allowed_statuses or row.get("group_ids") != expected_groups
            or not bool(row.get("official_base"))
            or (
                expected_schedulable is not None
                and bool(row.get("schedulable")) != expected_schedulable
            )
            or (require_clear_error and bool(str(row.get("error_message") or "").strip()))
        ):
            raise ReconcileError("target account does not satisfy the locked Grok isolation state")
    return rows


def material_for(ctx: Context, account_id: int) -> tuple[Path, dict[str, Any]]:
    mapping = ctx.manifest["recover"].get("material")
    if not isinstance(mapping, dict) or set(map(str, ctx.recover_ids)) != set(mapping):
        raise ReconcileError("recover.material must map each recovery ID exactly once")
    material_path = safe_path(mapping.get(str(account_id)), project=ctx.project, batch=ctx.batch, label="recovery material")
    data = load_json(material_path, "recovery material")
    rows = data.get("results")
    if not isinstance(rows, list) or len(rows) != 1 or not isinstance(rows[0], dict):
        raise ReconcileError("recovery material must contain exactly one result")
    row = rows[0]
    email = str(row.get("email") or "").strip().lower()
    password = str(row.get("password") or "")
    if not email or "@" not in email or not password or row.get("sso_ok") is not True:
        raise ReconcileError("recovery material is incomplete")
    return material_path, row


def identity_count(ctx: Context, email: str, subject: str) -> int:
    sql = (
        "select count(*) from accounts a where a.deleted_at is null and a.platform='grok' "
        "and a.type='oauth' and (lower(coalesce(a.credentials->>'email',''))="
        + ctx.bridge._sql_literal(email) + " or coalesce(a.credentials->>'sub','')="
        + ctx.bridge._sql_literal(subject) + ")"
    )
    value = ctx.bridge._psql_json("select to_json((" + sql + "))")
    return int(value or 0)


def deleted_group_binding_count(ctx: Context, account_ids: list[int]) -> int:
    if not account_ids:
        return 0
    sql_ids = ",".join(str(value) for value in account_ids)
    value = ctx.bridge._psql_json(
        "select to_json(count(*)) from account_groups where account_id in (" + sql_ids + ")"
    )
    return int(value or 0)


def resolve_recovery_identity(
    ctx: Context,
    account_id: int,
    email: str,
) -> tuple[dict[str, Any], str]:
    snapshot = ctx.bridge.find_account_snapshot_by_id(account_id)
    credentials = (snapshot or {}).get("credentials") or {}
    subject = ctx.bridge.auth_subject(credentials)
    current_email = str(credentials.get("email") or "").strip().lower()
    if not snapshot or not subject or (current_email and current_email != email):
        raise ReconcileError("recovery identity is missing or does not match its material")

    resolver = getattr(ctx.bridge, "find_account_snapshot", None)
    stable_name = f"grok_{email.replace('@', '_')}"
    if not callable(resolver):
        raise ReconcileError("bridge identity resolver is unavailable")
    try:
        inspect.signature(resolver).bind(stable_name, email, subject)
    except (TypeError, ValueError) as exc:
        raise ReconcileError("bridge identity resolver does not support name/email/subject lookup") from exc
    try:
        resolved = resolver(stable_name, email, subject)
    except Exception as exc:
        raise ReconcileError("bridge identity lookup failed or is ambiguous") from exc
    if (
        not resolved
        or int(resolved.get("id") or 0) != account_id
        or identity_count(ctx, email, subject) != 1
    ):
        raise ReconcileError("recovery identity does not resolve exactly to its original account")
    return snapshot, subject


def assert_source_scope(ctx: Context) -> dict[str, int]:
    source = load_json(assert_source(ctx), "source audit")
    classification = source.get("classification")
    recovery = source.get("recovery_material")
    if not isinstance(classification, dict) or not isinstance(recovery, dict):
        raise ReconcileError("source audit does not contain revoked recovery classifications")
    refresh = classification.get("refresh_revoked")
    if not isinstance(refresh, dict):
        raise ReconcileError("source audit refresh_revoked classification is missing")
    revoked = set(ids(refresh.get("account_ids"), "source refresh_revoked.account_ids"))
    proven = set(ids(recovery.get("proven_remint_account_ids"), "source proven_remint_account_ids"))
    not_proven = set(ids(
        recovery.get("local_result_match_not_proven_account_ids"),
        "source local_result_match_not_proven_account_ids",
    ))
    if proven & not_proven or proven | not_proven != revoked:
        raise ReconcileError("source audit recovery classifications are not an exact revoked partition")
    if not set(ctx.delete_ids).issubset(not_proven):
        raise ReconcileError("delete candidates are not all in the source not-proven revoked set")
    if not set(ctx.recover_ids).issubset(proven):
        raise ReconcileError("recovery candidates are not all in the source proven-remint set")
    return {"revoked": len(revoked), "proven": len(proven), "not_proven": len(not_proven)}


def validation_scope(ctx: Context) -> dict[str, Any]:
    material_hashes: dict[str, str] = {}
    for account_id in ctx.recover_ids:
        path, _ = material_for(ctx, account_id)
        material_hashes[str(account_id)] = sha256_file(path)
    proxy_health = ctx.manifest.get("proxy_health") or {}
    proxy_scope: dict[str, Any] = {
        "path": proxy_health.get("path") or "",
        "healthy_refs": proxy_health.get("healthy_refs") or [],
    }
    if proxy_scope["path"]:
        health_path = safe_path(
            proxy_scope["path"],
            project=ctx.project,
            batch=ctx.batch,
            label="proxy health",
        )
        proxy_scope["sha256"] = sha256_file(health_path)
    return {
        "schema_version": ctx.manifest.get("schema_version"),
        "environment": ctx.manifest.get("environment"),
        "source_audit": ctx.manifest.get("source_audit"),
        "delete": {"candidate_ids": ctx.delete_ids},
        "recover": {
            "canary_id": int(ctx.manifest["recover"].get("canary_id") or 0),
            "candidate_ids": ctx.recover_ids,
            "material": ctx.manifest["recover"].get("material"),
            "material_sha256": material_hashes,
        },
        "proxy_health": proxy_scope,
    }


def assert_validation(ctx: Context) -> dict[str, Any]:
    path = ctx.batch / "validate-results.json"
    require_private(path, label="validation result")
    result = load_json(path, "validation result")
    if result.get("status") != "passed":
        raise ReconcileError("validation result is not passed")
    expected = sha256_json(validation_scope(ctx))
    if result.get("scope_sha256") != expected:
        raise ReconcileError("validation result does not match the current locked scope")
    return result


def validate_manifest_shape(ctx: Context) -> None:
    if ctx.manifest.get("schema_version") != 2:
        raise ReconcileError("manifest schema_version must be 2")
    if ctx.manifest.get("operation") != "delete-revoked-and-remint-proven-grok-oauth":
        raise ReconcileError("manifest operation is not a revoked reconciliation")
    if not isinstance(ctx.manifest.get("delete"), dict) or not isinstance(ctx.manifest.get("recover"), dict):
        raise ReconcileError("manifest delete/recover sections are missing")
    delete_ids = ctx.delete_ids
    recover_ids = ctx.recover_ids
    if set(delete_ids) & set(recover_ids):
        raise ReconcileError("delete and recover candidate IDs overlap")
    assert_source_scope(ctx)
    recover = ctx.manifest["recover"]
    mapping = recover.get("material")
    if not isinstance(mapping, dict) or set(mapping) != {str(value) for value in recover_ids}:
        raise ReconcileError("recover.material must have one entry for every recovery ID")
    try:
        canary_id = int(recover.get("canary_id") or 0)
    except (TypeError, ValueError) as exc:
        raise ReconcileError("recover.canary_id is invalid") from exc
    if (recover_ids and canary_id not in recover_ids) or (not recover_ids and canary_id != 0):
        raise ReconcileError("recover.canary_id must identify one locked recovery account")
    proxy_health = ctx.manifest.get("proxy_health")
    if proxy_health is not None:
        if not isinstance(proxy_health, dict):
            raise ReconcileError("proxy_health must be an object")
        path_value = proxy_health.get("path")
        if path_value:
            health_path = safe_path(path_value, project=ctx.project, batch=ctx.batch, label="proxy health")
            health = load_json(health_path, "proxy health")
            healthy = proxy_health.get("healthy_refs") or health.get("healthy_refs")
        else:
            healthy = proxy_health.get("healthy_refs")
        if healthy is not None and (not isinstance(healthy, list) or any(not isinstance(x, str) or not x for x in healthy)):
            raise ReconcileError("proxy health references are invalid")


def phase_validate(ctx: Context) -> dict[str, Any]:
    validate_manifest_shape(ctx)
    isolated_statuses = frozenset({"active", "error"})
    delete_rows = assert_grok_rows(
        ctx, ctx.delete_ids,
        allowed_statuses=isolated_statuses,
        expected_schedulable=False,
    )
    recover_rows = assert_grok_rows(
        ctx, ctx.recover_ids,
        allowed_statuses=isolated_statuses,
        expected_schedulable=False,
    )
    exact_identity = 0
    material_paths: set[Path] = set()
    for account_id in ctx.recover_ids:
        material_path, material = material_for(ctx, account_id)
        if material_path in material_paths:
            raise ReconcileError("recovery material paths must be unique per account")
        material_paths.add(material_path)
        email = str(material["email"]).strip().lower()
        resolve_recovery_identity(ctx, account_id, email)
        exact_identity += 1
    result = {
        "phase": "validate", "status": "passed", "ok": True,
        "validated_at": now(),
        "delete_count": len(delete_rows), "recover_count": len(recover_rows),
        "delete_recover_overlap": False, "delete_all_unschedulable": True,
        "recover_material_complete": True, "bridge_identity_exact_count": exact_identity,
        "source_scope_locked": True,
        "scope_sha256": sha256_json(validation_scope(ctx)),
    }
    atomic_json(ctx.batch / "validate-results.json", result)
    return result


def phase_backup(ctx: Context) -> dict[str, Any]:
    validate_manifest_shape(ctx)
    assert_validation(ctx)
    current = ctx.manifest.get("backup")
    if isinstance(current, dict) and current.get("pg_restore_list_verified") is True:
        path = assert_backup(ctx)
        verify_backup_archive(ctx, path)
        result = {
            "phase": "backup",
            "status": "completed",
            "ok": True,
            "path": current.get("path"),
            "sha256": current.get("sha256"),
            "bytes": path.stat().st_size,
            "pg_restore_list_verified": True,
            "reused": True,
        }
        atomic_json(ctx.batch / "backup-results.json", result)
        return result
    backup_dir = ctx.batch / "backup"
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    backup_dir.chmod(0o700)
    stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = backup_dir / f"pre-reconcile-revoked-{stamp}.dump"
    bridge = ctx.bridge
    try:
        with path.open("wb") as handle:
            proc = subprocess.run([
                "docker", "exec", bridge.SUB2API_POSTGRES_CONTAINER, "pg_dump",
                "-U", bridge.SUB2API_PG_USER, "-d", bridge.SUB2API_PG_DB,
                "-Fc", "--no-owner", "--no-acl",
            ], stdout=handle, stderr=subprocess.PIPE, timeout=600, check=False)
        if proc.returncode != 0:
            raise ReconcileError("production backup failed")
        path.chmod(0o600)
        verify_backup_archive(ctx, path)
        backup = {
            "path": relative_private_path(path, ctx.project), "sha256": sha256_file(path),
            "bytes": path.stat().st_size, "format": "postgres-custom",
            "pg_restore_list_verified": True, "verified_at": now(), "retention_status": "retain_until_finalized",
        }
        ctx.manifest["backup"] = backup
        atomic_json(ctx.manifest_path, ctx.manifest)
        result = {
            "phase": "backup", "status": "completed", "ok": True,
            "path": backup["path"], "sha256": backup["sha256"], "bytes": backup["bytes"],
            "pg_restore_list_verified": True, "reused": False,
        }
        atomic_json(ctx.batch / "backup-results.json", result)
        return result
    except Exception:
        path.unlink(missing_ok=True)
        raise


def verify_backup_archive(ctx: Context, path: Path) -> None:
    with path.open("rb") as handle:
        verified = subprocess.run([
            "docker", "exec", "-i", ctx.bridge.SUB2API_POSTGRES_CONTAINER, "pg_restore", "-l",
        ], stdin=handle, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=120, check=False)
    if verified.returncode != 0:
        raise ReconcileError("production backup pg_restore verification failed")


def result_file(ctx: Context, name: str) -> Path:
    return ctx.batch / name


def phase_delete(ctx: Context) -> dict[str, Any]:
    validate_manifest_shape(ctx)
    assert_validation(ctx)
    assert_source(ctx)
    assert_backup_ready(ctx)
    path = result_file(ctx, "delete-results.json")
    existing = load_json(path, "delete results") if path.exists() else {}
    if path.exists() and not isinstance(existing.get("results"), list):
        raise ReconcileError("delete results must contain a results list")
    rows = existing.get("results") or []
    row_indexes: dict[int, int] = {}
    completed: set[int] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ReconcileError("delete results contain an invalid row")
        try:
            account_id = int(row.get("account_id"))
        except (TypeError, ValueError) as exc:
            raise ReconcileError("delete results contain an invalid account ID") from exc
        if account_id not in ctx.delete_ids or account_id in row_indexes:
            raise ReconcileError("delete results contain duplicate or out-of-scope IDs")
        row_indexes[account_id] = index
        if row.get("post_delete_get_http_status") == 404:
            if row.get("delete_http_status") not in (200, 204, 404):
                raise ReconcileError("completed delete result has an invalid HTTP status")
            completed.add(account_id)

    for account_id in completed:
        status, _ = ctx.bridge.sub2api_api_status("GET", f"/api/v1/admin/accounts/{account_id}")
        if status != 404:
            raise ReconcileError("a completed delete ID is live again; operation stopped")
    pending = [account_id for account_id in ctx.delete_ids if account_id not in completed]
    assert_grok_rows(
        ctx, pending,
        allowed_statuses=frozenset({"active", "error"}),
        expected_schedulable=False,
    )
    payload = {
        "operation": "delete-exact-revoked-grok-accounts", "status": "running", "started_at": existing.get("started_at") or now(),
        "candidate_count": len(ctx.delete_ids), "preflight_passed": True, "results": rows,
    }
    atomic_json(path, payload)
    for account_id in pending:
        before, _ = ctx.bridge.sub2api_api_status("GET", f"/api/v1/admin/accounts/{account_id}")
        if before != 200:
            payload.update({"status": "failed", "failure": {"account_id": account_id, "stage": "pre_get", "http_status": before}})
            atomic_json(path, payload)
            raise ReconcileError("delete precondition changed; operation stopped")
        deleted, _ = ctx.bridge.sub2api_api_status("DELETE", f"/api/v1/admin/accounts/{account_id}")
        after, _ = ctx.bridge.sub2api_api_status("GET", f"/api/v1/admin/accounts/{account_id}")
        row = {"account_id": account_id, "delete_http_status": deleted, "post_delete_get_http_status": after, "verified_at": now()}
        if account_id in row_indexes:
            payload["results"][row_indexes[account_id]] = row
        else:
            row_indexes[account_id] = len(payload["results"])
            payload["results"].append(row)
        if deleted not in (200, 204) or after != 404:
            payload.update({"status": "failed", "failure": {"account_id": account_id, "stage": "delete_or_verify"}})
            atomic_json(path, payload)
            raise ReconcileError("delete verification failed; operation stopped")
        atomic_json(path, payload)
    remaining_bindings = deleted_group_binding_count(ctx, ctx.delete_ids)
    if remaining_bindings != 0:
        payload.update({"status": "failed", "remaining_group_bindings": remaining_bindings})
        atomic_json(path, payload)
        raise ReconcileError("deleted accounts still have group bindings")
    payload.update({"status": "completed", "completed_at": now(), "remaining_group_bindings": 0})
    atomic_json(path, payload)
    return {
        "phase": "delete", "ok": True,
        "deleted_count": len(ctx.delete_ids),
        "post_delete_get_404": len(ctx.delete_ids),
        "remaining_group_bindings": 0,
    }


def healthy_refs(ctx: Context) -> set[str]:
    data = ctx.manifest.get("proxy_health")
    if not isinstance(data, dict):
        raise ReconcileError("remint requires proxy_health")
    refs = data.get("healthy_refs")
    if data.get("path"):
        health = load_json(safe_path(data["path"], project=ctx.project, batch=ctx.batch, label="proxy health"), "proxy health")
        refs = refs or health.get("healthy_refs")
    if not isinstance(refs, list) or not refs or any(not isinstance(ref, str) or not ref for ref in refs):
        raise ReconcileError("remint requires verified healthy proxy references")
    return set(refs)


def safe_bridge_response(value: Any) -> dict[str, Any]:
    allowed = {"status", "ok", "account_id", "action", "probe", "availability", "error_code", "imported", "group_id", "rollback_succeeded"}
    return {key: value.get(key) for key in sorted(allowed) if isinstance(value, dict) and key in value}


def remint_result_path(ctx: Context, account_id: int) -> Path:
    return ctx.batch / "remint" / str(account_id) / "result.json"


def load_remint_result(ctx: Context, account_id: int) -> dict[str, Any]:
    path = remint_result_path(ctx, account_id)
    if not path.exists():
        return {}
    require_private(path, label="remint result")
    data = load_json(path, "remint result")
    if int(data.get("account_id") or 0) != account_id:
        raise ReconcileError("remint result account ID does not match its path")
    return data


def bridge_result_verified(data: dict[str, Any], account_id: int) -> bool:
    bridge = data.get("bridge")
    return bool(
        isinstance(bridge, dict)
        and bridge.get("http_status") == 200
        and bridge.get("action") == "updated"
        and int(bridge.get("account_id") or 0) == account_id
        and bridge.get("probe") == "passed"
        and bridge.get("availability") in {"usable", "usable_exhausted"}
    )


def isolate_account(ctx: Context, account_id: int) -> bool:
    try:
        ctx.bridge.sub2api_api(
            "POST",
            f"/api/v1/admin/accounts/{account_id}/schedulable",
            {"schedulable": False},
        )
        snapshot = ctx.bridge.find_account_snapshot_by_id(account_id)
        return bool(snapshot and snapshot.get("schedulable") is False)
    except Exception:
        return False


def verify_isolated_recovery(
    ctx: Context,
    account_id: int,
    email: str,
) -> tuple[dict[str, Any], dict[str, Any]]:
    rows = assert_grok_rows(
        ctx, [account_id],
        allowed_statuses=frozenset({"active"}),
        expected_schedulable=False,
        require_clear_error=True,
    )
    snapshot, _ = resolve_recovery_identity(ctx, account_id, email)
    return rows[account_id], snapshot


def phase_remint(
    ctx: Context,
    account_id: int,
    proxy_ref: str,
    playwright_fallback: bool = False,
) -> dict[str, Any]:
    validate_manifest_shape(ctx)
    assert_validation(ctx)
    assert_source(ctx)
    assert_backup_ready(ctx)
    assert_delete_complete(ctx)
    if account_id not in ctx.recover_ids:
        raise ReconcileError("account ID is outside the locked recovery set")
    material_path, material = material_for(ctx, account_id)
    email = str(material["email"]).strip().lower()
    account_dir = ctx.batch / "remint" / str(account_id)
    auth_dir = account_dir / "auth"
    output = remint_result_path(ctx, account_id)
    existing_result = load_remint_result(ctx, account_id)
    if existing_result.get("status") in {
        "recovered", "recovered_isolated", "postcheck_failed_isolated", "postcheck_failed_unisolated",
    }:
        if not bridge_result_verified(existing_result, account_id):
            raise ReconcileError("existing remint result lacks verified bridge evidence")
        if existing_result.get("status") in {"recovered", "postcheck_failed_unisolated"} and not isolate_account(ctx, account_id):
            raise ReconcileError("verified candidate could not be isolated for reconciliation")
        row, snapshot = verify_isolated_recovery(ctx, account_id, email)
        existing_result.update({
            "status": "recovered_isolated",
            "completed_at": now(),
            "postcondition": {
                "status": snapshot.get("status"),
                "schedulable": False,
                "group_ids": snapshot.get("group_ids") or [],
                "official_base": bool(row.get("official_base")),
                "error_cleared": True,
                "identity_row_count": 1,
            },
        })
        atomic_json(output, existing_result)
        return {
            "phase": "remint", "ok": True, "account_id": account_id,
            "action": "updated", "availability": existing_result["bridge"]["availability"],
            "reused_verified_candidate": True, "schedulable": False,
        }
    completed = completed_remint_ids(ctx)
    canary_id = int(ctx.manifest["recover"]["canary_id"])
    if completed and canary_id not in completed:
        raise ReconcileError("existing remint results do not include the locked canary")
    if not completed and account_id != canary_id:
        raise ReconcileError("the locked canary must recover before other accounts")
    if proxy_ref not in healthy_refs(ctx):
        raise ReconcileError("proxy reference is not verified healthy")
    assert_grok_rows(
        ctx, [account_id],
        allowed_statuses=frozenset({"active", "error"}),
        expected_schedulable=False,
    )
    snapshot, subject = resolve_recovery_identity(ctx, account_id, email)
    account_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    account_dir.chmod(0o700)
    auth_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    auth_dir.chmod(0o700)
    resume_pending_push = existing_result.get("status") == "minted_pending_push"
    if resume_pending_push and existing_result.get("material_sha256") != sha256_file(material_path):
        raise ReconcileError("pending remint result does not match the locked recovery material")
    result: dict[str, Any] = dict(existing_result) if resume_pending_push else {
        "account_id": account_id, "status": "minting", "started_at": now(), "proxy_ref": proxy_ref,
        "material_sha256": sha256_file(material_path),
        "precondition": {"resolved_original_id": True, "unique_identity": True, "schedulable": False, "group_ids": [ctx.target_group_id]},
    }
    if resume_pending_push:
        result.update({"resumed_at": now(), "proxy_ref": proxy_ref})
    atomic_json(output, result)
    captured = io.StringIO()
    bridge_verified = False
    try:
        if resume_pending_push:
            auth_path = safe_path(
                result.get("auth_path"),
                project=ctx.project,
                batch=ctx.batch,
                label="pending reminted auth",
            )
            if sha256_file(auth_path) != result.get("auth_sha256"):
                raise ReconcileError("pending reminted auth hash no longer matches")
            auth = load_json(auth_path, "pending reminted auth")
        else:
            pool = ctx.register.load_proxy_pool(ctx.runtime.get("GROK_PROXY_POOL_FILE", ""), ctx.runtime)
            proxy = pool.url_for(proxy_ref)
            from xconsole_client.xai_oauth import CLIPROXYAPI_GROK_BASE_URL, complete_build_oauth
            with contextlib.redirect_stdout(captured), contextlib.redirect_stderr(captured):
                oauth = complete_build_oauth(
                    email, str(material["password"]), cliproxyapi_auth_dir=auth_dir,
                    cliproxyapi_base_url=CLIPROXYAPI_GROK_BASE_URL, proxy=proxy,
                    yescaptcha_key=ctx.runtime.get("YESCAPTCHA_API_KEY", ""), protocol=True,
                    playwright_fallback=playwright_fallback, headless=True, timeout=240, debug=False,
                )
            auth_path = Path(str(oauth.cliproxyapi_path or "")).resolve()
            if not auth_path.is_file() or auth_dir.resolve() not in auth_path.parents:
                raise ReconcileError("remint did not produce an auth artifact")
            auth_path.chmod(0o600)
            auth = load_json(auth_path, "reminted auth")
        if str(auth.get("email") or "").strip().lower() != email or ctx.bridge.auth_subject(auth) != subject:
            raise ReconcileError("reminted identity does not match its original account")
        if ctx.bridge.auth_is_stale(snapshot, auth):
            raise ReconcileError("reminted credentials are stale")
        result.update({
            "status": "minted_pending_push",
            "minted_at": result.get("minted_at") or now(),
            "auth_path": relative_private_path(auth_path, ctx.project),
            "auth_sha256": sha256_file(auth_path),
            "auth_file_retained": True,
            "subject_match": True,
        })
        atomic_json(output, result)
        key_path = Path(ctx.bridge_env.get("BRIDGE_MANAGEMENT_KEY_FILE", "")).expanduser().resolve()
        require_private(key_path, label="bridge management key")
        remote_base = str(ctx.bridge_env.get("BRIDGE_BASE") or "").strip()
        if not remote_base:
            port = str(ctx.bridge_env.get("BRIDGE_PORT") or "").strip()
            if not port.isdigit():
                raise ReconcileError("bridge endpoint configuration is incomplete")
            remote_base = f"http://127.0.0.1:{port}"
        add_import_path(ctx.project / "clients" / "windows")
        import cpa
        ok, http_status, response_text = cpa.push_auth_file(
            remote_base=remote_base, secret=key_path.read_text(encoding="utf-8").strip(),
            filename=f"xai-remint-{account_id}.json", payload=auth, proxy=None, verify_tls=True, timeout=300,
        )
        try:
            response = json.loads(response_text)
        except json.JSONDecodeError:
            response = {}
        result["bridge"] = {"http_status": http_status, **safe_bridge_response(response)}
        received_id = int(response.get("account_id") or 0)
        if response.get("action") == "created" and received_id != account_id:
            removed = received_id > 0 and ctx.bridge.delete_sub2api_account(received_id)
            result.update({"status": "failed", "failure_stage": "unexpected_create", "unexpected_duplicate_removed": bool(removed)})
            atomic_json(output, result)
            raise ReconcileError("bridge created an unexpected duplicate; duplicate delete was attempted")
        expected = (
            ok and http_status == 200 and response.get("action") == "updated" and received_id == account_id
            and response.get("probe") == "passed" and response.get("availability") in {"usable", "usable_exhausted"}
        )
        if not expected:
            result.update({"status": "failed", "failure_stage": "bridge_update_or_probe"})
            atomic_json(output, result)
            raise ReconcileError("bridge update or semantic probe failed")
        bridge_verified = True
        if not isolate_account(ctx, account_id):
            raise ReconcileError("verified bridge candidate could not be isolated")
        final_row, final = verify_isolated_recovery(ctx, account_id, email)
        final_subject = ctx.bridge.auth_subject(final.get("credentials") or {})
        final_ok = bool(
            final
            and final_subject == subject
            and ctx.bridge.auth_subject(final.get("credentials") or {}) == subject
        )
        result.update({
            "status": "recovered_isolated" if final_ok else "postcheck_failed_isolated", "completed_at": now(),
            "postcondition": {
                "status": (final or {}).get("status"),
                "schedulable": False,
                "group_ids": (final or {}).get("group_ids") or [],
                "official_base": bool(final_row.get("official_base")),
                "error_cleared": not bool(str(final_row.get("error_message") or "").strip()),
                "subject_match": bool(final_ok),
                "identity_row_count": identity_count(ctx, email, subject),
            },
        })
        atomic_json(output, result)
        if not final_ok:
            raise ReconcileError("remint postcondition is not exact")
        return {
            "phase": "remint", "ok": True, "account_id": account_id,
            "action": "updated", "availability": response.get("availability"),
            "schedulable": False,
        }
    except Exception as exc:
        if bridge_verified:
            isolated = isolate_account(ctx, account_id)
            result.update({
                "status": "postcheck_failed_isolated" if isolated else "postcheck_failed_unisolated",
                "completed_at": now(),
                "failure_stage": "post_bridge_isolation_or_verification",
                "error_type": type(exc).__name__,
            })
            atomic_json(output, result)
        elif result.get("status") == "minted_pending_push":
            result.update({"last_attempt_failed_at": now(), "error_type": type(exc).__name__})
            atomic_json(output, result)
        elif result.get("status") not in {"failed", "recovered_isolated"}:
            result.update({"status": "failed", "completed_at": now(), "failure_stage": result.get("status"), "error_type": type(exc).__name__})
            try:
                after = ctx.bridge.find_account_snapshot_by_id(account_id)
                result["post_failure_state"] = {"exists": bool(after), "schedulable": bool((after or {}).get("schedulable")), "group_ids": (after or {}).get("group_ids") or []}
            except Exception:
                result["post_failure_state"] = {"verified": False}
            atomic_json(output, result)
        if isinstance(exc, ReconcileError):
            raise
        raise ReconcileError("remint failed; see the redacted result artifact") from exc


def completed_remint_ids(ctx: Context) -> list[int]:
    result: list[int] = []
    for account_id in ctx.recover_ids:
        data = load_remint_result(ctx, account_id)
        if (
            data.get("status") in {"recovered", "recovered_isolated"}
            and bridge_result_verified(data, account_id)
        ):
            result.append(account_id)
    return result


def recovered_ids(ctx: Context) -> list[int]:
    result = completed_remint_ids(ctx)
    if set(result) != set(ctx.recover_ids):
        raise ReconcileError("reverify requires every locked recovery ID to be recovered")
    return result


def phase_reverify(ctx: Context) -> dict[str, Any]:
    validate_manifest_shape(ctx)
    assert_validation(ctx)
    assert_source(ctx)
    assert_backup_ready(ctx)
    assert_delete_complete(ctx)
    locked = recovered_ids(ctx)
    path = result_file(ctx, "reverify-results.json")
    existing = load_json(path, "reverify results") if path.exists() else {}
    if path.exists() and not isinstance(existing.get("results"), list):
        raise ReconcileError("reverify results must contain a results list")
    rows = existing.get("results") or []
    row_indexes: dict[int, int] = {}
    completed: set[int] = set()
    for index, row in enumerate(rows):
        if not isinstance(row, dict):
            raise ReconcileError("reverify results contain an invalid row")
        try:
            account_id = int(row.get("account_id"))
        except (TypeError, ValueError) as exc:
            raise ReconcileError("reverify results contain an invalid account ID") from exc
        if account_id not in locked or account_id in row_indexes:
            raise ReconcileError("reverify results contain duplicate or out-of-scope IDs")
        row_indexes[account_id] = index
        if row.get("status") == "reverified":
            completed.add(account_id)

    for account_id in completed:
        assert_grok_rows(
            ctx, [account_id],
            allowed_statuses=frozenset({"active"}),
            expected_schedulable=True,
            require_clear_error=True,
        )
        _, material = material_for(ctx, account_id)
        resolve_recovery_identity(ctx, account_id, str(material["email"]).strip().lower())

    payload: dict[str, Any] = {
        "operation": "promote-bridge-verified-isolated-recoveries",
        "status": "running",
        "started_at": existing.get("started_at") or now(),
        "locked_recovered_count": len(locked),
        "results": rows,
    }
    atomic_json(path, payload)
    for account_id in (value for value in locked if value not in completed):
        remint_result = load_remint_result(ctx, account_id)
        availability = str((remint_result.get("bridge") or {}).get("availability") or "")
        try:
            assert_grok_rows(
                ctx, [account_id],
                allowed_statuses=frozenset({"active"}),
                expected_schedulable=False,
                require_clear_error=True,
            )
            if availability not in {"usable", "usable_exhausted"}:
                raise ReconcileError("remint result lacks usable bridge probe evidence")
            _, material = material_for(ctx, account_id)
            resolve_recovery_identity(ctx, account_id, str(material["email"]).strip().lower())
            if not ctx.bridge.promote_sub2api_account(account_id):
                raise ReconcileError("promotion verification failed")
            after = ctx.bridge.find_account_snapshot_by_id(account_id)
            final_rows = assert_grok_rows(
                ctx, [account_id],
                allowed_statuses=frozenset({"active"}),
                expected_schedulable=True,
                require_clear_error=True,
            )
            resolve_recovery_identity(ctx, account_id, str(material["email"]).strip().lower())
            row = {
                "account_id": account_id,
                "status": "reverified",
                "availability": availability,
                "schedulable": bool((after or {}).get("schedulable")),
                "group_ids": (after or {}).get("group_ids") or [],
                "official_base": bool(final_rows[account_id].get("official_base")),
                "verified_at": now(),
            }
            if account_id in row_indexes:
                payload["results"][row_indexes[account_id]] = row
            else:
                row_indexes[account_id] = len(payload["results"])
                payload["results"].append(row)
            atomic_json(path, payload)
        except Exception as exc:
            # Keep the failing account isolated; later accounts are not modified.
            try:
                ctx.bridge.sub2api_api("POST", f"/api/v1/admin/accounts/{account_id}/schedulable", {"schedulable": False})
            except Exception:
                pass
            failed = {
                "account_id": account_id,
                "status": "failed_isolated",
                "error_type": type(exc).__name__,
                "verified_at": now(),
            }
            if availability is not None:
                failed["availability"] = availability
            if account_id in row_indexes:
                payload["results"][row_indexes[account_id]] = failed
            else:
                row_indexes[account_id] = len(payload["results"])
                payload["results"].append(failed)
            payload["status"] = "failed"
            atomic_json(path, payload)
            raise ReconcileError("reverify failed; affected account remains isolated") from exc
    payload.update({"status": "completed", "completed_at": now()})
    atomic_json(path, payload)
    return {"phase": "reverify", "ok": True, "reverified_count": len(locked), "usable": sum(r.get("availability") == "usable" for r in payload["results"]), "usable_exhausted": sum(r.get("availability") == "usable_exhausted" for r in payload["results"])}


def phase_status(ctx: Context) -> dict[str, Any]:
    validate_manifest_shape(ctx)

    def summary(name: str) -> dict[str, Any]:
        path = ctx.batch / name
        if not path.exists():
            return {"present": False, "count": 0}
        require_private(path, label=name)
        data = load_json(path, name)
        return {"present": True, "status": data.get("status"), "count": len(data.get("results") or [])}
    remint = {"recovered": 0, "failed": 0, "present": 0, "expected": len(ctx.recover_ids)}
    for account_id in ctx.recover_ids:
        path = remint_result_path(ctx, account_id)
        if path.exists():
            data = load_remint_result(ctx, account_id)
            remint["present"] += 1
            if data.get("status") in {"recovered", "recovered_isolated"}:
                remint["recovered"] += 1
            elif data.get("status") in {"failed", "postcheck_failed_isolated", "postcheck_failed_unisolated"}:
                remint["failed"] += 1
    delete = summary("delete-results.json")
    reverify = summary("reverify-results.json")
    delete_complete = not ctx.delete_ids or (
        delete.get("status") == "completed" and delete.get("count") == len(ctx.delete_ids)
    )
    remint_complete = remint["recovered"] == len(ctx.recover_ids)
    reverify_complete = not ctx.recover_ids or (
        reverify.get("status") == "completed" and reverify.get("count") == len(ctx.recover_ids)
    )
    return {
        "phase": "status",
        "ok": delete_complete and remint_complete and reverify_complete,
        "delete": delete,
        "remint": remint,
        "reverify": reverify,
        "complete": delete_complete and remint_complete and reverify_complete,
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Reconcile a reviewed Grok revoked-token batch with locked validation evidence.")
    parser.add_argument("--project-dir", required=True, help="grok-build-auth project directory")
    parser.add_argument("--batch-dir", required=True, help="batch directory under project/private/runs")
    parser.add_argument("--phase", required=True, choices=PHASES)
    parser.add_argument("--confirm-production-write", action="store_true", help="required for backup, delete, remint, and reverify")
    parser.add_argument("--account-id", type=int, help="required for a single remint")
    parser.add_argument("--proxy-ref", help="required, verified proxy reference for remint")
    parser.add_argument(
        "--playwright-fallback",
        action="store_true",
        help="allow a headless Playwright retry after protocol remint fails",
    )
    return parser.parse_args()


def main() -> int:
    os.umask(0o077)
    args = parse_args()
    try:
        if args.phase in WRITE_PHASES and not args.confirm_production_write:
            raise ReconcileError("write phase requires --confirm-production-write")
        if args.phase == "remint":
            if args.account_id is None or not args.proxy_ref:
                raise ReconcileError("remint requires exactly one --account-id and --proxy-ref")
        elif args.account_id is not None or args.proxy_ref or args.playwright_fallback:
            raise ReconcileError("remint-only options are not valid with this phase")
        ctx = load_context(args)
        lock = batch_lock(ctx.batch) if args.phase != "status" else contextlib.nullcontext()
        with lock:
            if args.phase == "validate": result = phase_validate(ctx)
            elif args.phase == "backup": result = phase_backup(ctx)
            elif args.phase == "delete": result = phase_delete(ctx)
            elif args.phase == "remint": result = phase_remint(
                ctx, args.account_id, args.proxy_ref, args.playwright_fallback,
            )
            elif args.phase == "reverify": result = phase_reverify(ctx)
            else: result = phase_status(ctx)
        print(json.dumps(result, ensure_ascii=False, sort_keys=True))
        return 0
    except ReconcileError as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False))
        return 2
    except Exception as exc:  # Do not expose imported runtime, OAuth, or bridge details.
        print(json.dumps({"ok": False, "error": "unexpected reconciler failure", "error_type": type(exc).__name__}, ensure_ascii=False))
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
