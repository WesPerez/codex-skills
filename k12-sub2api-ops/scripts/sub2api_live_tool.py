#!/usr/bin/env python3
"""Live Sub2API import helper for prepared K12/OpenAI bundles.

The tool never prints raw tokens or generated admin JWTs. It assumes the agent
is running on the Sub2API host and can access Docker, the Postgres container,
the Sub2API admin HTTP endpoint, and the deployment env file.
"""

from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import sys
import time
from typing import Any
import urllib.error
import urllib.request
import uuid


class ToolError(Exception):
    pass


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def sql_literal(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"


def load_env(path: Path) -> dict[str, str]:
    if not path.exists():
        raise ToolError(f"env file not found: {path}")
    env: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def load_bundle(path: Path) -> dict[str, Any]:
    if not path.exists():
        raise ToolError(f"bundle not found: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("accounts"), list):
        raise ToolError("bundle must be a JSON object with an accounts array")
    data.setdefault("type", "sub2api-data")
    data.setdefault("version", 1)
    data.setdefault("proxies", [])
    return data


def candidate_identities(bundle: dict[str, Any]) -> list[dict[str, str]]:
    rows: list[dict[str, str]] = []
    for index, account in enumerate(bundle.get("accounts") or [], 1):
        if not isinstance(account, dict):
            continue
        creds = account.get("credentials")
        creds = creds if isinstance(creds, dict) else {}
        token = str(creds.get("access_token") or "")
        rows.append(
            {
                "index": str(index),
                "name": str(account.get("name") or "").strip(),
                "email": str(creds.get("email") or account.get("email") or "").strip(),
                "token_sha": sha256_text(token) if token else "",
            }
        )
    if not rows:
        raise ToolError("bundle contains no account records")
    return rows


def run(args: list[str], *, input_text: str | None = None, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        args,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        check=False,
    )


def run_psql(args: argparse.Namespace, sql: str) -> str:
    proc = run(
        [
            "docker",
            "exec",
            "-i",
            args.postgres_container,
            "psql",
            "-U",
            args.pg_user,
            "-d",
            args.pg_db,
            "-At",
            "-F",
            "\t",
        ],
        input_text=sql,
        timeout=args.timeout,
    )
    if proc.returncode != 0:
        raise ToolError(f"psql failed: {proc.stderr.strip() or proc.returncode}")
    return proc.stdout


def table_has_column(args: argparse.Namespace, table: str, column: str) -> bool:
    sql = (
        "select count(*) from information_schema.columns "
        f"where table_name={sql_literal(table)} and column_name={sql_literal(column)};\n"
    )
    return run_psql(args, sql).strip() == "1"


def get_admin(args: argparse.Namespace) -> dict[str, Any]:
    has_token_version = table_has_column(args, "users", "token_version")
    token_expr = "coalesce(token_version,0)" if has_token_version else "0"
    sql = (
        "select id, email, password_hash, role, status, "
        f"{token_expr} from users "
        "where role='admin' and deleted_at is null order by id limit 1;\n"
    )
    rows = [line.split("\t") for line in run_psql(args, sql).splitlines() if line.strip()]
    if not rows:
        raise ToolError("no active admin user found")
    row = rows[0]
    if len(row) != 6:
        raise ToolError("unexpected admin query result")
    user_id, email, password_hash, role, status, token_version = row
    if role != "admin" or status != "active":
        raise ToolError(f"admin user is not active: role={role} status={status}")
    material = email.strip().lower() + "\n" + password_hash
    fingerprint = int.from_bytes(hashlib.sha256(material.encode()).digest()[:8], "big") & 0x7FFFFFFFFFFFFFFF
    return {
        "id": int(user_id),
        "email": email,
        "role": role,
        "token_version": int(token_version or "0") ^ fingerprint,
    }


def b64url(raw: bytes) -> str:
    return base64.urlsafe_b64encode(raw).rstrip(b"=").decode("ascii")


def make_admin_jwt(env: dict[str, str], admin: dict[str, Any], ttl_seconds: int) -> str:
    secret = env.get("JWT_SECRET")
    if not secret:
        raise ToolError("JWT_SECRET missing from env file")
    now = int(time.time())
    header = {"alg": "HS256", "typ": "JWT"}
    claims = {
        "user_id": admin["id"],
        "email": admin["email"],
        "role": admin["role"],
        "token_version": admin["token_version"],
        "iat": now,
        "nbf": now,
        "exp": now + ttl_seconds,
    }
    parts = [
        b64url(json.dumps(header, separators=(",", ":")).encode()),
        b64url(json.dumps(claims, separators=(",", ":")).encode()),
    ]
    signing = ".".join(parts).encode()
    sig = hmac.new(secret.encode(), signing, hashlib.sha256).digest()
    return ".".join(parts + [b64url(sig)])


def duplicate_scan(args: argparse.Namespace, candidates: list[dict[str, str]]) -> dict[str, Any]:
    sql = """
select id, coalesce(name,''), coalesce(credentials->>'email',''),
       coalesce(credentials->>'access_token',''), deleted_at is not null
from accounts;
"""
    existing = []
    for line in run_psql(args, sql).splitlines():
        parts = line.split("\t")
        if len(parts) != 5:
            continue
        row_id, name, email, token, deleted = parts
        existing.append(
            {
                "id": int(row_id),
                "name": name,
                "email": email,
                "token_sha": sha256_text(token) if token else "",
                "deleted": deleted == "t",
            }
        )

    buckets: dict[str, dict[str, list[int]]] = {
        "active_name": {},
        "deleted_name": {},
        "active_email": {},
        "deleted_email": {},
        "active_token_sha": {},
        "deleted_token_sha": {},
    }
    for row in existing:
        prefix = "deleted" if row["deleted"] else "active"
        for field in ("name", "email", "token_sha"):
            value = row[field]
            if value:
                buckets.setdefault(f"{prefix}_{field}", {}).setdefault(value, []).append(row["id"])

    hits: dict[str, int] = {}
    samples: dict[str, list[dict[str, Any]]] = {}
    for key, bucket in buckets.items():
        field = key.split("_", 1)[1]
        rows = []
        for candidate in candidates:
            value = candidate.get(field) or ""
            if value and value in bucket:
                rows.append(
                    {
                        "candidate_index": int(candidate["index"]),
                        "value_hash": value[:12] if field == "token_sha" else sha256_text(value)[:12],
                        "ids": bucket[value][:8],
                    }
                )
        hits[key] = len(rows)
        if rows:
            samples[key] = rows[:8]

    return {
        "candidate_accounts": len(candidates),
        "existing_accounts_checked": len(existing),
        "hit_counts": hits,
        "sample_hits": samples,
        "note": "token_sha matches are strong duplicates; name/email matches may be diagnostic for K12 bundles",
    }


def backup_db(args: argparse.Namespace) -> dict[str, Any]:
    backup_dir = Path(args.backup_dir)
    backup_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    stamp = dt.datetime.now().strftime("%Y%m%d%H%M%S")
    path = backup_dir / f"pre-k12-import-{stamp}.dump"
    with path.open("wb") as handle:
        proc = subprocess.run(
            [
                "docker",
                "exec",
                args.postgres_container,
                "sh",
                "-lc",
                'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc --no-owner --no-acl',
            ],
            stdout=handle,
            stderr=subprocess.PIPE,
            check=False,
            timeout=args.timeout,
        )
    if proc.returncode != 0:
        raise ToolError(f"pg_dump failed: {proc.stderr.decode('utf-8', 'replace').strip() or proc.returncode}")
    os.chmod(path, 0o600)
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    return {"path": str(path), "bytes": path.stat().st_size, "sha256": digest}


def import_bundle(args: argparse.Namespace, bundle: dict[str, Any], token: str) -> dict[str, Any]:
    body = json.dumps({"data": bundle, "skip_default_group_bind": True}, separators=(",", ":")).encode()
    url = args.base_url.rstrip("/") + "/api/v1/admin/accounts/data"
    req = urllib.request.Request(url, data=body, method="POST")
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", "Bearer " + token)
    req.add_header("Idempotency-Key", "k12-import-" + uuid.uuid4().hex)
    try:
        with urllib.request.urlopen(req, timeout=args.timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
            code = resp.status
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        code = exc.code
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ToolError(f"import API returned non-JSON status={code}: {raw[:400]}") from exc
    if code >= 400:
        raise ToolError(f"import API failed status={code}: {json.dumps(parsed, ensure_ascii=True)[:800]}")
    return {"http_status": code, "response": parsed}


def resolve_imported_ids(args: argparse.Namespace, candidates: list[dict[str, str]]) -> list[int]:
    wanted = {row["token_sha"] for row in candidates if row.get("token_sha")}
    sql = """
select id, coalesce(credentials->>'access_token',''), deleted_at is not null
from accounts;
"""
    ids: list[int] = []
    for line in run_psql(args, sql).splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        row_id, token, deleted = parts
        if deleted == "t":
            continue
        if token and sha256_text(token) in wanted:
            ids.append(int(row_id))
    ids = sorted(set(ids))
    if len(ids) != len(wanted):
        raise ToolError(f"resolved {len(ids)} active imported ids for {len(wanted)} candidate token hashes")
    return ids


def values_for_ids(ids: list[int]) -> str:
    if not ids:
        raise ToolError("no account ids to operate on")
    return ",".join(f"({int(item)})" for item in ids)


def bind_group(args: argparse.Namespace, ids: list[int]) -> int:
    group_sql = f"select id from groups where name={sql_literal(args.group)} and deleted_at is null order by id limit 1;\n"
    group_rows = [line.strip() for line in run_psql(args, group_sql).splitlines() if line.strip()]
    if not group_rows:
        raise ToolError(f"group not found: {args.group}")
    group_id = int(group_rows[0])
    sql = f"""
with imported(account_id) as (values {values_for_ids(ids)}),
inserted as (
  insert into account_groups (account_id, group_id, priority, created_at)
  select i.account_id, {group_id}, {int(args.group_priority)}, now()
  from imported i
  join accounts a on a.id = i.account_id and a.deleted_at is null
  where not exists (
    select 1 from account_groups ag where ag.account_id = i.account_id and ag.group_id = {group_id}
  )
  on conflict do nothing
  returning account_id
)
select count(*) from inserted;
"""
    out = run_psql(args, sql).strip()
    return int(out or "0")


def sync_top_level_expires(args: argparse.Namespace, ids: list[int]) -> int:
    sql = f"""
with imported(id) as (values {values_for_ids(ids)}),
updated as (
  update accounts a
  set expires_at = to_timestamp((a.credentials->>'expires_at')::bigint)
  from imported i
  where a.id = i.id
    and a.deleted_at is null
    and a.expires_at is null
    and a.credentials ? 'expires_at'
    and (a.credentials->>'expires_at') ~ '^[0-9]+$'
  returning a.id
)
select count(*) from updated;
"""
    out = run_psql(args, sql).strip()
    return int(out or "0")


def verify(args: argparse.Namespace, ids: list[int]) -> dict[str, Any]:
    id_values = values_for_ids(ids)
    sql = f"""
select 'active_total', count(*) from accounts where deleted_at is null;
select 'active_openai_oauth_k12', count(*) from accounts where deleted_at is null and platform='openai' and type='oauth' and credentials->>'plan_type'='k12';
select 'imported_active', count(*) from accounts where deleted_at is null and id in (select id from (values {id_values}) as imported(id));
select 'imported_bound_group', count(*) from account_groups ag join groups g on g.id=ag.group_id where g.name={sql_literal(args.group)} and ag.account_id in (select id from (values {id_values}) as imported(id));
select 'imported_missing_expires_at', count(*) from accounts where deleted_at is null and id in (select id from (values {id_values}) as imported(id)) and expires_at is null;
select 'active_status_error', count(*) from accounts where deleted_at is null and status='error';
select 'active_error_401', count(*) from accounts where deleted_at is null and coalesce(error_message,'') ilike '%401%';
select 'active_error_402', count(*) from accounts where deleted_at is null and coalesce(error_message,'') ilike '%402%';
"""
    counts: dict[str, int] = {}
    for line in run_psql(args, sql).splitlines():
        parts = line.split("\t")
        if len(parts) == 2:
            counts[parts[0]] = int(parts[1])
    return counts


def cmd_preflight(args: argparse.Namespace) -> int:
    bundle = load_bundle(Path(args.bundle))
    candidates = candidate_identities(bundle)
    scan = duplicate_scan(args, candidates)
    print(json.dumps({"bundle_accounts": len(candidates), "duplicate_scan": scan}, indent=2, sort_keys=True))
    token_hits = scan["hit_counts"].get("active_token_sha", 0) + scan["hit_counts"].get("deleted_token_sha", 0)
    if token_hits and not args.allow_token_duplicates:
        return 1
    return 0


def cmd_import(args: argparse.Namespace) -> int:
    bundle = load_bundle(Path(args.bundle))
    candidates = candidate_identities(bundle)
    scan = duplicate_scan(args, candidates)
    token_hits = scan["hit_counts"].get("active_token_sha", 0) + scan["hit_counts"].get("deleted_token_sha", 0)
    if token_hits and not args.allow_token_duplicates:
        print(json.dumps({"duplicate_scan": scan}, indent=2, sort_keys=True))
        raise ToolError("token hash duplicate detected; use --allow-token-duplicates only if this is intentional")
    if args.dry_run:
        print(json.dumps({"dry_run": True, "bundle_accounts": len(candidates), "duplicate_scan": scan}, indent=2, sort_keys=True))
        return 0
    if not args.confirm_write:
        raise ToolError("live import requires --confirm-write after verifying scope and rollback")
    if args.environment in {"production", "preproduction"} and not args.confirm_production_write:
        raise ToolError(
            "production/preproduction import requires --confirm-production-write after explicit user authorization"
        )

    backup = backup_db(args)
    env = load_env(Path(args.env_file))
    admin = get_admin(args)
    token = make_admin_jwt(env, admin, args.jwt_ttl_seconds)
    import_result = import_bundle(args, bundle, token)
    imported_ids = resolve_imported_ids(args, candidates)
    inserted_bindings = bind_group(args, imported_ids)
    updated_expires = sync_top_level_expires(args, imported_ids)
    verification = verify(args, imported_ids)
    print(
        json.dumps(
            {
                "backup": backup,
                "duplicate_scan": scan,
                "import": import_result,
                "imported_ids": imported_ids,
                "inserted_group_bindings": inserted_bindings,
                "updated_top_level_expires_at": updated_expires,
                "verification": verification,
                "not_run": "upstream usability/quota probes",
            },
            indent=2,
            sort_keys=True,
        )
    )
    return 0


def add_common_args(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--bundle", required=True, help="prepared sub2api-data bundle JSON")
    parser.add_argument("--postgres-container", required=True)
    parser.add_argument("--pg-user", required=True)
    parser.add_argument("--pg-db", required=True)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--allow-token-duplicates", action="store_true")
    parser.add_argument(
        "--environment",
        required=True,
        choices=["local", "development", "test", "preproduction", "production"],
        help="verified target environment; required even for read-only preflight",
    )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Live Sub2API K12 import helper without printing secrets.")
    sub = parser.add_subparsers(dest="command", required=True)

    preflight = sub.add_parser("preflight", help="check a prepared bundle against live DB without writes")
    add_common_args(preflight)
    preflight.set_defaults(func=cmd_preflight)

    imp = sub.add_parser("import", help="backup, import, bind, sync expiry, and verify a prepared bundle")
    add_common_args(imp)
    imp.add_argument("--env-file", required=True, help="Sub2API deployment .env containing JWT_SECRET")
    imp.add_argument("--base-url", required=True, help="Sub2API base URL, e.g. http://127.0.0.1:13080")
    imp.add_argument("--backup-dir", required=True)
    imp.add_argument("--group", default="openai")
    imp.add_argument("--group-priority", type=int, default=1)
    imp.add_argument("--jwt-ttl-seconds", type=int, default=3600)
    imp.add_argument("--dry-run", action="store_true", help="run duplicate checks only; no backup/import/bind writes")
    imp.add_argument("--confirm-write", action="store_true", help="confirm scoped write and rollback plan")
    imp.add_argument(
        "--confirm-production-write",
        action="store_true",
        help="additional confirmation for explicitly authorized production/preproduction writes",
    )
    imp.set_defaults(func=cmd_import)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except ToolError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
