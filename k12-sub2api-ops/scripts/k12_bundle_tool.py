#!/usr/bin/env python3
"""Offline inspector/converter for K12/OpenAI Sub2API account bundles.

The script never prints raw tokens. Conversion output contains secrets and is
therefore written only to an explicit output path with mode 0600.
"""

from __future__ import annotations

import argparse
import base64
import copy
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from typing import Any
import zipfile


class ToolError(Exception):
    pass


def sha256_text(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def token_hash(token: str | None) -> str | None:
    if not token:
        return None
    return sha256_text(token)


def short_hash(value: str | None) -> str | None:
    return value[:12] if value else None


def parse_json_bytes(raw: bytes, source: str) -> Any:
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise ToolError(f"{source}: not UTF-8 JSON") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise ToolError(f"{source}: invalid JSON: {exc}") from exc


def parse_leading_json(text: str, source: str) -> tuple[Any, int]:
    stripped = text.lstrip()
    if not stripped:
        raise ToolError(f"{source}: empty text")
    try:
        data, end = json.JSONDecoder().raw_decode(stripped)
    except json.JSONDecodeError as exc:
        raise ToolError(f"{source}: no leading JSON object: {exc}") from exc
    return data, len(stripped) - end


def run_capture(args: list[str]) -> bytes:
    proc = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    if proc.returncode != 0:
        stderr = proc.stderr.decode("utf-8", errors="replace").strip()
        raise ToolError(f"{args[0]} failed: {stderr or proc.returncode}")
    return proc.stdout


def zip_json_docs(path: Path) -> list[dict[str, Any]]:
    docs: list[dict[str, Any]] = []
    with zipfile.ZipFile(path) as zf:
        for info in sorted(zf.infolist(), key=lambda item: item.filename):
            if info.is_dir() or not info.filename.lower().endswith(".json"):
                continue
            data = parse_json_bytes(zf.read(info), f"{path}!{info.filename}")
            docs.append({"source": f"{path}!{info.filename}", "data": data})
    return docs


def rar_members_with_unrar(path: Path) -> list[str]:
    if not shutil.which("unrar"):
        return []
    try:
        out = run_capture(["unrar", "lb", "-p-", str(path)])
    except ToolError:
        return []
    return [
        line.strip()
        for line in out.decode("utf-8", errors="replace").splitlines()
        if line.strip().lower().endswith(".json")
    ]


def rar_members_with_7z(path: Path) -> list[str]:
    if not shutil.which("7z"):
        return []
    try:
        out = run_capture(["7z", "l", "-slt", str(path)])
    except ToolError:
        return []
    members: list[str] = []
    for line in out.decode("utf-8", errors="replace").splitlines():
        if line.startswith("Path = "):
            member = line.removeprefix("Path = ").strip()
            if member and member != str(path) and member.lower().endswith(".json"):
                members.append(member)
    return members


def rar_json_docs(path: Path) -> list[dict[str, Any]]:
    members = rar_members_with_unrar(path)
    if members and shutil.which("unrar"):
        docs: list[dict[str, Any]] = []
        for member in members:
            raw = run_capture(["unrar", "p", "-inul", "-p-", str(path), member])
            docs.append({"source": f"{path}!{member}", "data": parse_json_bytes(raw, f"{path}!{member}")})
        return docs

    members = rar_members_with_7z(path)
    if members and shutil.which("7z"):
        docs = []
        for member in members:
            raw = run_capture(["7z", "x", "-so", str(path), member])
            docs.append({"source": f"{path}!{member}", "data": parse_json_bytes(raw, f"{path}!{member}")})
        return docs

    return []


def load_json_docs(path: Path) -> list[dict[str, Any]]:
    if not path.exists():
        raise ToolError(f"not found: {path}")

    if path.is_dir():
        docs = []
        for item in sorted(path.rglob("*.json")):
            docs.append({"source": str(item), "data": parse_json_bytes(item.read_bytes(), str(item))})
        return docs

    if zipfile.is_zipfile(path):
        return zip_json_docs(path)

    rar_docs = rar_json_docs(path)
    if rar_docs:
        return rar_docs

    return [{"source": str(path), "data": parse_json_bytes(path.read_bytes(), str(path))}]


def iter_codex_session_user_texts(path: Path) -> list[tuple[int, str]]:
    if not path.exists():
        raise ToolError(f"session not found: {path}")
    rows: list[tuple[int, str]] = []
    with path.open("r", encoding="utf-8") as handle:
        for line_no, line in enumerate(handle, 1):
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            payload = row.get("payload")
            if not isinstance(payload, dict) or payload.get("role") != "user":
                continue
            content = payload.get("content")
            if not isinstance(content, list):
                continue
            for part in content:
                if isinstance(part, dict) and isinstance(part.get("text"), str):
                    rows.append((line_no, part["text"]))
    return rows


def classify(data: Any) -> str:
    if isinstance(data, dict):
        accounts = data.get("accounts")
        if isinstance(accounts, list) and (data.get("type") == "sub2api-data" or "proxies" in data or "version" in data):
            return "sub2api_bundle"
        if data.get("platform") == "openai" and isinstance(data.get("credentials"), dict):
            return "sub2api_account"
        if data.get("type") == "codex" or ("access_token" in data and ("email" in data or "account_id" in data)):
            return "codex_account"
        if isinstance(accounts, list):
            return "account_container"
    if isinstance(data, list):
        return "account_list"
    return "unknown"


def account_items(doc: dict[str, Any]) -> list[tuple[str, dict[str, Any], str]]:
    source = doc["source"]
    data = doc["data"]
    kind = classify(data)
    if kind in {"sub2api_bundle", "account_container"}:
        return [(source, item, "sub2api_account") for item in data.get("accounts", []) if isinstance(item, dict)]
    if kind in {"sub2api_account", "codex_account"}:
        return [(source, data, kind)]
    if kind == "account_list":
        items = []
        for item in data:
            if isinstance(item, dict):
                items.append((source, item, classify(item)))
        return items
    return []


def decode_jwt_payload(token: str | None) -> dict[str, Any]:
    if not token or token.count(".") < 2:
        return {}
    part = token.split(".")[1]
    padding = "=" * (-len(part) % 4)
    try:
        raw = base64.urlsafe_b64decode(part + padding)
        payload = json.loads(raw.decode("utf-8"))
    except Exception:
        return {}
    return payload if isinstance(payload, dict) else {}


def find_key(obj: Any, names: set[str]) -> Any:
    if isinstance(obj, dict):
        for key, value in obj.items():
            if key in names:
                return value
        for value in obj.values():
            found = find_key(value, names)
            if found is not None:
                return found
    elif isinstance(obj, list):
        for value in obj:
            found = find_key(value, names)
            if found is not None:
                return found
    return None


def parse_time(value: Any) -> Any:
    if value is None or isinstance(value, (int, float)):
        return value
    if not isinstance(value, str):
        return value
    stripped = value.strip()
    if not stripped:
        return value
    if stripped.isdigit():
        return int(stripped)
    try:
        normalized = stripped.replace("Z", "+00:00")
        parsed = dt.datetime.fromisoformat(normalized)
    except ValueError:
        return value
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return int(parsed.timestamp())


def normalize_expires(account: dict[str, Any]) -> dict[str, Any]:
    out = copy.deepcopy(account)
    if "expires_at" in out:
        out["expires_at"] = parse_time(out["expires_at"])
    creds = out.get("credentials")
    if isinstance(creds, dict) and "expires_at" in creds:
        creds["expires_at"] = parse_time(creds["expires_at"])
        if out.get("expires_at") in (None, "") and isinstance(creds.get("expires_at"), (int, float)):
            out["expires_at"] = creds["expires_at"]
    return out


def source_ws_suffix(source: str) -> str | None:
    stem = Path(source.split("!", 1)[-1]).stem
    match = re.search(r"(?:^|[_\-.])(ws\d{1,4})(?:$|[_\-.])", stem, re.IGNORECASE)
    return match.group(1).lower() if match else None


def clean_name(value: Any) -> str | None:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    text = text.replace("/", "_").replace("\\", "_")
    return re.sub(r"\s+", "_", text)


def make_account_name(raw: dict[str, Any], source: str, access_token: str | None) -> str:
    email = clean_name(raw.get("email"))
    if email:
        base = email.lower()
    else:
        base = (
            clean_name(raw.get("name"))
            or clean_name(raw.get("account_id"))
            or clean_name(raw.get("chatgpt_account_id"))
            or f"token_{short_hash(token_hash(access_token)) or 'unknown'}"
        )
    suffix = source_ws_suffix(source)
    if suffix and not base.lower().endswith(f"__{suffix}"):
        return f"{base}__{suffix}"
    return base


def convert_codex_account(raw: dict[str, Any], source: str) -> dict[str, Any]:
    access_token = raw.get("access_token")
    if not access_token:
        raise ToolError(f"{source}: codex account is missing access_token")

    payload = decode_jwt_payload(access_token)
    exp = raw.get("expires_at") or raw.get("exp") or payload.get("exp")
    exp = parse_time(exp)
    plan_type = (
        raw.get("plan_type")
        or raw.get("chatgpt_plan_type")
        or find_key(payload, {"plan_type", "chatgpt_plan_type"})
    )

    credentials: dict[str, Any] = {
        "access_token": access_token,
    }
    if plan_type:
        credentials["plan_type"] = plan_type
    optional_fields = {
        "session_token": raw.get("session_token"),
        "email": raw.get("email").strip().lower() if isinstance(raw.get("email"), str) else raw.get("email"),
        "account_id": raw.get("account_id") or find_key(payload, {"account_id"}),
        "chatgpt_account_id": raw.get("chatgpt_account_id") or find_key(payload, {"chatgpt_account_id"}),
        "chatgpt_user_id": raw.get("chatgpt_user_id") or find_key(payload, {"chatgpt_user_id", "user_id", "sub"}),
    }
    for key, value in optional_fields.items():
        if value not in (None, ""):
            credentials[key] = value
    if exp:
        credentials["expires_at"] = exp

    account: dict[str, Any] = {
        "name": make_account_name(raw, source, access_token),
        "platform": "openai",
        "type": "oauth",
        "credentials": credentials,
        "auto_pause_on_expired": True,
        "concurrency": 10,
        "priority": 5,
        "rate_multiplier": 1,
        "extra": {
            "source": "codex",
            "import_source": "k12_bundle_tool",
            "source_file": source,
            "access_token_sha256": token_hash(access_token),
            "openai_oauth_responses_websockets_v2_mode": True,
        },
    }
    if exp:
        account["expires_at"] = exp
    return account


def account_identity(account: dict[str, Any]) -> dict[str, str | None]:
    creds = account.get("credentials") if isinstance(account.get("credentials"), dict) else {}
    extra = account.get("extra") if isinstance(account.get("extra"), dict) else {}
    raw_token = creds.get("access_token") or account.get("access_token")
    token_sha = extra.get("access_token_sha256") or token_hash(raw_token)
    return {
        "name": clean_name(account.get("name")),
        "email": (creds.get("email") or account.get("email")),
        "token_sha": token_sha,
        "chatgpt_account_id": creds.get("chatgpt_account_id") or account.get("chatgpt_account_id"),
        "plan_type": creds.get("plan_type") or account.get("plan_type") or account.get("chatgpt_plan_type"),
    }


def account_plan(account: dict[str, Any]) -> str:
    ident = account_identity(account)
    return str(ident.get("plan_type") or "unknown")


def ensure_unique_names(accounts: list[dict[str, Any]]) -> None:
    base_counts: dict[str, int] = {}
    for account in accounts:
        name = clean_name(account.get("name")) or "unnamed"
        base_counts[name] = base_counts.get(name, 0) + 1

    seen_ordinals: dict[str, int] = {}
    used: set[str] = set()
    for account in accounts:
        name = clean_name(account.get("name")) or "unnamed"
        seen_ordinals[name] = seen_ordinals.get(name, 0) + 1
        if base_counts[name] == 1 and name not in used:
            account["name"] = name
            used.add(name)
            continue

        ident = account_identity(account)
        suffix = None
        if ident.get("chatgpt_account_id"):
            suffix = str(ident["chatgpt_account_id"])[:8]
        elif ident.get("token_sha"):
            suffix = short_hash(str(ident["token_sha"]))
        candidate = f"{name}__{suffix}" if suffix else ""
        if not candidate or candidate in used:
            candidate = f"{name}__{seen_ordinals[name]:02d}"
        while candidate in used:
            seen_ordinals[name] += 1
            candidate = f"{name}__{seen_ordinals[name]:02d}"
        account["name"] = candidate
        used.add(candidate)


def docs_to_bundle(docs: list[dict[str, Any]]) -> dict[str, Any]:
    accounts: list[dict[str, Any]] = []
    proxies: list[Any] = []
    for doc in docs:
        kind = classify(doc["data"])
        if kind == "sub2api_bundle" and isinstance(doc["data"].get("proxies"), list):
            proxies.extend(doc["data"]["proxies"])
        for source, item, item_kind in account_items(doc):
            if item_kind == "codex_account":
                accounts.append(convert_codex_account(item, source))
            else:
                accounts.append(normalize_expires(item))
    if not accounts:
        raise ToolError("no supported account records found")
    ensure_unique_names(accounts)
    return {
        "type": "sub2api-data",
        "version": 1,
        "exported_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "proxies": proxies,
        "accounts": accounts,
    }


def summarize_docs(docs: list[dict[str, Any]]) -> dict[str, Any]:
    doc_rows = []
    accounts: list[dict[str, Any]] = []
    kinds: dict[str, int] = {}
    plans: dict[str, int] = {}
    platform_types: dict[str, int] = {}
    top_expires_iso = 0
    top_expires_numeric = 0
    credential_expires_iso = 0
    credential_expires_numeric = 0
    top_missing_credential_numeric = 0
    missing_token = 0

    for doc in docs:
        kind = classify(doc["data"])
        items = account_items(doc)
        doc_rows.append({"source": doc["source"], "kind": kind, "accounts": len(items)})
        kinds[kind] = kinds.get(kind, 0) + 1
        for _source, account, item_kind in items:
            accounts.append(account)
            plans[account_plan(account)] = plans.get(account_plan(account), 0) + 1
            if item_kind == "codex_account":
                platform = "openai"
                account_type = "oauth"
            else:
                platform = account.get("platform") or "unknown"
                account_type = account.get("type") or "unknown"
            key = f"{platform}/{account_type}"
            platform_types[key] = platform_types.get(key, 0) + 1
            creds = account.get("credentials") if isinstance(account.get("credentials"), dict) else account
            exp = account.get("expires_at")
            if isinstance(exp, str):
                top_expires_iso += 1
            elif isinstance(exp, (int, float)):
                top_expires_numeric += 1
            cred_exp = creds.get("expires_at") if isinstance(creds, dict) else None
            if isinstance(cred_exp, str):
                credential_expires_iso += 1
            elif isinstance(cred_exp, (int, float)):
                credential_expires_numeric += 1
                if exp in (None, ""):
                    top_missing_credential_numeric += 1
            if not creds.get("access_token"):
                missing_token += 1

    duplicates = duplicate_summary(accounts)
    return {
        "documents": doc_rows,
        "document_kinds": kinds,
        "account_count": len(accounts),
        "plans": plans,
        "platform_types": platform_types,
        "expires_at": {
            "top_level_iso_string": top_expires_iso,
            "top_level_numeric": top_expires_numeric,
            "credentials_iso_string": credential_expires_iso,
            "credentials_numeric": credential_expires_numeric,
            "top_level_missing_credentials_numeric": top_missing_credential_numeric,
        },
        "missing_access_token": missing_token,
        "duplicates": duplicates,
    }


def duplicate_summary(accounts: list[dict[str, Any]]) -> dict[str, list[dict[str, Any]]]:
    fields = ["name", "email", "token_sha", "chatgpt_account_id"]
    buckets: dict[str, dict[str, int]] = {field: {} for field in fields}
    for account in accounts:
        ident = account_identity(account)
        for field in fields:
            value = ident.get(field)
            if value:
                buckets[field][str(value)] = buckets[field].get(str(value), 0) + 1

    result: dict[str, list[dict[str, Any]]] = {}
    for field, bucket in buckets.items():
        rows = []
        for value, count in sorted(bucket.items(), key=lambda item: (-item[1], item[0])):
            if count <= 1:
                continue
            display = short_hash(value) if field == "token_sha" else short_hash(sha256_text(value))
            rows.append({"value": display, "count": count})
        result[field] = rows[:20]
    return result


def print_human_summary(summary: dict[str, Any]) -> None:
    print("Documents:")
    for row in summary["documents"]:
        print(f"  - {row['kind']:18} accounts={row['accounts']:5} source={row['source']}")
    print(f"Account count: {summary['account_count']}")
    print(f"Document kinds: {json.dumps(summary['document_kinds'], sort_keys=True)}")
    print(f"Platform/types: {json.dumps(summary['platform_types'], sort_keys=True)}")
    print(f"Plans: {json.dumps(summary['plans'], sort_keys=True)}")
    print(f"expires_at: {json.dumps(summary['expires_at'], sort_keys=True)}")
    print(f"Missing access_token: {summary['missing_access_token']}")
    print("Duplicates (strong first; token hashes are shortened):")
    for field in ["name", "email", "token_sha", "chatgpt_account_id"]:
        rows = summary["duplicates"].get(field, [])
        if rows:
            rendered = ", ".join(f"{row['value']} x{row['count']}" for row in rows[:8])
        else:
            rendered = "none"
        if field == "token_sha":
            label = "token_sha"
        elif field == "chatgpt_account_id":
            label = "chatgpt_account_id_hash (diagnostic)"
        else:
            label = f"{field}_hash"
        print(f"  - {label}: {rendered}")


def write_secret_json(path: Path, data: Any, force: bool) -> None:
    flags = os.O_WRONLY | os.O_CREAT
    flags |= os.O_TRUNC if force else os.O_EXCL
    try:
        fd = os.open(path, flags, 0o600)
    except FileExistsError as exc:
        raise ToolError(f"output exists, use --force to overwrite: {path}") from exc
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=True, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(path, 0o600)


def load_accounts_for_compare(path: Path) -> list[dict[str, Any]]:
    docs = load_json_docs(path)
    bundle = docs_to_bundle(docs)
    return bundle["accounts"]


def compare_accounts(candidate: list[dict[str, Any]], existing: list[dict[str, Any]]) -> dict[str, Any]:
    existing_sets: dict[str, set[str]] = {"name": set(), "email": set(), "token_sha": set()}
    for account in existing:
        ident = account_identity(account)
        for field in existing_sets:
            value = ident.get(field)
            if value:
                existing_sets[field].add(str(value))

    hits: dict[str, int] = {"name": 0, "email": 0, "token_sha": 0}
    for account in candidate:
        ident = account_identity(account)
        for field in hits:
            value = ident.get(field)
            if value and str(value) in existing_sets[field]:
                hits[field] += 1
    return {
        "candidate_accounts": len(candidate),
        "existing_accounts": len(existing),
        "duplicate_candidates": hits,
        "note": "chatgpt_account_id is intentionally not used as a duplicate boundary",
    }


def cmd_inspect(args: argparse.Namespace) -> int:
    docs = load_json_docs(Path(args.path))
    summary = summarize_docs(docs)
    if args.json:
        print(json.dumps(summary, ensure_ascii=True, indent=2, sort_keys=True))
    else:
        print_human_summary(summary)
    return 0


def cmd_convert(args: argparse.Namespace) -> int:
    docs = load_json_docs(Path(args.path))
    bundle = docs_to_bundle(docs)
    output = Path(args.output)
    write_secret_json(output, bundle, args.force)
    print(f"Wrote {len(bundle['accounts'])} account(s) to {output} with mode 0600.")
    print("Output contains account secrets; do not paste or upload it casually.")
    return 0


def cmd_extract_pasted_session(args: argparse.Namespace) -> int:
    session = Path(args.session)
    matches = []
    for line_no, text in iter_codex_session_user_texts(session):
        if args.marker and args.marker not in text:
            continue
        try:
            data, trailing = parse_leading_json(text, f"{session}:{line_no}")
        except ToolError:
            continue
        kind = classify(data)
        accounts = account_items({"source": f"{session}:{line_no}", "data": data})
        if kind in {"sub2api_bundle", "account_container"} and accounts:
            matches.append((line_no, data, trailing, len(accounts)))

    if not matches:
        raise ToolError("no pasted Sub2API-like account bundle found in session")

    line_no, data, trailing, account_count = matches[0 if args.first else -1]
    if isinstance(data, dict):
        data = copy.deepcopy(data)
        data.setdefault("type", "sub2api-data")
        data.setdefault("version", 1)
        data.setdefault("proxies", [])

    output = Path(args.output)
    write_secret_json(output, data, args.force)
    print(f"Wrote pasted bundle from session line {line_no} to {output} with mode 0600.")
    print(f"Accounts: {account_count}; trailing non-JSON characters ignored: {trailing}.")
    print("Output contains account secrets; do not paste or upload it casually.")
    return 0


def cmd_compare(args: argparse.Namespace) -> int:
    candidate = load_accounts_for_compare(Path(args.candidate))
    existing = load_accounts_for_compare(Path(args.existing))
    result = compare_accounts(candidate, existing)
    print(json.dumps(result, ensure_ascii=True, indent=2, sort_keys=True))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Inspect and convert K12/OpenAI Sub2API account bundles without printing tokens.")
    sub = parser.add_subparsers(dest="command", required=True)

    inspect = sub.add_parser("inspect", help="summarize a JSON file, directory, ZIP, or RAR archive")
    inspect.add_argument("path")
    inspect.add_argument("--json", action="store_true", help="emit machine-readable JSON summary")
    inspect.set_defaults(func=cmd_inspect)

    convert = sub.add_parser("convert", help="convert supported inputs to a Sub2API import bundle")
    convert.add_argument("path")
    convert.add_argument("--output", required=True, help="output JSON path; file is created with mode 0600")
    convert.add_argument("--force", action="store_true", help="overwrite an existing output file")
    convert.set_defaults(func=cmd_convert)

    extract = sub.add_parser("extract-pasted-session", help="extract a pasted Sub2API bundle from a Codex session JSONL")
    extract.add_argument("session", help="Codex session JSONL path")
    extract.add_argument("--output", required=True, help="output JSON path; file is created with mode 0600")
    extract.add_argument("--marker", default="", help="optional text that must appear in the source user message")
    extract.add_argument("--first", action="store_true", help="use the first matching pasted bundle instead of the latest")
    extract.add_argument("--force", action="store_true", help="overwrite an existing output file")
    extract.set_defaults(func=cmd_extract_pasted_session)

    compare = sub.add_parser("compare", help="compare candidate bundle against an existing export by strong identifiers")
    compare.add_argument("candidate")
    compare.add_argument("existing")
    compare.set_defaults(func=cmd_compare)
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
