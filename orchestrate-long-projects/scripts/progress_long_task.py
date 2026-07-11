#!/usr/bin/env python3
"""Single-writer CLI for standard and hardened long-task ledgers."""

from __future__ import print_function

import argparse
import datetime as dt
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple

from continuity_core import (
    continuity_metadata_paths,
    FileLock,
    append_jsonl,
    atomic_write_json,
    atomic_write_text,
    ensure_git_root,
    evidence_current,
    file_sha256,
    git_private_path,
    git_snapshot,
    ledger_record,
    ledger_tail,
    load_json,
    load_jsonl,
    object_hash,
    parse_utc,
    render_status,
    safe_repo_path,
    sign_evidence,
    utc_now,
)


EVENT_TYPES = {
    "decision", "scope_change", "slice_start", "slice_state", "test_run",
    "runtime_observation", "blocker", "checkpoint", "commit", "push",
    "reconciliation", "action_intent", "action_result", "note",
}
EVIDENCE_CATEGORIES = {
    "audit", "test", "build", "app_runtime", "live_action", "live_outcome",
    "foreground_unaffected", "multi_instance", "persistence", "failure_recovery",
    "external_state",
}
GATE_STATUSES = {"not_started", "observed", "passed", "failed", "blocked", "not_required", "stale"}
CRITERION_STATUSES = {"pending", "failed", "blocked", "not_required", "stale"}
OVERALL_STATUSES = {"active", "blocked", "completed", "cancelled"}
RUNTIME_CATEGORIES = {
    "app_runtime", "live_action", "live_outcome", "foreground_unaffected",
    "multi_instance", "persistence", "failure_recovery", "external_state",
}
SIDE_EFFECT_CLASSES = {"none", "repository_write", "local_runtime", "external_read", "external_write", "destructive"}
EXTERNAL_SIDE_EFFECT_CLASSES = {"external_write", "destructive"}


class Context(object):
    def __init__(self, repo: Path, output_rel: str, plan_rel: str) -> None:
        self.repo = repo
        self.output_rel = output_rel
        self.plan_rel = plan_rel
        self.execution_dir = safe_repo_path(repo, output_rel, "--output-dir")
        self.state_path = self.execution_dir / "state.json"
        self.status_path = self.execution_dir / "STATUS.md"
        self.events_path = self.execution_dir / "events.jsonl"
        self.evidence_path = self.execution_dir / "evidence.jsonl"
        self.profiles_path = self.execution_dir / "profiles.json"
        self.checkpoint_dir = self.execution_dir / "checkpoints"
        self.lock_path = git_private_path(repo, "orchestrate-long-projects.lock")

    def load(self, allow_tail_drift: bool = False) -> Tuple[Dict[str, Any], List[Dict[str, Any]], List[Dict[str, Any]]]:
        required = [self.state_path, self.status_path, self.events_path, self.evidence_path, self.profiles_path]
        missing = [str(path) for path in required if not path.is_file()]
        if missing:
            raise RuntimeError("缺少 standard/hardened 台账文件:\n- " + "\n- ".join(missing))
        state = load_json(self.state_path)
        if state.get("continuityMode") not in {"standard", "hardened"}:
            raise RuntimeError("progress CLI 仅支持 standard/hardened 模式")
        events = load_jsonl(self.events_path)
        evidence = load_jsonl(self.evidence_path)
        validate_chain_for_write(events, "long-task.execution-event", "events")
        validate_chain_for_write(evidence, "long-task.execution-evidence", "evidence")
        if not allow_tail_drift and (
            state.get("eventTail") != ledger_tail(events)
            or state.get("evidenceTail") != ledger_tail(evidence)
        ):
            raise RuntimeError("state 与账本 tail 漂移；仅允许先运行 reconcile")
        return state, events, evidence

    def metadata_paths(self, state: Dict[str, Any]) -> List[str]:
        expected = continuity_metadata_paths(self.output_rel, self.plan_rel)
        source = state.get("sourceDocuments") or {}
        expected_sources = {
            "plan": self.plan_rel,
            "protocol": self.output_rel + "/PROTOCOL.md",
            "status": self.output_rel + "/STATUS.md",
            "profiles": self.output_rel + "/profiles.json",
        }
        for key, expected_value in expected_sources.items():
            if source.get(key) != expected_value:
                raise RuntimeError("state sourceDocuments.{} 与 CLI 路径不一致".format(key))
        value = source.get("metadataPaths")
        if value != expected:
            raise RuntimeError("state metadataPaths 与 CLI 固定路径不一致")
        return expected

    def snapshot(self, state: Dict[str, Any]) -> Dict[str, Any]:
        return git_snapshot(self.repo, self.output_rel, self.metadata_paths(state))


def normalize_relative(value: str, label: str = "path") -> str:
    normalized = value.replace("\\", "/").rstrip("/")
    if not normalized or normalized == "." or normalized.startswith("/"):
        raise RuntimeError("{} 必须是仓库内非根相对路径".format(label))
    return normalized


def next_id(records: List[Dict[str, Any]], prefix: str) -> str:
    maximum = 0
    pattern = re.compile(r"^{}-([0-9]+)$".format(re.escape(prefix)))
    for record in records:
        match = pattern.match(str(record.get("id") or ""))
        if match:
            maximum = max(maximum, int(match.group(1)))
    return "{}-{:04d}".format(prefix, maximum + 1)


def validate_chain_for_write(records: List[Dict[str, Any]], kind: str, label: str) -> None:
    previous_hash = None
    seen = set()
    for expected_seq, record in enumerate(records, 1):
        if record.get("kind") != kind or record.get("schemaVersion") != 1:
            raise RuntimeError("{} seq {} kind/schema 无效".format(label, expected_seq))
        if record.get("seq") != expected_seq or not record.get("id") or record.get("id") in seen:
            raise RuntimeError("{} seq/id 不连续或重复".format(label))
        seen.add(record.get("id"))
        if record.get("prevHash") != previous_hash or record.get("hash") != object_hash(record):
            raise RuntimeError("{} hash 链无效；禁止继续写入".format(label))
        previous_hash = record.get("hash")


def create_event(
    state: Dict[str, Any],
    events: List[Dict[str, Any]],
    event_type: str,
    summary: str,
    evidence_ids: Optional[List[str]] = None,
    detail: Optional[str] = None,
    extra: Optional[Dict[str, Any]] = None,
) -> Dict[str, Any]:
    payload: Dict[str, Any] = {
        "timestamp": utc_now(),
        "runId": state.get("run", {}).get("runId"),
        "attempt": state.get("run", {}).get("attempt"),
        "eventType": event_type,
        "phaseId": state.get("activePhase", {}).get("id"),
        "sliceId": state.get("activeSlice", {}).get("id"),
        "summary": summary,
        "git": {
            "observedHead": state.get("git", {}).get("observedHead"),
            "workingTreeFingerprint": state.get("git", {}).get("workingTreeFingerprint"),
        },
        "evidenceIds": list(evidence_ids or []),
    }
    if detail:
        payload["detail"] = detail
    if extra:
        payload.update(extra)
    return ledger_record(events, "long-task.execution-event", next_id(events, "EVT"), payload)


def persist(
    context: Context,
    state: Dict[str, Any],
    events: List[Dict[str, Any]],
    evidence: List[Dict[str, Any]],
    event: Optional[Dict[str, Any]] = None,
    evidence_record: Optional[Dict[str, Any]] = None,
) -> None:
    if evidence_record is not None:
        append_jsonl(context.evidence_path, evidence_record)
        evidence.append(evidence_record)
    if event is not None:
        append_jsonl(context.events_path, event)
        events.append(event)
    state["eventTail"] = ledger_tail(events)
    state["evidenceTail"] = ledger_tail(evidence)
    verified = state.get("git", {}).get("verifiedHead")
    verified_evidence = list(state.get("git", {}).get("verifiedByEvidenceIds") or [])
    state["git"] = context.snapshot(state)
    state["git"]["verifiedHead"] = verified
    state["git"]["verifiedByEvidenceIds"] = verified_evidence
    state["revision"] = int(state.get("revision", 0)) + 1
    state["updatedAt"] = utc_now()
    atomic_write_json(context.state_path, state)
    atomic_write_text(context.status_path, render_status(state, events, evidence, context.repo, load_profiles(context)))


def load_profiles(context: Context) -> Dict[str, Dict[str, Any]]:
    document = load_json(context.profiles_path)
    if document.get("kind") != "long-task.verification-profiles" or document.get("schemaVersion") != 1:
        raise RuntimeError("profiles.json kind/schemaVersion 无效")
    profiles = document.get("profiles")
    if not isinstance(profiles, dict):
        raise RuntimeError("profiles.json profiles 必须是 object")
    return profiles


def validate_profile(name: str, profile: Dict[str, Any], context: Context) -> Tuple[List[str], Path, str, int, List[str], Optional[int], bool, str]:
    command = profile.get("command")
    if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
        raise RuntimeError("profile {} command 必须是非空字符串数组".format(name))
    category = profile.get("category")
    if category not in EVIDENCE_CATEGORIES:
        raise RuntimeError("profile {} category 无效".format(name))
    cwd_raw = str(profile.get("cwd") or ".")
    cwd = context.repo if cwd_raw == "." else safe_repo_path(context.repo, cwd_raw, "profile cwd")
    if not cwd.is_dir():
        raise RuntimeError("profile {} cwd 不存在".format(name))
    timeout = int(profile.get("timeoutSeconds", 1800))
    if timeout < 1 or timeout > 86400:
        raise RuntimeError("profile {} timeoutSeconds 超出范围".format(name))
    artifacts = profile.get("requiredArtifacts") or []
    if not isinstance(artifacts, list) or not all(isinstance(item, str) and item for item in artifacts):
        raise RuntimeError("profile {} requiredArtifacts 无效".format(name))
    for artifact in artifacts:
        safe_repo_path(context.repo, artifact, "profile artifact")
    ttl = profile.get("ttlSeconds")
    if ttl is not None:
        ttl = int(ttl)
        if ttl < 1 or ttl > 604800:
            raise RuntimeError("profile {} ttlSeconds 超出范围".format(name))
    if category in RUNTIME_CATEGORIES and ttl is None:
        ttl = 300
    if profile.get("verifiesHead") not in {None, True, False}:
        raise RuntimeError("profile {} verifiesHead 必须是 boolean".format(name))
    if profile.get("controlType") not in {None, "lease", "action"}:
        raise RuntimeError("profile {} controlType 无效".format(name))
    if profile.get("controlType") and category != "external_state":
        raise RuntimeError("control profile {} 必须使用 external_state category".format(name))
    read_only = profile.get("readOnly")
    if not isinstance(read_only, bool):
        raise RuntimeError("profile {} 必须显式声明 boolean readOnly".format(name))
    side_effect_class = profile.get("sideEffectClass")
    if side_effect_class not in SIDE_EFFECT_CLASSES:
        raise RuntimeError("profile {} sideEffectClass 未知；拒绝执行".format(name))
    if read_only and side_effect_class not in {"none", "external_read"}:
        raise RuntimeError("profile {} readOnly 与 sideEffectClass 冲突".format(name))
    if not read_only and side_effect_class == "none":
        raise RuntimeError("profile {} 非只读却声明 sideEffectClass=none".format(name))
    external_authorization = profile.get("externalAuthorization")
    if side_effect_class in EXTERNAL_SIDE_EFFECT_CLASSES:
        if not isinstance(external_authorization, str) or not external_authorization.strip():
            raise RuntimeError("profile {} 执行外部/破坏性动作必须声明 externalAuthorization".format(name))
    elif external_authorization is not None:
        raise RuntimeError("profile {} 非外部写入不得声明 externalAuthorization".format(name))
    return command, cwd, category, timeout, artifacts, ttl, read_only, side_effect_class


def command_render(context: Context, _: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load(allow_tail_drift=True)
        if state.get("eventTail") != ledger_tail(events) or state.get("evidenceTail") != ledger_tail(evidence):
            raise RuntimeError("账本 tail 漂移；先运行 reconcile")
        persist(context, state, events, evidence)
    print("已刷新 state Git 投影和 STATUS")
    return 0


def command_note(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        if args.next_action:
            state["activeSlice"]["nextAction"] = args.next_action
        if args.blocker is not None:
            state["resume"]["blockers"] = list(args.blocker)
        if args.do_not is not None:
            state["resume"]["doNotDo"] = list(args.do_not)
        event = create_event(state, events, args.type, args.summary, detail=args.detail)
        persist(context, state, events, evidence, event=event)
    print("已记录 {}".format(event["id"]))
    return 0


def parse_criterion(value: str) -> Dict[str, Any]:
    if "=" not in value:
        raise RuntimeError("--criterion 格式必须是 ID|category[,category]=text")
    left, text = value.split("=", 1)
    if "|" not in left:
        raise RuntimeError("--criterion 缺少允许证据类别")
    criterion_id, raw_categories = left.split("|", 1)
    categories = [item.strip() for item in raw_categories.split(",") if item.strip()]
    if not criterion_id.strip() or not text.strip() or not categories:
        raise RuntimeError("--criterion 字段不能为空")
    unknown = sorted(set(categories) - EVIDENCE_CATEGORIES)
    if unknown:
        raise RuntimeError("--criterion 包含未知证据类别: {}".format(unknown))
    return {"id": criterion_id.strip(), "text": text.strip(), "status": "pending", "allowedCategories": categories, "evidenceIds": []}


def command_begin_slice(context: Context, args: argparse.Namespace) -> int:
    criteria = [parse_criterion(item) for item in (args.criterion or [])]
    if len({item["id"] for item in criteria}) != len(criteria):
        raise RuntimeError("验收条件 ID 重复")
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        if state.get("inFlightAction"):
            raise RuntimeError("存在未决副作用，不能开始新切片")
        state["activePhase"] = {"id": args.phase, "title": args.phase_title or args.phase, "status": "in_progress"}
        state["activeSlice"] = {
            "id": args.slice,
            "title": args.title,
            "status": "in_progress",
            "scope": list(args.scope or []),
            "nonGoals": list(args.non_goal or []),
            "safetyBoundaries": list(args.safety_boundary or []),
            "acceptanceCriteria": criteria,
            "nextAction": args.next_action,
        }
        state["resume"]["blockers"] = []
        event = create_event(state, events, "slice_start", "开始切片 {}：{}".format(args.slice, args.title))
        persist(context, state, events, evidence, event=event)
    print("已开始 {}".format(args.slice))
    return 0


def command_slice_state(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        criteria = state.get("activeSlice", {}).get("acceptanceCriteria", [])
        if args.slice_status == "passed" and any(item.get("status") not in {"passed", "not_required"} for item in criteria):
            raise RuntimeError("仍有未通过验收条件，不能把切片标为 passed")
        state["activePhase"]["status"] = args.phase_status
        state["activeSlice"]["status"] = args.slice_status
        if args.next_action:
            state["activeSlice"]["nextAction"] = args.next_action
        state["resume"]["blockers"] = list(args.blocker or [])
        event = create_event(state, events, "slice_state", args.summary)
        persist(context, state, events, evidence, event=event)
    print("已更新切片状态")
    return 0


def command_run_evidence(context: Context, args: argparse.Namespace) -> int:
    if args.authorization == "read_only":
        raise RuntimeError("read_only workflow 永不执行 run-evidence")
    profiles = load_profiles(context)
    profile = profiles.get(args.profile)
    if not isinstance(profile, dict):
        raise RuntimeError("未知 profile {}；先在 profiles.json 固定命令和验收类别".format(args.profile))
    command, cwd, category, profile_timeout, required_artifacts, ttl, read_only, side_effect_class = validate_profile(args.profile, profile, context)
    if side_effect_class in EXTERNAL_SIDE_EFFECT_CLASSES and args.authorization != "external_authorized":
        raise RuntimeError("外部/破坏性 profile 必须使用 --authorization external_authorized")
    with FileLock(context.lock_path):
        preflight_state, _, _ = context.load()
        validate_evidence_links(preflight_state, category, args.criterion or [], args.gate or [])
        preflight_snapshot = context.snapshot(preflight_state)
    timeout = args.timeout_seconds or profile_timeout
    log_dir = git_private_path(context.repo, "orchestrate-long-projects/logs")
    log_dir.mkdir(parents=True, exist_ok=True)
    log_name = "{}-{}-{}.log".format(utc_now().replace(":", "").replace("-", ""), args.profile, os.getpid())
    log_path = log_dir / log_name
    started_at = utc_now()
    with log_path.open("xb") as handle:
        creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
        process = subprocess.Popen(
            command,
            cwd=str(cwd),
            stdout=handle,
            stderr=subprocess.STDOUT,
            creationflags=creationflags,
            start_new_session=(os.name != "nt"),
        )
        try:
            exit_code = process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            handle.write(b"\nTIMEOUT: terminating owned process tree\n")
            handle.flush()
            if os.name == "nt":
                subprocess.run(
                    ["taskkill", "/PID", str(process.pid), "/T", "/F"],
                    check=False,
                    stdout=handle,
                    stderr=subprocess.STDOUT,
                )
            else:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
            exit_code = 124
        handle.flush()
        os.fsync(handle.fileno())
    finished_at = utc_now()

    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        validate_evidence_links(state, category, args.criterion or [], args.gate or [])
        snapshot = context.snapshot(state)
        source_unchanged = (
            preflight_snapshot.get("observedHead") == snapshot.get("observedHead")
            and preflight_snapshot.get("workingTreeFingerprint") == snapshot.get("workingTreeFingerprint")
        )
        artifacts: List[Dict[str, Any]] = [{
            "path": "git-private:orchestrate-long-projects/logs/" + log_name,
            "required": True,
            "sha256": file_sha256(log_path),
            "size": log_path.stat().st_size,
            "retention": "local-private",
        }]
        artifacts_ok = True
        for relative in required_artifacts:
            path = safe_repo_path(context.repo, relative, "profile artifact")
            exists = path.is_file()
            artifacts_ok = artifacts_ok and exists
            artifacts.append({
                "path": relative,
                "required": True,
                "sha256": file_sha256(path) if exists else None,
                "size": path.stat().st_size if exists else None,
            })
        status = "passed" if exit_code == 0 and artifacts_ok and source_unchanged else "failed"
        valid_until = None
        if ttl is not None:
            valid_until = (parse_utc(finished_at) + dt.timedelta(seconds=ttl)).replace(microsecond=0).isoformat().replace("+00:00", "Z")
        evidence_record = ledger_record(evidence, "long-task.execution-evidence", next_id(evidence, "EVD"), {
            "capturedAt": finished_at,
            "startedAt": started_at,
            "finishedAt": finished_at,
            "validUntil": valid_until,
            "category": category,
            "claim": args.claim,
            "status": status,
            "command": command,
            "cwd": "." if cwd == context.repo else cwd.relative_to(context.repo).as_posix(),
            "exitCode": exit_code,
            "git": {
                "observedHead": snapshot.get("observedHead"),
                "workingTreeFingerprint": snapshot.get("workingTreeFingerprint"),
            },
            "gitBefore": {
                "observedHead": preflight_snapshot.get("observedHead"),
                "workingTreeFingerprint": preflight_snapshot.get("workingTreeFingerprint"),
            },
            "artifacts": artifacts,
            "provenance": {
                "captureMethod": "command_runner",
                "profile": args.profile,
                "profileDigest": object_hash(profile),
                "readOnly": read_only,
                "sideEffectClass": side_effect_class,
                "sourceUnchangedDuringRun": source_unchanged,
            },
        })
        evidence_record["runnerSignature"] = sign_evidence(context.repo, evidence_record)
        evidence_record["hash"] = object_hash(evidence_record)
        if status == "passed":
            for criterion_id in args.criterion or []:
                matches = [item for item in state["activeSlice"].get("acceptanceCriteria", []) if item.get("id") == criterion_id]
                if not matches:
                    raise RuntimeError("未知 criterion {}".format(criterion_id))
                criterion = matches[0]
                allowed = criterion.get("allowedCategories") or []
                if allowed and category not in allowed:
                    raise RuntimeError("criterion {} 不接受 {} 证据".format(criterion_id, category))
                if evidence_record["id"] not in criterion["evidenceIds"]:
                    criterion["evidenceIds"].append(evidence_record["id"])
                criterion["status"] = "passed"
            for gate_name in args.gate or []:
                gate = state.get("projectVerification", {}).get(gate_name)
                if not isinstance(gate, dict):
                    raise RuntimeError("未知 gate {}".format(gate_name))
                allowed = gate.get("allowedCategories") or []
                if category not in allowed:
                    raise RuntimeError("gate {} 不接受 {} 证据".format(gate_name, category))
                gate["status"] = "passed"
                gate["note"] = args.claim
                if evidence_record["id"] not in gate["evidenceIds"]:
                    gate["evidenceIds"].append(evidence_record["id"])
            verified_head = state.get("git", {}).get("verifiedHead")
            verified_evidence = list(state.get("git", {}).get("verifiedByEvidenceIds") or [])
            if profile.get("verifiesHead") is True:
                verified_head = snapshot.get("observedHead")
                verified_evidence = [evidence_record["id"]]
            state["git"] = dict(
                snapshot,
                verifiedHead=verified_head,
                verifiedByEvidenceIds=verified_evidence,
            )
        event = create_event(state, events, "test_run", "{}: {}".format(status, args.claim), [evidence_record["id"]])
        persist(context, state, events, evidence, event=event, evidence_record=evidence_record)
    print("{} {}；exit={}；log={}".format(evidence_record["id"], status, exit_code, log_path))
    return 0 if status == "passed" else 1


def command_criterion_state(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        matches = [
            item for item in state.get("activeSlice", {}).get("acceptanceCriteria", [])
            if item.get("id") == args.id
        ]
        if not matches:
            raise RuntimeError("未知 criterion {}".format(args.id))
        criterion = matches[0]
        criterion["status"] = args.status
        event = create_event(
            state,
            events,
            "decision",
            "更新验收条件 {} -> {}：{}".format(args.id, args.status, args.note),
            list(criterion.get("evidenceIds") or []),
        )
        persist(context, state, events, evidence, event=event)
    print("已更新 criterion {}".format(args.id))
    return 0


def command_project_state(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        existing_blockers = list(state.get("resume", {}).get("blockers") or [])
        if args.status == "blocked" and not (args.blocker or existing_blockers):
            raise RuntimeError("blocked 状态至少需要一个 blocker")
        if args.status in {"active", "completed"} and existing_blockers:
            raise RuntimeError("仍有 blocker，不能把项目标为 {}；先通过 note 明确清除".format(args.status))
        if args.status == "completed":
            if state.get("inFlightAction"):
                raise RuntimeError("存在未决动作，不能把项目标为 completed")
            if state.get("activePhase", {}).get("status") != "passed" or state.get("activeSlice", {}).get("status") != "passed":
                raise RuntimeError("completed 要求 active phase/slice 均为 passed")
            criteria = state.get("activeSlice", {}).get("acceptanceCriteria", [])
            if any(item.get("status") not in {"passed", "not_required"} for item in criteria):
                raise RuntimeError("completed 前仍有未通过验收条件")
            gates = state.get("projectVerification", {}).values()
            if any(item.get("status") not in {"passed", "not_required"} for item in gates):
                raise RuntimeError("completed 前仍有未通过验收轴")
        state["overallStatus"] = args.status
        if args.status == "blocked" and args.blocker:
            state["resume"]["blockers"] = list(args.blocker)
        event = create_event(
            state,
            events,
            "decision",
            "更新项目状态 -> {}：{}".format(args.status, args.summary),
        )
        persist(context, state, events, evidence, event=event)
    print("已更新项目状态 -> {}".format(args.status))
    return 0


def validate_evidence_links(
    state: Dict[str, Any],
    category: str,
    criterion_ids: Iterable[str],
    gate_names: Iterable[str],
) -> None:
    for criterion_id in criterion_ids:
        matches = [item for item in state.get("activeSlice", {}).get("acceptanceCriteria", []) if item.get("id") == criterion_id]
        if not matches:
            raise RuntimeError("未知 criterion {}".format(criterion_id))
        allowed = matches[0].get("allowedCategories") or []
        if category not in allowed:
            raise RuntimeError("criterion {} 不接受 {} 证据".format(criterion_id, category))
    for gate_name in gate_names:
        gate = state.get("projectVerification", {}).get(gate_name)
        if not isinstance(gate, dict):
            raise RuntimeError("未知 gate {}".format(gate_name))
        if category not in (gate.get("allowedCategories") or []):
            raise RuntimeError("gate {} 不接受 {} 证据".format(gate_name, category))


def command_gate(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        gate = state.get("projectVerification", {}).get(args.name)
        if not isinstance(gate, dict):
            raise RuntimeError("未知 gate {}".format(args.name))
        evidence_by_id = {item.get("id"): item for item in evidence}
        ids = list(args.evidence or [])
        profiles = load_profiles(context)
        if args.status == "passed":
            allowed = gate.get("allowedCategories") or []
            records = [evidence_by_id.get(item, {}) for item in ids]
            if not records or not all(
                evidence_current(record, state, context.repo, profiles)
                and record.get("category") in allowed
                for record in records
            ):
                raise RuntimeError("passed gate 的全部证据必须当前有效且类别匹配")
        gate.update({"status": args.status, "note": args.note, "evidenceIds": ids})
        event = create_event(state, events, "decision", "更新验收轴 {} -> {}".format(args.name, args.status), ids)
        persist(context, state, events, evidence, event=event)
    print("已更新 gate {}".format(args.name))
    return 0


def command_action_start(context: Context, args: argparse.Namespace) -> int:
    if not re.fullmatch(r"ACT-[A-Za-z0-9._-]+", args.action_id):
        raise RuntimeError("action-id 必须匹配 ACT-[A-Za-z0-9._-]+")
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        if state.get("continuityMode") != "hardened":
            raise RuntimeError("高风险 action intent 仅允许 hardened 模式；先升级连续性级别")
        if state.get("inFlightAction"):
            raise RuntimeError("已有未决动作，禁止开始新动作")
        action = {
            "actionId": args.action_id,
            "kind": args.kind,
            "status": "running",
            "targetIdentity": args.target,
            "precondition": args.precondition,
            "postcondition": args.postcondition,
            "idempotencyKey": args.idempotency_key,
            "owner": state.get("run", {}).get("owner"),
            "ownershipEvidence": list(args.ownership_evidence or []),
            "startedAt": utc_now(),
        }
        state["actionStatus"] = "running"
        state["inFlightAction"] = action
        event = create_event(
            state,
            events,
            "action_intent",
            "开始副作用 {} -> {}".format(args.action_id, args.target),
            extra={"action": dict(action)},
        )
        persist(context, state, events, evidence, event=event)
    print("已记录 intent {}；执行前仍需用户授权、checkpoint 和项目专用控制门".format(args.action_id))
    return 0


def command_action_finish(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        action = state.get("inFlightAction")
        if not isinstance(action, dict) or action.get("actionId") != args.action_id:
            raise RuntimeError("当前未决动作不是 {}".format(args.action_id))
        if action.get("status") == "unknown_after_interruption":
            raise RuntimeError("unknown_after_interruption 必须由项目专用 verifier 对账，通用 CLI 不解锁")
        if args.status == "unknown_after_interruption":
            action["status"] = args.status
            action["result"] = args.result
            action["finishedAt"] = utc_now()
            state["actionStatus"] = args.status
        else:
            state["actionStatus"] = args.status
            action["status"] = args.status
            action["result"] = args.result
            action["finishedAt"] = utc_now()
            state["lastAction"] = action
            state["inFlightAction"] = None
        event = create_event(
            state,
            events,
            "action_result",
            "动作 {} -> {}：{}".format(args.action_id, args.status, args.result),
            extra={"action": dict(action)},
        )
        persist(context, state, events, evidence, event=event)
    print("已记录动作结果 {}".format(args.status))
    return 0


def command_runtime_observe(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        state["runtime"]["observedAt"] = utc_now()
        state["runtime"]["staleAfterSeconds"] = args.stale_after_seconds
        state["runtime"]["summary"] = args.summary
        event = create_event(state, events, "runtime_observation", args.summary)
        persist(context, state, events, evidence, event=event)
    print("已更新运行观察；这不等于真实业务通过")
    return 0


def next_checkpoint_number(context: Context) -> int:
    maximum = 0
    if context.checkpoint_dir.is_dir():
        for path in context.checkpoint_dir.glob("CP-*.json"):
            match = re.match(r"^CP-([0-9]+)", path.name)
            if match:
                maximum = max(maximum, int(match.group(1)))
    return maximum + 1


def command_checkpoint(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load()
        if args.safe_to_run_live:
            raise RuntimeError("通用 CLI 不授权真实副作用；由项目专用 writer/verifier 创建 live checkpoint")
        if args.safe_to_resume and state.get("inFlightAction"):
            raise RuntimeError("存在未决动作，不能声明 safeToResume")
        current_snapshot = context.snapshot(state)
        if args.type == "git_checkpoint":
            if current_snapshot.get("dirtyPaths"):
                raise RuntimeError("git_checkpoint 要求产品工作树无 dirty path")
            if state.get("git", {}).get("verifiedHead") != current_snapshot.get("observedHead"):
                raise RuntimeError("git_checkpoint 要求 verifiedHead 等于当前 HEAD")
            profiles = load_profiles(context)
            evidence_by_id = {record.get("id"): record for record in evidence}
            verified_ids = state.get("git", {}).get("verifiedByEvidenceIds") or []
            if not verified_ids or not all(
                evidence_current(evidence_by_id.get(evidence_id, {}), state, context.repo, profiles)
                and profiles.get((evidence_by_id.get(evidence_id, {}).get("provenance") or {}).get("profile"), {}).get("verifiesHead") is True
                for evidence_id in verified_ids
            ):
                raise RuntimeError("git_checkpoint 缺少当前有效 verifiesHead evidence")
        event = create_event(state, events, "checkpoint", "创建 checkpoint：{}".format(args.reason))
        append_jsonl(context.events_path, event)
        events.append(event)
        state["eventTail"] = ledger_tail(events)
        state["evidenceTail"] = ledger_tail(evidence)
        verified = state.get("git", {}).get("verifiedHead")
        verified_evidence = list(state.get("git", {}).get("verifiedByEvidenceIds") or [])
        state["git"] = current_snapshot
        state["git"]["verifiedHead"] = verified
        state["git"]["verifiedByEvidenceIds"] = verified_evidence
        runtime_fresh = False
        if state.get("runtime", {}).get("observedAt"):
            runtime_fresh = (dt.datetime.now(dt.timezone.utc) - parse_utc(state["runtime"]["observedAt"])).total_seconds() <= int(state["runtime"].get("staleAfterSeconds", 300))
        can_edit = args.safe_to_resume and state.get("inFlightAction") is None and not state.get("resume", {}).get("blockers")
        can_side_effect = False
        can_live = False
        checkpoint_id = "CP-{:04d}".format(next_checkpoint_number(context))
        checkpoint: Dict[str, Any] = {
            "kind": "long-task.execution-checkpoint",
            "schemaVersion": 1,
            "id": checkpoint_id,
            "createdAt": utc_now(),
            "type": args.type,
            "reason": args.reason,
            "run": state.get("run"),
            "phase": state.get("activePhase"),
            "slice": state.get("activeSlice"),
            "git": state.get("git"),
            "eventTail": state.get("eventTail"),
            "evidenceTail": state.get("evidenceTail"),
            "inFlightAction": state.get("inFlightAction"),
            "permissions": {
                "safeToResume": args.safe_to_resume,
                "canEdit": can_edit,
                "canStartSideEffect": can_side_effect,
                "canRunLive": can_live,
            },
            "safeToResume": args.safe_to_resume,
            "safeToRunLive": can_live,
            "nextAction": state.get("activeSlice", {}).get("nextAction"),
        }
        checkpoint["hash"] = object_hash(checkpoint)
        label = re.sub(r"[^A-Za-z0-9._-]+", "-", args.label).strip("-") or "checkpoint"
        path = context.checkpoint_dir / "{}-{}.json".format(checkpoint_id, label)
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open("x", encoding="utf-8", newline="\n") as handle:
            json.dump(checkpoint, handle, ensure_ascii=False, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        state["lastCheckpoint"] = {
            "id": checkpoint_id,
            "path": path.relative_to(context.repo).as_posix(),
            "type": args.type,
            "createdAt": checkpoint["createdAt"],
            "safeToResume": args.safe_to_resume,
            "safeToRunLive": can_live,
            "permissions": checkpoint["permissions"],
            "hash": checkpoint["hash"],
        }
        state["revision"] = int(state.get("revision", 0)) + 1
        state["updatedAt"] = utc_now()
        atomic_write_json(context.state_path, state)
        atomic_write_text(context.status_path, render_status(state, events, evidence, context.repo, load_profiles(context)))
    print("已创建 {}".format(path))
    return 0


def command_reconcile(context: Context, args: argparse.Namespace) -> int:
    with FileLock(context.lock_path):
        state, events, evidence = context.load(allow_tail_drift=True)
        action = state.get("inFlightAction")
        if isinstance(action, dict) and action.get("status") == "running":
            action["status"] = "unknown_after_interruption"
            action["interruptedAt"] = utc_now()
            state["actionStatus"] = "unknown_after_interruption"
        state["run"]["attempt"] = int(state.get("run", {}).get("attempt", 0)) + 1
        if args.thread_id:
            state["run"]["previousThreadId"] = state["run"].get("threadId")
            state["run"]["threadId"] = args.thread_id
        if args.next_action:
            state["activeSlice"]["nextAction"] = args.next_action
        state["eventTail"] = ledger_tail(events)
        state["evidenceTail"] = ledger_tail(evidence)
        event = create_event(
            state,
            events,
            "reconciliation",
            args.summary,
            extra={"action": dict(state["inFlightAction"])} if state.get("inFlightAction") else None,
        )
        persist(context, state, events, evidence, event=event)
    print("已完成 reconciliation；未决 unknown 动作仍保持阻塞")
    return 0


def file_signature(paths: Iterable[Path]) -> Dict[str, Tuple[bool, Optional[int], Optional[int], Optional[str]]]:
    result = {}
    for path in paths:
        if path.is_file():
            stat = path.stat()
            result[str(path)] = (True, stat.st_size, stat.st_mtime_ns, file_sha256(path))
        else:
            result[str(path)] = (False, None, None, None)
    return result


def command_resume_check(context: Context, args: argparse.Namespace) -> int:
    if not context.state_path.exists():
        paths = [context.status_path, context.events_path, context.evidence_path, context.profiles_path]
        before = file_signature(paths)
        reasons = []
        if not context.status_path.is_file():
            reasons.append("轻量 STATUS.md 缺失")
        partial = [path.name for path in (context.events_path, context.evidence_path, context.profiles_path) if path.exists()]
        if partial:
            reasons.append("检测到不完整 standard/hardened 文件: {}".format(", ".join(partial)))
        next_action = None
        if context.status_path.is_file():
            for line in context.status_path.read_text(encoding="utf-8").splitlines():
                if line.startswith("- 唯一下一动作："):
                    next_action = line.split("：", 1)[1].strip()
                    break
        if not next_action:
            reasons.append("轻量 STATUS.md 未提供非空唯一下一动作")
        if before != file_signature(paths):
            reasons.append("读取期间轻量状态发生变化")
        decision = "blocked" if reasons else "light_manual_review"
        report = {
            "decision": decision,
            "reasons": reasons,
            "phase": None,
            "slice": None,
            "nextAction": next_action,
            "technicalGates": {
                "technicallySafeToEdit": None,
                "canStartSideEffect": False,
                "canRunLive": False,
            },
        }
        if args.json:
            print(json.dumps(report, ensure_ascii=False, indent=2))
        else:
            print("resume-check: {}".format(decision))
            for reason in reasons:
                print("- " + reason)
            if not reasons:
                print("- 轻量模式无机器 state；继续前仍需完整 audit、Git 核验和用户 repo_write 授权")
                print("- 下一动作: {}".format(next_action))
        return 0 if not reasons else 3

    paths = [context.state_path, context.status_path, context.events_path, context.evidence_path, context.profiles_path]
    before = file_signature(paths)
    reasons: List[str] = []
    next_action = None
    try:
        state, events, evidence = context.load(allow_tail_drift=True)
        if state.get("eventTail") != ledger_tail(events):
            reasons.append("event tail 漂移")
        if state.get("evidenceTail") != ledger_tail(evidence):
            reasons.append("evidence tail 漂移")
        snapshot = context.snapshot(state)
        if state.get("git", {}).get("workingTreeFingerprint") != snapshot.get("workingTreeFingerprint") or state.get("git", {}).get("observedHead") != snapshot.get("observedHead"):
            reasons.append("Git/工作树与 state 不一致")
        action = state.get("inFlightAction")
        if action:
            reasons.append("存在未决动作 {} ({})".format(action.get("actionId"), action.get("status")))
        for blocker in state.get("resume", {}).get("blockers", []):
            reasons.append("blocker: {}".format(blocker))
        next_action = state.get("activeSlice", {}).get("nextAction")
        if state.get("overallStatus") in {"active", "blocked"} and (
            not isinstance(next_action, str) or not next_action.strip()
        ):
            reasons.append("active/blocked 项目缺少非空唯一下一动作")
        checkpoint = state.get("lastCheckpoint") or {}
        if checkpoint.get("safeToResume") is not True:
            reasons.append("最新 checkpoint 未声明 safeToResume")
        profiles = load_profiles(context)
        checkpoint_path = safe_repo_path(context.repo, str(checkpoint.get("path") or ""), "lastCheckpoint.path")
        if not checkpoint_path.is_file():
            reasons.append("最新 checkpoint 文件缺失")
        else:
            checkpoint_value = load_json(checkpoint_path)
            if checkpoint_value.get("hash") != checkpoint.get("hash") or checkpoint_value.get("hash") != object_hash(checkpoint_value):
                reasons.append("最新 checkpoint hash 不一致")
            if checkpoint.get("permissions") != checkpoint_value.get("permissions"):
                reasons.append("最新 checkpoint 技术门禁投影不一致")
            technical = checkpoint_value.get("permissions") or {}
            if not all(isinstance(technical.get(key), bool) for key in ("safeToResume", "canEdit", "canStartSideEffect", "canRunLive")):
                reasons.append("最新 checkpoint 技术门禁不是 boolean")
            if checkpoint.get("safeToResume") != checkpoint_value.get("safeToResume") or checkpoint.get("safeToRunLive") != checkpoint_value.get("safeToRunLive"):
                reasons.append("最新 checkpoint safe flags 投影不一致")
        checkpoint_ids = []
        if context.checkpoint_dir.is_dir():
            for path in context.checkpoint_dir.glob("CP-*.json"):
                match = re.match(r"^CP-([0-9]+)", path.name)
                if match:
                    checkpoint_ids.append((int(match.group(1)), "CP-{:04d}".format(int(match.group(1)))))
        if checkpoint_ids and checkpoint.get("id") != max(checkpoint_ids)[1]:
            reasons.append("lastCheckpoint 未指向编号最高的 checkpoint")
        evidence_by_id = {record.get("id"): record for record in evidence}
        for gate_name, gate in state.get("projectVerification", {}).items():
            if gate.get("status") == "passed":
                allowed = gate.get("allowedCategories") or []
                records = [evidence_by_id.get(item, {}) for item in gate.get("evidenceIds", [])]
                if not records or not all(
                    evidence_current(record, state, context.repo, profiles)
                    and record.get("category") in allowed
                    for record in records
                ):
                    reasons.append("passed gate {} 的 evidence 已失效".format(gate_name))
        if context.status_path.read_text(encoding="utf-8") != render_status(state, events, evidence, context.repo, profiles):
            reasons.append("STATUS 投影不一致")
    except Exception as exc:
        state = {}
        reasons.append("读取失败: {}".format(exc))
    after = file_signature(paths)
    if before != after:
        reasons.append("读取期间状态并发变化")
    decision = "blocked" if reasons else "safe_for_code_only"
    report = {
        "decision": decision,
        "reasons": reasons,
        "phase": state.get("activePhase", {}).get("id") if state else None,
        "slice": state.get("activeSlice", {}).get("id") if state else None,
        "nextAction": next_action,
        "technicalGates": {
            "technicallySafeToEdit": not reasons,
            "canStartSideEffect": False,
            "canRunLive": False,
        },
    }
    if args.json:
        print(json.dumps(report, ensure_ascii=False, indent=2))
    else:
        print("resume-check: {}".format(decision))
        for reason in reasons:
            print("- " + reason)
        if not reasons:
            print("- 技术上可继续代码/文档切片；这不等于用户 repo_write 授权")
            print("- 真实副作用仍需独立用户授权和项目专用门禁")
            print("- 下一动作: {}".format(report["nextAction"]))
    return 0 if not reasons else 3


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="更新 standard/hardened 长任务台账")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--output-dir", default="docs/execution")
    parser.add_argument("--plan-path", default="docs/project-master-plan.md")
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    subparsers.add_parser("render", help="刷新 Git 投影和 STATUS")
    resume = subparsers.add_parser("resume-check", help="只读恢复判断，不写文件")
    resume.add_argument("--json", action="store_true")

    note = subparsers.add_parser("note", help="记录重要事件")
    note.add_argument("--type", choices=sorted(EVENT_TYPES), default="note")
    note.add_argument("--summary", required=True)
    note.add_argument("--detail")
    note.add_argument("--next-action")
    note.add_argument("--blocker", action="append")
    note.add_argument("--do-not", action="append")

    begin = subparsers.add_parser("begin-slice", help="开始一个有界纵向切片")
    begin.add_argument("--phase", required=True)
    begin.add_argument("--phase-title")
    begin.add_argument("--slice", required=True)
    begin.add_argument("--title", required=True)
    begin.add_argument("--next-action", required=True)
    begin.add_argument("--criterion", action="append")
    begin.add_argument("--scope", action="append")
    begin.add_argument("--non-goal", action="append")
    begin.add_argument("--safety-boundary", action="append")

    slice_state = subparsers.add_parser("slice-state", help="更新当前 phase/slice 状态")
    slice_state.add_argument("--phase-status", required=True, choices=["pending", "in_progress", "verifying", "passed", "blocked"])
    slice_state.add_argument("--slice-status", required=True, choices=["ready", "in_progress", "verifying", "passed", "blocked"])
    slice_state.add_argument("--summary", required=True)
    slice_state.add_argument("--next-action")
    slice_state.add_argument("--blocker", action="append")

    run = subparsers.add_parser("run-evidence", help="运行 profiles.json 中固定命令并记录真实退出码")
    run.add_argument("--profile", required=True)
    run.add_argument("--claim", required=True)
    run.add_argument("--criterion", action="append")
    run.add_argument("--gate", action="append")
    run.add_argument("--timeout-seconds", type=int)
    run.add_argument("--authorization", required=True, choices=["read_only", "repo_write", "external_authorized"], help="当前 workflow 的明确执行授权")

    gate = subparsers.add_parser("gate", help="用已有证据更新一个验收轴")
    gate.add_argument("--name", required=True)
    gate.add_argument("--status", required=True, choices=sorted(GATE_STATUSES))
    gate.add_argument("--note", required=True)
    gate.add_argument("--evidence", action="append")

    criterion_state = subparsers.add_parser("criterion-state", help="更新验收条件的非通过状态；passed 必须由 run-evidence 产生")
    criterion_state.add_argument("--id", required=True)
    criterion_state.add_argument("--status", required=True, choices=sorted(CRITERION_STATUSES))
    criterion_state.add_argument("--note", required=True)

    project_state = subparsers.add_parser("project-state", help="更新项目总体状态")
    project_state.add_argument("--status", required=True, choices=sorted(OVERALL_STATUSES))
    project_state.add_argument("--summary", required=True)
    project_state.add_argument("--blocker", action="append")

    action_start = subparsers.add_parser("action-start", help="在高风险副作用前持久化 intent")
    action_start.add_argument("--action-id", required=True)
    action_start.add_argument("--kind", required=True)
    action_start.add_argument("--target", required=True)
    action_start.add_argument("--precondition", required=True)
    action_start.add_argument("--postcondition", required=True)
    action_start.add_argument("--idempotency-key", required=True)
    action_start.add_argument("--ownership-evidence", action="append")

    action_finish = subparsers.add_parser("action-finish", help="记录正在运行动作的结果")
    action_finish.add_argument("--action-id", required=True)
    action_finish.add_argument("--status", required=True, choices=["succeeded", "failed", "unknown_after_interruption"])
    action_finish.add_argument("--result", required=True)

    runtime = subparsers.add_parser("runtime-observe", help="登记当前运行观察时间和摘要")
    runtime.add_argument("--summary", required=True)
    runtime.add_argument("--stale-after-seconds", type=int, default=300)

    checkpoint = subparsers.add_parser("checkpoint", help="创建不可覆盖恢复快照")
    checkpoint.add_argument("--label", required=True)
    checkpoint.add_argument("--type", choices=["state_snapshot", "git_checkpoint"], required=True)
    checkpoint.add_argument("--reason", required=True)
    checkpoint.add_argument("--safe-to-resume", action="store_true")
    checkpoint.add_argument("--safe-to-run-live", action="store_true")

    reconcile = subparsers.add_parser("reconcile", help="中断后对齐 tail/Git 并开启新 attempt")
    reconcile.add_argument("--summary", required=True)
    reconcile.add_argument("--next-action")
    reconcile.add_argument("--thread-id")
    reconcile.add_argument("--increment-attempt", action="store_true")
    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    repo = ensure_git_root(Path(args.repo).resolve())
    context = Context(
        repo,
        normalize_relative(args.output_dir, "--output-dir"),
        normalize_relative(args.plan_path, "--plan-path"),
    )
    handlers = {
        "render": command_render,
        "resume-check": command_resume_check,
        "note": command_note,
        "begin-slice": command_begin_slice,
        "slice-state": command_slice_state,
        "run-evidence": command_run_evidence,
        "gate": command_gate,
        "criterion-state": command_criterion_state,
        "project-state": command_project_state,
        "action-start": command_action_start,
        "action-finish": command_action_finish,
        "runtime-observe": command_runtime_observe,
        "checkpoint": command_checkpoint,
        "reconcile": command_reconcile,
    }
    return handlers[args.command_name](context, args)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("progress failed: {}".format(exc), file=sys.stderr)
        raise SystemExit(1)
