#!/usr/bin/env python3
"""Build recommended/all Sub2API bundles from explicitly named ZIP groups."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import zipfile


def load_json_entry(zip_file: zipfile.ZipFile, name: str) -> dict:
    try:
        with zip_file.open(name) as handle:
            data = json.load(handle)
    except KeyError as exc:
        raise SystemExit(f"missing entry in zip: {name}") from exc
    if not isinstance(data, dict) or not isinstance(data.get("accounts"), list):
        raise SystemExit(f"{name} does not contain an accounts list")
    return data


def account_key(account: dict) -> tuple[str, ...]:
    credentials = account.get("credentials") if isinstance(account.get("credentials"), dict) else {}
    token = str(credentials.get("access_token") or "")
    if token:
        return ("token_sha256", hashlib.sha256(token.encode("utf-8")).hexdigest())
    email = str(credentials.get("email") or account.get("email") or "").strip().lower()
    account_id = str(
        credentials.get("chatgpt_account_id") or credentials.get("account_id") or ""
    ).strip().lower()
    if email or account_id:
        return ("context", email, account_id)
    name = str(account.get("name") or "").strip().lower()
    if name:
        return ("name", name)
    rendered = json.dumps(account, sort_keys=True, ensure_ascii=True)
    return ("record_sha256", hashlib.sha256(rendered.encode("utf-8")).hexdigest())


def build_bundle(zip_path: Path, group_names: list[str]) -> tuple[dict, list[dict], int]:
    summary: list[dict] = []
    output_accounts: list[dict] = []
    seen: set[tuple[str, ...]] = set()
    duplicate_count = 0

    with zipfile.ZipFile(zip_path) as zip_file:
        for group_name in group_names:
            raw = load_json_entry(zip_file, group_name)
            accounts = raw["accounts"]
            added = 0
            duplicates = 0
            for account in accounts:
                if not isinstance(account, dict):
                    raise SystemExit(f"{group_name} contains a non-object account record")
                key = account_key(account)
                if key in seen:
                    duplicate_count += 1
                    duplicates += 1
                    continue
                seen.add(key)
                output_accounts.append(account)
                added += 1
            summary.append(
                {
                    "source": group_name,
                    "input_accounts": len(accounts),
                    "added_accounts": added,
                    "duplicates_skipped": duplicates,
                }
            )

    bundle = {
        "type": "sub2api-data",
        "version": 1,
        "exported_at": datetime.now(timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "proxies": [],
        "accounts": output_accounts,
    }
    return bundle, summary, duplicate_count


def write_json(path: Path, data: dict, force: bool) -> None:
    if path.exists() and not force:
        raise SystemExit(f"refusing to overwrite existing file without --force: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | (os.O_TRUNC if force else os.O_EXCL)
    fd = os.open(path, flags, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(data, handle, ensure_ascii=True, indent=2, sort_keys=True)
        handle.write("\n")
    os.chmod(path, 0o600)


def output_path(out_dir: Path, name: str) -> Path:
    candidate = Path(name)
    if candidate.name != name or name in {"", ".", ".."}:
        raise SystemExit("output names must be plain file names without directories")
    return out_dir / name


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Build recommended/all Sub2API bundles from explicit JSON groups in a ZIP archive."
    )
    parser.add_argument("--source-zip", required=True)
    parser.add_argument(
        "--recommended-group",
        action="append",
        required=True,
        help="ZIP JSON entry included in both recommended and all outputs; repeat as needed.",
    )
    parser.add_argument(
        "--optional-group",
        action="append",
        default=[],
        help="ZIP JSON entry included only in the all output; repeat as needed.",
    )
    parser.add_argument("--out-dir", default="data")
    parser.add_argument("--recommended-name", default="k12_sub2api_recommended.json")
    parser.add_argument("--all-name", default="k12_sub2api_all.json")
    parser.add_argument("--manifest-name", default="k12_bundle_manifest.json")
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    zip_path = Path(args.source_zip).expanduser().resolve()
    out_dir = Path(args.out_dir).expanduser().resolve()
    if not zip_path.is_file():
        raise SystemExit(f"source zip not found: {zip_path}")
    if len(set(args.recommended_group)) != len(args.recommended_group):
        raise SystemExit("duplicate --recommended-group values are not allowed")
    if set(args.recommended_group) & set(args.optional_group):
        raise SystemExit("the same group cannot be both recommended and optional")
    if len(set(args.optional_group)) != len(args.optional_group):
        raise SystemExit("duplicate --optional-group values are not allowed")

    recommended, recommended_summary, recommended_duplicates = build_bundle(
        zip_path, args.recommended_group
    )
    all_groups = args.recommended_group + args.optional_group
    all_bundle, all_summary, all_duplicates = build_bundle(zip_path, all_groups)

    recommended_path = output_path(out_dir, args.recommended_name)
    all_path = output_path(out_dir, args.all_name)
    manifest_path = output_path(out_dir, args.manifest_name)
    output_paths = [recommended_path, all_path, manifest_path]
    if len(set(output_paths)) != len(output_paths):
        raise SystemExit("recommended, all, and manifest output names must be distinct")
    existing = [str(path) for path in output_paths if path.exists()]
    if existing and not args.force:
        raise SystemExit(
            "refusing to create a partial output set; existing files require --force: "
            + ", ".join(existing)
        )
    manifest = {
        "source_zip": str(zip_path),
        "recommended": {
            "groups": recommended_summary,
            "total_accounts": len(recommended["accounts"]),
            "duplicates_skipped": recommended_duplicates,
            "output": str(recommended_path),
        },
        "all": {
            "groups": all_summary,
            "total_accounts": len(all_bundle["accounts"]),
            "duplicates_skipped": all_duplicates,
            "output": str(all_path),
        },
        "notes": [
            "Group selection was explicit; no ZIP group was inferred from its name.",
            "Do not refresh OAuth tokens unless the source policy and user authorization allow it.",
        ],
    }

    write_json(recommended_path, recommended, args.force)
    write_json(all_path, all_bundle, args.force)
    write_json(manifest_path, manifest, args.force)
    print(
        json.dumps(
            {
                "recommended_accounts": len(recommended["accounts"]),
                "all_accounts": len(all_bundle["accounts"]),
                "recommended_output": str(recommended_path),
                "all_output": str(all_path),
                "manifest": str(manifest_path),
            },
            ensure_ascii=True,
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
