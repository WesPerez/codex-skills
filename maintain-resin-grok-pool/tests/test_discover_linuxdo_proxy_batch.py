from __future__ import annotations

import datetime as dt
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock


SCRIPTS = Path(__file__).resolve().parents[1] / "scripts"
sys.path.insert(0, str(SCRIPTS))
SCRIPT = SCRIPTS / "discover_linuxdo_proxy_batch.py"
SPEC = importlib.util.spec_from_file_location("discover_linuxdo_proxy_batch", SCRIPT)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class DiscoveryTests(unittest.TestCase):
    def setUp(self):
        self.original_curl_get = MODULE.curl_get

    def tearDown(self):
        MODULE.curl_get = self.original_curl_get

    def test_parse_reader_json(self):
        value = MODULE.parse_reader_json("Title:\n\nMarkdown Content:\n{\"id\": 12}\ntrailer")
        self.assertEqual(value["id"], 12)

    def test_discover_topic_ids_filters_small_and_sorts(self):
        markdown = "\n".join(
            (
                "[1000个 HTTP 代理节点](https://linux.do/t/topic/20)",
                "[100000个 HTTP 代理节点](https://linux.do/t/topic/30)",
                "[100个 HTTP 代理节点](https://linux.do/t/topic/40)",
            )
        )
        self.assertEqual(MODULE.discover_topic_ids(markdown, 1000, 3), [30, 20])

    def test_parse_topic_uses_post_one_and_ttl(self):
        payload = {
            "id": 30,
            "title": "100000个 HTTP 代理节点",
            "post_stream": {
                "posts": [
                    {
                        "post_number": 1,
                        "created_at": "2026-07-28T14:03:47Z",
                        "cooked": '<p>100000个 HTTP 代理节点 / 7 天有效</p><a href="/uploads/short-url/abc123.txt">part.txt</a>',
                    }
                ]
            },
        }
        topic = MODULE.parse_topic(payload)
        self.assertEqual(topic.topic_id, 30)
        self.assertEqual(topic.declared_nodes, 100000)
        self.assertEqual(topic.expires_at, dt.datetime(2026, 8, 4, 14, 3, 47, tzinfo=dt.timezone.utc))
        self.assertEqual(topic.attachments[0].short_url, "abc123.txt")

    def test_category_index_filters_and_sorts_by_created_at(self):
        payload = {
            "topic_list": {
                "topics": [
                    {"id": 20, "title": "10000个 HTTP 代理节点", "created_at": "2026-07-20T00:00:00Z"},
                    {"id": 10, "title": "100000个 HTTP 代理节点", "created_at": "2026-07-30T00:00:00Z"},
                    {"id": 30, "title": "普通代理讨论", "created_at": "2026-07-31T00:00:00Z"},
                ]
            }
        }
        self.assertEqual(MODULE.discover_category_topic_ids(payload, 1000), [10, 20])

    def test_ranked_sample_balances_topics_and_deduplicates(self):
        one = {
            f"http://u:p@1.1.1.{index}:80": MODULE.ProxySpec("http", f"1.1.1.{index}", 80, "u", "p")
            for index in range(1, 6)
        }
        two = {
            f"http://u:p@2.2.2.{index}:80": MODULE.ProxySpec("http", f"2.2.2.{index}", 80, "u", "p")
            for index in range(1, 6)
        }
        result = MODULE.ranked_sample({20: one, 30: two}, 6, "seed")
        self.assertEqual(len(result), 6)
        self.assertEqual(len({item.canonical for item in result}), 6)
        self.assertEqual(sum(item.host.startswith("1.") for item in result), 3)
        self.assertEqual(sum(item.host.startswith("2.") for item in result), 3)

    def test_network_path_budget_is_bounded(self):
        paths = tuple(MODULE.parse_network_path(item) for item in ("direct", "a=http://127.0.0.1:8080", "b=socks5h://127.0.0.1:10900"))
        self.assertEqual(len(paths), 3)
        with self.assertRaises(MODULE.DiscoveryError):
            MODULE.parse_network_path("bad=https://user:pass@example.com")

    def test_duplicate_network_route_is_rejected_by_refresh(self):
        with self.assertRaises(MODULE.DiscoveryError):
            MODULE.validate_network_paths(
                (MODULE.NetworkPath("one", ""), MODULE.NetworkPath("two", ""))
            )

    def test_retry_after_parses_seconds_and_http_date(self):
        now = dt.datetime(2026, 7, 30, 0, 0, tzinfo=dt.timezone.utc)
        self.assertEqual(MODULE.parse_retry_after("30", now), 30)
        self.assertEqual(MODULE.parse_retry_after("Thu, 30 Jul 2026 00:00:45 GMT", now), 45)
        self.assertIsNone(MODULE.parse_retry_after("invalid", now))
        self.assertIsNone(MODULE.parse_retry_after("0", now))

    def test_nested_reader_rate_limit_is_detected_conservatively(self):
        limited = (
            "Title:\n\nWarning: Target URL returned error 429: Too Many Requests\n\n"
            "Markdown Content:\n{\"failed\":\"FAILED\",\"message\":"
            "\"You\u2019ve performed this action too many times, please try again later.\"}"
        )
        self.assertTrue(MODULE.is_nested_rate_limit(limited))
        self.assertFalse(MODULE.is_nested_rate_limit("Markdown Content:\n{\"id\": 429}"))

    def test_http_429_waits_on_same_path_before_success(self):
        calls = []
        sleeps = []
        responses = iter(((429, {}, True), (200, {}, True)))

        def fake_curl(_url, destination, network_path, _timeout, _max_bytes):
            calls.append(network_path.label)
            response = next(responses)
            if response[0] == 200:
                destination.write_text("ok", encoding="utf-8")
            return response

        MODULE.curl_get = fake_curl
        with tempfile.TemporaryDirectory() as temp:
            budget = MODULE.WaitBudget(60)
            label = MODULE.fetch_bounded(
                "https://example.com",
                Path(temp) / "response.txt",
                (MODULE.NetworkPath("one"), MODULE.NetworkPath("two")),
                1,
                1024,
                budget,
                30,
                sleeps.append,
            )
        self.assertEqual(label, "one")
        self.assertEqual(calls, ["one", "one"])
        self.assertEqual(sleeps, [30])
        self.assertEqual(budget.spent_seconds, 30)

    def test_nested_429_uses_two_waits_then_switches_path(self):
        calls = []
        sleeps = []

        def fake_curl(_url, destination, network_path, _timeout, _max_bytes):
            calls.append(network_path.label)
            if network_path.label == "one":
                destination.write_text(
                    "Warning: Target URL returned error 429: Too Many Requests",
                    encoding="utf-8",
                )
                return 200, {}, True
            destination.write_text("ok", encoding="utf-8")
            return 200, {}, True

        MODULE.curl_get = fake_curl
        with tempfile.TemporaryDirectory() as temp:
            budget = MODULE.WaitBudget(60)
            label = MODULE.fetch_bounded(
                "https://example.com",
                Path(temp) / "response.txt",
                (MODULE.NetworkPath("one"), MODULE.NetworkPath("two")),
                1,
                1024,
                budget,
                30,
                sleeps.append,
            )
        self.assertEqual(label, "two")
        self.assertEqual(calls, ["one", "one", "one", "two"])
        self.assertEqual(sleeps, [30, 30])
        self.assertEqual(budget.remaining_seconds, 0)

    def test_retry_after_over_budget_stops_without_path_switch(self):
        calls = []

        def fake_curl(_url, _destination, network_path, _timeout, _max_bytes):
            calls.append(network_path.label)
            return 429, {"retry-after": "90"}, True

        MODULE.curl_get = fake_curl
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(MODULE.DiscoveryDeferred, "Retry-After"):
                MODULE.fetch_bounded(
                    "https://example.com",
                    Path(temp) / "response.txt",
                    (MODULE.NetworkPath("one"), MODULE.NetworkPath("two")),
                    1,
                    1024,
                    MODULE.WaitBudget(60),
                    30,
                    lambda _seconds: self.fail("must not sleep past the wait budget"),
                )
        self.assertEqual(calls, ["one"])

    def test_repeated_retry_after_stops_without_path_switch(self):
        calls = []
        sleeps = []

        def fake_curl(_url, _destination, network_path, _timeout, _max_bytes):
            calls.append(network_path.label)
            return 429, {"retry-after": "5"}, True

        MODULE.curl_get = fake_curl
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaisesRegex(MODULE.DiscoveryDeferred, "same path"):
                MODULE.fetch_bounded(
                    "https://example.com",
                    Path(temp) / "response.txt",
                    (MODULE.NetworkPath("one"), MODULE.NetworkPath("two")),
                    1,
                    1024,
                    MODULE.WaitBudget(60),
                    30,
                    sleeps.append,
                )
        self.assertEqual(calls, ["one", "one", "one"])
        self.assertEqual(sleeps, [5, 5])

    def test_existing_source_accepts_private_manifest_generation(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "compatibility.txt"
            generation = root / "candidates.generation.txt"
            manifest_path = root / "manifest.json"
            generation.write_text("data", encoding="utf-8")
            generation.chmod(0o600)
            self.assertTrue(
                MODULE.has_existing_source(
                    output,
                    manifest_path,
                    {"content_file": generation.name},
                )
            )

    def test_global_wait_budget_is_shared_across_fetches(self):
        calls = []
        responses = iter(((429, {}, True), (200, {}, True), (429, {}, True), (429, {}, True)))

        def fake_curl(_url, destination, network_path, _timeout, _max_bytes):
            calls.append(network_path.label)
            response = next(responses)
            if response[0] == 200:
                destination.write_text("ok", encoding="utf-8")
            return response

        MODULE.curl_get = fake_curl
        sleeps = []
        budget = MODULE.WaitBudget(30)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            MODULE.fetch_bounded(
                "https://example.com/one",
                root / "one.txt",
                (MODULE.NetworkPath("one"),),
                1,
                1024,
                budget,
                30,
                sleeps.append,
            )
            with self.assertRaises(MODULE.DiscoveryUnavailable):
                MODULE.fetch_bounded(
                    "https://example.com/two",
                    root / "two.txt",
                    (MODULE.NetworkPath("one"), MODULE.NetworkPath("two")),
                    1,
                    1024,
                    budget,
                    30,
                    sleeps.append,
                )
        self.assertEqual(sleeps, [30])
        self.assertEqual(calls, ["one", "one", "one", "two"])

    def test_content_length_mismatch_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            path = Path(temp) / "partial.txt"
            path.write_bytes(b"short")
            self.assertFalse(MODULE.validate_download_length(path, {"content-length": "100"}))
            self.assertTrue(MODULE.validate_download_length(path, {}))

    def test_curl_get_does_not_follow_redirects(self):
        commands = []

        def fake_run(command, **_kwargs):
            commands.append(command)
            output = Path(command[command.index("--output") + 1])
            headers = Path(command[command.index("--dump-header") + 1])
            output.write_text("redirect", encoding="utf-8")
            headers.write_text(
                "HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1/private\r\n\r\n",
                encoding="iso-8859-1",
            )
            return SimpleNamespace(stdout="302", returncode=0)

        with tempfile.TemporaryDirectory() as temp, mock.patch.object(
            MODULE.subprocess, "run", side_effect=fake_run
        ):
            status, _, transport_ok = MODULE.curl_get(
                "https://example.com/file.txt",
                Path(temp) / "response.txt",
                MODULE.NetworkPath("direct"),
                1,
                1024,
            )
        self.assertEqual(status, 302)
        self.assertTrue(transport_ok)
        self.assertNotIn("--location", commands[0])

    def test_publish_commits_manifest_to_immutable_generation_first(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "candidates.txt"
            manifest_path = root / "manifest.json"
            payload = b"http://u:p@1.1.1.1:80\n"
            manifest = {
                "owner": MODULE.OWNER,
                "source_id": "linuxdo-current-public-batches",
                "content_sha256": MODULE.hashlib.sha256(payload).hexdigest(),
                "line_count": 1,
            }
            self.assertTrue(
                MODULE.publish_source_generation(output, manifest_path, payload, manifest)
            )
            published = json.loads(manifest_path.read_text(encoding="utf-8"))
            generation = root / published["content_file"]
            self.assertEqual(generation.read_bytes(), payload)
            self.assertEqual(output.read_bytes(), payload)
            self.assertEqual(generation.stat().st_mode & 0o777, 0o600)

    def test_prune_source_generations_keeps_only_manifest_target(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "candidates.txt"
            keep = root / f"candidates.{'a' * 64}.txt"
            stale = root / f"candidates.{'b' * 64}.txt"
            unrelated = root / "candidates.notes.txt"
            for path in (keep, stale, unrelated):
                path.write_text(path.name, encoding="utf-8")
            MODULE.prune_source_generations(output, {"content_file": keep.name})
            self.assertTrue(keep.exists())
            self.assertFalse(stale.exists())
            self.assertTrue(unrelated.exists())

    def test_recover_legacy_generation_before_network_discovery(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            output = root / "candidates.txt"
            manifest_path = root / "manifest.json"
            payload = b"http://u:p@1.1.1.1:80\n"
            output.write_bytes(payload)
            output.chmod(0o600)
            manifest_path.write_text(
                json.dumps(
                    {
                        "owner": MODULE.OWNER,
                        "source_id": "linuxdo-current-public-batches",
                        "content_sha256": MODULE.hashlib.sha256(payload).hexdigest(),
                        "line_count": 1,
                    }
                ),
                encoding="utf-8",
            )
            manifest_path.chmod(0o600)
            self.assertTrue(MODULE.recover_legacy_source_generation(output, manifest_path))
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual((root / manifest["content_file"]).read_bytes(), payload)

    def test_fetch_rejects_partial_file_after_curl_error(self):
        MODULE.curl_get = lambda *args, **kwargs: (200, {}, False)
        with tempfile.TemporaryDirectory() as temp:
            with self.assertRaises(MODULE.DiscoveryUnavailable):
                MODULE.fetch_bounded(
                    "https://example.com/file.txt",
                    Path(temp) / "response.txt",
                    (MODULE.NetworkPath("direct"),),
                    1,
                    10,
                )


if __name__ == "__main__":
    unittest.main()
