#!/usr/bin/env python3
"""Create or resume a non-overwriting long-task continuity scaffold."""

from __future__ import print_function

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import sys
from typing import Any, Dict, List, Optional

from continuity_core import (
    FileLock,
    atomic_write_json,
    continuity_metadata_paths,
    ensure_git_root,
    ensure_evidence_key,
    file_sha256,
    git_private_path,
    git_snapshot,
    ledger_record,
    ledger_tail,
    object_hash,
    render_status,
    repo_relative,
    run_git,
    safe_repo_path,
    utc_now,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="建立或恢复通用长任务主方案和连续性台账")
    parser.add_argument("--repo", required=True)
    parser.add_argument("--project-name")
    parser.add_argument("--objective")
    parser.add_argument("--mode", choices=["light", "standard", "hardened"], default="light")
    parser.add_argument("--output-dir", default="docs/execution")
    parser.add_argument("--plan-path", default="docs/project-master-plan.md")
    parser.add_argument("--thread-id")
    parser.add_argument("--previous-thread-id")
    parser.add_argument("--include-agents", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--resume-bootstrap", action="store_true")
    return parser.parse_args()


def normalize_relative(value: str, label: str) -> str:
    normalized = value.replace("\\", "/").rstrip("/")
    if not normalized or normalized == "." or normalized.startswith("/"):
        raise RuntimeError("{} 必须是仓库内非根相对路径".format(label))
    if re.search(r"[\x00-\x1f\x7f\"'`$%&|;<>(){}!^]", normalized):
        raise RuntimeError("{} 含不允许写入交接命令的 shell 元字符".format(label))
    return normalized


def exclusive_write_bytes(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())


def plan_template(project_name: str, objective: str) -> str:
    return """# {name} 项目审计与实施总方案

> Living document。当前源码、Git、测试和实际运行结果高于本文历史描述。

## 1. 根本目标

{objective}

## 2. 非目标和安全边界

- TODO：本阶段不做什么。
- TODO：数据、权限、生产环境和外部副作用边界。

## 3. 当前事实与证据

- TODO：Git、运行环境、历史提交、现有功能和真实运行状态。

## 4. 完成度分轴

| 维度 | 状态 | 证据 | 缺口 |
|---|---|---|---|
| 代码表面能力 | not_started | none | 待审计 |
| 自动测试 | not_started | none | 待运行 |
| 当前构建 | not_started | none | 待运行 |
| 当前应用启动 | not_started | none | 待验证 |
| 真实业务后置状态 | not_started | none | 待验证 |
| 失败恢复/重启 | not_started | none | 待验证 |

## 5. 架构、调用链和数据流

TODO

## 6. 断链、重复和过时代码候选

TODO

## 7. 外部资料和参考项目

TODO：区分官方事实、成熟模式、社区报告和本项目推导。

## 8. 目标方案和关键决策

TODO

## 9. 阶段、纵向切片和 commit 边界

### P0 安全基线与可重复验证

TODO

### P1 最小用户纵向工作流

TODO

### P2 核心能力和失败恢复

TODO

### P3 多实例、持久化和发布门

TODO

## 10. 测试、构建、实机和失败矩阵

TODO

## 11. 风险、限制和待用户决策

TODO

## 12. Outcomes & Retrospective

TODO：每个阶段完成后更新。
""".format(name=project_name, objective=objective)


def light_plan_template(project_name: str, objective: str) -> str:
    return """# {name} 轻量执行计划

> 当前源码、Git、测试和实际运行结果高于本文历史描述。

## 目标与范围

{objective}

- 范围：TODO
- 非目标：TODO
- 安全边界：TODO

## 当前事实

- TODO：Git、入口、现有行为、测试和运行基线。

## 执行步骤

1. TODO：第一个用户可见纵向切片。
2. TODO：核心实现和错误路径。
3. TODO：完整验证、文档和交付审计。

## 验收与验证

| 条件 | 命令/操作 | 状态 |
|---|---|---|
| TODO | TODO | pending |

## 风险与待决问题

- TODO

## 当前下一动作

完成只读 Git、源码、测试入口和运行现场审计。
""".format(name=project_name, objective=objective)


def light_status_template(project_name: str, objective: str) -> str:
    return """# 长任务状态

> 轻量模式：主代理维护此页。跨天、多 Agent 或出现高风险副作用时升级为 standard/hardened。

## 当前

- 项目：{name}
- 目标：{objective}
- 状态：ready
- 最近完成：已建立 living plan 和轻量状态页
- 当前动作：none
- 唯一下一动作：完成只读 Git、源码、测试入口和运行现场审计
- blocker：none
- 允许：用户已授权范围内的产品/测试/项目文档修改；只读现场核验
- 禁止：未授权产品修改、外部副作用、归属不明清理

## 验收轴

| 维度 | 状态 | 证据/缺口 |
|---|---|---|
| 代码表面能力 | not_started | 待审计 |
| 自动测试 | not_started | 待运行 |
| 当前构建 | not_started | 待运行 |
| 当前应用启动 | not_started | 待验证 |
| 真实业务结果 | not_started | 待验证 |

## 下一次更新

完成可见小闭环、发现 blocker、用户 steer 或准备交接时更新本页。
""".format(name=project_name, objective=objective)


def protocol_template(mode: str) -> str:
    hardened = "\n- hardened 只提供本地意图账本；共享外部目标必须另做项目专用 lease 和 verifier。" if mode == "hardened" else ""
    return """# 长任务执行协议

## 开工

1. 读 AGENTS.md 和 STATUS。
2. 使用 `python -B` 运行只读 resume-check、完整 audit，并运行 `git --no-optional-locks status --short --ignored`。
3. 只有审计异常、未决副作用或 STATUS 指示时再读本协议全文。
4. 当前源码、Git、测试和实际运行结果优先于线程历史。

## 单写入器

- 只有主代理用 `progress_long_task.py` 写 state、events、evidence、STATUS 和 checkpoint。
- 子代理默认只读并返回文件、产物、网络、配置、进程、测试、commit 和清理摘要。

## 副作用

- 只有非幂等、共享资源或中断后可能重复伤害的动作强制 intent/result。
- 普通 commit 记录 hash；push 前后核对远端 ref；本地服务登记 PID、命令和归属。
- `unknown_after_interruption` 禁止用通用命令猜测解锁，必须由项目专用 verifier 对账。
- 不能证明属于本轮的对象不得清理。{hardened}

## 收尾

- 等待或中断所有子代理。
- 运行完整验证和 `git --no-optional-locks status --short --ignored`。
- 报告文件、产物、下载、配置、进程、清理、commit 和 push 状态。
""".format(hardened=hardened)


def agents_template(plan_rel: str, output_rel: str, mode: str) -> str:
    return """# Agent 工作入口

本仓库使用 {mode} 长任务管理。

开工顺序：

1. 读取 `{output}/STATUS.md`。
2. 运行只读 `python -B <skill-dir>/scripts/progress_long_task.py --repo <repo> --output-dir "{output}" --plan-path "{plan}" resume-check`、`python -B <skill-dir>/scripts/audit_long_task.py --repo <repo> --output-dir "{output}" --plan-path "{plan}"` 和 `git --no-optional-locks status --short --ignored`。
3. 审计允许继续后，只读 `{plan}` 当前阶段章节。
4. 当前源码、Git、测试和运行结果高于历史线程。

复杂状态通过 `$orchestrate-long-projects` 和配套脚本维护。不能证明属于本轮的文件、进程、页签和产物不得清理。
""".format(mode=mode, output=output_rel, plan=plan_rel)


def ensure_unique_targets(paths: Dict[str, Path]) -> None:
    by_path: Dict[str, List[str]] = {}
    for label, path in paths.items():
        by_path.setdefault(os.path.normcase(str(path.resolve())), []).append(label)
    collisions = [labels for labels in by_path.values() if len(labels) > 1]
    if collisions:
        raise RuntimeError("目标路径冲突: {}".format(collisions))
    items = list(paths.items())
    for index, (left_label, left_path) in enumerate(items):
        left = left_path.resolve()
        for right_label, right_path in items[index + 1:]:
            right = right_path.resolve()
            if left in right.parents or right in left.parents:
                raise RuntimeError("目标路径祖先冲突: {} <-> {}".format(left_label, right_label))


def build_state(args: argparse.Namespace, snapshot: Dict[str, Any], output_rel: str, plan_rel: str) -> Dict[str, Any]:
    run_id = "RUN-{}-{}".format(utc_now().replace(":", "").replace("-", "")[:15], secrets.token_hex(3).upper())
    state: Dict[str, Any] = {
        "kind": "long-task.execution-state",
        "schemaVersion": 1,
        "continuityMode": args.mode,
        "revision": 1,
        "updatedAt": utc_now(),
        "projectName": args.project_name,
        "objective": args.objective,
        "sourceDocuments": {
            "plan": plan_rel,
            "protocol": output_rel + "/PROTOCOL.md",
            "status": output_rel + "/STATUS.md",
            "profiles": output_rel + "/profiles.json",
            "metadataPaths": continuity_metadata_paths(output_rel, plan_rel),
        },
        "run": {
            "runId": run_id,
            "attempt": 1,
            "threadId": args.thread_id,
            "previousThreadId": args.previous_thread_id,
            "owner": "primary-agent",
        },
        "overallStatus": "active",
        "activePhase": {"id": "P0", "title": "安全基线与可重复验证", "status": "in_progress"},
        "activeSlice": {
            "id": "P0-S1",
            "title": "审计当前事实并建立第一组可信证据",
            "status": "ready",
            "scope": ["核对 Git、源码入口、测试、构建和运行现场", "完成主方案当前事实章节", "建立第一组绑定当前源码的验证证据"],
            "nonGoals": ["不在完成审计前大规模重构", "不执行未授权外部副作用", "不清理归属不明产物"],
            "safetyBoundaries": ["当前源码和运行结果高于旧文档", "高风险副作用前先记录 intent", "未知结果禁止重试"],
            "acceptanceCriteria": [
                {"id": "P0-S1-C1", "text": "当前 Git、源码、测试和运行事实已记录", "status": "pending", "allowedCategories": ["audit"], "evidenceIds": []},
                {"id": "P0-S1-C2", "text": "主方案完成当前事实、风险和下一阶段", "status": "pending", "allowedCategories": ["audit"], "evidenceIds": []},
                {"id": "P0-S1-C3", "text": "至少一组验证证据绑定当前源码指纹", "status": "pending", "allowedCategories": ["test", "build"], "evidenceIds": []},
            ],
            "nextAction": "完成只读 Git/源码/测试/运行现场审计，并更新主方案当前事实",
        },
        "projectVerification": {
            key: {"status": "not_started", "note": note, "allowedCategories": categories, "evidenceIds": []}
            for key, (note, categories) in {
                "codeSurface": ("待源码审计", ["audit", "test"]),
                "automated": ("待运行当前测试", ["test"]),
                "currentBuild": ("待构建", ["build"]),
                "currentRuntime": ("待启动当前版本", ["app_runtime"]),
                "liveOutcome": ("待真实后置验证", ["live_outcome"]),
                "foregroundOrExternalUnaffected": ("待验证", ["foreground_unaffected"]),
                "multiInstance": ("待验证", ["multi_instance"]),
                "restartPersistence": ("待验证", ["persistence"]),
                "failureRecovery": ("待验证", ["failure_recovery"]),
            }.items()
        },
        "git": dict(snapshot, verifiedHead=None, verifiedByEvidenceIds=[]),
        "actionStatus": "none",
        "inFlightAction": None,
        "eventTail": {"seq": 0, "id": None, "hash": None},
        "evidenceTail": {"seq": 0, "id": None, "hash": None},
        "lastCheckpoint": None,
        "runtime": {
            "observedAt": None,
            "staleAfterSeconds": 300,
            "managedProcesses": [],
            "observedExternalProcesses": [],
            "managedArtifacts": [],
            "observedArtifacts": [],
        },
        "hardenedControls": {
            "ready": False,
            "leaseVerifier": None,
            "actionVerifier": None,
            "evidenceIds": [],
            "note": "通用脚本不授权真实副作用；由项目专用扩展建立 lease/verifier 后再置为 ready",
        },
        "resume": {
            "blockers": [],
            "nextCommands": ["git --no-optional-locks status --short --ignored", "运行项目现有最小安全测试", "更新主方案当前事实"],
            "doNotDo": ["不要凭旧线程直接继续副作用", "不要删除或停止归属不明对象", "不要把代码存在写成真实业务完成"],
        },
    }
    return state


def build_bundle(args: argparse.Namespace, repo: Path, output_rel: str, plan_rel: str) -> Dict[str, bytes]:
    metadata_paths = continuity_metadata_paths(output_rel, plan_rel)
    snapshot = git_snapshot(repo, output_rel, metadata_paths)
    bundle: Dict[str, bytes] = {
        plan_rel: (
            light_plan_template(str(args.project_name), str(args.objective))
            if args.mode == "light"
            else plan_template(str(args.project_name), str(args.objective))
        ).encode("utf-8"),
        output_rel + "/STATUS.md": light_status_template(str(args.project_name), str(args.objective)).encode("utf-8"),
    }
    if args.include_agents and not (repo / "AGENTS.md").exists():
        bundle["AGENTS.md"] = agents_template(plan_rel, output_rel, args.mode).encode("utf-8")
    if args.mode == "light":
        return bundle

    state = build_state(args, snapshot, output_rel, plan_rel)
    event = ledger_record([], "long-task.execution-event", "EVT-0001", {
        "timestamp": utc_now(),
        "runId": state["run"]["runId"],
        "attempt": 1,
        "eventType": "session_start",
        "phaseId": "P0",
        "sliceId": "P0-S1",
        "summary": "建立长任务主方案和可恢复台账",
        "git": {"observedHead": snapshot.get("observedHead"), "workingTreeFingerprint": snapshot.get("workingTreeFingerprint")},
        "evidenceIds": [],
    })
    state["eventTail"] = ledger_tail([event])
    checkpoint: Dict[str, Any] = {
        "kind": "long-task.execution-checkpoint",
        "schemaVersion": 1,
        "id": "CP-0001",
        "createdAt": utc_now(),
        "type": "state_snapshot",
        "reason": "bootstrap",
        "run": state["run"],
        "phase": state["activePhase"],
        "slice": state["activeSlice"],
        "git": snapshot,
        "eventTail": state["eventTail"],
        "evidenceTail": state["evidenceTail"],
        "inFlightAction": None,
        "permissions": {"safeToResume": True, "canEdit": True, "canStartSideEffect": False, "canRunLive": False},
        "safeToResume": True,
        "safeToRunLive": False,
        "nextAction": state["activeSlice"]["nextAction"],
    }
    checkpoint["hash"] = object_hash(checkpoint)
    checkpoint_rel = output_rel + "/checkpoints/CP-0001-bootstrap.json"
    state["lastCheckpoint"] = {
        "id": "CP-0001",
        "path": checkpoint_rel,
        "type": "state_snapshot",
        "createdAt": checkpoint["createdAt"],
        "safeToResume": True,
        "safeToRunLive": False,
        "permissions": checkpoint["permissions"],
        "hash": checkpoint["hash"],
    }
    state["revision"] = 2
    state["updatedAt"] = utc_now()
    bundle.update({
        output_rel + "/PROTOCOL.md": protocol_template(args.mode).encode("utf-8"),
        output_rel + "/profiles.json": (json.dumps({
            "kind": "long-task.verification-profiles",
            "schemaVersion": 1,
            "profiles": {},
        }, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
        output_rel + "/events.jsonl": (json.dumps(event, ensure_ascii=True, sort_keys=True, separators=(",", ":")) + "\n").encode("utf-8"),
        output_rel + "/evidence.jsonl": b"",
        output_rel + "/state.json": (json.dumps(state, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
        checkpoint_rel: (json.dumps(checkpoint, ensure_ascii=False, indent=2) + "\n").encode("utf-8"),
        output_rel + "/STATUS.md": render_status(state, [event], [], repo).encode("utf-8"),
    })
    return bundle


def pending_dir(repo: Path) -> Path:
    return git_private_path(repo, "orchestrate-long-projects-bootstrap.pending")


def prepare_pending(repo: Path, bundle: Dict[str, bytes], mode: str) -> Path:
    target = pending_dir(repo)
    if target.exists():
        raise RuntimeError("存在未完成 bootstrap；请使用 --resume-bootstrap")
    preparing = git_private_path(repo, "orchestrate-long-projects-bootstrap.preparing-" + secrets.token_hex(6))
    preparing.mkdir(parents=True, exist_ok=False)
    try:
        records = []
        for index, (relative, payload) in enumerate(sorted(bundle.items()), 1):
            stage_name = "{:04d}.bin".format(index)
            exclusive_write_bytes(preparing / stage_name, payload)
            records.append({
                "path": relative,
                "stage": stage_name,
                "sha256": hashlib.sha256(payload).hexdigest(),
                "size": len(payload),
            })
        manifest = {
            "kind": "long-task.bootstrap-manifest",
            "schemaVersion": 1,
            "repo": str(repo.resolve()),
            "mode": mode,
            "createdAt": utc_now(),
            "targets": records,
        }
        atomic_write_json(preparing / "manifest.json", manifest)
        os.replace(str(preparing), str(target))
    except Exception:
        if preparing.exists():
            shutil.rmtree(str(preparing))
        raise
    return target


def load_manifest(repo: Path) -> Dict[str, Any]:
    directory = pending_dir(repo)
    manifest_path = directory / "manifest.json"
    if not manifest_path.is_file():
        raise RuntimeError("没有可恢复的 bootstrap manifest")
    with manifest_path.open("r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    if manifest.get("kind") != "long-task.bootstrap-manifest" or manifest.get("schemaVersion") != 1:
        raise RuntimeError("bootstrap manifest kind/schema 无效")
    if Path(str(manifest.get("repo"))).resolve() != repo.resolve():
        raise RuntimeError("bootstrap manifest 绑定到其他仓库")
    if not isinstance(manifest.get("targets"), list) or not manifest["targets"]:
        raise RuntimeError("bootstrap manifest targets 无效")
    if manifest.get("mode") not in {"light", "standard", "hardened"}:
        raise RuntimeError("bootstrap manifest mode 无效")
    seen_paths = set()
    seen_stages = set()
    for index, record in enumerate(manifest["targets"], 1):
        if not isinstance(record, dict):
            raise RuntimeError("bootstrap manifest target {} 结构无效".format(index))
        relative = str(record.get("path") or "")
        stage = str(record.get("stage") or "")
        digest = record.get("sha256")
        size = record.get("size")
        if not relative:
            raise RuntimeError("bootstrap manifest target {} 缺少 path".format(index))
        safe_repo_path(repo, relative, "bootstrap target")
        path_key = os.path.normcase(relative.replace("\\", "/"))
        if path_key in seen_paths:
            raise RuntimeError("bootstrap manifest target path 重复: {}".format(relative))
        seen_paths.add(path_key)
        if not re.fullmatch(r"[0-9]{4}\.bin", stage):
            raise RuntimeError("bootstrap manifest stage 无效: {}".format(stage))
        if stage in seen_stages:
            raise RuntimeError("bootstrap manifest stage 重复: {}".format(stage))
        seen_stages.add(stage)
        if not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise RuntimeError("bootstrap manifest sha256 无效: {}".format(relative))
        if not isinstance(size, int) or isinstance(size, bool) or size < 0:
            raise RuntimeError("bootstrap manifest size 无效: {}".format(relative))
    return manifest


def install_pending(repo: Path) -> Dict[str, Any]:
    directory = pending_dir(repo)
    manifest = load_manifest(repo)
    targets: Dict[str, Path] = {}
    for record in manifest["targets"]:
        relative = str(record.get("path") or "")
        target = safe_repo_path(repo, relative, "bootstrap target")
        targets[relative] = target
        staged = directory / str(record["stage"])
        if staged.is_symlink() or staged.resolve().parent != directory.resolve():
            raise RuntimeError("bootstrap stage 逃逸 pending 目录: {}".format(record["stage"]))
        if not staged.is_file() or file_sha256(staged) != record.get("sha256") or staged.stat().st_size != record.get("size"):
            raise RuntimeError("bootstrap staging 损坏: {}".format(relative))
    ensure_unique_targets(targets)
    for record in manifest["targets"]:
        relative = str(record["path"])
        target = targets[relative]
        staged = directory / str(record["stage"])
        if target.exists():
            if not target.is_file() or file_sha256(target) != record["sha256"] or target.stat().st_size != record["size"]:
                raise RuntimeError("恢复时发现目标已被其他内容占用: {}".format(target))
            continue
        exclusive_write_bytes(target, staged.read_bytes())
    for record in manifest["targets"]:
        target = targets[str(record["path"])]
        if not target.is_file() or file_sha256(target) != record["sha256"]:
            raise RuntimeError("bootstrap 安装后校验失败: {}".format(target))
    shutil.rmtree(str(directory))
    return manifest


def main() -> int:
    args = parse_args()
    repo = ensure_git_root(Path(args.repo).resolve())
    if run_git(repo, "rev-parse", "HEAD", allow_failure=True) is None:
        raise RuntimeError("--repo 必须先有至少一个 commit；bootstrap 不会在 unborn 仓库留下半成品")
    lock_path = git_private_path(repo, "orchestrate-long-projects-bootstrap.lock")
    if args.resume_bootstrap:
        with FileLock(lock_path):
            manifest = load_manifest(repo)
            if manifest.get("mode") in {"standard", "hardened"}:
                ensure_evidence_key(repo)
            install_pending(repo)
            print("已恢复并完成 {} bootstrap".format(manifest.get("mode")))
            return 0

    if not args.project_name or not args.objective:
        raise RuntimeError("新建 bootstrap 必须提供 --project-name 和 --objective")
    output_rel = normalize_relative(args.output_dir, "--output-dir")
    plan_rel = normalize_relative(args.plan_path, "--plan-path")
    execution_dir = safe_repo_path(repo, output_rel, "--output-dir")
    plan_path = safe_repo_path(repo, plan_rel, "--plan-path")
    candidates: Dict[str, Path] = {"plan": plan_path, "status": execution_dir / "STATUS.md"}
    if args.include_agents and not (repo / "AGENTS.md").exists():
        candidates["agents"] = repo / "AGENTS.md"
    if args.mode in {"standard", "hardened"}:
        candidates.update({
            "protocol": execution_dir / "PROTOCOL.md",
            "state": execution_dir / "state.json",
            "events": execution_dir / "events.jsonl",
            "evidence": execution_dir / "evidence.jsonl",
            "profiles": execution_dir / "profiles.json",
            "checkpoint": execution_dir / "checkpoints" / "CP-0001-bootstrap.json",
        })
    ensure_unique_targets(candidates)
    existing = [str(path) for path in candidates.values() if path.exists()]
    if existing:
        raise RuntimeError("拒绝覆盖已有文件:\n- " + "\n- ".join(existing))
    bundle = build_bundle(args, repo, output_rel, plan_rel)
    print("模式: {}\n将创建:".format(args.mode))
    for relative in sorted(bundle):
        print("- {}".format(safe_repo_path(repo, relative, "target")))
    if args.include_agents and (repo / "AGENTS.md").exists():
        print("- AGENTS.md 已存在，不修改；请人工确认其链接到 STATUS")
    if args.dry_run:
        print("dry-run: 未写入文件")
        return 0

    with FileLock(lock_path):
        existing = [str(path) for path in candidates.values() if path.exists()]
        if existing:
            raise RuntimeError("并发期间目标已出现，拒绝覆盖:\n- " + "\n- ".join(existing))
        if args.mode in {"standard", "hardened"}:
            ensure_evidence_key(repo)
        prepare_pending(repo, bundle, args.mode)
        install_pending(repo)
    print("已创建 {} 长任务资料；standard/hardened 使用 progress_long_task.py 更新".format(args.mode))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as exc:
        print("bootstrap failed: {}".format(exc), file=sys.stderr)
        raise SystemExit(1)
