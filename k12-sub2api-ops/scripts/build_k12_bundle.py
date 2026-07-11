#!/usr/bin/env python3
import argparse
import json
import sys
import zipfile
import os
from datetime import datetime, timezone
from pathlib import Path


DEFAULT_GROUPS = [
    "k12_5h_high_36.json",
    "k12_5h_mid_73.json",
    "k12_5h_full_203.json",
]
ALL_GROUPS = DEFAULT_GROUPS + ["k12_5h_low_1022.json"]


def load_json_entry(zip_file, name):
    try:
        with zip_file.open(name) as fh:
            return json.load(fh)
    except KeyError:
        raise SystemExit(f"missing entry in zip: {name}")


def account_key(account):
    credentials = account.get("credentials") or {}
    # K12 account dumps often share one ChatGPT workspace/account id across many
    # distinct OAuth users. Email/name/token are the real per-account identity.
    email = str(credentials.get("email") or account.get("email") or "").strip().lower()
    account_id = str(credentials.get("chatgpt_account_id") or credentials.get("account_id") or "").strip().lower()
    token = str(credentials.get("access_token") or "")
    if email or account_id or token:
        return ("account", email, account_id, token)
    name = account.get("name")
    if name:
        return f"name:{str(name).strip().lower()}"
    token = credentials.get("access_token")
    if token:
        return f"access_token:{token[:80]}"
    for key in ("chatgpt_account_id", "account_id"):
        value = credentials.get(key) or account.get(key)
        if value:
            return f"{key}:{str(value).strip().lower()}"
    return json.dumps(account, sort_keys=True, ensure_ascii=False)[:200]


def normalize_bundle(raw, source_name):
    accounts = raw.get("accounts")
    if not isinstance(accounts, list):
        raise SystemExit(f"{source_name} does not contain an accounts list")
    return accounts


def build_bundle(zip_path, group_names):
    summary = []
    output_accounts = []
    seen = set()
    duplicate_count = 0

    with zipfile.ZipFile(zip_path) as zf:
        for group_name in group_names:
            raw = load_json_entry(zf, group_name)
            accounts = normalize_bundle(raw, group_name)
            added = 0
            duplicates = 0
            for account in accounts:
                key = account_key(account)
                if key in seen:
                    duplicate_count += 1
                    duplicates += 1
                    continue
                seen.add(key)
                output_accounts.append(account)
                added += 1
            summary.append({
                "source": group_name,
                "input_accounts": len(accounts),
                "added_accounts": added,
                "duplicates_skipped": duplicates,
            })

    bundle = {
        "exported_at": datetime.now(timezone.utc).isoformat(),
        "proxies": [],
        "accounts": output_accounts,
    }
    manifest = {
        "source_zip": str(zip_path),
        "groups": summary,
        "total_accounts": len(output_accounts),
        "duplicates_skipped": duplicate_count,
        "notes": [
            "Generated from the LINUX DO 1334 K12 package.",
            "Do not batch refresh imported tokens; source thread explicitly says not to refresh tokens.",
            "Recommended bundle excludes the low_1022 group to reduce duplicate/low-quality imports.",
        ],
    }
    return bundle, manifest


def write_json(path, data, force=False):
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing file without --force: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    if os.name != "nt":
        path.chmod(0o600)


def main():
    parser = argparse.ArgumentParser(description="Build deduplicated sub2api bundles from the 1334 K12 zip.")
    parser.add_argument("--source-zip", required=True, help="Path to 1334个-不要去刷新令牌.zip")
    parser.add_argument("--out-dir", default="data", help="Output directory")
    parser.add_argument("--force", action="store_true", help="Allow overwriting generated output files.")
    args = parser.parse_args()

    zip_path = Path(args.source_zip).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()
    if not zip_path.exists():
        raise SystemExit(f"source zip not found: {zip_path}")

    recommended, recommended_manifest = build_bundle(zip_path, DEFAULT_GROUPS)
    all_bundle, all_manifest = build_bundle(zip_path, ALL_GROUPS)

    recommended_path = out_dir / "k12_sub2api_recommended_312.json"
    all_path = out_dir / "k12_sub2api_all_1334.json"
    manifest_path = out_dir / "k12_bundle_manifest.json"

    write_json(recommended_path, recommended, args.force)
    write_json(all_path, all_bundle, args.force)
    write_json(manifest_path, {
        "recommended": recommended_manifest,
        "all": all_manifest,
        "files": {
            "recommended": str(recommended_path),
            "all": str(all_path),
        },
    }, args.force)

    print(json.dumps({
        "recommended_accounts": len(recommended["accounts"]),
        "all_accounts": len(all_bundle["accounts"]),
        "recommended_file": str(recommended_path),
        "all_file": str(all_path),
        "manifest_file": str(manifest_path),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
