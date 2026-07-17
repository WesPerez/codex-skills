#!/usr/bin/env python3

from __future__ import annotations

import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlsplit


SKILL_ROOT = Path(__file__).resolve().parents[1]


def load_module(name: str, relative_path: str):
    spec = importlib.util.spec_from_file_location(name, SKILL_ROOT / relative_path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {relative_path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


planner = load_module("account_organizer_planner", "scripts/plan_account_names.py")
renderer = load_module("account_organizer_renderer", "scripts/render_name_update_sql.py")


def account(
    aid: int,
    name: str,
    *,
    platform: str = "openai",
    account_type: str = "apikey",
    base_url: str = "",
    parent_account_id: int | None = None,
    extra: dict | None = None,
) -> dict:
    credentials = {"base_url": base_url} if base_url else {}
    return {
        "id": aid,
        "name": name,
        "platform": platform,
        "type": account_type,
        "credentials": credentials,
        "extra": extra or {},
        "parent_account_id": parent_account_id,
        "priority": 50,
        "status": "active",
        "schedulable": True,
        "group_ids": [2, 1],
        "proxy_id": None,
        "quota_dimension": "spark" if parent_account_id else "global",
        "concurrency": 3,
        "rate_multiplier": 1,
    }


class PlannerTests(unittest.TestCase):
    def test_groups_normalized_urls_and_inherits_parent(self) -> None:
        rows = [
            account(10, "alpha", base_url="HTTPS://Api.Example.com:443/v1/"),
            account(11, "beta", base_url="https://api.example.com/v1"),
            account(12, "shadow", account_type="oauth", parent_account_id=10),
        ]
        plan = planner.build_plan(rows, {})
        self.assertEqual(plan["group_count"], 1)
        self.assertEqual(plan["groups"][0]["account_ids"], [10, 11, 12])
        prefixes = {change["new_name"].split("] ", 1)[0] for change in plan["changes"]}
        self.assertEqual(len(prefixes), 1)

    def test_openai_oauth_ignores_stored_base_url(self) -> None:
        rows = [
            account(20, "oauth-a", account_type="oauth", base_url="https://one.invalid/v1"),
            account(21, "oauth-b", account_type="oauth", base_url="https://two.invalid/v1"),
        ]
        plan = planner.build_plan(rows, {})
        self.assertEqual(plan["group_count"], 1)
        self.assertEqual(plan["groups"][0]["label"], "openai-oauth-default")

    def test_plan_does_not_contain_url_query_secret(self) -> None:
        rows = [account(30, "secret-query", base_url="https://relay.example/v1?token=do-not-store")]
        encoded = json.dumps(planner.build_plan(rows, {}), ensure_ascii=False)
        self.assertNotIn("do-not-store", encoded)
        self.assertNotIn("token=", encoded)
        self.assertNotIn("/v1", encoded)

    def test_query_does_not_split_the_same_base_endpoint(self) -> None:
        rows = [
            account(31, "query-a", base_url="https://relay.example/v1?token=one"),
            account(32, "query-b", base_url="https://relay.example/v1?token=two"),
        ]
        plan = planner.build_plan(rows, {})
        self.assertEqual(plan["group_count"], 1)
        self.assertEqual(plan["groups"][0]["account_ids"], [31, 32])

    def test_custom_marker_order_keeps_urls_together_and_excludes_platform(self) -> None:
        rows = [
            account(33, "QQ6-second", base_url="https://z.example/v1"),
            account(34, "6945-first", base_url="https://a.example/v1"),
            account(35, "1223-inside-a", base_url="https://a.example/v1"),
            account(36, "unmatched", base_url="https://m.example/v1"),
            account(37, "grok-untouched", platform="grok", account_type="oauth"),
        ]
        plan = planner.build_plan(
            rows,
            {},
            exclude_platforms=["GROK"],
            order_markers=["6945", "1223", "QQ6"],
        )
        self.assertEqual(plan["excluded_account_ids"], [37])
        self.assertEqual(plan["groups"][0]["account_ids"], [34, 35])
        self.assertEqual(plan["groups"][0]["matched_markers"], ["6945", "1223"])
        by_id = {change["id"]: change for change in plan["changes"]}
        self.assertTrue(by_id[34]["new_name"].startswith("!00-"))
        self.assertTrue(by_id[35]["new_name"].startswith("!01-"))
        self.assertLess(by_id[34]["new_name"], by_id[35]["new_name"])
        self.assertNotIn(37, by_id)

    def test_compact_prefix_removes_legacy_prefix_without_changing_base_name(self) -> None:
        legacy = "!S2:00001:01:1234567890 original-name"
        plan = planner.build_plan(
            [account(38, legacy, base_url="https://compact.example/v1")],
            {},
            order_markers=["original"],
        )
        change = plan["changes"][0]
        self.assertEqual(change["base_name"], "original-name")
        self.assertEqual(change["new_name"], "!00-original-name")
        self.assertEqual(len(change["new_name"]) - len(change["base_name"]), 4)

    def test_name_buckets_keep_any_before_claude_inside_one_url_group(self) -> None:
        rows = [
            account(39, "any-1223", base_url="https://anyrouter.example/v1"),
            account(40, "6945-CLAUDE", base_url="https://anyrouter.example/v1"),
            account(41, "any-6945", base_url="https://anyrouter.example/v1"),
            account(42, "1223-CLAUDE", base_url="https://anyrouter.example/v1"),
            account(43, "6945-other", base_url="https://other.example/v1"),
        ]
        plan = planner.build_plan(
            rows,
            {},
            order_markers=["6945", "1223"],
            name_buckets=["any-", "claude"],
        )
        self.assertEqual(plan["groups"][0]["account_ids"], [39, 40, 41, 42])
        ordered = sorted(plan["changes"], key=lambda row: row["new_name"])
        self.assertEqual([row["id"] for row in ordered], [41, 39, 40, 42, 43])
        self.assertTrue(all(len(row["new_name"]) - len(row["base_name"]) == 4 for row in ordered))

    def test_compact_prefix_replan_does_not_duplicate_separator(self) -> None:
        plan = planner.build_plan(
            [account(44, "!00-any-6945", base_url="https://separator.example/v1")],
            {},
            order_markers=["6945"],
            name_buckets=["any-"],
        )
        self.assertEqual(plan["changes"], [])
        self.assertEqual(plan["verification_rows"][0]["base_name"], "any-6945")

    def test_repeated_plan_is_idempotent(self) -> None:
        rows = [account(40, "first", base_url="https://same.example/v1")]
        first = planner.build_plan(rows, {})
        self.assertEqual(first["changed_count"], 1)
        rows[0]["name"] = first["changes"][0]["new_name"]
        second = planner.build_plan(rows, {})
        self.assertEqual(second["changed_count"], 0)

    def test_verify_detects_protected_field_change(self) -> None:
        rows = [account(50, "guarded", base_url="https://guard.example/v1")]
        plan = planner.build_plan(rows, {})
        self.assertTrue(planner.verify_plan(plan, rows, "before")["ok"])
        rows[0]["priority"] = 1
        result = planner.verify_plan(plan, rows, "before")
        self.assertFalse(result["ok"])
        self.assertEqual(result["errors"][0]["reason"], "protected_fields_changed")

    def test_verify_detects_route_and_account_set_changes(self) -> None:
        rows = [account(51, "route", base_url="https://one.example/v1")]
        plan = planner.build_plan(rows, {})
        rows[0]["credentials"]["base_url"] = "https://two.example/v1"
        result = planner.verify_plan(plan, rows, "before")
        self.assertFalse(result["ok"])
        self.assertEqual(result["errors"][0]["reason"], "route_changed")

        rows = [account(51, "route", base_url="https://one.example/v1")]
        rows.append(account(52, "new", base_url="https://one.example/v1"))
        result = planner.verify_plan(plan, rows, "before")
        self.assertFalse(result["ok"])
        self.assertEqual(result["errors"][0]["reason"], "unexpected_active_account")

    def test_verify_rejects_unknown_expectation_and_duplicate_plan_ids(self) -> None:
        rows = [account(53, "verify", base_url="https://verify.example/v1")]
        plan = planner.build_plan(rows, {})
        with self.assertRaises(planner.PlanError):
            planner.verify_plan(plan, rows, "later")

        plan["verification_rows"].append(dict(plan["verification_rows"][0]))
        with self.assertRaises(planner.PlanError):
            planner.verify_plan(plan, rows, "before")

    def test_long_name_is_reversible_in_plan(self) -> None:
        original = "x" * 100
        plan = planner.build_plan([account(60, original, base_url="https://long.example/v1")], {})
        change = plan["changes"][0]
        self.assertTrue(change["truncated"])
        self.assertEqual(change["base_name"], original)
        self.assertLessEqual(len(change["new_name"]), 100)

    def test_prefix_only_name_is_rejected(self) -> None:
        with self.assertRaises(planner.PlanError):
            planner.build_plan(
                [account(61, "[@url:relay.example:1234567890] ", base_url="https://relay.example/v1")],
                {},
            )

    def test_active_shadow_with_deleted_parent_is_rejected(self) -> None:
        parent = account(62, "deleted-parent", base_url="https://relay.example/v1")
        parent["deleted_at"] = "2026-01-01T00:00:00Z"
        shadow = account(63, "shadow", parent_account_id=62)
        with self.assertRaises(planner.PlanError):
            planner.build_plan([parent, shadow], {})


class RendererTests(unittest.TestCase):
    def test_rendered_sql_has_narrow_write_contract(self) -> None:
        plan = planner.build_plan([account(70, "render", base_url="https://sql.example/v1")], {})
        sql = renderer.render_sql(plan, "a" * 64, "apply", "public")
        self.assertIn("SET name = plan.replacement_name", sql)
        self.assertIn("updated_at = NOW()", sql)
        self.assertIn("scheduler_outbox", sql)
        self.assertNotIn("SET credentials", sql)
        self.assertNotIn("SET priority", sql)
        self.assertNotIn("DELETE FROM", sql)
        self.assertNotIn("ALTER TABLE", sql)

    def test_apply_and_rollback_swap_expected_names(self) -> None:
        plan = planner.build_plan([account(80, "rollback", base_url="https://rollback.example/v1")], {})
        with tempfile.TemporaryDirectory() as tmp:
            plan_path = Path(tmp) / "plan.json"
            plan_path.write_text(json.dumps(plan), encoding="utf-8")
            loaded, digest = renderer.load_plan(str(plan_path))
            apply_sql = renderer.render_sql(loaded, digest, "apply", "public")
            rollback_sql = renderer.render_sql(loaded, digest, "rollback", "public")
        self.assertNotEqual(apply_sql, rollback_sql)
        self.assertIn("Direction: apply", apply_sql)
        self.assertIn("Direction: rollback", rollback_sql)

    def test_render_rejects_unknown_direction(self) -> None:
        plan = planner.build_plan([account(81, "direction", base_url="https://direction.example/v1")], {})
        with self.assertRaises(ValueError):
            renderer.render_sql(plan, "a" * 64, "sideways", "public")

    def test_load_plan_rejects_wrong_operation(self) -> None:
        plan = planner.build_plan([account(82, "operation", base_url="https://operation.example/v1")], {})
        plan["operation"] = "unrelated-operation"
        with tempfile.TemporaryDirectory() as tmp:
            plan_path = Path(tmp) / "plan.json"
            plan_path.write_text(json.dumps(plan), encoding="utf-8")
            with self.assertRaises(ValueError):
                renderer.load_plan(str(plan_path))


class FetcherTests(unittest.TestCase):
    def test_fetches_all_pages_without_printing_auth(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                if self.headers.get("x-api-key") != "test-admin-secret":
                    self.send_response(401)
                    self.end_headers()
                    return
                query = parse_qs(urlsplit(self.path).query)
                page = int(query.get("page", ["1"])[0])
                items = [account(90 + page, f"page-{page}")] if page <= 2 else []
                body = json.dumps(
                    {
                        "code": 0,
                        "message": "success",
                        "data": {"items": items, "total": 2, "page": page, "page_size": 1, "pages": 2},
                    }
                ).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args) -> None:  # noqa: A002
                return

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "accounts.json"
                env = os.environ.copy()
                env.update(
                    {
                        "SUB2API_BASE_URL": f"http://127.0.0.1:{server.server_port}",
                        "SUB2API_ADMIN_API_KEY": "test-admin-secret",
                    }
                )
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SKILL_ROOT / "scripts/fetch_redacted_accounts.py"),
                        "--output",
                        str(output),
                        "--page-size",
                        "1",
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertNotIn("test-admin-secret", result.stdout + result.stderr)
                payload = json.loads(output.read_text(encoding="utf-8"))
                self.assertEqual(payload["count"], 2)
                self.assertEqual([item["id"] for item in payload["items"]], [91, 92])
                self.assertEqual(output.stat().st_mode & 0o777, 0o600)
        finally:
            server.shutdown()
            server.server_close()

    def test_rejects_unredacted_sensitive_credentials(self) -> None:
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
                item = account(93, "unsafe")
                item["credentials"]["access_token"] = "must-not-be-written"
                body = json.dumps({"code": 0, "data": {"items": [item], "total": 1}}).encode("utf-8")
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, format: str, *args) -> None:  # noqa: A002
                return

        server = HTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as tmp:
                output = Path(tmp) / "accounts.json"
                env = os.environ.copy()
                env.update(
                    {
                        "SUB2API_BASE_URL": f"http://127.0.0.1:{server.server_port}",
                        "SUB2API_ADMIN_API_KEY": "test-admin-secret",
                    }
                )
                result = subprocess.run(
                    [
                        sys.executable,
                        str(SKILL_ROOT / "scripts/fetch_redacted_accounts.py"),
                        "--output",
                        str(output),
                    ],
                    check=False,
                    capture_output=True,
                    text=True,
                    env=env,
                )
                self.assertEqual(result.returncode, 2)
                self.assertFalse(output.exists())
                self.assertNotIn("must-not-be-written", result.stdout + result.stderr)
        finally:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    unittest.main()
