#!/usr/bin/env python3
"""Read-only integrity and freshness audit for a long-task scaffold."""

from __future__ import print_function

import argparse
import datetime as dt
from pathlib import Path
import re
import sys
from typing import Any, Dict, Iterable, List, Optional, Tuple

from continuity_core import (
    continuity_metadata_paths,
    ensure_git_root,
    evidence_current,
    file_sha256,
    git_snapshot,
    ledger_tail,
    load_json,
    load_jsonl,
    object_hash,
    parse_utc,
    render_status,
    run_git,
    safe_repo_path,
)


OVERALL = {"active", "blocked", "completed", "cancelled"}
PHASE = {"pending", "in_progress", "verifying", "passed", "blocked"}
SLICE = {"ready", "in_progress", "verifying", "passed", "blocked"}
ACTION = {"none", "running", "succeeded", "failed", "unknown_after_interruption"}
GATE = {"not_started", "observed", "passed", "failed", "blocked", "not_required", "stale"}
CRITERION = {"pending", "passed", "failed", "blocked", "not_required", "stale"}
RUNTIME_CATEGORIES = {"app_runtime", "live_action", "live_outcome", "multi_instance", "persistence", "failure_recovery", "external_state"}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="只读审计通用长任务台账")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--output-dir", default="docs/execution")
    parser.add_argument("--plan-path", default="docs/project-master-plan.md")
    return parser.parse_args()


def normalize_relative(value: str, label: str) -> str:
    normalized = value.replace("\\", "/").rstrip("/")
    if not normalized or normalized == "." or normalized.startswith("/"):
        raise RuntimeError("{} 必须是仓库内非根相对路径".format(label))
    return normalized


def signature(paths: Iterable[Path]) -> Dict[str, Tuple[bool, Optional[int], Optional[int], Optional[str]]]:
    result: Dict[str, Tuple[bool, Optional[int], Optional[int], Optional[str]]] = {}
    for path in paths:
        if path.is_file():
            stat = path.stat()
            result[str(path.resolve())] = (True, stat.st_size, stat.st_mtime_ns, file_sha256(path))
        elif path.is_dir():
            stat = path.stat()
            listing = "\n".join(sorted(item.name for item in path.iterdir()))
            import hashlib
            result[str(path.resolve())] = (True, len(listing), stat.st_mtime_ns, hashlib.sha256(listing.encode("utf-8")).hexdigest())
        else:
            result[str(path.resolve())] = (False, None, None, None)
    return result


def require_fields(record: Dict[str, Any], fields: Iterable[str], label: str, errors: List[str]) -> None:
    for field in fields:
        if field not in record or record.get(field) is None:
            errors.append("{} 缺少 {}".format(label, field))


def validate_chain(
    records: List[Dict[str, Any]],
    kind: str,
    label: str,
    required: Iterable[str],
    errors: List[str],
) -> None:
    previous_hash = None
    seen = set()
    for expected_seq, record in enumerate(records, 1):
        prefix = "{} seq {}".format(label, expected_seq)
        require_fields(record, required, prefix, errors)
        if record.get("kind") != kind:
            errors.append(prefix + " kind 无效")
        if record.get("schemaVersion") != 1:
            errors.append(prefix + " schemaVersion 无效")
        if record.get("seq") != expected_seq:
            errors.append("{} 序号不连续: got {}".format(prefix, record.get("seq")))
        record_id = record.get("id")
        if not isinstance(record_id, str) or not record_id:
            errors.append(prefix + " id 无效")
        elif record_id in seen:
            errors.append("{} 包含重复 id {}".format(label, record_id))
        seen.add(record_id)
        if record.get("prevHash") != previous_hash:
            errors.append(prefix + " prevHash 不匹配")
        if record.get("hash") != object_hash(record):
            errors.append(prefix + " hash 不匹配")
        previous_hash = record.get("hash")


def tail_matches(records: List[Dict[str, Any]], tail: Any) -> bool:
    if not isinstance(tail, dict):
        return False
    seq = tail.get("seq")
    if seq == 0:
        return tail == {"seq": 0, "id": None, "hash": None}
    if not isinstance(seq, int) or seq < 1 or seq > len(records):
        return False
    record = records[seq - 1]
    return tail == {"seq": record.get("seq"), "id": record.get("id"), "hash": record.get("hash")}


def validate_state_schema(state: Dict[str, Any], errors: List[str]) -> None:
    require_fields(
        state,
        ["kind", "schemaVersion", "continuityMode", "revision", "updatedAt", "projectName", "objective", "run", "git", "activePhase", "activeSlice", "projectVerification", "actionStatus", "eventTail", "evidenceTail", "runtime", "resume"],
        "state",
        errors,
    )
    if state.get("kind") != "long-task.execution-state" or state.get("schemaVersion") != 1:
        errors.append("state kind/schemaVersion 无效")
    if state.get("continuityMode") not in {"standard", "hardened"}:
        errors.append("state.continuityMode 必须是 standard/hardened")
    if state.get("continuityMode") == "hardened":
        controls = state.get("hardenedControls")
        if not isinstance(controls, dict) or not isinstance(controls.get("ready"), bool):
            errors.append("hardenedControls schema 无效")
    if not isinstance(state.get("revision"), int) or state.get("revision", 0) < 1:
        errors.append("state.revision 无效")
    try:
        parse_utc(state.get("updatedAt"))
    except Exception as exc:
        errors.append("state.updatedAt 无效: {}".format(exc))
    if state.get("overallStatus") not in OVERALL:
        errors.append("state.overallStatus 无效")
    phase = state.get("activePhase") or {}
    active = state.get("activeSlice") or {}
    if not isinstance(phase.get("id"), str) or phase.get("status") not in PHASE:
        errors.append("activePhase id/status 无效")
    if not isinstance(active.get("id"), str) or active.get("status") not in SLICE:
        errors.append("activeSlice id/status 无效")
    next_action = active.get("nextAction")
    if state.get("overallStatus") in {"active", "blocked"} and (
        not isinstance(next_action, str) or not next_action.strip()
    ):
        errors.append("active/blocked 项目必须提供非空 activeSlice.nextAction")
    if not isinstance(active.get("acceptanceCriteria"), list):
        errors.append("activeSlice.acceptanceCriteria 必须是 list")
    else:
        seen = set()
        for index, criterion in enumerate(active["acceptanceCriteria"], 1):
            if not isinstance(criterion, dict):
                errors.append("criterion {} 必须是 object".format(index))
                continue
            require_fields(criterion, ["id", "text", "status", "allowedCategories", "evidenceIds"], "criterion {}".format(index), errors)
            if criterion.get("id") in seen:
                errors.append("criterion id 重复: {}".format(criterion.get("id")))
            seen.add(criterion.get("id"))
            if criterion.get("status") not in CRITERION:
                errors.append("criterion {} status 无效".format(criterion.get("id")))
            if not isinstance(criterion.get("evidenceIds"), list):
                errors.append("criterion {} evidenceIds 无效".format(criterion.get("id")))
            if not isinstance(criterion.get("allowedCategories"), list) or not criterion.get("allowedCategories"):
                errors.append("criterion {} allowedCategories 无效".format(criterion.get("id")))
    if not isinstance(state.get("projectVerification"), dict):
        errors.append("projectVerification 必须是 object")
    else:
        for name, gate in state["projectVerification"].items():
            if (
                not isinstance(gate, dict)
                or gate.get("status") not in GATE
                or not isinstance(gate.get("evidenceIds"), list)
                or not isinstance(gate.get("allowedCategories"), list)
                or not gate.get("allowedCategories")
            ):
                errors.append("gate {} schema/status 无效".format(name))
    if state.get("actionStatus") not in ACTION:
        errors.append("state.actionStatus 无效")


def validate_evidence(
    records: List[Dict[str, Any]],
    state: Dict[str, Any],
    repo: Path,
    profiles: Dict[str, Dict[str, Any]],
    errors: List[str],
) -> None:
    for record in records:
        label = "evidence {}".format(record.get("id"))
        if record.get("status") not in {"passed", "failed", "observed", "blocked", "not_required"}:
            errors.append(label + " status 无效")
        try:
            parse_utc(record.get("capturedAt"))
        except Exception as exc:
            errors.append(label + " capturedAt 无效: {}".format(exc))
        started_at = record.get("startedAt")
        finished_at = record.get("finishedAt")
        if started_at is not None or finished_at is not None:
            try:
                started = parse_utc(started_at)
                finished = parse_utc(finished_at)
                if finished < started:
                    errors.append(label + " finishedAt 早于 startedAt")
            except Exception as exc:
                errors.append(label + " startedAt/finishedAt 无效: {}".format(exc))
        if record.get("status") == "passed":
            provenance = record.get("provenance") or {}
            if provenance.get("sourceUnchangedDuringRun") is False:
                errors.append(label + " passed 但验证期间源码发生变化")
            profile_name = provenance.get("profile")
            profile = profiles.get(profile_name)
            if not isinstance(profile, dict):
                errors.append(label + " 引用了不存在的 verification profile")
            else:
                if provenance.get("profileDigest") != object_hash(profile):
                    errors.append(label + " profileDigest 与当前 profiles.json 不一致")
                if record.get("command") != profile.get("command"):
                    errors.append(label + " command 与固定 profile 不一致")
                if record.get("category") != profile.get("category"):
                    errors.append(label + " category 与固定 profile 不一致")
            if not evidence_current(record, state, repo, profiles):
                errors.append(label + " passed 但不是当前可信证据")
            if record.get("category") in RUNTIME_CATEGORIES and not record.get("validUntil"):
                errors.append(label + " 运行/外部证据缺少 validUntil")


def validate_checkpoints(
    repo: Path,
    execution_dir: Path,
    state: Dict[str, Any],
    events: List[Dict[str, Any]],
    evidence: List[Dict[str, Any]],
    profiles: Dict[str, Dict[str, Any]],
    errors: List[str],
) -> List[Path]:
    checkpoint_dir = execution_dir / "checkpoints"
    paths = sorted(checkpoint_dir.glob("*.json")) if checkpoint_dir.is_dir() else []
    latest_meta = state.get("lastCheckpoint")
    if not latest_meta:
        errors.append("state.lastCheckpoint 缺失")
        return paths
    seen = set()
    latest = None
    checkpoint_numbers: Dict[str, int] = {}
    for path in paths:
        try:
            checkpoint = load_json(path)
        except Exception as exc:
            errors.append("checkpoint {} 解析失败: {}".format(path.name, exc))
            continue
        checkpoint_id = checkpoint.get("id")
        if checkpoint_id in seen:
            errors.append("checkpoint id 重复: {}".format(checkpoint_id))
        seen.add(checkpoint_id)
        if checkpoint.get("kind") != "long-task.execution-checkpoint" or checkpoint.get("schemaVersion") != 1:
            errors.append("checkpoint {} kind/schema 无效".format(path.name))
        require_fields(checkpoint, ["id", "createdAt", "type", "reason", "run", "phase", "slice", "git", "eventTail", "evidenceTail", "permissions", "nextAction", "hash"], "checkpoint {}".format(path.name), errors)
        if checkpoint.get("type") not in {"state_snapshot", "git_checkpoint"}:
            errors.append("checkpoint {} type 无效".format(path.name))
        if not re.fullmatch(r"CP-[0-9]{4,}", str(checkpoint_id or "")):
            errors.append("checkpoint {} id 无效".format(path.name))
        else:
            checkpoint_numbers[str(checkpoint_id)] = int(str(checkpoint_id).split("-", 1)[1])
        try:
            parse_utc(checkpoint.get("createdAt"))
        except Exception as exc:
            errors.append("checkpoint {} createdAt 无效: {}".format(path.name, exc))
        if checkpoint.get("hash") != object_hash(checkpoint):
            errors.append("checkpoint {} 自哈希无效".format(path.name))
        if not tail_matches(events, checkpoint.get("eventTail")):
            errors.append("checkpoint {} eventTail 无效".format(path.name))
        if not tail_matches(evidence, checkpoint.get("evidenceTail")):
            errors.append("checkpoint {} evidenceTail 无效".format(path.name))
        permissions = checkpoint.get("permissions") or {}
        permission_keys = ("safeToResume", "canEdit", "canStartSideEffect", "canRunLive")
        if not all(key in permissions for key in permission_keys):
            errors.append("checkpoint {} permissions 不完整".format(path.name))
        elif not all(isinstance(permissions.get(key), bool) for key in permission_keys):
            errors.append("checkpoint {} permissions 必须是 boolean".format(path.name))
        if not isinstance(checkpoint.get("safeToResume"), bool) or not isinstance(checkpoint.get("safeToRunLive"), bool):
            errors.append("checkpoint {} safe flags 必须是 boolean".format(path.name))
        if checkpoint.get("safeToResume") != permissions.get("safeToResume"):
            errors.append("checkpoint {} safeToResume 与 permissions 不一致".format(path.name))
        if checkpoint.get("safeToRunLive") != permissions.get("canRunLive"):
            errors.append("checkpoint {} safeToRunLive 与 permissions 不一致".format(path.name))
        if checkpoint.get("type") == "git_checkpoint":
            checkpoint_git = checkpoint.get("git") or {}
            if checkpoint_git.get("dirtyPaths"):
                errors.append("checkpoint {} git_checkpoint 包含产品 dirty path".format(path.name))
            if checkpoint_git.get("verifiedHead") != checkpoint_git.get("observedHead"):
                errors.append("checkpoint {} git_checkpoint 未绑定 verified HEAD".format(path.name))
            verified_ids = checkpoint_git.get("verifiedByEvidenceIds") or []
            evidence_by_id = {record.get("id"): record for record in evidence[: int((checkpoint.get("evidenceTail") or {}).get("seq") or 0)]}
            if not verified_ids or not all(
                evidence_current(evidence_by_id.get(evidence_id, {}), {"git": checkpoint_git}, repo, profiles)
                and profiles.get((evidence_by_id.get(evidence_id, {}).get("provenance") or {}).get("profile"), {}).get("verifiesHead") is True
                for evidence_id in verified_ids
            ):
                errors.append("checkpoint {} git_checkpoint 缺少有效 verifiesHead evidence".format(path.name))
        if checkpoint_id == latest_meta.get("id"):
            latest = (path, checkpoint)
    if latest is None:
        errors.append("state.lastCheckpoint 指向的 checkpoint 不存在")
    else:
        path, checkpoint = latest
        try:
            expected_path = safe_repo_path(repo, str(latest_meta.get("path") or ""), "lastCheckpoint.path")
            if expected_path != path.resolve():
                errors.append("state.lastCheckpoint.path 不匹配")
        except Exception as exc:
            errors.append("state.lastCheckpoint.path 无效: {}".format(exc))
        if latest_meta.get("hash") != checkpoint.get("hash"):
            errors.append("state.lastCheckpoint.hash 不一致")
        for key in ("type", "createdAt", "safeToResume", "safeToRunLive", "permissions"):
            if latest_meta.get(key) != checkpoint.get(key if key != "permissions" else "permissions"):
                errors.append("state.lastCheckpoint.{} 与 checkpoint 不一致".format(key))
    if checkpoint_numbers:
        highest_id = max(checkpoint_numbers, key=checkpoint_numbers.get)
        if latest_meta.get("id") != highest_id:
            errors.append("state.lastCheckpoint 回滚：未指向编号最高的 checkpoint {}".format(highest_id))
    return paths


def validate_hardened_controls(
    repo: Path,
    state: Dict[str, Any],
    evidence: List[Dict[str, Any]],
    profiles: Dict[str, Dict[str, Any]],
    errors: List[str],
) -> None:
    if state.get("continuityMode") != "hardened":
        return
    controls = state.get("hardenedControls")
    if not isinstance(controls, dict) or controls.get("ready") is not True:
        return
    errors.append("通用 audit 不授权 hardenedControls.ready；必须改用项目专用 writer + audit")
    return


def validate_action_history(events: List[Dict[str, Any]], state: Dict[str, Any], errors: List[str]) -> None:
    actions: Dict[str, Dict[str, Any]] = {}
    for event in events:
        event_type = event.get("eventType")
        if event_type not in {"action_intent", "action_result", "reconciliation"} or "action" not in event:
            continue
        action = event.get("action")
        if not isinstance(action, dict) or not action.get("actionId") or not action.get("status"):
            errors.append("{} {} 缺少结构化 action".format(event_type, event.get("id")))
            continue
        action_id = str(action["actionId"])
        if event_type == "action_intent":
            if action_id in actions and actions[action_id].get("status") in {"running", "unknown_after_interruption"}:
                errors.append("action {} 存在重复未决 intent".format(action_id))
            actions[action_id] = dict(action)
        else:
            if action_id not in actions:
                errors.append("action {} result 缺少先前 intent".format(action_id))
            actions[action_id] = dict(action)
    unresolved = [action for action in actions.values() if action.get("status") in {"running", "unknown_after_interruption"}]
    state_action = state.get("inFlightAction")
    if not state_action and unresolved:
        errors.append("事件历史仍有未决 action，但 state.inFlightAction 已清空")
    if state_action:
        matches = [action for action in unresolved if action.get("actionId") == state_action.get("actionId")]
        if len(matches) != 1:
            errors.append("state.inFlightAction 与事件历史不一致")
        elif matches[0].get("status") != state_action.get("status"):
            errors.append("state.inFlightAction status 与事件历史不一致")


def main() -> int:
    args = parse_args()
    repo = ensure_git_root(Path(args.repo).resolve())
    output_rel = normalize_relative(args.output_dir, "--output-dir")
    plan_rel = normalize_relative(args.plan_path, "--plan-path")
    execution_dir = safe_repo_path(repo, output_rel, "--output-dir")
    plan_path = safe_repo_path(repo, plan_rel, "--plan-path")
    state_path = execution_dir / "state.json"
    status_path = execution_dir / "STATUS.md"
    events_path = execution_dir / "events.jsonl"
    evidence_path = execution_dir / "evidence.jsonl"
    protocol_path = execution_dir / "PROTOCOL.md"
    profiles_path = execution_dir / "profiles.json"
    errors: List[str] = []
    warnings: List[str] = []

    if not state_path.exists():
        required = [plan_path, status_path]
        missing = [str(path) for path in required if not path.is_file()]
        partial = [path for path in (protocol_path, profiles_path, events_path, evidence_path) if path.exists()]
        for path in missing:
            errors.append("缺少轻量模式文件: {}".format(path))
        if partial:
            errors.append("检测到不完整 standard/hardened 台账: {}".format(", ".join(str(path) for path in partial)))
        if status_path.is_file():
            next_action = None
            for line in status_path.read_text(encoding="utf-8").splitlines():
                if line.startswith("- 唯一下一动作："):
                    next_action = line.split("：", 1)[1].strip()
                    break
            if not next_action:
                errors.append("轻量 STATUS.md 未提供非空唯一下一动作")
        if not (repo / "AGENTS.md").is_file():
            warnings.append("AGENTS.md 缺失")
        for warning in warnings:
            print("WARN: " + warning)
        for error in errors:
            print("ERROR: " + error)
        if errors:
            print("light long-task audit failed")
            return 1
        print("light long-task audit passed: plan/STATUS present, {} warning(s)".format(len(warnings)))
        return 0

    required = [state_path, status_path, events_path, evidence_path, protocol_path, profiles_path, plan_path]
    missing = [str(path) for path in required if not path.is_file()]
    if missing:
        for path in missing:
            print("ERROR: 缺少文件: " + path)
        return 1
    checkpoint_paths = sorted((execution_dir / "checkpoints").glob("*.json")) if (execution_dir / "checkpoints").is_dir() else []
    observed_paths = required + [execution_dir / "checkpoints"] + checkpoint_paths
    before = signature(observed_paths)
    try:
        state = load_json(state_path)
        events = load_jsonl(events_path)
        evidence = load_jsonl(evidence_path)
        profile_document = load_json(profiles_path)
    except Exception as exc:
        print("ERROR: 无法解析台账: {}".format(exc))
        return 1

    validate_state_schema(state, errors)
    if profile_document.get("kind") != "long-task.verification-profiles" or profile_document.get("schemaVersion") != 1:
        errors.append("profiles.json kind/schemaVersion 无效")
    profiles = profile_document.get("profiles")
    if not isinstance(profiles, dict):
        errors.append("profiles.json profiles 必须是 object")
        profiles = {}
    else:
        for name, profile in profiles.items():
            if not isinstance(name, str) or not name or not isinstance(profile, dict):
                errors.append("verification profile 名称/结构无效")
                continue
            command = profile.get("command")
            if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
                errors.append("profile {} command 无效".format(name))
            if profile.get("category") not in {"audit", "test", "build", "app_runtime", "live_action", "live_outcome", "foreground_unaffected", "multi_instance", "persistence", "failure_recovery", "external_state"}:
                errors.append("profile {} category 无效".format(name))
            if profile.get("verifiesHead") not in {None, True, False}:
                errors.append("profile {} verifiesHead 必须是 boolean".format(name))
            if profile.get("controlType") not in {None, "lease", "action"}:
                errors.append("profile {} controlType 无效".format(name))
            if profile.get("controlType") and profile.get("category") != "external_state":
                errors.append("control profile {} 必须使用 external_state category".format(name))
    validate_chain(
        events,
        "long-task.execution-event",
        "events",
        ["id", "timestamp", "runId", "attempt", "eventType", "phaseId", "sliceId", "summary", "git", "evidenceIds"],
        errors,
    )
    validate_chain(
        evidence,
        "long-task.execution-evidence",
        "evidence",
        ["id", "capturedAt", "category", "claim", "status", "command", "exitCode", "git", "artifacts", "provenance"],
        errors,
    )
    if state.get("eventTail") != ledger_tail(events):
        errors.append("state.eventTail 与 events 不一致")
    if state.get("evidenceTail") != ledger_tail(evidence):
        errors.append("state.evidenceTail 与 evidence 不一致")

    expected_metadata_paths = continuity_metadata_paths(output_rel, plan_rel)
    source_documents = state.get("sourceDocuments") or {}
    expected_sources = {
        "plan": plan_rel,
        "protocol": output_rel + "/PROTOCOL.md",
        "status": output_rel + "/STATUS.md",
        "profiles": output_rel + "/profiles.json",
    }
    for key, expected in expected_sources.items():
        if source_documents.get(key) != expected:
            errors.append("sourceDocuments.{} 与 CLI 路径不一致".format(key))
    metadata_paths = source_documents.get("metadataPaths")
    if metadata_paths != expected_metadata_paths:
        errors.append("sourceDocuments.metadataPaths 与 CLI 固定路径不一致")
        metadata_paths = expected_metadata_paths
    for item in metadata_paths:
        try:
            safe_repo_path(repo, item, "metadata path")
        except Exception as exc:
            errors.append("metadata path 无效: {}".format(exc))
    snapshot = git_snapshot(repo, output_rel, metadata_paths)
    for key in ("branch", "observedHead", "upstreamHead", "dirtyPaths", "dirtyEntries", "indexDiffSha256", "worktreeDiffSha256", "indexEntriesSha256", "metadataPaths", "workingTreeFingerprint"):
        if state.get("git", {}).get(key) != snapshot.get(key):
            errors.append("state.git.{} 与当前 Git 不一致".format(key))

    observed_head = str(state.get("git", {}).get("observedHead") or "")
    if not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", observed_head):
        errors.append("observedHead 不是完整 SHA-1/SHA-256 object id")
    elif run_git(repo, "cat-file", "-e", observed_head + "^{commit}", allow_failure=True) is None:
        errors.append("observedHead 不能解析为 commit")

    validate_evidence(evidence, state, repo, profiles, errors)
    validate_hardened_controls(repo, state, evidence, profiles, errors)
    verified_head = state.get("git", {}).get("verifiedHead")
    verified_ids = state.get("git", {}).get("verifiedByEvidenceIds")
    if verified_head is not None:
        evidence_by_id_for_head = {record.get("id"): record for record in evidence}
        if not isinstance(verified_ids, list) or not verified_ids or verified_head != state.get("git", {}).get("observedHead"):
            errors.append("verifiedHead 缺少当前 evidence 绑定或不是 observedHead")
        else:
            for evidence_id in verified_ids:
                record = evidence_by_id_for_head.get(evidence_id, {})
                profile = profiles.get((record.get("provenance") or {}).get("profile"), {})
                if not evidence_current(record, state, repo, profiles) or profile.get("verifiesHead") is not True:
                    errors.append("verifiedHead evidence {} 无效".format(evidence_id))
    elif verified_ids not in (None, []):
        errors.append("verifiedHead 为空但 verifiedByEvidenceIds 非空")
    checkpoint_paths = validate_checkpoints(repo, execution_dir, state, events, evidence, profiles, errors)
    observed_paths = required + [execution_dir / "checkpoints"] + checkpoint_paths

    evidence_by_id = {record.get("id"): record for record in evidence}
    for criterion in (state.get("activeSlice") or {}).get("acceptanceCriteria", []):
        if not isinstance(criterion, dict):
            continue
        if criterion.get("status") == "passed":
            allowed = criterion.get("allowedCategories") or []
            if not any(
                evidence_current(evidence_by_id.get(item, {}), state, repo, profiles)
                and evidence_by_id.get(item, {}).get("category") in allowed
                for item in criterion.get("evidenceIds", [])
            ):
                errors.append("passed criterion {} 缺少当前有效证据".format(criterion.get("id")))
    for gate_name, gate in (state.get("projectVerification") or {}).items():
        if isinstance(gate, dict) and gate.get("status") == "passed":
            allowed = gate.get("allowedCategories") or []
            records = [evidence_by_id.get(item, {}) for item in gate.get("evidenceIds", [])]
            if not records or not all(
                evidence_current(record, state, repo, profiles)
                and record.get("category") in allowed
                for record in records
            ):
                errors.append("passed gate {} 的证据无效或类别不匹配".format(gate_name))

    action = state.get("inFlightAction")
    if action is None and state.get("actionStatus") in {"running", "unknown_after_interruption"}:
        errors.append("actionStatus 表示未决但 inFlightAction 为空")
    if action is not None:
        if not isinstance(action, dict) or action.get("status") not in {"running", "unknown_after_interruption"}:
            errors.append("inFlightAction 状态无效")
        if state.get("actionStatus") != action.get("status"):
            errors.append("actionStatus 与 inFlightAction.status 不一致")
    validate_action_history(events, state, errors)

    if state.get("overallStatus") == "completed":
        if action:
            errors.append("completed 状态不能包含未决动作")
        if state.get("resume", {}).get("blockers"):
            errors.append("completed 状态不能包含 blocker")
        if (state.get("activePhase") or {}).get("status") != "passed" or (state.get("activeSlice") or {}).get("status") != "passed":
            errors.append("completed 要求 active phase/slice 均为 passed")
        criteria = (state.get("activeSlice") or {}).get("acceptanceCriteria", [])
        if any(item.get("status") not in {"passed", "not_required"} for item in criteria if isinstance(item, dict)):
            errors.append("completed 但仍有未通过验收条件")
        gates = (state.get("projectVerification") or {}).values()
        if any(item.get("status") not in {"passed", "not_required"} for item in gates if isinstance(item, dict)):
            errors.append("completed 但仍有未通过验收轴")

    runtime = state.get("runtime") or {}
    if runtime.get("observedAt"):
        try:
            age = (dt.datetime.now(dt.timezone.utc) - parse_utc(runtime.get("observedAt"))).total_seconds()
            if age > int(runtime.get("staleAfterSeconds", 300)):
                warnings.append("runtime observation 已过期 {:.0f}s".format(age))
        except Exception as exc:
            errors.append("runtime.observedAt 无效: {}".format(exc))

    try:
        expected_status = render_status(state, events, evidence, repo, profiles)
        if status_path.read_text(encoding="utf-8") != expected_status:
            errors.append("STATUS 不是 state/账本的精确投影")
    except Exception as exc:
        errors.append("STATUS 渲染/读取失败: {}".format(exc))

    agents_path = repo / "AGENTS.md"
    if not agents_path.is_file():
        warnings.append("AGENTS.md 缺失")
    else:
        try:
            if output_rel + "/STATUS.md" not in agents_path.read_text(encoding="utf-8").replace("\\", "/"):
                warnings.append("AGENTS.md 未直接链接 STATUS")
        except UnicodeError:
            warnings.append("AGENTS.md 不是 UTF-8，未检查 STATUS 链接")

    after = signature(observed_paths)
    if before != after:
        errors.append("审计读取期间台账发生并发变化，请重试")

    for warning in warnings:
        print("WARN: " + warning)
    for error in errors:
        print("ERROR: " + error)
    if errors:
        print("long-task audit failed: {} error(s), {} warning(s)".format(len(errors), len(warnings)))
        return 1
    print("long-task audit passed: {} event(s), {} evidence record(s), {} checkpoint(s), {} warning(s)".format(len(events), len(evidence), len(checkpoint_paths), len(warnings)))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("ERROR: {}".format(exc), file=sys.stderr)
        raise SystemExit(1)
