from __future__ import annotations

import datetime as dt
import importlib.util
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "recover_402_resin_lease.py"
SPEC = importlib.util.spec_from_file_location("recover_402_resin_lease", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def account(status_code: int = 402, retry_after: int | None = 86400, account_id: int = 1) -> dict[str, Any]:
    snapshot: dict[str, Any] = {
        "status_code": status_code,
        "updated_at": "2026-07-30T12:00:00Z",
    }
    if retry_after is not None:
        snapshot["retry_after_seconds"] = retry_after
    return {
        "id": account_id,
        "platform": "grok",
        "type": "oauth",
        "status": "active",
        "schedulable": True,
        "parent_account_id": None,
        "group_ids": [5],
        "proxy_id": 13,
        "proxy": {
            "id": 13,
            "status": "active",
            "host": "172.17.0.1",
            "port": 10833,
            "protocol": "socks5h",
            "username": "GrokEU.shard-01",
        },
        "extra": {"grok_usage_snapshot": snapshot},
        "rate_limit_reset_at": "2026-07-31T12:00:00Z",
    }


def classify(value: dict[str, Any]):
    return MODULE.classify_candidate(
        value,
        group_id=5,
        resin_platform_name="GrokEU",
        expected_proxy_host="172.17.0.1",
        expected_proxy_port=10833,
        expected_proxy_protocol="socks5h",
    )


class FakeSub2:
    def __init__(self, before: list[dict[str, Any]], after: dict[int, dict[str, Any]], test_ok: bool = True):
        self.before = before
        self.after = after
        self.test_ok = test_ok
        self.calls: list[tuple[str, int | None]] = []

    def iter_accounts(self, group_id: int):
        self.calls.append(("iter", group_id))
        return self.before

    def get_account(self, account_id: int):
        self.calls.append(("get", account_id))
        return self.after[account_id]

    def test_account(self, account_id: int):
        self.calls.append(("test", account_id))
        if self.test_ok:
            healthy = dict(self.after[account_id])
            healthy["extra"] = {"grok_usage_snapshot": {"status_code": 200}}
            healthy["rate_limit_reset_at"] = None
            self.after[account_id] = healthy
            return True, "test_complete", ["content", "test_complete"]
        return False, "spending_limit", ["error"]

    def clear_rate_limit(self, account_id: int):
        self.calls.append(("clear", account_id))
        return self.after[account_id]


class FakeResin:
    def __init__(self):
        self.calls: list[tuple[str, str]] = []

    def verify_platform(self, platform_id: str, name: str):
        self.calls.append(("platform", name))

    def get_lease(self, platform_id: str, account_name: str):
        self.calls.append(("get_lease", account_name))
        return True

    def delete_lease(self, platform_id: str, account_name: str):
        self.calls.append(("delete_lease", account_name))
        return "deleted"


class RecoveryTests(unittest.TestCase):
    def test_sub2_client_refuses_all_unexpected_mutations(self):
        calls = []

        def http_do(*args):
            calls.append(args)
            return 200, {}, b'{"code":0,"data":{}}'

        client = MODULE.Sub2Client("http://127.0.0.1:13080", "key", 1, http_do=http_do)
        for method, path in (
            ("PUT", "/api/v1/admin/accounts/1"),
            ("DELETE", "/api/v1/admin/accounts/1"),
            ("POST", "/api/v1/admin/accounts/1/schedulable"),
        ):
            with self.assertRaises(MODULE.RecoveryError):
                client.request_json(method, path)
        self.assertEqual(calls, [])

    def test_resin_client_refuses_platform_delete(self):
        calls = []

        def http_do(*args):
            calls.append(args)
            return 204, {}, b""

        client = MODULE.ResinClient("http://172.17.0.1:10833", "token", 1, http_do=http_do)
        with self.assertRaises(MODULE.RecoveryError):
            client._request("DELETE", "/api/v1/platforms/4aaf9c1c-cc7d-4351-b913-d2c2ff0156eb")
        self.assertEqual(calls, [])

    def test_candidate_accepts_402_rolling_window(self):
        candidate, reason = classify(account())
        self.assertEqual(reason, "candidate")
        self.assertEqual(candidate.resin_account, "shard-01")

    def test_candidate_hard_rejects_429(self):
        candidate, reason = classify(account(status_code=429))
        self.assertIsNone(candidate)
        self.assertEqual(reason, "snapshot_429")

    def test_candidate_rejects_non_spending_402(self):
        candidate, reason = classify(account(retry_after=1800))
        self.assertIsNone(candidate)
        self.assertEqual(reason, "not_spending_limit")

    def test_candidate_accepts_safe_marker_without_retry(self):
        value = account(retry_after=None)
        value["error_message"] = "personal-team-blocked:spending-limit"
        candidate, reason = classify(value)
        self.assertIsNotNone(candidate)
        self.assertEqual(reason, "candidate")

    def test_username_parser_uses_resin_account_segment(self):
        self.assertEqual(MODULE.parse_resin_username("GrokEU.shard-99", "GrokEU"), "shard-99")
        with self.assertRaises(MODULE.RecoveryError):
            MODULE.parse_resin_username("Other.shard-99", "GrokEU")

    def test_success_deletes_lease_without_proxy_change(self):
        before = account()
        sub2 = FakeSub2([before], {1: dict(before)}, test_ok=True)
        resin = FakeResin()
        state = MODULE.new_state()
        now = dt.datetime(2026, 7, 30, 16, 0, tzinfo=dt.timezone.utc)
        with tempfile.TemporaryDirectory() as temp:
            summary = MODULE.run_once(
                sub2=sub2,
                resin=resin,
                state=state,
                state_file=Path(temp) / "state.json",
                events_file=Path(temp) / "events.jsonl",
                apply=True,
                now=now,
                group_id=5,
                resin_platform_id="4aaf9c1c-cc7d-4351-b913-d2c2ff0156eb",
                resin_platform_name="GrokEU",
                expected_proxy_host="172.17.0.1",
                expected_proxy_port=10833,
                expected_proxy_protocol="socks5h",
                test_interval=dt.timedelta(hours=24),
                global_backoff=dt.timedelta(minutes=30),
                max_accounts=5,
            )
        self.assertEqual(summary["recovered"], 1)
        self.assertIn(("delete_lease", "shard-01"), resin.calls)
        self.assertIn(("test", 1), sub2.calls)
        self.assertIn(("clear", 1), sub2.calls)
        self.assertTrue(all(call[0] != "put" for call in sub2.calls))

    def test_failed_test_keeps_cooldown_and_starts_global_backoff(self):
        before = account()
        sub2 = FakeSub2([before], {1: dict(before)}, test_ok=False)
        resin = FakeResin()
        state = MODULE.new_state()
        now = dt.datetime(2026, 7, 30, 16, 0, tzinfo=dt.timezone.utc)
        with tempfile.TemporaryDirectory() as temp:
            summary = MODULE.run_once(
                sub2=sub2,
                resin=resin,
                state=state,
                state_file=Path(temp) / "state.json",
                events_file=Path(temp) / "events.jsonl",
                apply=True,
                now=now,
                group_id=5,
                resin_platform_id="4aaf9c1c-cc7d-4351-b913-d2c2ff0156eb",
                resin_platform_name="GrokEU",
                expected_proxy_host="172.17.0.1",
                expected_proxy_port=10833,
                expected_proxy_protocol="socks5h",
                test_interval=dt.timedelta(hours=24),
                global_backoff=dt.timedelta(minutes=30),
                max_accounts=5,
            )
        self.assertEqual(summary["failed"], 1)
        self.assertEqual(summary["status"], "backoff_after_failure")
        self.assertNotIn(("clear", 1), sub2.calls)
        self.assertIsNotNone(state["backoff_until"])

    def test_recent_test_budget_skips_all_writes(self):
        before = account()
        sub2 = FakeSub2([before], {1: dict(before)}, test_ok=True)
        resin = FakeResin()
        now = dt.datetime(2026, 7, 30, 16, 0, tzinfo=dt.timezone.utc)
        state = MODULE.new_state()
        state["accounts"]["1"] = {"last_test_at": MODULE.isoformat(now - dt.timedelta(hours=1))}
        summary = MODULE.run_once(
            sub2=sub2,
            resin=resin,
            state=state,
            state_file=None,
            events_file=None,
            apply=True,
            now=now,
            group_id=5,
            resin_platform_id="4aaf9c1c-cc7d-4351-b913-d2c2ff0156eb",
            resin_platform_name="GrokEU",
            expected_proxy_host="172.17.0.1",
            expected_proxy_port=10833,
            expected_proxy_protocol="socks5h",
            test_interval=dt.timedelta(hours=24),
            global_backoff=dt.timedelta(minutes=30),
            max_accounts=5,
        )
        self.assertEqual(summary["status"], "test_budget_exhausted")
        self.assertEqual(resin.calls, [])
        self.assertTrue(all(call[0] not in {"test", "clear"} for call in sub2.calls))


if __name__ == "__main__":
    unittest.main()
