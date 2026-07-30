#!/usr/bin/env python3
"""Recover passive Grok 402 spending-limit accounts by rotating Resin leases."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import ipaddress
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


STATE_VERSION = 1
MAX_RESPONSE_BYTES = 2 * 1024 * 1024
SPENDING_RETRY_MIN = 86_000
SPENDING_RETRY_MAX = 86_800
SPENDING_MARKERS = (
    "personal-team-blocked:spending-limit",
    "subscription:free-usage-exhausted",
    "included free usage",
    "rolling 24-hour window",
    "run out of credits",
    "need a grok subscription",
)
RESIN_ACCOUNT_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")
HttpDo = Callable[[str, str, Mapping[str, str], bytes | None, float], tuple[int, Mapping[str, str], bytes]]


class RecoveryError(RuntimeError):
    pass


@dataclass(frozen=True)
class Candidate:
    account_id: int
    proxy_id: int
    resin_account: str
    snapshot_updated_at: str


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def isoformat(value: dt.datetime) -> str:
    return value.astimezone(dt.timezone.utc).isoformat()


def parse_timestamp(value: Any) -> dt.datetime | None:
    if not value:
        return None
    try:
        parsed = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def as_int(value: Any) -> int | None:
    if isinstance(value, bool):
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def safe_error(exc: BaseException) -> str:
    if isinstance(exc, RecoveryError):
        return str(exc)
    return exc.__class__.__name__


def validate_base_url(raw: str, *, loopback_only: bool) -> str:
    value = raw.strip().rstrip("/")
    parsed = urllib.parse.urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.hostname:
        raise RecoveryError("invalid API base URL")
    if parsed.username or parsed.password or parsed.path not in {"", "/"} or parsed.query or parsed.fragment:
        raise RecoveryError("API base URL must not contain credentials, paths, or query parameters")
    hostname = parsed.hostname
    if hostname == "localhost":
        address = ipaddress.ip_address("127.0.0.1")
    else:
        try:
            address = ipaddress.ip_address(hostname)
        except ValueError as exc:
            raise RecoveryError("API base URL must use a literal IP or localhost") from exc
    if loopback_only and not address.is_loopback:
        raise RecoveryError("Sub2API base URL must be loopback-only")
    if not loopback_only and not (address.is_loopback or address.is_private):
        raise RecoveryError("Resin base URL must use a private or loopback address")
    return value


def read_secret(path: Path) -> str:
    if not path.is_file() or path.stat().st_mode & 0o077:
        raise RecoveryError("credential file must exist and not be group/world accessible")
    value = path.read_text(encoding="utf-8").strip()
    if not value:
        raise RecoveryError("credential file is empty")
    return value


def canonical_json(value: Mapping[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True).encode("utf-8")


def atomic_write_json(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    temp = path.with_name(path.name + f".tmp-{os.getpid()}")
    data = json.dumps(value, ensure_ascii=True, indent=2, sort_keys=True) + "\n"
    with temp.open("x", encoding="utf-8") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temp, 0o600)
    os.replace(temp, path)


def append_event(path: Path, value: Mapping[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(value, ensure_ascii=True, separators=(",", ":"), sort_keys=True) + "\n")
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(path, 0o600)


def default_http_do(
    method: str,
    url: str,
    headers: Mapping[str, str],
    body: bytes | None,
    timeout: float,
) -> tuple[int, Mapping[str, str], bytes]:
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    request = urllib.request.Request(url, data=body, headers=dict(headers), method=method)
    try:
        with opener.open(request, timeout=timeout) as response:
            return int(response.status), dict(response.headers), response.read(MAX_RESPONSE_BYTES)
    except urllib.error.HTTPError as exc:
        return int(exc.code or 0), dict(exc.headers or {}), exc.read(MAX_RESPONSE_BYTES)
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        raise RecoveryError("API network request failed") from exc


class Sub2Client:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        timeout: float,
        http_do: HttpDo = default_http_do,
    ) -> None:
        self.base_url = validate_base_url(base_url, loopback_only=True)
        self.api_key = api_key
        self.timeout = timeout
        self.http_do = http_do

    def _request_raw(
        self,
        method: str,
        path: str,
        *,
        query: Mapping[str, Any] | None = None,
        body: Mapping[str, Any] | None = None,
    ) -> tuple[int, Mapping[str, str], bytes]:
        method = method.upper()
        allowed = (
            (method == "GET" and path == "/api/v1/admin/accounts")
            or (method == "GET" and re.fullmatch(r"/api/v1/admin/accounts/[1-9][0-9]*", path) is not None)
            or (method == "POST" and re.fullmatch(r"/api/v1/admin/accounts/[1-9][0-9]*/test", path) is not None)
            or (
                method == "POST"
                and re.fullmatch(r"/api/v1/admin/accounts/[1-9][0-9]*/clear-rate-limit", path) is not None
            )
        )
        if not allowed:
            raise RecoveryError("refusing unexpected Sub2API method or endpoint")
        url = self.base_url + path
        if query:
            url += "?" + urllib.parse.urlencode([(key, str(value)) for key, value in query.items() if value is not None])
        payload = canonical_json(body) if body is not None else (b"" if method.upper() == "POST" else None)
        headers = {"Accept": "application/json", "x-api-key": self.api_key}
        if body is not None:
            headers["Content-Type"] = "application/json"
        return self.http_do(method, url, headers, payload, self.timeout)

    def request_json(
        self,
        method: str,
        path: str,
        *,
        query: Mapping[str, Any] | None = None,
        body: Mapping[str, Any] | None = None,
    ) -> Any:
        status, _, raw = self._request_raw(method, path, query=query, body=body)
        if status >= 400:
            raise RecoveryError(f"Sub2API HTTP {status} for {method.upper()} {path}")
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError as exc:
            raise RecoveryError("Sub2API returned invalid JSON") from exc
        if not isinstance(payload, dict) or payload.get("code") not in (None, 0, "0"):
            raise RecoveryError("Sub2API rejected the request")
        return payload.get("data", payload)

    def iter_accounts(self, group_id: int) -> list[dict[str, Any]]:
        page = 1
        items: list[dict[str, Any]] = []
        seen: set[int] = set()
        total: int | None = None
        while True:
            data = self.request_json(
                "GET",
                "/api/v1/admin/accounts",
                query={
                    "page": page,
                    "page_size": 1000,
                    "platform": "grok",
                    "type": "oauth",
                    "group": group_id,
                    "sort_by": "id",
                    "sort_order": "asc",
                },
            )
            if not isinstance(data, dict) or not isinstance(data.get("items"), list):
                raise RecoveryError("Sub2API accounts list has an invalid shape")
            batch = data["items"]
            if total is None:
                total = as_int(data.get("total"))
            for item in batch:
                if not isinstance(item, dict):
                    raise RecoveryError("Sub2API account item has an invalid shape")
                account_id = as_int(item.get("id"))
                if account_id is None or account_id in seen:
                    raise RecoveryError("Sub2API accounts pagination is inconsistent")
                seen.add(account_id)
                items.append(item)
            if not batch or (total is not None and len(items) >= total):
                break
            page += 1
            if page > 1000:
                raise RecoveryError("Sub2API accounts pagination guard exceeded")
        return items

    def get_account(self, account_id: int) -> dict[str, Any]:
        data = self.request_json("GET", f"/api/v1/admin/accounts/{account_id}")
        if not isinstance(data, dict):
            raise RecoveryError("Sub2API account detail has an invalid shape")
        return data

    def test_account(self, account_id: int) -> tuple[bool, str, list[str]]:
        status, _, raw = self._request_raw(
            "POST",
            f"/api/v1/admin/accounts/{account_id}/test",
            body={"model_id": "grok-4.5", "mode": "responses"},
        )
        event_types: set[str] = set()
        success = False
        classification = "test_failed"
        text = raw.decode("utf-8", "replace")
        for line in text.splitlines():
            if not line.startswith("data:"):
                continue
            encoded = line[5:].strip()
            if not encoded or encoded == "[DONE]":
                continue
            try:
                event = json.loads(encoded)
            except json.JSONDecodeError:
                continue
            if not isinstance(event, dict):
                continue
            event_type = str(event.get("type") or "")
            if event_type:
                event_types.add(event_type)
            if event_type == "test_complete" and event.get("success") is True:
                success = True
                classification = "test_complete"
            error_value = event.get("error")
            if isinstance(error_value, dict):
                error_text = " ".join(str(error_value.get(key) or "") for key in ("type", "code", "message"))
            else:
                error_text = str(error_value or event.get("message") or "")
            normalized = error_text.lower()
            if any(marker in normalized for marker in SPENDING_MARKERS):
                classification = "spending_limit"
            elif "429" in normalized or "rate limit" in normalized or "too many requests" in normalized:
                classification = "rate_limited"
            elif event_type == "error" and classification == "test_failed":
                classification = "upstream_error"
        if status != 200:
            classification = f"http_{status}"
        return status == 200 and success, classification, sorted(event_types)

    def clear_rate_limit(self, account_id: int) -> dict[str, Any]:
        data = self.request_json("POST", f"/api/v1/admin/accounts/{account_id}/clear-rate-limit")
        if not isinstance(data, dict):
            raise RecoveryError("clear-rate-limit returned an invalid shape")
        return data


class ResinClient:
    def __init__(
        self,
        base_url: str,
        token: str,
        timeout: float,
        http_do: HttpDo = default_http_do,
    ) -> None:
        self.base_url = validate_base_url(base_url, loopback_only=False)
        self.token = token
        self.timeout = timeout
        self.http_do = http_do

    def _request(self, method: str, path: str) -> tuple[int, bytes]:
        method = method.upper()
        parts = path.split("/")
        valid_platform = len(parts) == 5 and parts[1:4] == ["api", "v1", "platforms"]
        valid_lease = len(parts) == 7 and parts[1:4] == ["api", "v1", "platforms"] and parts[5] == "leases"
        if not ((valid_platform and method == "GET") or (valid_lease and method in {"GET", "DELETE"})):
            raise RecoveryError("refusing unexpected Resin method or endpoint")
        headers = {"Accept": "application/json", "Authorization": f"Bearer {self.token}"}
        status, _, raw = self.http_do(method, self.base_url + path, headers, None, self.timeout)
        return status, raw

    def verify_platform(self, platform_id: str, expected_name: str) -> None:
        status, raw = self._request("GET", f"/api/v1/platforms/{urllib.parse.quote(platform_id, safe='')}")
        if status != 200:
            raise RecoveryError(f"Resin platform lookup failed with HTTP {status}")
        try:
            data = json.loads(raw)
        except json.JSONDecodeError as exc:
            raise RecoveryError("Resin platform response is invalid JSON") from exc
        if not isinstance(data, dict) or data.get("id") != platform_id or data.get("name") != expected_name:
            raise RecoveryError("Resin platform identity mismatch")

    def get_lease(self, platform_id: str, account: str) -> bool:
        path = "/api/v1/platforms/{}/leases/{}".format(
            urllib.parse.quote(platform_id, safe=""), urllib.parse.quote(account, safe="")
        )
        status, _ = self._request("GET", path)
        if status == 200:
            return True
        if status == 404:
            return False
        raise RecoveryError(f"Resin lease lookup failed with HTTP {status}")

    def delete_lease(self, platform_id: str, account: str) -> str:
        path = "/api/v1/platforms/{}/leases/{}".format(
            urllib.parse.quote(platform_id, safe=""), urllib.parse.quote(account, safe="")
        )
        status, _ = self._request("DELETE", path)
        if status == 204:
            return "deleted"
        if status == 404:
            return "absent"
        raise RecoveryError(f"Resin lease delete failed with HTTP {status}")


def usage_snapshot(account: Mapping[str, Any]) -> Mapping[str, Any]:
    extra = account.get("extra")
    if not isinstance(extra, Mapping):
        return {}
    usage = extra.get("grok_usage_snapshot")
    return usage if isinstance(usage, Mapping) else {}


def parse_resin_username(username: Any, expected_platform: str) -> str:
    value = str(username or "")
    platform, separator, account = value.partition(".")
    if separator != "." or platform != expected_platform or not RESIN_ACCOUNT_RE.fullmatch(account):
        raise RecoveryError("proxy username is not an expected Resin Platform.Account identity")
    return account


def classify_candidate(
    account: Mapping[str, Any],
    *,
    group_id: int,
    resin_platform_name: str,
    expected_proxy_host: str,
    expected_proxy_port: int,
    expected_proxy_protocol: str,
) -> tuple[Candidate | None, str]:
    snapshot = usage_snapshot(account)
    snapshot_status = as_int(snapshot.get("status_code"))
    if snapshot_status == 429:
        return None, "snapshot_429"
    if snapshot_status != 402:
        return None, "snapshot_not_402"
    if account.get("platform") != "grok" or account.get("type") != "oauth":
        return None, "not_grok_oauth"
    if account.get("status") != "active" or account.get("schedulable") is not True:
        return None, "not_active_schedulable"
    if account.get("parent_account_id") not in (None, 0):
        return None, "child_account"
    groups = sorted(value for value in (as_int(item) for item in account.get("group_ids") or []) if value is not None)
    if groups != [group_id]:
        return None, "group_mismatch"
    account_id = as_int(account.get("id"))
    proxy_id = as_int(account.get("proxy_id"))
    if account_id is None or account_id < 1 or proxy_id is None or proxy_id < 1:
        return None, "missing_identity_or_proxy"
    proxy = account.get("proxy")
    if not isinstance(proxy, Mapping):
        return None, "missing_proxy_detail"
    if proxy.get("status") != "active":
        return None, "proxy_inactive"
    if str(proxy.get("host") or "") != expected_proxy_host:
        return None, "proxy_host_mismatch"
    if as_int(proxy.get("port")) != expected_proxy_port:
        return None, "proxy_port_mismatch"
    if str(proxy.get("protocol") or "").lower() != expected_proxy_protocol.lower():
        return None, "proxy_protocol_mismatch"
    try:
        resin_account = parse_resin_username(proxy.get("username"), resin_platform_name)
    except RecoveryError:
        return None, "proxy_username_mismatch"
    retry_after = as_int(snapshot.get("retry_after_seconds"))
    evidence = " ".join(
        (
            str(account.get("error_message") or ""),
            str(account.get("temp_unschedulable_reason") or ""),
            json.dumps(snapshot, ensure_ascii=True, sort_keys=True),
        )
    ).lower()
    has_spending_marker = any(marker in evidence for marker in SPENDING_MARKERS)
    if not (retry_after is not None and SPENDING_RETRY_MIN <= retry_after <= SPENDING_RETRY_MAX) and not has_spending_marker:
        return None, "not_spending_limit"
    return (
        Candidate(
            account_id=account_id,
            proxy_id=proxy_id,
            resin_account=resin_account,
            snapshot_updated_at=str(snapshot.get("updated_at") or ""),
        ),
        "candidate",
    )


def new_state() -> dict[str, Any]:
    return {
        "version": STATE_VERSION,
        "backoff_until": None,
        "consecutive_failures": 0,
        "accounts": {},
    }


def load_state(path: Path) -> dict[str, Any]:
    if not path.exists():
        return new_state()
    if not path.is_file() or path.stat().st_mode & 0o077:
        raise RecoveryError("state file must be private")
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise RecoveryError("state file is invalid") from exc
    if not isinstance(value, dict) or value.get("version") != STATE_VERSION or not isinstance(value.get("accounts"), dict):
        raise RecoveryError("state file schema is invalid")
    return value


def test_budget_ready(state: Mapping[str, Any], account_id: int, now: dt.datetime, interval: dt.timedelta) -> bool:
    accounts = state.get("accounts")
    item = accounts.get(str(account_id), {}) if isinstance(accounts, Mapping) else {}
    last_test = parse_timestamp(item.get("last_test_at")) if isinstance(item, Mapping) else None
    return last_test is None or now - last_test >= interval


def proxy_invariant(account: Mapping[str, Any], candidate: Candidate, group_id: int) -> bool:
    groups = sorted(value for value in (as_int(item) for item in account.get("group_ids") or []) if value is not None)
    return (
        as_int(account.get("id")) == candidate.account_id
        and as_int(account.get("proxy_id")) == candidate.proxy_id
        and groups == [group_id]
        and account.get("status") == "active"
        and account.get("schedulable") is True
    )


def run_once(
    *,
    sub2: Sub2Client,
    resin: ResinClient,
    state: dict[str, Any],
    state_file: Path | None,
    events_file: Path | None,
    apply: bool,
    now: dt.datetime,
    group_id: int,
    resin_platform_id: str,
    resin_platform_name: str,
    expected_proxy_host: str,
    expected_proxy_port: int,
    expected_proxy_protocol: str,
    test_interval: dt.timedelta,
    global_backoff: dt.timedelta,
    max_accounts: int,
) -> dict[str, Any]:
    accounts = sub2.iter_accounts(group_id)
    reasons: dict[str, int] = {}
    candidates: list[Candidate] = []
    for account in accounts:
        candidate, reason = classify_candidate(
            account,
            group_id=group_id,
            resin_platform_name=resin_platform_name,
            expected_proxy_host=expected_proxy_host,
            expected_proxy_port=expected_proxy_port,
            expected_proxy_protocol=expected_proxy_protocol,
        )
        reasons[reason] = reasons.get(reason, 0) + 1
        if candidate is not None:
            candidates.append(candidate)
    candidates.sort(key=lambda item: item.account_id)
    ready = [item for item in candidates if test_budget_ready(state, item.account_id, now, test_interval)]
    backoff_until = parse_timestamp(state.get("backoff_until"))
    summary: dict[str, Any] = {
        "status": "dry_run" if not apply else "completed",
        "scanned": len(accounts),
        "candidate_count": len(candidates),
        "ready_count": len(ready),
        "skipped_429": reasons.get("snapshot_429", 0),
        "processed": 0,
        "recovered": 0,
        "failed": 0,
        "backoff_active": bool(backoff_until and backoff_until > now),
    }
    if not apply:
        return summary
    state["last_run_at"] = isoformat(now)
    if backoff_until and backoff_until > now:
        summary["status"] = "backoff"
        if state_file is not None:
            atomic_write_json(state_file, state)
        return summary
    if not ready:
        summary["status"] = "no_candidates" if not candidates else "test_budget_exhausted"
        if state_file is not None:
            atomic_write_json(state_file, state)
        return summary

    resin.verify_platform(resin_platform_id, resin_platform_name)
    for frozen in ready[:max_accounts]:
        detail = sub2.get_account(frozen.account_id)
        live, reason = classify_candidate(
            detail,
            group_id=group_id,
            resin_platform_name=resin_platform_name,
            expected_proxy_host=expected_proxy_host,
            expected_proxy_port=expected_proxy_port,
            expected_proxy_protocol=expected_proxy_protocol,
        )
        if live != frozen:
            event = {
                "at": isoformat(now),
                "account_id": frozen.account_id,
                "status": "skipped_revalidation",
                "reason": reason,
            }
            if events_file is not None:
                append_event(events_file, event)
            continue
        summary["processed"] += 1
        account_state = state["accounts"].setdefault(str(frozen.account_id), {})
        test_succeeded = False
        explicit_clear_completed = False
        try:
            lease_existed = resin.get_lease(resin_platform_id, frozen.resin_account)
            lease_result = resin.delete_lease(resin_platform_id, frozen.resin_account) if lease_existed else "absent"
            account_state.update(
                {
                    "proxy_id": frozen.proxy_id,
                    "resin_account": frozen.resin_account,
                    "last_lease_delete_at": isoformat(now),
                    "last_lease_delete_result": lease_result,
                    "last_test_at": isoformat(now),
                    "last_test_result": "started",
                }
            )
            if state_file is not None:
                atomic_write_json(state_file, state)
            test_ok, test_result, event_types = sub2.test_account(frozen.account_id)
            account_state["last_test_result"] = test_result
            if not test_ok:
                final = sub2.get_account(frozen.account_id)
                if not proxy_invariant(final, frozen, group_id):
                    raise RecoveryError("account proxy/group invariant changed after failed test")
                raise RecoveryError("specified account test did not complete")
            test_succeeded = True
            sub2.clear_rate_limit(frozen.account_id)
            explicit_clear_completed = True
            final = sub2.get_account(frozen.account_id)
            if not proxy_invariant(final, frozen, group_id):
                raise RecoveryError("account proxy/group invariant changed after recovery")
            final_status = as_int(usage_snapshot(final).get("status_code"))
            if final_status != 200 or final.get("rate_limit_reset_at") is not None:
                raise RecoveryError("recovered account final state is not healthy")
            account_state.update(
                {
                    "last_test_result": "recovered",
                    "last_clear_rate_limit_at": isoformat(now),
                }
            )
            state["backoff_until"] = None
            state["consecutive_failures"] = 0
            summary["recovered"] += 1
            event = {
                "at": isoformat(now),
                "account_id": frozen.account_id,
                "status": "recovered",
                "lease": lease_result,
                "event_types": event_types,
            }
            if events_file is not None:
                append_event(events_file, event)
            if state_file is not None:
                atomic_write_json(state_file, state)
        except Exception as exc:
            failure_status = "failed_keep_cooldown" if not test_succeeded else "failed_after_successful_test"
            account_state["last_test_result"] = failure_status
            account_state["explicit_clear_completed"] = explicit_clear_completed
            account_state["last_error"] = safe_error(exc)
            state["consecutive_failures"] = int(state.get("consecutive_failures") or 0) + 1
            state["last_failure_at"] = isoformat(now)
            state["backoff_until"] = isoformat(now + global_backoff)
            summary["failed"] += 1
            summary["status"] = "backoff_after_failure"
            event = {
                "at": isoformat(now),
                "account_id": frozen.account_id,
                "status": failure_status,
                "error": safe_error(exc),
            }
            if events_file is not None:
                append_event(events_file, event)
            if state_file is not None:
                atomic_write_json(state_file, state)
            break
    return summary


@contextlib.contextmanager
def exclusive_lock(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
    with path.open("a+", encoding="utf-8") as handle:
        try:
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise RecoveryError("another recovery run is active") from exc
        yield


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("scan", "run"))
    parser.add_argument("--sub2-base-url", default="http://127.0.0.1:13080")
    parser.add_argument("--sub2-admin-key-file", required=True)
    parser.add_argument("--resin-base-url", default="http://172.17.0.1:10833")
    parser.add_argument("--resin-admin-token-file", required=True)
    parser.add_argument("--resin-platform-id", required=True)
    parser.add_argument("--resin-platform-name", default="GrokEU")
    parser.add_argument("--group-id", type=int, default=5)
    parser.add_argument("--expected-proxy-host", default="172.17.0.1")
    parser.add_argument("--expected-proxy-port", type=int, default=10833)
    parser.add_argument("--expected-proxy-protocol", default="socks5h")
    parser.add_argument("--state-file", default="/var/lib/grok-402-lease-recovery/state.json")
    parser.add_argument("--events-file", default="/var/lib/grok-402-lease-recovery/events.jsonl")
    parser.add_argument("--lock-file", default="/run/lock/grok-402-lease-recovery.lock")
    parser.add_argument("--test-interval-hours", type=float, default=24.0)
    parser.add_argument("--global-backoff-minutes", type=float, default=30.0)
    parser.add_argument("--max-accounts", type=int, default=5)
    parser.add_argument("--timeout", type=float, default=90.0)
    parser.add_argument("--confirm-production-write", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if args.group_id < 1 or args.max_accounts < 1 or args.max_accounts > 100:
        raise RecoveryError("invalid group or max-accounts setting")
    if args.test_interval_hours < 1 or args.global_backoff_minutes < 1 or args.timeout <= 0:
        raise RecoveryError("invalid interval, backoff, or timeout setting")
    try:
        uuid.UUID(args.resin_platform_id)
    except ValueError as exc:
        raise RecoveryError("invalid Resin platform UUID") from exc
    apply = args.command == "run"
    if apply and not args.confirm_production_write:
        raise RecoveryError("run requires --confirm-production-write")
    sub2_key = read_secret(Path(args.sub2_admin_key_file))
    resin_token = read_secret(Path(args.resin_admin_token_file))
    sub2 = Sub2Client(args.sub2_base_url, sub2_key, args.timeout)
    resin = ResinClient(args.resin_base_url, resin_token, args.timeout)
    state_file = Path(args.state_file).resolve()
    events_file = Path(args.events_file).resolve()
    state = load_state(state_file) if apply else new_state()
    with exclusive_lock(Path(args.lock_file).resolve()):
        summary = run_once(
            sub2=sub2,
            resin=resin,
            state=state,
            state_file=state_file if apply else None,
            events_file=events_file if apply else None,
            apply=apply,
            now=utc_now(),
            group_id=args.group_id,
            resin_platform_id=args.resin_platform_id,
            resin_platform_name=args.resin_platform_name,
            expected_proxy_host=args.expected_proxy_host,
            expected_proxy_port=args.expected_proxy_port,
            expected_proxy_protocol=args.expected_proxy_protocol,
            test_interval=dt.timedelta(hours=args.test_interval_hours),
            global_backoff=dt.timedelta(minutes=args.global_backoff_minutes),
            max_accounts=args.max_accounts,
        )
    print(json.dumps(summary, ensure_ascii=True, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RecoveryError, OSError, ValueError) as exc:
        print(json.dumps({"status": "error", "error": safe_error(exc)}, ensure_ascii=True, sort_keys=True), file=sys.stderr)
        raise SystemExit(2)
