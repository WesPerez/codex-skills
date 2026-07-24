#!/usr/bin/env python3
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "analyze_ws_logs.py"


class AnalyzeWsLogsTest(unittest.TestCase):
    def test_self_test(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--self-test"],
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("PASS", result.stdout)

    def test_json_is_redacted_and_classifies_limit(self):
        with tempfile.TemporaryDirectory(prefix="proxy443-test-") as directory:
            access = Path(directory) / "access.log"
            error = Path(directory) / "error.log"
            access.write_text(
                '198.51.100.10 - - [25/Jul/2026:06:00:00 +0800] "GET /ws-secret?token=do-not-leak HTTP/1.1" 503 0 request_time=0.000\n',
                encoding="utf-8",
            )
            error.write_text(
                '2026/07/25 06:00:00 [error] limiting connections by zone "zone"\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                [sys.executable, str(SCRIPT), "--access-log", str(access), "--error-log", str(error), "--format", "json"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertNotIn("do-not-leak", result.stdout)
            self.assertNotIn("ws-secret", result.stdout)
            report = json.loads(result.stdout)
            self.assertEqual(report["access"]["status"]["503"], 1)
            self.assertEqual(report["access"]["zero_duration_503"], 1)
            self.assertEqual(report["access"]["status_503_ratio"], 1.0)
            self.assertEqual(report["access"]["zero_duration_503_ratio"], 1.0)
            self.assertEqual(report["findings"][0]["bucket"], "edge_limit")
            self.assertTrue(report["mode"]["read_only"])

    def test_window_ss_and_unreadable_name_are_safe(self):
        with tempfile.TemporaryDirectory(prefix="proxy443-test-") as directory:
            access = Path(directory) / "access.log"
            error = Path(directory) / "error.log"
            ss = Path(directory) / "ss.txt"
            access.write_text(
                '198.51.100.11 - - [25/Jul/2026:06:00:00 +0800] "GET /a HTTP/1.1" 101 0 request_time=1.000\n'
                '198.51.100.11 - - [25/Jul/2026:07:00:00 +0800] "GET /b HTTP/1.1" 503 0 request_time=0.000\n',
                encoding="utf-8",
            )
            error.write_text(
                '[25/Jul/2026:06:00:00 +0800] [error] limiting connections by zone "zone"\n'
                '[25/Jul/2026:07:00:00 +0800] [error] connect() failed (111: Connection refused) while connecting to upstream\n',
                encoding="utf-8",
            )
            ss.write_text(
                'ESTAB 0 0 127.0.0.1:443 127.0.0.1:50000\n'
                'ESTAB 0 0 127.0.0.1:17001 127.0.0.1:50001\n',
                encoding="utf-8",
            )
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--access-log",
                    str(access),
                    "--error-log",
                    str(error),
                    "--ss-file",
                    str(ss),
                    "--backend-port",
                    "17001",
                    "--since",
                    "2026-07-25T05:59:00+08:00",
                    "--until",
                    "2026-07-25T06:01:00+08:00",
                    "--format",
                    "json",
                ],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(report["access"]["records"], 1)
            self.assertEqual(report["access"]["status"]["101"], 1)
            self.assertEqual(report["errors"]["limit_conn"], 1)
            self.assertNotIn("Connection refused", result.stdout)
            self.assertEqual(report["connections"]["established_443"], 1)
            self.assertEqual(report["connections"]["established_backend"], 1)

            missing = subprocess.run(
                [sys.executable, str(SCRIPT), "--access-log", "/tmp/token-super-secret.log", "--format", "json"],
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(missing.returncode, 0)
            self.assertNotIn("token-super-secret", missing.stdout)


if __name__ == "__main__":
    unittest.main()
