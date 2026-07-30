from __future__ import annotations

import datetime as dt
import hashlib
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
SCRIPT = SCRIPTS / "proxy_probe.py"
SPEC = importlib.util.spec_from_file_location("proxy_probe_manifest_test", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class ManifestTests(unittest.TestCase):
    def make_source(self, root: Path, expires_at: str, content_file: str | None = None):
        data = b"http://u:p@1.1.1.1:80\n"
        source = root / "candidates.txt"
        source.write_bytes(data)
        source.chmod(0o600)
        manifest = root / "manifest.json"
        value = {
            "owner": "maintain-resin-grok-pool",
            "source_id": "linuxdo-current-public-batches",
            "expires_at": expires_at,
            "content_sha256": hashlib.sha256(data).hexdigest(),
            "line_count": 1,
        }
        if content_file is not None:
            value["content_file"] = content_file
        manifest.write_text(
            json.dumps(value),
            encoding="utf-8",
        )
        manifest.chmod(0o600)
        return source, manifest

    def test_manifest_source_loads_when_current(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, manifest = self.make_source(root, "2099-01-01T00:00:00Z")
            specs, audit = MODULE.load_sources(
                [
                    {
                        "id": "linuxdo-current-public-batches",
                        "type": "file",
                        "path": str(source),
                        "manifest_path": str(manifest),
                    }
                ],
                MODULE.PublicResolver(),
                1,
                1024,
            )
            self.assertEqual(len(specs), 1)
            self.assertEqual(audit[0]["status"], "loaded")

    def test_manifest_generation_is_authoritative_over_compatibility_file(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            generation = root / "candidates.abc.txt"
            generation.write_bytes(b"http://u:p@1.1.1.1:80\n")
            generation.chmod(0o600)
            source, manifest = self.make_source(
                root, "2099-01-01T00:00:00Z", generation.name
            )
            source.write_text("partial", encoding="utf-8")
            source.chmod(0o600)
            specs, audit = MODULE.load_sources(
                [
                    {
                        "id": "linuxdo-current-public-batches",
                        "type": "file",
                        "path": str(source),
                        "manifest_path": str(manifest),
                    }
                ],
                MODULE.PublicResolver(),
                1,
                1024,
            )
            self.assertEqual(len(specs), 1)
            self.assertEqual(audit[0]["status"], "loaded")

    def test_manifest_generation_rejects_path_traversal(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, manifest = self.make_source(
                root, "2099-01-01T00:00:00Z", "../outside.txt"
            )
            with self.assertRaisesRegex(ValueError, "content file is invalid"):
                MODULE.load_sources(
                    [
                        {
                            "id": "linuxdo-current-public-batches",
                            "type": "file",
                            "path": str(source),
                            "manifest_path": str(manifest),
                        }
                    ],
                    MODULE.PublicResolver(),
                    1,
                    1024,
                )

    def test_manifest_source_is_skipped_when_expired(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, manifest = self.make_source(root, "2000-01-01T00:00:00Z")
            specs, audit = MODULE.load_sources(
                [
                    {
                        "id": "linuxdo-current-public-batches",
                        "type": "file",
                        "path": str(source),
                        "manifest_path": str(manifest),
                    }
                ],
                MODULE.PublicResolver(),
                1,
                1024,
            )
            self.assertEqual(specs, [])
            self.assertEqual(audit[0]["status"], "expired")

    def test_manifest_hash_mismatch_fails_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source, manifest = self.make_source(root, "2099-01-01T00:00:00Z")
            source.write_text("http://u:p@8.8.8.8:80\n", encoding="utf-8")
            source.chmod(0o600)
            with self.assertRaisesRegex(ValueError, "hash mismatch"):
                MODULE.load_sources(
                    [
                        {
                            "id": "linuxdo-current-public-batches",
                            "type": "file",
                            "path": str(source),
                            "manifest_path": str(manifest),
                        }
                    ],
                    MODULE.PublicResolver(),
                    1,
                    1024,
                )


if __name__ == "__main__":
    unittest.main()
