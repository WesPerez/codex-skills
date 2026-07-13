# 可恢复进度台账

## 目录

1. 分级与文件
2. 权威模型
3. 初始化和恢复安装
4. 唯一写入器
5. 固定验证 profile 和证据
6. Checkpoint
7. 副作用与加固扩展
8. STATUS 和恢复判断
9. 一致性、安全与限制
10. 日常节奏

## 1. 分级与文件

### 快速

约 2 小时内、范围小、低风险：不建台账。使用 Git、测试输出和最终报告。

### 轻量

约 2-8 小时、希望可见进度、无高风险外部动作：

```text
docs/project-master-plan.md
docs/execution/STATUS.md
```

`AGENTS.md` 是可选仓库规则入口，只有仓库原本已有或用户明确授权 `--include-agents` 时存在。轻量 `STATUS.md` 由主代理维护。跨天、多 Agent、需要机器校验或明确可能中断时升级，不要伪装成标准账本。

### 标准

跨天、多模块，或多 Agent 带来跨阶段交接、并发写入、中断恢复需求：

```text
docs/project-master-plan.md
docs/execution/
  PROTOCOL.md
  STATUS.md
  profiles.json
  state.json
  events.jsonl
  evidence.jsonl
  checkpoints/CP-0001-bootstrap.json
```

标准/加固模式同样把 `AGENTS.md` 视为可选仓库规则入口，不因建立台账而默认新增。

### 加固

实际执行非幂等外部写入、共享目标操作、数据库迁移、真实设备输入或发布，且中断后需要对账。使用标准文件和通用 intent/result，但必须由项目补充：

- 外部 lease 存储和所有权 token。
- 动作专用 verifier。
- 目标身份、权限、前置/后置状态 schema。
- 环境特定 TTL、并发键和停止方式。

通用技能不会假装理解任意数据库、设备、窗口或业务后置状态。
在 state 中，`hardenedControls.ready` 默认是 `false`。通用 checkpoint 命令永不授予 `canStartSideEffect/canRunLive`，通用 audit 也会拒绝任何 `ready=true`。需要真实副作用的项目必须扩展专用 writer 和 audit，由它们登记并实际执行 lease/action verifier，验证目标语义和两类当前有效 `external_state` 证据；不能只修改通用 state 字段。

## 2. 权威模型

主方案解释“为什么、总体做什么”；台账解释“当前停在哪里”。不要把二者合成一个不断重写的大文档。

```text
state       当前机器可读投影
events      重要转换的追加历史
evidence    命令、退出码、源码指纹和产物
checkpoint  不可覆盖恢复快照
STATUS      由上述内容生成的人类首屏
profiles    可生成 passed 证据的固定命令
```

状态按不同轴表达：

```text
overallStatus: active | blocked | completed | cancelled
phaseStatus: pending | in_progress | verifying | passed | blocked
sliceStatus: ready | in_progress | verifying | passed | blocked
actionStatus: none | running | succeeded | failed | unknown_after_interruption
gateStatus: not_started | observed | passed | failed | blocked | not_required | stale
```

`checkpointed` 是快照属性，不是工作状态。`interrupted` 属于 attempt/action；不要覆盖整个项目状态。

Git 指纹至少绑定：完整 HEAD、branch/upstream、产品 dirty entries、untracked 文件、工作树内容、index entries、cached diff 和 index-to-worktree diff。台账、方案和 AGENTS 被列为 metadata，不因状态写入让测试证据自行失效。

## 3. 初始化和恢复安装

新建前先 dry-run：

```powershell
python -B <skill-dir>\scripts\bootstrap_long_task.py --repo <repo> `
  --project-name "<name>" --objective "<objective>" `
  --mode light|standard|hardened --dry-run
```

要求：

- `--repo` 必须是有首个 commit 的 Git 根。
- 输出只能是仓库内相对路径。
- 目标不能碰撞或已存在。
- 默认不创建 `AGENTS.md`；只有显式 `--include-agents` 才创建，已有文件始终不覆盖。
- `read_only` 不执行 bootstrap；`plan_write` 仅在用户明确要求时允许 light；`resume` 必须有已证明或重新获得的 `repo_write` 才可恢复安装。

`plan_write` 必须显式提供 `--plan-path` 和 `--output-dir`，并核对 dry-run 目标集合与用户授权完全相等。

实际安装先把完整内容和 manifest 放到 Git 私有目录，再逐个以 exclusive create 安装。若进程在安装中断，目标可能部分存在，但内容绑定 manifest；只运行：

```powershell
python -B <skill-dir>\scripts\bootstrap_long_task.py --repo <repo> --resume-bootstrap
```

恢复只接受 manifest 中唯一、规范的仓库目标和 pending 目录内固定编号 stage；拒绝绝对路径、遍历、任意层级 `.git`、重复 target/stage、链接逃逸及 hash/size 不一致。已有目标只有与 staging 字节完全相同才接受，其他情况停止，不覆盖、不猜测。

## 4. 唯一写入器

标准/加固台账只允许主代理调用：

```powershell
python -B <skill-dir>\scripts\progress_long_task.py --repo <repo> <command>
```

常用命令：

```text
resume-check     只读判断；不更新任何状态
render           刷新 Git 投影和 STATUS
note             记录决策、blocker、scope 或 commit/push 摘要
begin-slice      建立当前 phase/slice、范围、非目标和验收条件
slice-state      更新 phase/slice 状态；有 pending 条件时拒绝 passed
run-evidence     运行 profiles.json 固定命令，保存真实退出码和私有日志
criterion-state  更新 pending/failed/blocked/not_required/stale；passed 只能来自有效 evidence
gate             用当前有效 evidence 更新一个验收轴
project-state    更新项目总体状态；completed 前强制检查 phase/slice/criterion/gate
runtime-observe  登记现场观察时间和摘要，不等于业务通过
checkpoint       创建不可覆盖恢复快照
action-start     hardened 模式下写 intent；不等于允许执行
action-finish    记录正在运行动作的已知结果
reconcile        中断后对齐 tail/Git、增加 attempt；running 自动转 unknown
```

writer 使用 Git 私有 OS 锁。JSON 使用临时文件、flush/fsync 和原子 replace；JSONL 追加后 flush/fsync；最后投影 STATUS。

若中断发生在 JSONL 已追加、state 未更新之间，`reconcile` 可把完整有效 tail 对齐到新 attempt。若 JSONL 末尾是截断片段或完整记录 hash 错误，通用工具拒绝解析；先保全原文件，再做人工取证和有边界修复，禁止自动删整条历史。

## 5. 固定验证 profile 和证据

`profiles.json` 是验证命令 allowlist：

```json
{
  "kind": "long-task.verification-profiles",
  "schemaVersion": 1,
  "profiles": {
    "frontend-build": {
      "category": "build",
      "command": ["npm.cmd", "run", "build"],
      "cwd": ".",
      "readOnly": false,
      "sideEffectClass": "repository_write",
      "timeoutSeconds": 1800,
      "verifiesHead": true,
      "requiredArtifacts": ["dist/index.html"]
    }
  }
}
```

Windows 可执行 shim 使用实际可直接启动的名称，如 `npm.cmd`。不使用 `shell=True`，不把自由命令字符串交给 shell。每个 profile 必须显式声明 boolean `readOnly` 和 `sideEffectClass`；允许值为 `none`、`repository_write`、`local_runtime`、`external_read`、`external_write`、`destructive`。`external_write`/`destructive` 必须另有非空 `externalAuthorization`，未知或矛盾分类一律拒绝。

运行：

```powershell
python <skill-dir>\scripts\progress_long_task.py --repo <repo> run-evidence `
  --authorization repo_write `
  --profile frontend-build --claim "当前前端生产构建通过" `
  --criterion P1-S1-C2 --gate currentBuild
```

`passed` 必须同时满足：

- 当前 workflow 不是 `read_only`；外部或破坏性命令使用 `external_authorized` 且 profile 已记录对应授权。

- 固定 profile 存在，命令、类别和 profile digest 一致。
- 真实退出码为 0。
- 验证命令执行前后 HEAD 和产品工作树指纹完全一致，防止把旧源码上的成功误绑定到并发修改后的源码。
- required artifact 存在，路径在仓库内，hash/size 当前匹配。
- HEAD 和非 metadata 工作树指纹与 state 一致。
- 运行/外部证据未超过 `validUntil`。
- 记录带有本机 Git 私有 runner HMAC；从远端 clone 到没有本机 key 的环境后自动失效。
- 记录 `startedAt`、`finishedAt`、执行前后 Git 指纹和源码是否保持不变。

命令输出存入 `.git/orchestrate-long-projects/logs/`，账本只记录 `git-private:` 路径、hash 和大小，避免把大日志或敏感输出直接提交。不要清理这些日志，除非能证明属于本轮且保留策略允许。

固定 profile 只能证明“该命令按约定成功”，不能自动证明命令本身覆盖了真实用户目标。HMAC 主要防手工拼装和意外漂移，不是对拥有本机文件读写权限的恶意执行者的安全边界。profile 的选择仍需代码审查和项目验收矩阵复核。

## 6. Checkpoint

Checkpoint 只在语义恢复边界创建：切片真正完成、handoff、上下文压缩、长暂停、真实副作用前后、commit/push 前和失败阻塞时。普通 note、gate 更新、只读浏览、重复验证或无变化轮询不创建 checkpoint。

它记录：run/attempt、phase/slice、Git 指纹、账本 tails、当前动作、下一动作和明确技术门禁：

```text
safeToResume
canEdit
canStartSideEffect
canRunLive
```

区分：

```text
state_snapshot  保存 dirty 现场，不保证可回滚
git_checkpoint  指向可解析、已验证的 commit
```

所有 checkpoint 不可覆盖、自哈希。完整 audit 会枚举全部 checkpoint，验证 schema、ID、tails、hash、路径和最新指针。

## 7. 副作用与加固扩展

仅对非幂等、共享或中断后可能重复伤害的动作强制：

```text
intent -> execute -> result -> postcondition evidence
```

intent 至少包含：actionId、kind、targetIdentity、precondition、postcondition、idempotencyKey、owner、ownershipEvidence 和 startedAt。

中断窗口：

```text
intent 已写，动作未发生
动作发生，result 未写
result 已写，外部 lease 未释放
```

第二种必须为 `unknown_after_interruption`。通用 `action-finish` 会拒绝把 unknown 猜成 succeeded/failed；必须由项目专用 verifier 证明 `applied`、`not_applied` 或 `ambiguous`，并验证 actionId、target 和 idempotencyKey。

普通 commit 不强制 intent，记录 hash 即可。本地开发服务登记 PID、完整命令、启动时间、工作目录和所有权证据。push 前后读取远端 ref。共享外部资源才需要 lease；不要给普通单 Agent 本地开发增加虚假 lease。

## 8. STATUS 和恢复判断

首屏必须回答：SAFE/STOP、更新时间、phase/slice/attempt、未决动作、源码绑定证据摘要、唯一下一动作、blocker、最近 Git 观测、checkpoint 和技术门禁。STATUS 是快速投影；artifact、历史链和完整 Git 一致性由 full audit 证明。技术门禁不等于用户授权。

轻量模式最小恢复顺序：

```text
1. 读 AGENTS.md
2. 读 STATUS.md
3. 运行一次 `git --no-optional-locks status --short`
4. 允许继续后，只读主方案当前 phase/slice
```

标准/加固模式最小恢复顺序：

```text
1. 读 AGENTS.md 和 STATUS.md
2. 运行 progress_long_task.py resume-check
3. fast 返回 safe_for_code_only 时，在现有 repo_write 授权内继续代码工作
4. fast blocked/ambiguous、旧台账缺 fast 数据、完整性异常、unknown 动作、高风险外部动作、handoff/完成/发布/push 前，才运行 audit_long_task.py；旧台账 full 诊断确认仅缺 fast 字段后，在 repo_write 下执行 render 迁移
5. 只在 fast/full 输出未包含所需 Git 细节时补充精确 Git 查询
6. 允许继续后，只读主方案当前 phase/slice
```

fast `resume-check` 验证当前状态、tail、最新 checkpoint、未决动作和有界 Git 指纹，不重 hash 全部 artifact、不遍历全部历史 checkpoint，也不重复渲染全历史 STATUS。它只给出 code-only 连续性结论，不授予用户写权限、真实副作用或项目完成状态。

完整 audit 验证 schema、hash 链、profiles/evidence、全部 checkpoint、STATUS 投影、固定 metadata paths、完整 Git 指纹、artifact 和读取期间并发变化。`resume-check --full` 只重验完整 Git 指纹和 passed gate 关联 artifact，可用于诊断；它不替代全部 evidence/criterion/checkpoint 审计，交接/完成的权威 full gate 仍是 `audit_long_task.py`。

PROTOCOL、state、events、evidence 和 checkpoint 默认由工具读取；只有 audit 异常、未决动作或 STATUS 指示时，人再深入阅读。

## 9. 一致性、安全与限制

- Hash 链能发现意外损坏和未同步修改，不防拥有仓库写权限者整体重算；Git commit/远端是额外锚点。
- 标准工具不持久化凭据，不把大日志放进 tracked 文件。
- 主方案和 objective 可能进入 Git；落盘前先移除凭据、客户隐私和不应公开的真实路径。
- `profiles.json` 变化会让对应旧 passed evidence 失效。
- 运行证据必须有 TTL；旧 PID、窗口句柄、页签和数据库连接只能作线索。
- `completed` 必须没有未决动作，当前切片条件和全部 required gates 均 passed/not_required。
- 归属不明的文件、日志、进程、页签、缓存和 ignored 产物不清理。

## 10. 日常节奏

只在语义状态变化时写台账：决策、切片开始/结束、关键测试结果、blocker、用户 steer、真实动作前后、checkpoint、commit/push 和收尾。不要把每次 `rg`、无变化轮询或重复测试写成事件。

面向用户的 commentary 不等于 durable event。每个小闭环都要能回答：完成什么、当前做什么、唯一下一步、风险、是否启动当前版本、是否执行真实副作用、证据在哪里。
