#!/usr/bin/env python3
"""Regression tests for the generic long-task continuity tools."""

from __future__ import print_function

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest

SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))

import bootstrap_long_task as bootstrap
from continuity_core import git_snapshot, ledger_record, load_json, load_jsonl, object_hash, render_status, utc_now


def run(command, cwd, expected=0):
    completed = subprocess.run(
        command,
        cwd=str(cwd),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=dict(os.environ, PYTHONDONTWRITEBYTECODE="1", PYTHONUTF8="1"),
    )
    if completed.returncode != expected:
        raise AssertionError("command returned {} instead of {}:\n{}\n{}".format(completed.returncode, expected, command, completed.stdout))
    return completed.stdout


def git(repo, *args, expected=0):
    return run(["git"] + list(args), repo, expected)


def init_repo(path, commit=True):
    path.mkdir(parents=True)
    git(path, "init", "-b", "main")
    git(path, "config", "user.email", "eval@example.invalid")
    git(path, "config", "user.name", "Long Task Eval")
    if commit:
        git(path, "commit", "--allow-empty", "-m", "initial")
    return path


def bootstrap_command(repo, mode="standard", extra=None, include_agents=True):
    command = [
        sys.executable,
        str(SCRIPT_DIR / "bootstrap_long_task.py"),
        "--repo", str(repo),
        "--project-name", "Eval Project",
        "--objective", "Verify continuity tools",
        "--mode", mode,
    ]
    if include_agents:
        command.append("--include-agents")
    command.extend(extra or [])
    return command


def audit_command(repo, extra=None):
    command = [sys.executable, str(SCRIPT_DIR / "audit_long_task.py"), "--repo", str(repo)]
    command.extend(extra or [])
    return command


def progress_command(repo, *args):
    command_args = list(args)
    if command_args and command_args[0] == "run-evidence":
        profile_path = Path(repo) / "docs" / "execution" / "profiles.json"
        document = load_json(profile_path)
        profile_name = command_args[command_args.index("--profile") + 1]
        profile = document["profiles"][profile_name]
        profile.setdefault("readOnly", False)
        profile.setdefault("sideEffectClass", "repository_write")
        profile_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        command_args[1:1] = ["--authorization", "repo_write"]
    return [sys.executable, str(SCRIPT_DIR / "progress_long_task.py"), "--repo", str(repo)] + command_args


class LongTaskToolsTest(unittest.TestCase):
    def test_run_evidence_profile_contract_fails_closed(self):
        with tempfile.TemporaryDirectory(prefix="olp-profile-contract-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            profile_path = repo / "docs" / "execution" / "profiles.json"
            document = load_json(profile_path)
            document["profiles"]["missing"] = {
                "category": "test", "command": ["git", "rev-parse", "HEAD"], "cwd": ".",
                "requiredArtifacts": [],
            }
            profile_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            base = [sys.executable, str(SCRIPT_DIR / "progress_long_task.py"), "--repo", str(repo), "run-evidence"]
            output = run(base + ["--authorization", "repo_write", "--profile", "missing", "--claim", "missing fields"], repo, expected=1)
            self.assertIn("readOnly", output)

            document = load_json(profile_path)
            document["profiles"]["missing"].update({"readOnly": True, "sideEffectClass": "none"})
            profile_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            output = run(base + ["--authorization", "read_only", "--profile", "missing", "--claim", "read only blocked"], repo, expected=1)
            self.assertIn("永不执行", output)

            document = load_json(profile_path)
            document["profiles"]["missing"].update({"readOnly": False, "sideEffectClass": "external_write"})
            profile_path.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            output = run(base + ["--authorization", "external_authorized", "--profile", "missing", "--claim", "missing external auth"], repo, expected=1)
            self.assertIn("externalAuthorization", output)

    def test_light_and_standard_bootstrap(self):
        with tempfile.TemporaryDirectory(prefix="olp-bootstrap-") as temp:
            light = init_repo(Path(temp) / "light")
            run(bootstrap_command(light, "light", ["--dry-run"]), light)
            self.assertFalse((light / "docs").exists())
            run(bootstrap_command(light, "light"), light)
            self.assertTrue((light / "docs" / "execution" / "STATUS.md").is_file())
            self.assertFalse((light / "docs" / "execution" / "state.json").exists())
            self.assertIn("轻量执行计划", (light / "docs" / "project-master-plan.md").read_text(encoding="utf-8"))
            run(progress_command(light, "resume-check"), light)
            run(audit_command(light), light)

            standard = init_repo(Path(temp) / "standard")
            run(bootstrap_command(standard), standard)
            run(audit_command(standard), standard)
            state = load_json(standard / "docs" / "execution" / "state.json")
            self.assertEqual(state["continuityMode"], "standard")
            self.assertEqual(state["eventTail"]["seq"], 1)

    def test_resume_requires_next_action_and_agents_preserve_custom_paths(self):
        with tempfile.TemporaryDirectory(prefix="olp-resume-contract-") as temp:
            base = Path(temp)
            light = init_repo(base / "light")
            custom_args = ["--output-dir", "操作 台账/ledger", "--plan-path", "操作 台账/主 方案.md"]
            run(bootstrap_command(light, "light", custom_args), light)
            agents = (light / "AGENTS.md").read_text(encoding="utf-8")
            self.assertIn("python -B", agents)
            self.assertIn('--output-dir "操作 台账/ledger"', agents)
            self.assertIn('--plan-path "操作 台账/主 方案.md"', agents)
            self.assertIn("git --no-optional-locks status --short", agents)
            status_path = light / "操作 台账" / "ledger" / "STATUS.md"
            lines = [
                line for line in status_path.read_text(encoding="utf-8").splitlines()
                if not line.startswith("- 唯一下一动作：")
            ]
            status_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
            output = run(progress_command(
                light, "--output-dir", "操作 台账/ledger", "--plan-path", "操作 台账/主 方案.md", "resume-check"
            ), light, expected=3)
            self.assertIn("唯一下一动作", output)
            output = run(audit_command(
                light, ["--output-dir", "操作 台账/ledger", "--plan-path", "操作 台账/主 方案.md"]
            ), light, expected=1)
            self.assertIn("唯一下一动作", output)

            standard = init_repo(base / "standard")
            run(bootstrap_command(standard), standard)
            state_path = standard / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            state["activeSlice"]["nextAction"] = ""
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            output = run(audit_command(standard), standard, expected=1)
            self.assertIn("activeSlice.nextAction", output)
            output = run(progress_command(standard, "resume-check"), standard, expected=3)
            self.assertIn("唯一下一动作", output)

    def test_read_only_git_observation_does_not_refresh_index(self):
        with tempfile.TemporaryDirectory(prefix="olp-git-read-only-") as temp:
            repo = init_repo(Path(temp) / "repo")
            product = repo / "product.txt"
            product.write_text("stable\n", encoding="utf-8")
            git(repo, "add", "product.txt")
            git(repo, "commit", "-m", "add product")
            run(bootstrap_command(repo), repo)
            index_path = repo / ".git" / "index"
            before = index_path.stat().st_mtime_ns
            time.sleep(1.1)
            os.utime(str(product), None)
            run(progress_command(repo, "resume-check"), repo)
            run(audit_command(repo), repo)
            self.assertEqual(index_path.stat().st_mtime_ns, before)

    def test_unborn_repo_fails_before_project_writes(self):
        with tempfile.TemporaryDirectory(prefix="olp-unborn-") as temp:
            repo = init_repo(Path(temp) / "repo", commit=False)
            run(bootstrap_command(repo), repo, expected=1)
            self.assertFalse((repo / "docs").exists())
            self.assertFalse((repo / "AGENTS.md").exists())

    def test_path_escape_and_collision_are_rejected(self):
        with tempfile.TemporaryDirectory(prefix="olp-path-") as temp:
            base = Path(temp)
            repo = init_repo(base / "repo")
            run(bootstrap_command(repo, extra=["--output-dir", "../outside-ledger", "--dry-run"]), repo, expected=1)
            self.assertFalse((base / "outside-ledger").exists())
            run(bootstrap_command(repo, extra=["--plan-path", "docs/execution/STATUS.md", "--dry-run"]), repo, expected=1)
            run(bootstrap_command(repo, extra=["--plan-path", "docs/execution", "--dry-run"]), repo, expected=1)
            run(bootstrap_command(repo, extra=["--plan-path", ".git/plan.md", "--dry-run"]), repo, expected=1)
            run(bootstrap_command(repo, extra=["--plan-path", "docs/.git/plan.md", "--dry-run"]), repo, expected=1)
            run(bootstrap_command(repo, extra=["--output-dir", "ops/$(whoami)", "--dry-run"]), repo, expected=1)
            run(bootstrap_command(repo, extra=["--plan-path", "ops/`whoami`.md", "--dry-run"]), repo, expected=1)
            run(bootstrap_command(repo, extra=["--plan-path", "ops/%USERNAME%.md", "--dry-run"]), repo, expected=1)
            if os.name == "nt":
                run(bootstrap_command(repo, extra=["--plan-path", "docs/plan.md:secret", "--dry-run"]), repo, expected=1)
                run(bootstrap_command(repo, extra=["--plan-path", "docs/plan.md.", "--dry-run"]), repo, expected=1)
            self.assertFalse((repo / "docs").exists())

    def test_resume_bootstrap_rejects_manifest_escape_and_duplicates(self):
        with tempfile.TemporaryDirectory(prefix="olp-manifest-security-") as temp:
            base = Path(temp)
            escape_repo = init_repo(base / "escape")
            args = argparse.Namespace(
                repo=str(escape_repo), project_name="Eval Project", objective="Manifest escape",
                mode="standard", output_dir="docs/execution", plan_path="docs/project-master-plan.md",
                thread_id=None, previous_thread_id=None, include_agents=True, dry_run=False, resume_bootstrap=False,
            )
            bundle = bootstrap.build_bundle(args, escape_repo, args.output_dir, args.plan_path)
            pending = bootstrap.prepare_pending(escape_repo, bundle, args.mode)
            external = base / "external.bin"
            external.write_bytes(b"external")
            manifest_path = pending / "manifest.json"
            manifest = load_json(manifest_path)
            manifest["targets"][0]["stage"] = str(external)
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run([sys.executable, str(SCRIPT_DIR / "bootstrap_long_task.py"), "--repo", str(escape_repo), "--resume-bootstrap"], escape_repo, expected=1)
            self.assertTrue(pending.exists())
            self.assertFalse((escape_repo / manifest["targets"][0]["path"]).exists())

            duplicate_repo = init_repo(base / "duplicate")
            args.repo = str(duplicate_repo)
            bundle = bootstrap.build_bundle(args, duplicate_repo, args.output_dir, args.plan_path)
            pending = bootstrap.prepare_pending(duplicate_repo, bundle, args.mode)
            manifest_path = pending / "manifest.json"
            manifest = load_json(manifest_path)
            manifest["targets"].append(dict(manifest["targets"][0]))
            manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run([sys.executable, str(SCRIPT_DIR / "bootstrap_long_task.py"), "--repo", str(duplicate_repo), "--resume-bootstrap"], duplicate_repo, expected=1)
            self.assertTrue(pending.exists())
            self.assertFalse((duplicate_repo / manifest["targets"][0]["path"]).exists())

    def test_dry_run_creates_no_git_private_lock(self):
        with tempfile.TemporaryDirectory(prefix="olp-dry-run-") as temp:
            repo = init_repo(Path(temp) / "repo")
            lock_path = repo / ".git" / "orchestrate-long-projects-bootstrap.lock"
            run(bootstrap_command(repo, extra=["--dry-run"]), repo)
            self.assertFalse(lock_path.exists())
            self.assertFalse((repo / "docs").exists())

    def test_evidence_key_failure_precedes_install_and_resume_recovers(self):
        with tempfile.TemporaryDirectory(prefix="olp-key-failure-") as temp:
            repo = init_repo(Path(temp) / "repo")
            key_path = repo / ".git" / "orchestrate-long-projects" / "evidence.key"
            key_path.mkdir(parents=True)
            run(bootstrap_command(repo), repo, expected=1)
            self.assertFalse((repo / "docs").exists())
            self.assertFalse(bootstrap.pending_dir(repo).exists())
            key_path.rmdir()
            run(bootstrap_command(repo), repo)
            run(audit_command(repo), repo)

        with tempfile.TemporaryDirectory(prefix="olp-key-resume-") as temp:
            repo = init_repo(Path(temp) / "repo")
            args = argparse.Namespace(
                repo=str(repo), project_name="Eval", objective="Resume key failure",
                mode="standard", output_dir="docs/execution", plan_path="docs/project-master-plan.md",
                thread_id=None, previous_thread_id=None, include_agents=True,
                dry_run=False, resume_bootstrap=False,
            )
            bundle = bootstrap.build_bundle(args, repo, "docs/execution", "docs/project-master-plan.md")
            pending = bootstrap.prepare_pending(repo, bundle, "standard")
            key_path = repo / ".git" / "orchestrate-long-projects" / "evidence.key"
            key_path.mkdir(parents=True)
            run([sys.executable, str(SCRIPT_DIR / "bootstrap_long_task.py"), "--repo", str(repo), "--resume-bootstrap"], repo, expected=1)
            self.assertTrue(pending.exists())
            self.assertFalse((repo / "docs").exists())
            key_path.rmdir()
            run([sys.executable, str(SCRIPT_DIR / "bootstrap_long_task.py"), "--repo", str(repo), "--resume-bootstrap"], repo)
            run(audit_command(repo), repo)

    def test_output_dir_does_not_hide_sibling_product_files(self):
        with tempfile.TemporaryDirectory(prefix="olp-output-src-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo, extra=["--output-dir", "src", "--plan-path", "plan.md"]), repo)
            product = repo / "src" / "hidden_product.py"
            product.write_text("print('product')\n", encoding="utf-8")
            run([
                sys.executable, str(SCRIPT_DIR / "progress_long_task.py"), "--repo", str(repo),
                "--output-dir", "src", "--plan-path", "plan.md", "render",
            ], repo)
            state = load_json(repo / "src" / "state.json")
            self.assertIn("src/hidden_product.py", state["git"]["dirtyPaths"])
            run(audit_command(repo, ["--output-dir", "src", "--plan-path", "plan.md"]), repo)

    def test_resume_bootstrap_installs_only_staged_bytes(self):
        with tempfile.TemporaryDirectory(prefix="olp-resume-bootstrap-") as temp:
            repo = init_repo(Path(temp) / "repo")
            args = argparse.Namespace(
                repo=str(repo),
                project_name="Eval Project",
                objective="Resume interrupted bootstrap",
                mode="standard",
                output_dir="docs/execution",
                plan_path="docs/project-master-plan.md",
                thread_id=None,
                previous_thread_id=None,
                include_agents=True,
                dry_run=False,
                resume_bootstrap=False,
            )
            bundle = bootstrap.build_bundle(args, repo, "docs/execution", "docs/project-master-plan.md")
            pending = bootstrap.prepare_pending(repo, bundle, "standard")
            manifest = json.loads((pending / "manifest.json").read_text(encoding="utf-8"))
            first = manifest["targets"][0]
            first_target = repo / first["path"]
            first_target.parent.mkdir(parents=True, exist_ok=True)
            first_target.write_bytes((pending / first["stage"]).read_bytes())
            run([sys.executable, str(SCRIPT_DIR / "bootstrap_long_task.py"), "--repo", str(repo), "--resume-bootstrap"], repo)
            self.assertFalse(pending.exists())
            run(audit_command(repo), repo)

    def test_profile_evidence_checkpoint_and_tamper_detection(self):
        with tempfile.TemporaryDirectory(prefix="olp-evidence-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            profile_path = repo / "docs" / "execution" / "profiles.json"
            profile = load_json(profile_path)
            profile["profiles"]["git-head"] = {
                "category": "test",
                "command": ["git", "rev-parse", "HEAD"],
                "cwd": ".",
                "timeoutSeconds": 30,
                "verifiesHead": True,
                "requiredArtifacts": [],
            }
            profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(progress_command(repo, "run-evidence", "--profile", "git-head", "--claim", "HEAD resolves", "--criterion", "P0-S1-C3", "--gate", "codeSurface"), repo)
            run(progress_command(repo, "checkpoint", "--label", "verified-head", "--type", "git_checkpoint", "--reason", "verified head"), repo)
            run(progress_command(repo, "checkpoint", "--label", "verified", "--type", "state_snapshot", "--reason", "evidence test", "--safe-to-resume"), repo)
            run(audit_command(repo), repo)
            profile["profiles"]["git-head"]["command"] = ["git", "status", "--short"]
            profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("profileDigest", output)
            output = run(progress_command(repo, "resume-check"), repo, expected=3)
            self.assertIn("evidence 已失效", output)

    def test_evidence_fails_when_product_changes_during_run(self):
        with tempfile.TemporaryDirectory(prefix="olp-evidence-drift-") as temp:
            repo = init_repo(Path(temp) / "repo")
            product = repo / "product.txt"
            product.write_text("before\n", encoding="utf-8")
            git(repo, "add", "product.txt")
            git(repo, "commit", "-m", "add product")
            run(bootstrap_command(repo), repo)
            profile_path = repo / "docs" / "execution" / "profiles.json"
            profile = load_json(profile_path)
            mutation = "from pathlib import Path; p=Path('product.txt'); assert p.read_text() == 'before\\n'; p.write_text('after\\n')"
            profile["profiles"]["mutates-product"] = {
                "category": "test",
                "command": [sys.executable, "-c", mutation],
                "cwd": ".",
                "timeoutSeconds": 30,
                "requiredArtifacts": [],
            }
            profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(progress_command(repo, "run-evidence", "--profile", "mutates-product", "--claim", "must fail on source drift"), repo, expected=1)
            evidence = load_jsonl(repo / "docs" / "execution" / "evidence.jsonl")[-1]
            self.assertEqual(evidence["status"], "failed")
            self.assertFalse(evidence["provenance"]["sourceUnchangedDuringRun"])
            self.assertNotEqual(evidence["gitBefore"]["workingTreeFingerprint"], evidence["git"]["workingTreeFingerprint"])
            self.assertLessEqual(evidence["startedAt"], evidence["finishedAt"])
            run(audit_command(repo), repo)

    def test_metadata_commit_and_render_do_not_self_invalidate(self):
        with tempfile.TemporaryDirectory(prefix="olp-metadata-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            git(repo, "add", "AGENTS.md", "docs")
            git(repo, "commit", "-m", "add continuity metadata")
            run(progress_command(repo, "render"), repo)
            run(audit_command(repo), repo)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            state["sourceDocuments"]["metadataPaths"].append("src")
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(progress_command(repo, "render"), repo, expected=1)
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("metadataPaths", output)

    def test_gate_category_and_checkpoint_integrity_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="olp-gates-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            profile_path = repo / "docs" / "execution" / "profiles.json"
            profile = load_json(profile_path)
            profile["profiles"]["unit"] = {
                "category": "test",
                "command": ["git", "rev-parse", "HEAD"],
                "cwd": ".",
                "requiredArtifacts": [],
            }
            profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(progress_command(repo, "run-evidence", "--profile", "unit", "--claim", "must not satisfy live", "--gate", "liveOutcome"), repo, expected=1)
            run(progress_command(repo, "checkpoint", "--label", "normal", "--type", "state_snapshot", "--reason", "integrity", "--safe-to-resume"), repo)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            state["lastCheckpoint"]["safeToRunLive"] = True
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(audit_command(repo), repo, expected=1)
            run(progress_command(repo, "resume-check"), repo, expected=3)

    def test_git_checkpoint_requires_clean_verified_head(self):
        with tempfile.TemporaryDirectory(prefix="olp-git-checkpoint-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            run(progress_command(
                repo, "action-start", "--action-id", "ACT-STANDARD-001", "--kind", "external",
                "--target", "target", "--precondition", "none", "--postcondition", "done",
                "--idempotency-key", "standard-must-fail",
            ), repo, expected=1)
            run(progress_command(repo, "checkpoint", "--label", "invalid", "--type", "git_checkpoint", "--reason", "no verified head"), repo, expected=1)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            state["git"]["verifiedHead"] = state["git"]["observedHead"]
            state["git"]["verifiedByEvidenceIds"] = []
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(progress_command(repo, "checkpoint", "--label", "manual-verified", "--type", "git_checkpoint", "--reason", "forged verified head"), repo, expected=1)
            product = repo / "product.txt"
            product.write_text("dirty\n", encoding="utf-8")
            run(progress_command(repo, "checkpoint", "--label", "dirty", "--type", "git_checkpoint", "--reason", "dirty"), repo, expected=1)

    def test_hardened_controls_and_blockers_fail_closed(self):
        with tempfile.TemporaryDirectory(prefix="olp-hardened-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo, "hardened"), repo)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            state["hardenedControls"].update({
                "ready": True,
                "leaseVerifier": "fake",
                "actionVerifier": "fake",
                "evidenceIds": [],
            })
            state["resume"]["blockers"] = ["real blocker"]
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            events = load_jsonl(repo / "docs" / "execution" / "events.jsonl")
            evidence = load_jsonl(repo / "docs" / "execution" / "evidence.jsonl")
            status = render_status(state, events, evidence, repo, {})
            self.assertIn("恢复结论：**STOP**", status)
            self.assertIn("canEdit=`false`", status)
            run(audit_command(repo), repo, expected=1)
            run(progress_command(repo, "resume-check"), repo, expected=3)
            run(progress_command(repo, "checkpoint", "--label", "live", "--type", "state_snapshot", "--reason", "generic live must fail", "--safe-to-run-live"), repo, expected=1)

    def test_checkpoint_rollback_and_non_boolean_permissions_fail(self):
        with tempfile.TemporaryDirectory(prefix="olp-checkpoint-rollback-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            run(progress_command(repo, "checkpoint", "--label", "second", "--type", "state_snapshot", "--reason", "second", "--safe-to-resume"), repo)
            run(progress_command(repo, "checkpoint", "--label", "third", "--type", "state_snapshot", "--reason", "third", "--safe-to-resume"), repo)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            second_path = next((repo / "docs" / "execution" / "checkpoints").glob("CP-0002-*.json"))
            second = load_json(second_path)
            state["lastCheckpoint"] = {
                "id": second["id"],
                "path": second_path.relative_to(repo).as_posix(),
                "type": second["type"],
                "createdAt": second["createdAt"],
                "safeToResume": second["safeToResume"],
                "safeToRunLive": second["safeToRunLive"],
                "permissions": second["permissions"],
                "hash": second["hash"],
            }
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            events = load_jsonl(repo / "docs" / "execution" / "events.jsonl")
            evidence = load_jsonl(repo / "docs" / "execution" / "evidence.jsonl")
            (repo / "docs" / "execution" / "STATUS.md").write_text(render_status(state, events, evidence, repo, {}), encoding="utf-8")
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("回滚", output)

        with tempfile.TemporaryDirectory(prefix="olp-checkpoint-bool-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            checkpoint_path = repo / state["lastCheckpoint"]["path"]
            checkpoint = load_json(checkpoint_path)
            checkpoint["permissions"]["canEdit"] = "true"
            checkpoint["hash"] = object_hash(checkpoint)
            checkpoint_path.write_text(json.dumps(checkpoint, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            state["lastCheckpoint"]["permissions"] = checkpoint["permissions"]
            state["lastCheckpoint"]["hash"] = checkpoint["hash"]
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            events = load_jsonl(repo / "docs" / "execution" / "events.jsonl")
            evidence = load_jsonl(repo / "docs" / "execution" / "evidence.jsonl")
            (repo / "docs" / "execution" / "STATUS.md").write_text(render_status(state, events, evidence, repo, {}), encoding="utf-8")
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("boolean", output)

    def test_checkpoint_blocker_disables_can_edit(self):
        with tempfile.TemporaryDirectory(prefix="olp-checkpoint-blocker-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            run(progress_command(repo, "note", "--summary", "blocked", "--blocker", "needs user decision"), repo)
            run(progress_command(repo, "checkpoint", "--label", "blocked", "--type", "state_snapshot", "--reason", "blocked handoff", "--safe-to-resume"), repo)
            state = load_json(repo / "docs" / "execution" / "state.json")
            checkpoint = load_json(repo / state["lastCheckpoint"]["path"])
            self.assertTrue(checkpoint["permissions"]["safeToResume"])
            self.assertFalse(checkpoint["permissions"]["canEdit"])
            run(audit_command(repo), repo)
            run(progress_command(repo, "resume-check"), repo, expected=3)

    def test_plan_write_light_does_not_create_agents_without_opt_in(self):
        with tempfile.TemporaryDirectory(prefix="olp-plan-write-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo, "light", include_agents=False), repo)
            self.assertFalse((repo / "AGENTS.md").exists())
            self.assertTrue((repo / "docs" / "project-master-plan.md").is_file())
            self.assertTrue((repo / "docs" / "execution" / "STATUS.md").is_file())

    def test_timeout_terminates_owned_process_tree(self):
        with tempfile.TemporaryDirectory(prefix="olp-timeout-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            marker = repo / "child-survived.txt"
            child_code = "import time; from pathlib import Path; time.sleep(3); Path({!r}).write_text('survived')".format(str(marker))
            parent_code = "import subprocess,sys,time; subprocess.Popen([sys.executable,'-c',{!r}]); time.sleep(30)".format(child_code)
            profile_path = repo / "docs" / "execution" / "profiles.json"
            profile = load_json(profile_path)
            profile["profiles"]["timeout-tree"] = {
                "category": "test",
                "command": [sys.executable, "-c", parent_code],
                "cwd": ".",
                "timeoutSeconds": 1,
                "requiredArtifacts": [],
            }
            profile_path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            run(progress_command(repo, "run-evidence", "--profile", "timeout-tree", "--claim", "timeout tree"), repo, expected=1)
            time.sleep(4)
            self.assertFalse(marker.exists())

    def test_staged_index_changes_fingerprint(self):
        with tempfile.TemporaryDirectory(prefix="olp-index-") as temp:
            repo = init_repo(Path(temp) / "repo")
            product = repo / "product.txt"
            product.write_text("base\n", encoding="utf-8")
            git(repo, "add", "product.txt")
            git(repo, "commit", "-m", "product")
            product.write_text("staged-A\n", encoding="utf-8")
            git(repo, "add", "product.txt")
            product.write_text("base\n", encoding="utf-8")
            first = git_snapshot(repo, "docs/execution", ["docs/execution", "docs/project-master-plan.md", "AGENTS.md"])
            product.write_text("staged-B\n", encoding="utf-8")
            git(repo, "add", "product.txt")
            product.write_text("base\n", encoding="utf-8")
            second = git_snapshot(repo, "docs/execution", ["docs/execution", "docs/project-master-plan.md", "AGENTS.md"])
            self.assertNotEqual(first["workingTreeFingerprint"], second["workingTreeFingerprint"])

    def test_unknown_action_blocks_resume_and_generic_unlock(self):
        with tempfile.TemporaryDirectory(prefix="olp-action-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo, "hardened"), repo)
            run(progress_command(
                repo, "action-start", "--action-id", "ACT-EVAL-001", "--kind", "external-write",
                "--target", "shared target", "--precondition", "target absent", "--postcondition", "target verified",
                "--idempotency-key", "eval-001",
            ), repo)
            run(progress_command(repo, "action-finish", "--action-id", "ACT-EVAL-001", "--status", "unknown_after_interruption", "--result", "simulated crash"), repo)
            run(progress_command(repo, "resume-check"), repo, expected=3)
            output = run(progress_command(repo, "action-finish", "--action-id", "ACT-EVAL-001", "--status", "succeeded", "--result", "guess"), repo, expected=1)
            self.assertIn("专用 verifier", output)
            state_path = repo / "docs" / "execution" / "state.json"
            state = load_json(state_path)
            state["inFlightAction"]["status"] = "running"
            state["actionStatus"] = "running"
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            events = load_jsonl(repo / "docs" / "execution" / "events.jsonl")
            evidence = load_jsonl(repo / "docs" / "execution" / "evidence.jsonl")
            (repo / "docs" / "execution" / "STATUS.md").write_text(render_status(state, events, evidence, repo, {}), encoding="utf-8")
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("status 与事件历史不一致", output)
            state["inFlightAction"]["status"] = "unknown_after_interruption"
            state["inFlightAction"] = None
            state["actionStatus"] = "none"
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("事件历史仍有未决 action", output)

    def test_reconcile_repairs_only_valid_tail_drift(self):
        with tempfile.TemporaryDirectory(prefix="olp-reconcile-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            state = load_json(repo / "docs" / "execution" / "state.json")
            events_path = repo / "docs" / "execution" / "events.jsonl"
            events = load_jsonl(events_path)
            extra = ledger_record(events, "long-task.execution-event", "EVT-0002", {
                "timestamp": utc_now(),
                "runId": state["run"]["runId"],
                "attempt": state["run"]["attempt"],
                "eventType": "note",
                "phaseId": state["activePhase"]["id"],
                "sliceId": state["activeSlice"]["id"],
                "summary": "simulated append before state write",
                "git": {
                    "observedHead": state["git"]["observedHead"],
                    "workingTreeFingerprint": state["git"]["workingTreeFingerprint"],
                },
                "evidenceIds": [],
            })
            with events_path.open("a", encoding="utf-8", newline="\n") as handle:
                handle.write(json.dumps(extra, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n")
            run(progress_command(repo, "note", "--summary", "must not silently align"), repo, expected=1)
            run(progress_command(repo, "reconcile", "--summary", "align valid interrupted tail", "--increment-attempt"), repo)
            run(audit_command(repo), repo)

    def test_completed_without_evidence_fails(self):
        with tempfile.TemporaryDirectory(prefix="olp-completed-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            state_path = repo / "docs" / "execution" / "state.json"
            status_path = repo / "docs" / "execution" / "STATUS.md"
            events_path = repo / "docs" / "execution" / "events.jsonl"
            evidence_path = repo / "docs" / "execution" / "evidence.jsonl"
            state = load_json(state_path)
            state["overallStatus"] = "completed"
            state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            status_path.write_text(render_status(state, load_jsonl(events_path), load_jsonl(evidence_path), repo), encoding="utf-8")
            output = run(audit_command(repo), repo, expected=1)
            self.assertIn("completed", output)

    def test_writer_can_finish_project_without_manual_state_edits(self):
        with tempfile.TemporaryDirectory(prefix="olp-project-state-") as temp:
            repo = init_repo(Path(temp) / "repo")
            run(bootstrap_command(repo), repo)
            for criterion_id in ("P0-S1-C1", "P0-S1-C2", "P0-S1-C3"):
                run(progress_command(repo, "criterion-state", "--id", criterion_id, "--status", "not_required", "--note", "evaluation only"), repo)
            state = load_json(repo / "docs" / "execution" / "state.json")
            for gate_name in state["projectVerification"]:
                run(progress_command(repo, "gate", "--name", gate_name, "--status", "not_required", "--note", "evaluation only"), repo)
            run(progress_command(repo, "slice-state", "--phase-status", "passed", "--slice-status", "passed", "--summary", "evaluation slice complete"), repo)
            run(progress_command(repo, "project-state", "--status", "completed", "--summary", "evaluation project complete"), repo)
            state = load_json(repo / "docs" / "execution" / "state.json")
            self.assertEqual(state["overallStatus"], "completed")
            run(audit_command(repo), repo)


if __name__ == "__main__":
    unittest.main(verbosity=2)
