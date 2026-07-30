from __future__ import annotations

import importlib.util
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "scripts" / "discourse_public_upload.py"
SPEC = importlib.util.spec_from_file_location("discourse_public_upload_test", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class RedirectingOpener:
    def open(self, request, timeout):
        raise urllib.error.HTTPError(
            request.full_url,
            302,
            "Found",
            {"Location": "http://127.0.0.1/private"},
            None,
        )


class DiscoursePublicUploadTests(unittest.TestCase):
    def test_probe_reports_redirect_without_following_it(self):
        with mock.patch.object(
            MODULE.urllib.request,
            "build_opener",
            return_value=RedirectingOpener(),
        ):
            result = MODULE.probe_head("https://cdn.example/file.txt", 1)
        self.assertEqual(result["status"], 302)
        self.assertEqual(result["final_url"], "https://cdn.example/file.txt")


if __name__ == "__main__":
    unittest.main()
