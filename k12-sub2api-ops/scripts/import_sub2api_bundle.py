#!/usr/bin/env python3
import argparse
import getpass
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path


DEFAULT_TIMEOUT = 120
SECRET_KEYS = {
    "access_token", "refresh_token", "id_token", "session_token",
    "authorization", "cookie", "cookies", "bearer", "password", "passwd",
    "token", "tokens", "secret", "secrets", "api_key", "private_key",
    "credential", "credentials",
}


def is_secret_key(value):
    key = str(value).strip().lower().replace("-", "_")
    return key in SECRET_KEYS or key.endswith(("_token", "_secret", "_password", "_passwd", "_cookie", "_credential"))


def redact(value):
    if isinstance(value, dict):
        return {key: ("[REDACTED]" if is_secret_key(key) else redact(item)) for key, item in value.items()}
    if isinstance(value, list):
        return [redact(item) for item in value]
    return value


def mask_email(value):
    text = str(value or "")
    if "@" not in text:
        return text[:2] + "***" if text else ""
    local, domain = text.split("@", 1)
    return f"{local[:2]}***@{domain}"


def validate_base_url(base_url, allow_insecure_remote=False):
    parsed = urllib.parse.urlparse(base_url)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise RuntimeError("--base-url must be an absolute HTTP(S) URL")
    loopback = parsed.hostname.lower() in {"127.0.0.1", "localhost", "::1"}
    if parsed.scheme != "https" and not loopback and not allow_insecure_remote:
        raise RuntimeError("non-loopback Sub2API endpoints require HTTPS; use --allow-insecure-remote only for an explicitly authorized isolated environment")
    return loopback


def load_json(path):
    with Path(path).expanduser().open("r", encoding="utf-8") as fh:
        return json.load(fh)


def unwrap_response(payload):
    if isinstance(payload, dict) and "code" in payload:
        if payload.get("code") == 0:
            return payload.get("data")
        raise RuntimeError(f"API error code={payload.get('code')}")
    return payload


def request_json(method, base_url, path, body=None, token=None, cookie=None, extra_headers=None, timeout=DEFAULT_TIMEOUT):
    url = urllib.parse.urljoin(base_url.rstrip("/") + "/", path.lstrip("/"))
    headers = {
        "Accept": "application/json",
        "Content-Type": "application/json",
        "User-Agent": "k12-sub2api-import/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if cookie:
        headers["Cookie"] = cookie
    if extra_headers:
        headers.update(extra_headers)

    data = None
    if body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")

    req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            text = resp.read().decode("utf-8", errors="replace")
            if not text.strip():
                return None
            return unwrap_response(json.loads(text))
    except urllib.error.HTTPError as exc:
        raise RuntimeError(f"HTTP {exc.code} during {method} {urllib.parse.urlparse(url).path}") from exc


def login(base_url, login_name, password, timeout):
    attempts = []
    if "@" in login_name:
        attempts.append({"email": login_name, "password": password})
    attempts.append({"username": login_name, "password": password})
    attempts.append({"account": login_name, "password": password})

    last_error = None
    for payload in attempts:
        try:
            data = request_json("POST", base_url, "/auth/login", payload, timeout=timeout)
            token = data.get("access_token") if isinstance(data, dict) else None
            if token:
                return token
            last_error = RuntimeError("login response did not include access_token")
        except Exception as exc:
            last_error = exc
    raise RuntimeError("login failed") from last_error


def account_identity(account):
    credentials = account.get("credentials") or {}
    return {
        "name": account.get("name"),
        "email": mask_email(credentials.get("email") or account.get("email")),
        "raw_email": credentials.get("email") or account.get("email"),
        "chatgpt_account_id": credentials.get("chatgpt_account_id") or credentials.get("account_id") or account.get("account_id"),
        "platform": account.get("platform"),
        "type": account.get("type"),
    }


def identity_key(identity):
    # Many K12 accounts can share one chatgpt_account_id because they are joined
    # to the same workspace. Treat email/name as the duplicate boundary first.
    email = str(identity.get("raw_email") or "").strip().lower()
    account_id = str(identity.get("chatgpt_account_id") or "").strip().lower()
    name = str(identity.get("name") or "").strip().lower()
    if email or account_id:
        return (email, account_id)
    return ("name", name) if name else None


def summarize_bundle(bundle):
    accounts = bundle.get("accounts")
    if not isinstance(accounts, list):
        raise RuntimeError("bundle must contain an accounts list")
    identities = [account_identity(account) for account in accounts]
    platforms = {}
    plan_types = {}
    missing_tokens = 0
    for account in accounts:
        credentials = account.get("credentials") or {}
        platforms[account.get("platform", "unknown")] = platforms.get(account.get("platform", "unknown"), 0) + 1
        plan = credentials.get("plan_type") or "unknown"
        plan_types[plan] = plan_types.get(plan, 0) + 1
        if not credentials.get("access_token"):
            missing_tokens += 1
    return {
        "accounts": len(accounts),
        "platforms": platforms,
        "plan_types": plan_types,
        "missing_access_token": missing_tokens,
        "sample_identities": [{key: value for key, value in identity.items() if key != "raw_email"} for identity in identities[:5]],
    }


def validate_accounts_for_execute(bundle):
    errors = []
    for index, account in enumerate(bundle.get("accounts") or []):
        credentials = account.get("credentials") or {}
        if account.get("platform") != "openai":
            errors.append(f"account[{index}].platform must be openai")
        if account.get("type") != "oauth":
            errors.append(f"account[{index}].type must be oauth")
        if str(credentials.get("plan_type") or "").lower() != "k12":
            errors.append(f"account[{index}].credentials.plan_type must be k12")
        if not credentials.get("access_token"):
            errors.append(f"account[{index}].credentials.access_token is required")
    if errors:
        preview = "; ".join(errors[:10])
        raise RuntimeError(f"execute validation failed ({len(errors)} errors): {preview}")


def fetch_existing_keys(base_url, token, cookie, timeout):
    data = request_json(
        "GET",
        base_url,
        "/admin/accounts/data?include_proxies=false",
        token=token,
        cookie=cookie,
        timeout=timeout,
    )
    accounts = []
    if isinstance(data, dict):
        accounts = data.get("accounts") or data.get("data", {}).get("accounts") or []
    if not isinstance(accounts, list):
        return set(), 0
    keys = set()
    for account in accounts:
        key = identity_key(account_identity(account))
        if key:
            keys.add(key)
    return keys, len(accounts)


def filter_existing(bundle, existing_keys):
    filtered = []
    skipped = 0
    for account in bundle["accounts"]:
        key = identity_key(account_identity(account))
        if key and key in existing_keys:
            skipped += 1
            continue
        filtered.append(account)
    new_bundle = dict(bundle)
    new_bundle["accounts"] = filtered
    return new_bundle, skipped


def parse_headers(items):
    headers = {}
    for item in items or []:
        if ":" not in item:
            raise RuntimeError(f"bad header format, expected 'Name: value': {item}")
        name, value = item.split(":", 1)
        headers[name.strip()] = value.strip()
    return headers


def main():
    parser = argparse.ArgumentParser(description="Import a K12 sub2api bundle into a Sub2API server.")
    parser.add_argument("--base-url", default=os.getenv("SUB2API_BASE_URL", "http://127.0.0.1:3000"))
    parser.add_argument("--bundle", default="data/k12_sub2api_recommended_312.json")
    parser.add_argument("--execute", action="store_true", help="Actually POST the bundle. Without this, only preview.")
    parser.add_argument("--skip-existing", action="store_true", help="Fetch existing accounts and skip duplicates before import.")
    parser.add_argument("--skip-default-group-bind", action="store_true")
    parser.add_argument("--max-accounts", type=int, default=0, help="Import only the first N accounts after filtering.")
    parser.add_argument("--shuffle", action="store_true", help="Shuffle accounts before applying --max-accounts.")
    parser.add_argument("--shuffle-seed", type=int, default=0, help="Seed used with --shuffle. Defaults to the current time.")
    parser.add_argument("--bearer", default=os.getenv("SUB2API_AUTH_TOKEN", ""))
    parser.add_argument("--cookie", default=os.getenv("SUB2API_COOKIE", ""))
    parser.add_argument("--login", default=os.getenv("SUB2API_LOGIN", ""))
    parser.add_argument("--password", default=os.getenv("SUB2API_PASSWORD", ""))
    parser.add_argument("--header", action="append", default=[])
    parser.add_argument("--timeout", type=int, default=DEFAULT_TIMEOUT)
    parser.add_argument("--environment", choices=["local", "development", "test", "preproduction", "production"], default="")
    parser.add_argument("--confirm-write", action="store_true", help="Confirm the scoped account import and its rollback plan.")
    parser.add_argument("--allow-insecure-remote", action="store_true", help="Allow HTTP to a non-loopback host only in an explicitly authorized isolated environment.")
    args = parser.parse_args()

    bundle_path = Path(args.bundle).expanduser().resolve()
    bundle = load_json(bundle_path)
    summary = summarize_bundle(bundle)

    loopback = validate_base_url(args.base_url, args.allow_insecure_remote)
    print(json.dumps(redact({
        "mode": "execute" if args.execute else "preview",
        "base_url": args.base_url,
        "bundle": str(bundle_path),
        "summary": summary,
    }), ensure_ascii=False, indent=2))

    if args.execute:
        if not args.environment:
            raise SystemExit("--execute requires --environment")
        if args.environment in {"production", "preproduction"}:
            raise SystemExit("direct import to production/preproduction is prohibited; use the approved deployment process")
        if not loopback and args.environment == "local":
            raise SystemExit("--environment local requires a loopback base URL")
        if not args.confirm_write:
            raise SystemExit("--execute requires --confirm-write after confirming scope, rollback, and post-import verification")
        validate_accounts_for_execute(bundle)

    token = args.bearer.strip()
    cookie = args.cookie.strip()
    if args.execute and not token and not cookie and args.login:
        password = args.password or getpass.getpass("Sub2API password: ")
        token = login(args.base_url, args.login, password, args.timeout)
        print("login: ok")

    if args.skip_existing and not args.execute:
        raise SystemExit("preview is local-only; authenticated reconciliation requires --execute and explicit authorization")
    if args.skip_existing:
        if not token and not cookie:
            raise SystemExit("--skip-existing requires --bearer, --cookie, or --login")
        existing_keys, existing_count = fetch_existing_keys(args.base_url, token, cookie, args.timeout)
        bundle, skipped = filter_existing(bundle, existing_keys)
        print(json.dumps({
            "existing_accounts_seen": existing_count,
            "existing_identity_keys": len(existing_keys),
            "skipped_existing": skipped,
            "remaining_accounts": len(bundle["accounts"]),
        }, ensure_ascii=False, indent=2))

    if args.shuffle:
        seed = args.shuffle_seed or int(time.time())
        shuffled = dict(bundle)
        shuffled["accounts"] = list(bundle["accounts"])
        random.Random(seed).shuffle(shuffled["accounts"])
        bundle = shuffled
        print(json.dumps({
            "shuffled": True,
            "shuffle_seed": seed,
        }, ensure_ascii=False, indent=2))

    if args.max_accounts and args.max_accounts > 0:
        bundle = dict(bundle)
        bundle["accounts"] = bundle["accounts"][:args.max_accounts]
        print(f"limited import to first {len(bundle['accounts'])} accounts")

    if not args.execute:
        print("preview only: add --execute to import")
        return

    if not token and not cookie:
        raise SystemExit("missing auth: set SUB2API_AUTH_TOKEN, SUB2API_COOKIE, or SUB2API_LOGIN/SUB2API_PASSWORD")

    if not bundle["accounts"]:
        print("nothing to import")
        return

    payload = {
        "data": bundle,
        "skip_default_group_bind": bool(args.skip_default_group_bind),
    }
    started = time.time()
    result = request_json(
        "POST",
        args.base_url,
        "/admin/accounts/data",
        payload,
        token=token,
        cookie=cookie,
        extra_headers=parse_headers(args.header),
        timeout=args.timeout,
    )
    elapsed = round(time.time() - started, 2)
    safe_result = redact(result)
    print(json.dumps({
        "imported_requested_accounts": len(bundle["accounts"]),
        "elapsed_seconds": elapsed,
        "result": safe_result,
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        sys.exit(1)
