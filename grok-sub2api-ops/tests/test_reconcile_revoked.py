#!/usr/bin/env python3
from __future__ import annotations

import hashlib
import importlib.util
import inspect
import json
from pathlib import Path
import re
import sys
import tempfile
import types
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "reconcile_revoked.py"
SPEC = importlib.util.spec_from_file_location("reconcile_revoked_tested", SCRIPT)
assert SPEC and SPEC.loader
reconcile = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(reconcile)


def write_private_json(path: Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    path.write_text(json.dumps(value), encoding="utf-8")
    path.chmod(0o600)


def write_private_bytes(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    path.write_bytes(value)
    path.chmod(0o600)


class FakeBridge:
    SUB2API_GROK_GROUP_ID = 5
    SUB2API_POSTGRES_CONTAINER = "synthetic-postgres"

    def __init__(self, rows: dict[int, dict], identities: dict[int, tuple[str, str]] | None = None):
        self.rows = rows
        self.identities = identities or {}
        self.deleted: set[int] = set()
        self.identity_count_value = 1
        self.resolved_override: dict | None = None
        self.resolve_calls: list[tuple[str, str, str]] = []
        self.status_calls: list[tuple[str, int]] = []
        self.api_calls: list[tuple[str, str, dict]] = []
        self.test_calls: list[int] = []
        self.test_results: dict[int, str] = {}
        self.promote_results: dict[int, bool] = {}

    @staticmethod
    def _sql_literal(value: object) -> str:
        return "'" + str(value).replace("'", "''") + "'"

    def _psql_json(self, query: str):
        if query.startswith("select to_json((select count(*)"):
            return self.identity_count_value
        if query.startswith("select to_json(count(*)) from account_groups"):
            return 0
        match = re.search(r"a\.id in \(([0-9,]+)\)", query)
        if not match:
            raise AssertionError(f"unexpected synthetic query: {query[:80]}")
        account_ids = [int(value) for value in match.group(1).split(",")]
        return [dict(self.rows[value]) for value in account_ids if value in self.rows and value not in self.deleted]

    def find_account_snapshot_by_id(self, account_id: int):
        if account_id in self.deleted or account_id not in self.rows:
            return None
        email, subject = self.identities.get(account_id, (f"user{account_id}@example.com", f"sub-{account_id}"))
        row = self.rows[account_id]
        return {
            "id": account_id,
            "name": f"prefix-grok_{email.replace('@', '_')}",
            "credentials": {"email": email, "sub": subject, "base_url": reconcile.OFFICIAL_BASE},
            "status": row["status"],
            "schedulable": row["schedulable"],
            "group_ids": list(row["group_ids"]),
        }

    @staticmethod
    def auth_subject(credentials: dict) -> str:
        return str(credentials.get("sub") or "")

    def find_account_snapshot(self, name: str, email: str = "", subject: str = ""):
        self.resolve_calls.append((name, email, subject))
        if self.resolved_override is not None:
            return self.resolved_override
        for account_id, identity in self.identities.items():
            if identity == (email, subject):
                return self.find_account_snapshot_by_id(account_id)
        return None

    def sub2api_api_status(self, method: str, path: str, body=None):
        account_id = int(path.rstrip("/").rsplit("/", 1)[-1])
        self.status_calls.append((method, account_id))
        if method == "GET":
            return (404 if account_id in self.deleted else 200), None
        if method == "DELETE":
            self.deleted.add(account_id)
            return 200, None
        raise AssertionError(f"unexpected method: {method}")

    def sub2api_api(self, method: str, path: str, body: dict):
        self.api_calls.append((method, path, body))
        account_id = int(path.split("/accounts/", 1)[1].split("/", 1)[0])
        if path.endswith("/schedulable"):
            self.rows[account_id]["schedulable"] = bool(body["schedulable"])
        elif path.endswith("/clear-error"):
            self.rows[account_id]["status"] = "active"
        return {}

    def test_sub2api_account_result(self, account_id: int) -> str:
        self.test_calls.append(account_id)
        return self.test_results.get(account_id, "usable")

    def promote_sub2api_account(self, account_id: int) -> bool:
        if self.promote_results.get(account_id, True) is False:
            return False
        self.rows[account_id].update({"status": "active", "schedulable": True, "group_ids": [5]})
        return True

    @staticmethod
    def auth_is_stale(snapshot: dict, auth: dict) -> bool:
        return False

    def delete_sub2api_account(self, account_id: int) -> bool:
        self.deleted.add(account_id)
        return True


class Harness:
    def __init__(self, *, delete_ids: list[int], recover_ids: list[int], rows: dict[int, dict]):
        self.temp = tempfile.TemporaryDirectory()
        self.project = Path(self.temp.name)
        self.runs = self.project / "private" / "runs"
        self.batch = self.runs / "batch"
        self.batch.mkdir(parents=True, mode=0o700)
        self.batch.chmod(0o700)

        source = self.runs / "audit" / "source.json"
        write_private_json(
            source,
            {
                "classification": {
                    "refresh_revoked": {"account_ids": delete_ids + recover_ids},
                },
                "recovery_material": {
                    "proven_remint_account_ids": recover_ids,
                    "local_result_match_not_proven_account_ids": delete_ids,
                },
            },
        )
        backup = self.batch / "backup" / "before.dump"
        write_private_bytes(backup, b"PGDMP-synthetic-postgres-custom-dump")

        material: dict[str, str] = {}
        identities: dict[int, tuple[str, str]] = {}
        for account_id in recover_ids:
            email = f"user{account_id}@example.com"
            identities[account_id] = (email, f"sub-{account_id}")
            path = self.runs / "materials" / f"{account_id}.json"
            write_private_json(path, {"results": [{"email": email, "password": "synthetic-secret", "sso_ok": True}]})
            material[str(account_id)] = str(path.relative_to(self.project))

        self.manifest = {
            "schema_version": 2,
            "operation": "delete-revoked-and-remint-proven-grok-oauth",
            "environment": {"name": "production", "target_group": {"id": 5, "name": "grok", "platform": "grok"}},
            "source_audit": {"path": str(source.relative_to(self.project)), "sha256": hashlib.sha256(source.read_bytes()).hexdigest()},
            "backup": {
                "path": str(backup.relative_to(self.project)),
                "sha256": hashlib.sha256(backup.read_bytes()).hexdigest(),
                "bytes": backup.stat().st_size,
                "format": "postgres-custom",
                "pg_restore_list_verified": True,
            },
            "proxy_health": {"healthy_refs": ["node-01"]},
            "delete": {"candidate_ids": delete_ids},
            "recover": {
                "canary_id": recover_ids[0] if recover_ids else 0,
                "candidate_ids": recover_ids,
                "material": material,
            },
        }
        self.manifest_path = self.batch / "manifest.json"
        write_private_json(self.manifest_path, self.manifest)
        self.bridge = FakeBridge(rows, identities)
        self.ctx = reconcile.Context(
            self.project,
            self.batch,
            self.manifest_path,
            self.manifest,
            {},
            {},
        )
        self.ctx._bridge = self.bridge

    def close(self) -> None:
        self.temp.cleanup()

    def write_recovered(self, account_id: int) -> None:
        write_private_json(
            self.batch / "remint" / str(account_id) / "result.json",
            {
                "account_id": account_id,
                "status": "recovered_isolated",
                "bridge": {
                    "http_status": 200,
                    "account_id": account_id,
                    "action": "updated",
                    "probe": "passed",
                    "availability": "usable",
                },
            },
        )

    def write_validation_lock(self) -> None:
        write_private_json(
            self.batch / "validate-results.json",
            {
                "status": "passed",
                "scope_sha256": reconcile.sha256_json(reconcile.validation_scope(self.ctx)),
            },
        )

    def write_backup_lock(self) -> None:
        backup = self.manifest["backup"]
        write_private_json(
            self.batch / "backup-results.json",
            {
                "status": "completed",
                "path": backup["path"],
                "sha256": backup["sha256"],
                "bytes": backup["bytes"],
                "pg_restore_list_verified": True,
            },
        )


def isolated_row(account_id: int, status: str = "error", schedulable: bool = False) -> dict:
    return {
        "id": account_id,
        "platform": "grok",
        "type": "oauth",
        "status": status,
        "schedulable": schedulable,
        "official_base": True,
        "group_ids": [5],
    }


class ReconcileRevokedTests(unittest.TestCase):
    def test_backup_reuses_verified_manifest_recovery_point(self):
        harness = Harness(delete_ids=[101], recover_ids=[], rows={101: isolated_row(101)})
        self.addCleanup(harness.close)
        harness.write_validation_lock()

        with mock.patch.object(
            reconcile.subprocess,
            "run",
            return_value=mock.Mock(returncode=0),
        ) as run:
            result = reconcile.phase_backup(harness.ctx)

        self.assertTrue(result["ok"])
        self.assertTrue(result["reused"])
        self.assertEqual(result["bytes"], len(b"PGDMP-synthetic-postgres-custom-dump"))
        run.assert_called_once()

    def test_remint_defaults_to_protocol_only(self):
        parameter = inspect.signature(reconcile.phase_remint).parameters["playwright_fallback"]
        self.assertIs(parameter.default, False)

    def test_validate_accepts_error_and_usage_flapped_active_rows(self):
        harness = Harness(
            delete_ids=[101],
            recover_ids=[202],
            rows={101: isolated_row(101, "error"), 202: isolated_row(202, "active")},
        )
        self.addCleanup(harness.close)

        result = reconcile.phase_validate(harness.ctx)

        self.assertTrue(result["ok"])
        self.assertEqual(result["bridge_identity_exact_count"], 1)
        self.assertEqual(
            harness.bridge.resolve_calls,
            [("grok_user202_example.com", "user202@example.com", "sub-202")],
        )

    def test_validate_rejects_schedulable_revoked_candidate(self):
        harness = Harness(delete_ids=[101], recover_ids=[], rows={101: isolated_row(101, schedulable=True)})
        self.addCleanup(harness.close)

        with self.assertRaisesRegex(reconcile.ReconcileError, "isolation state"):
            reconcile.phase_validate(harness.ctx)

    def test_validate_rejects_candidate_outside_source_partition(self):
        harness = Harness(delete_ids=[101], recover_ids=[], rows={101: isolated_row(101)})
        self.addCleanup(harness.close)
        source = harness.project / harness.manifest["source_audit"]["path"]
        write_private_json(
            source,
            {
                "classification": {"refresh_revoked": {"account_ids": [999]}},
                "recovery_material": {
                    "proven_remint_account_ids": [],
                    "local_result_match_not_proven_account_ids": [999],
                },
            },
        )
        harness.manifest["source_audit"]["sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()

        with self.assertRaisesRegex(reconcile.ReconcileError, "not all in the source"):
            reconcile.phase_validate(harness.ctx)

    def test_delete_resumes_after_completed_id_and_only_mutates_pending_id(self):
        harness = Harness(
            delete_ids=[101, 102],
            recover_ids=[],
            rows={101: isolated_row(101), 102: isolated_row(102)},
        )
        self.addCleanup(harness.close)
        harness.bridge.deleted.add(101)
        harness.write_validation_lock()
        harness.write_backup_lock()
        write_private_json(
            harness.batch / "delete-results.json",
            {
                "status": "running",
                "started_at": "2026-07-24T00:00:00Z",
                "results": [{"account_id": 101, "delete_http_status": 200, "post_delete_get_http_status": 404}],
            },
        )

        result = reconcile.phase_delete(harness.ctx)

        self.assertTrue(result["ok"])
        self.assertNotIn(("DELETE", 101), harness.bridge.status_calls)
        self.assertIn(("DELETE", 102), harness.bridge.status_calls)
        artifact = json.loads((harness.batch / "delete-results.json").read_text(encoding="utf-8"))
        self.assertEqual(artifact["status"], "completed")
        self.assertEqual(artifact["remaining_group_bindings"], 0)
        self.assertEqual({row["account_id"] for row in artifact["results"]}, {101, 102})
        reconcile.assert_delete_complete(harness.ctx)

    def test_reverify_requires_every_locked_account_to_be_recovered(self):
        harness = Harness(
            delete_ids=[],
            recover_ids=[201, 202],
            rows={201: isolated_row(201), 202: isolated_row(202)},
        )
        self.addCleanup(harness.close)
        harness.write_recovered(201)

        with self.assertRaisesRegex(reconcile.ReconcileError, "every locked recovery ID"):
            reconcile.recovered_ids(harness.ctx)

    def test_first_remint_must_use_locked_canary(self):
        harness = Harness(
            delete_ids=[],
            recover_ids=[201, 202],
            rows={201: isolated_row(201), 202: isolated_row(202)},
        )
        self.addCleanup(harness.close)
        harness.write_validation_lock()
        harness.write_backup_lock()

        with self.assertRaisesRegex(reconcile.ReconcileError, "locked canary"):
            reconcile.phase_remint(harness.ctx, 202, "node-01")

    def test_post_bridge_verification_failure_isolates_and_resumes_without_remint(self):
        harness = Harness(delete_ids=[], recover_ids=[201], rows={201: isolated_row(201)})
        self.addCleanup(harness.close)
        harness.write_validation_lock()
        harness.write_backup_lock()
        key = harness.project / "private" / "bridge-management.key"
        write_private_bytes(key, b"synthetic-management-key")
        harness.ctx.bridge_env = {
            "BRIDGE_MANAGEMENT_KEY_FILE": str(key),
            "BRIDGE_BASE": "http://127.0.0.1:8190",
        }
        harness.ctx._register = types.SimpleNamespace(
            load_proxy_pool=lambda *_: types.SimpleNamespace(url_for=lambda _ref: "socks5://synthetic")
        )

        oauth_module = types.ModuleType("xconsole_client.xai_oauth")
        oauth_module.CLIPROXYAPI_GROK_BASE_URL = reconcile.OFFICIAL_BASE
        mint_calls: list[int] = []

        def complete_build_oauth(email, password, *, cliproxyapi_auth_dir, **kwargs):
            mint_calls.append(1)
            auth_path = Path(cliproxyapi_auth_dir) / "xai-synthetic.json"
            write_private_json(auth_path, {"email": email, "sub": "sub-201", "access_token": "synthetic"})
            return types.SimpleNamespace(cliproxyapi_path=auth_path)

        oauth_module.complete_build_oauth = complete_build_oauth
        package = types.ModuleType("xconsole_client")
        package.__path__ = []
        cpa_module = types.ModuleType("cpa")

        def push_auth_file(**kwargs):
            harness.bridge.rows[201].update({"status": "active", "schedulable": True})
            harness.bridge.identity_count_value = 2
            return True, 200, json.dumps({
                "account_id": 201,
                "action": "updated",
                "probe": "passed",
                "availability": "usable",
            })

        cpa_module.push_auth_file = push_auth_file
        with mock.patch.dict(
            sys.modules,
            {"xconsole_client": package, "xconsole_client.xai_oauth": oauth_module, "cpa": cpa_module},
        ):
            with self.assertRaisesRegex(reconcile.ReconcileError, "original account"):
                reconcile.phase_remint(harness.ctx, 201, "node-01")

            artifact = json.loads(reconcile.remint_result_path(harness.ctx, 201).read_text(encoding="utf-8"))
            self.assertEqual(artifact["status"], "postcheck_failed_isolated")
            self.assertFalse(harness.bridge.rows[201]["schedulable"])

            harness.bridge.identity_count_value = 1
            result = reconcile.phase_remint(harness.ctx, 201, "node-01")

        self.assertTrue(result["reused_verified_candidate"])
        self.assertFalse(result["schedulable"])
        self.assertEqual(len(mint_calls), 1)

    def test_minted_pending_push_resumes_without_another_oauth_mint(self):
        harness = Harness(delete_ids=[], recover_ids=[201], rows={201: isolated_row(201)})
        self.addCleanup(harness.close)
        harness.write_validation_lock()
        harness.write_backup_lock()
        key = harness.project / "private" / "bridge-management.key"
        write_private_bytes(key, b"synthetic-management-key")
        harness.ctx.bridge_env = {
            "BRIDGE_MANAGEMENT_KEY_FILE": str(key),
            "BRIDGE_BASE": "http://127.0.0.1:8190",
        }
        auth_path = harness.batch / "remint" / "201" / "auth" / "xai-synthetic.json"
        write_private_json(
            auth_path,
            {"email": "user201@example.com", "sub": "sub-201", "access_token": "synthetic"},
        )
        write_private_json(
            reconcile.remint_result_path(harness.ctx, 201),
            {
                "account_id": 201,
                "status": "minted_pending_push",
                "material_sha256": hashlib.sha256(
                    (harness.project / harness.manifest["recover"]["material"]["201"]).read_bytes()
                ).hexdigest(),
                "auth_path": str(auth_path.relative_to(harness.project)),
                "auth_sha256": hashlib.sha256(auth_path.read_bytes()).hexdigest(),
            },
        )
        cpa_module = types.ModuleType("cpa")
        push_calls: list[int] = []

        def push_auth_file(**kwargs):
            push_calls.append(1)
            harness.bridge.rows[201].update({"status": "active", "schedulable": True})
            return True, 200, json.dumps({
                "account_id": 201,
                "action": "updated",
                "probe": "passed",
                "availability": "usable",
            })

        cpa_module.push_auth_file = push_auth_file
        with mock.patch.dict(sys.modules, {"cpa": cpa_module}):
            result = reconcile.phase_remint(harness.ctx, 201, "node-01")

        self.assertTrue(result["ok"])
        self.assertEqual(push_calls, [1])
        artifact = json.loads(reconcile.remint_result_path(harness.ctx, 201).read_text(encoding="utf-8"))
        self.assertEqual(artifact["status"], "recovered_isolated")
        self.assertFalse(harness.bridge.rows[201]["schedulable"])

    def test_reverify_failure_writes_one_row_and_does_not_touch_later_account(self):
        harness = Harness(
            delete_ids=[],
            recover_ids=[201, 202],
            rows={201: isolated_row(201, "active", False), 202: isolated_row(202, "active", False)},
        )
        self.addCleanup(harness.close)
        harness.write_recovered(201)
        harness.write_recovered(202)
        harness.write_validation_lock()
        harness.write_backup_lock()
        harness.bridge.promote_results[201] = False

        with self.assertRaisesRegex(reconcile.ReconcileError, "remains isolated"):
            reconcile.phase_reverify(harness.ctx)

        artifact = json.loads((harness.batch / "reverify-results.json").read_text(encoding="utf-8"))
        self.assertEqual(len(artifact["results"]), 1)
        self.assertEqual(artifact["results"][0]["account_id"], 201)
        self.assertEqual(artifact["results"][0]["status"], "failed_isolated")
        self.assertEqual(harness.bridge.test_calls, [])
        self.assertNotIn("/accounts/202/", " ".join(call[1] for call in harness.bridge.api_calls))

    def test_reverify_resume_skips_still_valid_completed_account(self):
        harness = Harness(
            delete_ids=[],
            recover_ids=[201],
            rows={201: isolated_row(201, "active", True)},
        )
        self.addCleanup(harness.close)
        harness.write_recovered(201)
        harness.write_validation_lock()
        harness.write_backup_lock()
        write_private_json(
            harness.batch / "reverify-results.json",
            {
                "status": "running",
                "started_at": "2026-07-24T00:00:00Z",
                "results": [{"account_id": 201, "status": "reverified", "availability": "usable"}],
            },
        )

        result = reconcile.phase_reverify(harness.ctx)

        self.assertTrue(result["ok"])
        self.assertEqual(harness.bridge.test_calls, [])
        self.assertEqual(harness.bridge.api_calls, [])

    def test_reverify_promotes_isolated_candidate_without_repeating_probe(self):
        harness = Harness(
            delete_ids=[],
            recover_ids=[201],
            rows={201: isolated_row(201, "active", False)},
        )
        self.addCleanup(harness.close)
        harness.write_recovered(201)
        harness.write_validation_lock()
        harness.write_backup_lock()

        result = reconcile.phase_reverify(harness.ctx)

        self.assertTrue(result["ok"])
        self.assertTrue(harness.bridge.rows[201]["schedulable"])
        self.assertEqual(harness.bridge.test_calls, [])
        artifact = json.loads((harness.batch / "reverify-results.json").read_text(encoding="utf-8"))
        self.assertEqual(artifact["results"][0]["status"], "reverified")

    def test_write_phase_rejects_missing_validation_lock(self):
        harness = Harness(delete_ids=[101], recover_ids=[], rows={101: isolated_row(101)})
        self.addCleanup(harness.close)

        with self.assertRaisesRegex(reconcile.ReconcileError, "validation result"):
            reconcile.phase_delete(harness.ctx)

    def test_delete_rejects_missing_backup_phase_proof(self):
        harness = Harness(delete_ids=[101], recover_ids=[], rows={101: isolated_row(101)})
        self.addCleanup(harness.close)
        harness.write_validation_lock()

        with self.assertRaisesRegex(reconcile.ReconcileError, "backup result"):
            reconcile.phase_delete(harness.ctx)

    def test_remint_rejects_before_locked_delete_phase_completes(self):
        harness = Harness(
            delete_ids=[101],
            recover_ids=[201],
            rows={101: isolated_row(101), 201: isolated_row(201)},
        )
        self.addCleanup(harness.close)
        harness.write_validation_lock()
        harness.write_backup_lock()

        with self.assertRaisesRegex(reconcile.ReconcileError, "delete (result|phase)"):
            reconcile.phase_remint(harness.ctx, 201, "node-01")

    def test_batch_lock_rejects_parallel_mutating_phase(self):
        harness = Harness(delete_ids=[], recover_ids=[], rows={})
        self.addCleanup(harness.close)

        with reconcile.batch_lock(harness.batch):
            with self.assertRaisesRegex(reconcile.ReconcileError, "already running"):
                with reconcile.batch_lock(harness.batch):
                    self.fail("nested batch lock should not be acquired")

    def test_bridge_identity_resolution_must_return_original_id(self):
        harness = Harness(delete_ids=[], recover_ids=[201], rows={201: isolated_row(201)})
        self.addCleanup(harness.close)
        harness.bridge.resolved_override = {"id": 999}

        with self.assertRaisesRegex(reconcile.ReconcileError, "original account"):
            reconcile.phase_validate(harness.ctx)


if __name__ == "__main__":
    unittest.main(verbosity=2)
