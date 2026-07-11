#!/usr/bin/env python3
"""Shared primitives for the generic long-task continuity scaffold."""

from __future__ import print_function

import contextlib
import datetime as dt
import hashlib
import hmac
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
from typing import Any, Dict, Iterable, List, Optional, Sequence


def utc_now() -> str:
    return dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z")


def canonical_json(value: Dict[str, Any]) -> str:
    return json.dumps(value, ensure_ascii=True, sort_keys=True, separators=(",", ":"))


def object_hash(value: Dict[str, Any]) -> str:
    payload = dict(value)
    payload.pop("hash", None)
    return "sha256:" + hashlib.sha256(canonical_json(payload).encode("utf-8")).hexdigest()


def evidence_signature_payload(value: Dict[str, Any]) -> bytes:
    payload = dict(value)
    payload.pop("hash", None)
    payload.pop("runnerSignature", None)
    return canonical_json(payload).encode("utf-8")


def evidence_key_path(repo: Path) -> Path:
    return git_private_path(repo, "orchestrate-long-projects/evidence.key")


def ensure_evidence_key(repo: Path) -> Path:
    path = evidence_key_path(repo)
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists():
        with path.open("xb") as handle:
            handle.write(os.urandom(32))
            handle.flush()
            os.fsync(handle.fileno())
    if not path.is_file() or path.stat().st_size < 32:
        raise RuntimeError("evidence signing key 无效")
    return path


def sign_evidence(repo: Path, value: Dict[str, Any]) -> str:
    key = ensure_evidence_key(repo).read_bytes()
    return "hmac-sha256:" + hmac.new(key, evidence_signature_payload(value), hashlib.sha256).hexdigest()


def verify_evidence_signature(repo: Path, value: Dict[str, Any]) -> bool:
    path = evidence_key_path(repo)
    signature = value.get("runnerSignature")
    if not path.is_file() or not isinstance(signature, str) or not signature.startswith("hmac-sha256:"):
        return False
    expected = "hmac-sha256:" + hmac.new(path.read_bytes(), evidence_signature_payload(value), hashlib.sha256).hexdigest()
    return hmac.compare_digest(signature, expected)


def file_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write_text(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(text)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp_name, str(path))
        if os.name != "nt":
            directory_fd = os.open(str(path.parent), os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
    except Exception:
        with contextlib.suppress(OSError):
            os.unlink(temp_name)
        raise


def atomic_write_json(path: Path, value: Dict[str, Any]) -> None:
    atomic_write_text(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def load_json(path: Path) -> Dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError("{} 必须是 JSON object".format(path))
    return value


def load_jsonl(path: Path) -> List[Dict[str, Any]]:
    records: List[Dict[str, Any]] = []
    if not path.exists():
        return records
    with path.open("r", encoding="utf-8") as handle:
        for line_number, raw_line in enumerate(handle, 1):
            line = raw_line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError as exc:
                raise ValueError("{}:{} JSON 无效: {}".format(path, line_number, exc))
            if not isinstance(value, dict):
                raise ValueError("{}:{} 必须是 JSON object".format(path, line_number))
            records.append(value)
    return records


def append_jsonl(path: Path, value: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8", newline="\n") as handle:
        handle.write(canonical_json(value) + "\n")
        handle.flush()
        os.fsync(handle.fileno())


def run_git(repo: Path, *args: str, allow_failure: bool = False) -> Optional[str]:
    env = dict(os.environ)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    completed = subprocess.run(
        ["git"] + list(args),
        cwd=str(repo),
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        env=env,
    )
    if completed.returncode != 0:
        if allow_failure:
            return None
        raise RuntimeError("git {} 失败: {}".format(" ".join(args), completed.stderr.strip()))
    return completed.stdout.rstrip("\r\n")


def ensure_git_root(repo: Path) -> Path:
    root = run_git(repo, "rev-parse", "--show-toplevel")
    resolved = Path(str(root)).resolve()
    if resolved != repo.resolve():
        raise RuntimeError("--repo 必须指向 Git 根目录: {}".format(resolved))
    return resolved


def safe_repo_path(repo: Path, relative: str, label: str) -> Path:
    raw = Path(relative)
    if raw.is_absolute():
        raise RuntimeError("{} 必须是仓库内相对路径".format(label))
    normalized_raw = Path(os.path.normpath(str(raw)))
    if any(part.casefold() == ".git" for part in normalized_raw.parts):
        raise RuntimeError("{} 不能指向 Git 私有目录".format(label))
    if os.name == "nt":
        reserved = {"CON", "PRN", "AUX", "NUL"}
        reserved.update("COM{}".format(index) for index in range(1, 10))
        reserved.update("LPT{}".format(index) for index in range(1, 10))
        for part in raw.parts:
            stem = part.split(".", 1)[0].upper()
            if ":" in part or part.endswith((".", " ")) or stem in reserved:
                raise RuntimeError("{} 包含 Windows 不安全路径组件: {}".format(label, part))
    target = (repo / raw).resolve()
    try:
        target.relative_to(repo.resolve())
    except ValueError:
        raise RuntimeError("{} 逃逸仓库根目录: {}".format(label, target))
    git_marker = (repo / ".git").resolve()
    if git_marker.is_dir():
        try:
            target.relative_to(git_marker)
            raise RuntimeError("{} 不能指向 Git 私有目录: {}".format(label, target))
        except ValueError:
            pass
    return target


def repo_relative(repo: Path, path: Path) -> str:
    return path.resolve().relative_to(repo.resolve()).as_posix()


def git_private_path(repo: Path, name: str) -> Path:
    raw = run_git(repo, "rev-parse", "--git-path", name)
    path = Path(str(raw))
    if not path.is_absolute():
        path = repo / path
    return path.resolve()


class FileLock:
    def __init__(self, path: Path, timeout_seconds: float = 10.0) -> None:
        self.path = path
        self.timeout_seconds = timeout_seconds
        self.handle = None

    def __enter__(self) -> "FileLock":
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.handle = self.path.open("a+b")
        self.handle.seek(0, os.SEEK_END)
        if self.handle.tell() == 0:
            self.handle.write(b"0")
            self.handle.flush()
        deadline = time.time() + self.timeout_seconds
        while True:
            try:
                self.handle.seek(0)
                if os.name == "nt":
                    import msvcrt
                    msvcrt.locking(self.handle.fileno(), msvcrt.LK_NBLCK, 1)
                else:
                    import fcntl
                    fcntl.flock(self.handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                return self
            except (OSError, IOError):
                if time.time() >= deadline:
                    self.handle.close()
                    self.handle = None
                    raise RuntimeError("等待台账写锁超时")
                time.sleep(0.1)

    def __exit__(self, exc_type: Any, exc: Any, traceback: Any) -> None:
        if self.handle is None:
            return
        self.handle.seek(0)
        if os.name == "nt":
            import msvcrt
            with contextlib.suppress(OSError):
                msvcrt.locking(self.handle.fileno(), msvcrt.LK_UNLCK, 1)
        else:
            import fcntl
            with contextlib.suppress(OSError):
                fcntl.flock(self.handle.fileno(), fcntl.LOCK_UN)
        self.handle.close()
        self.handle = None


def normalize_path(value: str) -> str:
    normalized = value
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def continuity_metadata_paths(output_dir: str, plan_path: str) -> List[str]:
    output = normalize_path(output_dir).rstrip("/")
    return [
        normalize_path(plan_path),
        "AGENTS.md",
        output + "/PROTOCOL.md",
        output + "/STATUS.md",
        output + "/profiles.json",
        output + "/state.json",
        output + "/events.jsonl",
        output + "/evidence.jsonl",
        output + "/checkpoints",
    ]


def safe_git_text(value: str) -> str:
    return value.encode("utf-8", errors="backslashreplace").decode("utf-8")


def path_is_metadata(path: Optional[str], metadata_paths: Sequence[str]) -> bool:
    if not path:
        return True
    normalized = normalize_path(path)
    for raw in metadata_paths:
        candidate = normalize_path(raw).rstrip("/")
        if normalized == candidate or normalized.startswith(candidate + "/"):
            return True
    return False


def git_snapshot(repo: Path, output_dir: str, metadata_paths: Optional[Sequence[str]] = None) -> Dict[str, Any]:
    metadata = list(metadata_paths or [output_dir])
    env = dict(os.environ)
    env["GIT_OPTIONAL_LOCKS"] = "0"
    completed = subprocess.run(
        ["git", "status", "--porcelain=v1", "-z", "--untracked-files=all"],
        cwd=str(repo),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    tokens = completed.stdout.decode("utf-8", errors="surrogateescape").split("\0")
    entries: List[Dict[str, Any]] = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if not token:
            index += 1
            continue
        if len(token) < 3:
            raise RuntimeError("Git porcelain record 无效")
        status = token[:2]
        destination = safe_git_text(token[3:])
        source = None
        if "R" in status or "C" in status:
            if index + 1 >= len(tokens) or not tokens[index + 1]:
                raise RuntimeError("Git rename/copy 缺少 source path")
            source = safe_git_text(tokens[index + 1])
            index += 2
        else:
            index += 1
        display = "{} -> {}".format(source, destination) if source else destination
        entries.append({
            "status": status,
            "sourcePath": source,
            "destinationPath": destination,
            "displayPath": display,
        })
    entries.sort(key=lambda item: item["displayPath"])
    product_entries = [
        item for item in entries
        if not (
            path_is_metadata(item.get("sourcePath"), metadata)
            and path_is_metadata(item.get("destinationPath"), metadata)
        )
    ]
    product_files: List[Dict[str, Any]] = []
    for entry in product_entries:
        destination = repo / entry["destinationPath"]
        item: Dict[str, Any] = {"path": entry["displayPath"], "exists": destination.exists()}
        if destination.is_symlink():
            target = os.readlink(str(destination))
            item.update({"symlinkTarget": target, "sha256": hashlib.sha256(target.encode("utf-8", errors="surrogateescape")).hexdigest()})
        elif destination.is_file():
            item.update({"sha256": file_sha256(destination), "size": destination.stat().st_size})
        product_files.append(item)
    head = run_git(repo, "rev-parse", "HEAD")
    branch = run_git(repo, "branch", "--show-current", allow_failure=True) or "DETACHED"
    upstream = run_git(repo, "rev-parse", "@{upstream}", allow_failure=True)
    product_paths = sorted({
        path
        for entry in product_entries
        for path in (entry.get("sourcePath"), entry.get("destinationPath"))
        if path
    })
    index_diff = b""
    worktree_diff = b""
    if product_paths:
        index_diff = subprocess.run(
            ["git", "--literal-pathspecs", "diff", "--cached", "--binary", "--"] + product_paths,
            cwd=str(repo),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        ).stdout
        worktree_diff = subprocess.run(
            ["git", "--literal-pathspecs", "diff", "--binary", "--"] + product_paths,
            cwd=str(repo),
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
        ).stdout
    raw_index_entries = subprocess.run(
        ["git", "ls-files", "--stage", "-z"],
        cwd=str(repo),
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    ).stdout
    filtered_index_entries = []
    for raw_record in raw_index_entries.split(b"\0"):
        if not raw_record:
            continue
        try:
            raw_path = raw_record.split(b"\t", 1)[1]
        except IndexError:
            raise RuntimeError("git ls-files --stage record 无效")
        decoded_path = safe_git_text(raw_path.decode("utf-8", errors="surrogateescape"))
        if not path_is_metadata(decoded_path, metadata):
            filtered_index_entries.append(raw_record)
    index_entries = b"\0".join(sorted(filtered_index_entries))
    fingerprint_payload = {
        "branch": branch,
        "head": head,
        "upstream": upstream,
        "entries": product_entries,
        "files": product_files,
        "indexDiffSha256": hashlib.sha256(index_diff).hexdigest(),
        "worktreeDiffSha256": hashlib.sha256(worktree_diff).hexdigest(),
        "indexEntriesSha256": hashlib.sha256(index_entries).hexdigest(),
        "metadataPaths": metadata,
    }
    return {
        "branch": branch,
        "observedHead": head,
        "upstreamHead": upstream,
        "dirtyPaths": [item["displayPath"] for item in product_entries],
        "dirtyEntries": product_entries,
        "indexDiffSha256": hashlib.sha256(index_diff).hexdigest(),
        "worktreeDiffSha256": hashlib.sha256(worktree_diff).hexdigest(),
        "indexEntriesSha256": hashlib.sha256(index_entries).hexdigest(),
        "metadataPaths": metadata,
        "workingTreeFingerprint": "sha256:" + hashlib.sha256(canonical_json(fingerprint_payload).encode("utf-8")).hexdigest(),
    }


def ledger_record(
    existing: List[Dict[str, Any]],
    kind: str,
    record_id: str,
    payload: Dict[str, Any],
) -> Dict[str, Any]:
    reserved = {"kind", "schemaVersion", "seq", "id", "prevHash", "hash"}
    overlap = reserved.intersection(payload)
    if overlap:
        raise ValueError("ledger payload 不能覆盖保留字段: {}".format(sorted(overlap)))
    previous = existing[-1] if existing else None
    record = {
        "kind": kind,
        "schemaVersion": 1,
        "seq": int(previous["seq"]) + 1 if previous else 1,
        "id": record_id,
        "prevHash": previous.get("hash") if previous else None,
    }
    record.update(payload)
    record["hash"] = object_hash(record)
    return record


def ledger_tail(records: List[Dict[str, Any]]) -> Dict[str, Any]:
    if not records:
        return {"seq": 0, "id": None, "hash": None}
    record = records[-1]
    return {"seq": record.get("seq"), "id": record.get("id"), "hash": record.get("hash")}


def state_digest(state: Dict[str, Any]) -> str:
    encoded = (json.dumps(state, ensure_ascii=False, indent=2) + "\n").encode("utf-8")
    return "sha256:" + hashlib.sha256(encoded).hexdigest()


def md_cell(value: Any) -> str:
    text = "" if value is None else str(value)
    return text.replace("|", "\\|").replace("\r\n", "<br>").replace("\n", "<br>").replace("\r", "<br>")


def md_list(items: Iterable[str], empty: str = "none") -> List[str]:
    values = list(items)
    if not values:
        return ["- {}".format(empty)]
    return ["- {}".format(md_cell(value)) for value in values]


def resolve_artifact_path(repo: Path, raw_path: str) -> Optional[Path]:
    if raw_path.startswith("git-private:"):
        return git_private_path(repo, raw_path.split(":", 1)[1])
    try:
        return safe_repo_path(repo, raw_path, "artifact path")
    except RuntimeError:
        return None


def parse_utc(value: Any) -> dt.datetime:
    if not isinstance(value, str) or not value.endswith("Z"):
        raise ValueError("时间必须是 UTC Z 格式")
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def evidence_current(
    record: Dict[str, Any],
    state: Dict[str, Any],
    repo: Optional[Path] = None,
    profiles: Optional[Dict[str, Dict[str, Any]]] = None,
) -> bool:
    if record.get("status") != "passed":
        return False
    record_git = record.get("git", {})
    state_git = state.get("git", {})
    if record_git.get("observedHead") != state_git.get("observedHead"):
        return False
    if record_git.get("workingTreeFingerprint") != state_git.get("workingTreeFingerprint"):
        return False
    provenance = record.get("provenance") or {}
    if provenance.get("captureMethod") not in {"command_runner", "specialized_verifier"}:
        return False
    if profiles is not None and provenance.get("captureMethod") == "command_runner":
        profile = profiles.get(provenance.get("profile"))
        if not isinstance(profile, dict):
            return False
        if provenance.get("profileDigest") != object_hash(profile):
            return False
        if record.get("command") != profile.get("command") or record.get("category") != profile.get("category"):
            return False
    if repo is not None and provenance.get("captureMethod") == "command_runner":
        if not verify_evidence_signature(repo, record):
            return False
    if record.get("exitCode") != 0:
        return False
    command = record.get("command")
    if not isinstance(command, list) or not command or not all(isinstance(item, str) and item for item in command):
        return False
    valid_until = record.get("validUntil")
    if valid_until:
        try:
            if dt.datetime.now(dt.timezone.utc) > parse_utc(valid_until):
                return False
        except (TypeError, ValueError):
            return False
    for artifact in record.get("artifacts", []):
        if not artifact.get("required"):
            continue
        if not artifact.get("path") or not artifact.get("sha256"):
            return False
        if repo is not None:
            path = resolve_artifact_path(repo, str(artifact.get("path")))
            if path is None or not path.is_file() or file_sha256(path) != artifact.get("sha256"):
                return False
            if artifact.get("size") is not None and path.stat().st_size != artifact.get("size"):
                return False
        elif not artifact.get("exists"):
            return False
    return True


def render_status(
    state: Dict[str, Any],
    events: List[Dict[str, Any]],
    evidence: List[Dict[str, Any]],
    repo: Optional[Path] = None,
    profiles: Optional[Dict[str, Dict[str, Any]]] = None,
) -> str:
    active = state.get("activeSlice", {})
    git = state.get("git", {})
    checkpoint = state.get("lastCheckpoint") or {}
    current_evidence = [record for record in evidence if evidence_current(record, state, repo, profiles)]
    latest_evidence = current_evidence[-1] if current_evidence else None
    action = state.get("inFlightAction")
    next_action = (
        "先对账未决动作 {}，结果明确前禁止重放".format(action.get("actionId"))
        if action else active.get("nextAction", "none")
    )
    criteria = active.get("acceptanceCriteria", [])
    passed = sum(1 for item in criteria if item.get("status") in {"passed", "not_required"})
    checkpoint_safe = bool(checkpoint.get("safeToResume"))
    blockers = state.get("resume", {}).get("blockers") or []
    can_edit = checkpoint_safe and action is None and not blockers
    hardened_controls = state.get("hardenedControls") or {}
    runtime = state.get("runtime", {})
    runtime_fresh = False
    if runtime.get("observedAt"):
        try:
            runtime_fresh = (
                dt.datetime.now(dt.timezone.utc) - parse_utc(runtime.get("observedAt"))
            ).total_seconds() <= int(runtime.get("staleAfterSeconds", 300))
        except (TypeError, ValueError):
            runtime_fresh = False
    can_start_side_effect = (
        can_edit
        and state.get("continuityMode") == "hardened"
        and hardened_controls.get("ready") is True
        and runtime_fresh
        and (checkpoint.get("permissions") or {}).get("canStartSideEffect") is True
    )
    can_run_live = can_start_side_effect and bool(checkpoint.get("safeToRunLive")) and runtime_fresh
    recovery = "STOP" if action or blockers or not checkpoint_safe else "SAFE"
    lines = [
        "<!-- generated-by: orchestrate-long-projects -->",
        "<!-- state-digest: {} -->".format(state_digest(state)),
        "# 长任务执行状态",
        "",
        "> 本页是 state、事件和证据的生成投影；不要手工修改。",
        "",
        "## 恢复首屏",
        "",
        "- 恢复结论：**{}**".format(recovery),
        "- 更新时间：`{}`".format(state.get("updatedAt")),
        "- 项目：`{}`".format(state.get("projectName")),
        "- 运行：`{}` / attempt `{}`".format(state.get("run", {}).get("runId"), state.get("run", {}).get("attempt")),
        "- 当前阶段/切片：`{}` / `{}` - {}".format(state.get("activePhase", {}).get("id"), active.get("id"), active.get("title")),
        "- 状态：phase=`{}`；slice=`{}`；action=`{}`".format(state.get("activePhase", {}).get("status"), active.get("status"), state.get("actionStatus")),
        "- 当前切片验收：`{}/{}`".format(passed, len(criteria)),
        "- 未决副作用：{}".format("`{}`".format(action.get("actionId")) if action else "none"),
        "- 最新当前有效证据：{}".format("{} ({})".format(latest_evidence.get("claim"), latest_evidence.get("id")) if latest_evidence else "none"),
        "- 唯一下一动作：{}".format(next_action),
        "- 首要 blocker：{}".format((state.get("resume", {}).get("blockers") or ["none"])[0]),
        "- observed/verified/upstream：`{}` / `{}` / `{}`".format(git.get("observedHead"), git.get("verifiedHead"), git.get("upstreamHead")),
        "- 工作树指纹：`{}`".format(git.get("workingTreeFingerprint")),
        "- 最新 checkpoint：`{}`；safeToResume=`{}`；safeToRunLive=`{}`".format(checkpoint.get("id", "none"), str(checkpoint.get("safeToResume", False)).lower(), str(checkpoint.get("safeToRunLive", False)).lower()),
        "- 技术门禁（不等于用户授权）：canEdit=`{}`；canStartSideEffect=`{}`；canRunLive=`{}`".format(
            str(can_edit).lower(), str(can_start_side_effect).lower(), str(can_run_live).lower()
        ),
        "- 运行观察：{}".format("fresh" if runtime_fresh else "missing/stale"),
        "",
        "## 当前切片",
        "",
        "### 范围",
        "",
    ]
    lines.extend(md_list(active.get("scope", [])))
    lines.extend(["", "### 非目标", ""])
    lines.extend(md_list(active.get("nonGoals", [])))
    lines.extend(["", "### 安全边界", ""])
    lines.extend(md_list(active.get("safetyBoundaries", [])))
    lines.extend(["", "### 验收条件", "", "| ID | 条件 | 状态 | 证据 |", "|---|---|---|---|"])
    for criterion in criteria:
        evidence_ids = ", ".join("`{}`".format(item) for item in criterion.get("evidenceIds", [])) or "none"
        lines.append("| `{}` | {} | `{}` | {} |".format(md_cell(criterion.get("id")), md_cell(criterion.get("text")), md_cell(criterion.get("status")), evidence_ids))
    lines.extend(["", "## 验收轴", "", "| 轴 | 状态 | 说明 |", "|---|---|---|"])
    for key, value in state.get("projectVerification", {}).items():
        lines.append("| `{}` | `{}` | {} |".format(md_cell(key), md_cell(value.get("status")), md_cell(value.get("note", ""))))
    lines.extend(["", "## 恢复", ""])
    lines.extend(md_list(state.get("resume", {}).get("nextCommands", []), "先运行 continuity audit 和 git status --short；仅按具体风险路径检查 ignored 产物"))
    lines.extend(["", "### 禁止盲目执行", ""])
    lines.extend(md_list(state.get("resume", {}).get("doNotDo", [])))
    lines.extend(["", "## 最近事件", "", "| seq | 时间 | 类型 | 摘要 |", "|---:|---|---|---|"])
    for event in events[-10:]:
        lines.append("| {} | `{}` | `{}` | {} |".format(event.get("seq"), md_cell(event.get("timestamp")), md_cell(event.get("eventType")), md_cell(event.get("summary"))))
    lines.extend(["", "## 最近证据", "", "| ID | 类别 | 结果 | 当前绑定 | 结论 |", "|---|---|---|---|---|"])
    for record in evidence[-10:]:
        lines.append("| `{}` | `{}` | `{}` | `{}` | {} |".format(record.get("id"), md_cell(record.get("category")), md_cell(record.get("status")), "valid" if evidence_current(record, state, repo, profiles) else "stale/invalid", md_cell(record.get("claim"))))
    lines.append("")
    return "\n".join(lines)
