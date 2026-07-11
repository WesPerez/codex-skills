#!/usr/bin/env python3
import argparse
import json
import re
import sys
import zipfile
import os
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_CLIENT_ID = "app_X8zY6vW2pQ9tR3dE7nK1jL5gH"


def parse_timestamp(value):
    if value in (None, ""):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    if isinstance(value, str):
        text = value.strip()
        if not text:
            return None
        if text.isdigit():
            return int(text)
        normalized = text.replace("Z", "+00:00")
        try:
            return int(datetime.fromisoformat(normalized).timestamp())
        except ValueError:
            return None
    return None


def account_name(email, fallback):
    if email and "@" in email:
        return email.split("@", 1)[0]
    if email:
        return re.sub(r"[^A-Za-z0-9_.-]+", "_", email).strip("_") or fallback
    return fallback


def account_key(account):
    credentials = account.get("credentials") or {}
    email = str(credentials.get("email") or account.get("email") or "").strip().lower()
    account_id = str(credentials.get("chatgpt_account_id") or credentials.get("account_id") or "").strip().lower()
    token = str(credentials.get("access_token") or "")
    if email or account_id or token:
        return ("account", email, account_id, token)
    name = account.get("name")
    if name:
        return f"name:{str(name).strip().lower()}"
    return json.dumps(account, sort_keys=True, ensure_ascii=False)[:200]


def convert_cpa_account(raw, source_zip, source_entry, index):
    email = str(raw.get("email") or "").strip()
    expires_at = parse_timestamp(raw.get("expired"))
    last_refresh_at = parse_timestamp(raw.get("last_refresh"))
    name = account_name(email, f"cpa_{index:04d}")
    credentials = {
        "access_token": raw.get("access_token") or "",
        "account_id": raw.get("account_id") or "",
        "chatgpt_account_id": raw.get("account_id") or "",
        "chatgpt_user_id": "",
        "client_id": DEFAULT_CLIENT_ID,
        "email": email,
        "expires_at": expires_at,
        "id_token": raw.get("id_token") or "",
        "organization_id": "",
        "plan_type": raw.get("plan_type") or raw.get("chatgpt_plan_type") or "",
        "refresh_token": raw.get("refresh_token") or "",
        "session_token": "",
    }
    return {
        "auto_pause_on_expired": True,
        "concurrency": 10,
        "credentials": credentials,
        "extra": {
            "auth_provider": "openai-oauth",
            "email": email,
            "source": Path(source_zip).name,
            "source_entry": source_entry,
            "source_type": raw.get("type") or "cpa",
            "last_refresh_at": last_refresh_at,
            "privacy_mode": False,
        },
        "name": name,
        "platform": "openai",
        "priority": 1,
        "rate_multiplier": 1,
        "type": "oauth",
    }


def load_cpa_zip(zip_path, seen, start_index, dedupe):
    accounts = []
    duplicates = 0
    missing_access_token = 0
    missing_email = 0

    with zipfile.ZipFile(zip_path) as zf:
        names = sorted(name for name in zf.namelist() if name.lower().endswith(".json"))
        for offset, name in enumerate(names, start=start_index):
            with zf.open(name) as fh:
                raw = json.load(fh)
            account = convert_cpa_account(raw, zip_path, name, offset)
            if not account["credentials"].get("access_token"):
                missing_access_token += 1
            if not account["credentials"].get("email"):
                missing_email += 1
            key = account_key(account)
            if dedupe and key in seen:
                duplicates += 1
                continue
            if dedupe:
                seen.add(key)
            accounts.append(account)

    return {
        "source": str(zip_path),
        "json_entries": len(names),
        "added_accounts": len(accounts),
        "duplicates_skipped": duplicates,
        "missing_access_token": missing_access_token,
        "missing_email": missing_email,
    }, accounts


def write_json(path, data, force=False):
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing file without --force: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    if os.name != "nt":
        path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description="Build a Sub2API bundle from CPA single-account zip files.")
    parser.add_argument("--source-zip", action="append", required=True, help="CPA zip file. Repeat for multiple batches.")
    parser.add_argument("--out", required=True, help="Output Sub2API bundle JSON path.")
    parser.add_argument("--manifest", required=True, help="Output manifest JSON path.")
    parser.add_argument("--force", action="store_true", help="Allow overwriting the explicitly named output files.")
    parser.set_defaults(dedupe=False)
    parser.add_argument("--dedupe", dest="dedupe", action="store_true", help="Deduplicate entries using account identity rules.")
    parser.add_argument("--no-dedupe", dest="dedupe", action="store_false", help="Keep every JSON entry even when email/name repeats. This is the default.")
    args = parser.parse_args()

    seen = set()
    accounts = []
    summaries = []
    index = 1
    for source_zip in args.source_zip:
        zip_path = Path(source_zip).expanduser().resolve()
        if not zip_path.exists():
            raise SystemExit(f"source zip not found: {zip_path}")
        summary, new_accounts = load_cpa_zip(zip_path, seen, index, args.dedupe)
        summaries.append(summary)
        accounts.extend(new_accounts)
        index += summary["json_entries"]

    bundle = {
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "proxies": [],
        "accounts": accounts,
    }
    manifest = {
        "generated_at": bundle["exported_at"],
        "sources": summaries,
        "total_accounts": len(accounts),
        "dedupe": args.dedupe,
        "notes": [
            "Generated from CPA single-account zip files.",
            "For public/shared K12 account packages, prefer random/small imports rather than importing everything at once.",
            "Do not batch refresh these tokens.",
        ],
    }

    out_path = Path(args.out).expanduser().resolve()
    manifest_path = Path(args.manifest).expanduser().resolve()
    write_json(out_path, bundle, args.force)
    write_json(manifest_path, manifest, args.force)
    print(json.dumps({
        "accounts": len(accounts),
        "bundle": str(out_path),
        "manifest": str(manifest_path),
        "sources": summaries,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
