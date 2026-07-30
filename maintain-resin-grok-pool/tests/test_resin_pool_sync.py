from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "resin_pool_sync.py"
SPEC = importlib.util.spec_from_file_location("resin_pool_sync_test", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class FakeClient:
    def __init__(self):
        self.platform_patches: list[dict[str, object]] = []

    def request(self, method, path, body=None):
        if method == "PATCH" and path.startswith("/api/v1/platforms/"):
            self.platform_patches.append(dict(body or {}))
            if len(self.platform_patches) == 1:
                return {"id": "platform", "regex_filters": ["unexpected"]}
            return {"id": "platform", **dict(body or {})}
        raise AssertionError((method, path, body))


class ResinPoolSyncTests(unittest.TestCase):
    def test_platform_response_failure_restores_previous_filters(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state_dir = root / "state"
            run_dir = state_dir / "runs" / "validated"
            run_dir.mkdir(parents=True)
            output = b"http://user:pass@1.1.1.1:80\n"
            output_hash = hashlib.sha256(output).hexdigest()
            config_path = root / "config.json"
            config = {
                "version": 1,
                "state_dir": str(state_dir),
                "lock_file": str(root / "maintainer.lock"),
                "safety": {"min_selected": 1, "min_passed": 1},
                "resin": {
                    "base_url": "http://127.0.0.1:10833",
                    "subscription_name": "managed",
                    "platform_id": "11111111-1111-1111-1111-111111111111",
                    "platform_name": "GrokEU",
                    "platform_regex_filters": ["^desired/"],
                    "region_filters": [],
                },
            }
            config_path.write_text(json.dumps(config), encoding="utf-8")
            config_path.chmod(0o600)
            config_hash = MODULE.sha256_file(config_path)
            (run_dir / "validated-proxies.txt").write_bytes(output)
            (run_dir / "validated-proxies.txt").chmod(0o600)
            report = {
                "created_at": dt.datetime.now(dt.timezone.utc).isoformat(),
                "input_count": 1,
                "passed_count": 1,
                "selected_count": 1,
                "unique_egress_count": 1,
                "output_sha256": output_hash,
            }
            manifest = {
                "owner": MODULE.OWNER,
                "status": "validated_only",
                "config_sha256": config_hash,
                "validation": {"output_sha256": output_hash},
            }
            for name, value in (("validation-report.json", report), ("manifest.json", manifest)):
                path = run_dir / name
                path.write_text(json.dumps(value), encoding="utf-8")
                path.chmod(0o600)

            client = FakeClient()
            before_subscription = {"id": "subscription", "content": "old"}
            before_platform = {
                "id": config["resin"]["platform_id"],
                "name": "GrokEU",
                "regex_filters": ["^old/"],
                "region_filters": ["us"],
            }
            args = argparse.Namespace(
                command="apply",
                config=str(config_path),
                validated_run=str(run_dir),
                admin_token_file=str(root / "unused-token"),
                confirm_production_write=True,
            )
            patches = (
                mock.patch.object(MODULE, "load_token", return_value="secret"),
                mock.patch.object(MODULE, "ResinClient", return_value=client),
                mock.patch.object(MODULE, "find_subscription", return_value=before_subscription),
                mock.patch.object(MODULE, "get_platform", return_value=before_platform),
                mock.patch.object(MODULE, "create_backups", return_value=[]),
                mock.patch.object(
                    MODULE,
                    "update_subscription",
                    return_value={"id": "subscription"},
                ),
                mock.patch.object(MODULE, "refresh_subscription", return_value=None),
                mock.patch.object(
                    MODULE,
                    "verify_subscription",
                    return_value={"id": "subscription", "node_count": 1},
                ),
                mock.patch.object(
                    MODULE,
                    "restore_subscription",
                    return_value={"attempted": True, "subscription_restored": True},
                ),
            )
            with patches[0], patches[1], patches[2], patches[3], patches[4], patches[5], patches[6], patches[7], patches[8]:
                with self.assertRaisesRegex(MODULE.SyncError, "platform filter update verification failed"):
                    MODULE.run(args)

            self.assertEqual(
                client.platform_patches,
                [
                    {"regex_filters": ["^desired/"], "region_filters": []},
                    {"regex_filters": ["^old/"], "region_filters": ["us"]},
                ],
            )


if __name__ == "__main__":
    unittest.main()
