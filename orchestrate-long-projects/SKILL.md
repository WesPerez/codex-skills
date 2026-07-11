---
name: orchestrate-long-projects
description: 编排复杂、跨阶段、可能持续数小时或数天的软件项目：提炼真实需求，核验当前源码/Git/测试/运行态，做多源研究和主方案，建立轻量或可中断恢复的进度台账，按纵向切片实施并留下可信证据，支持多 Agent 协作、异常恢复、只读进度核验和交接。用户要求全面项目审计、详细开发方案、进度表/台账/checkpoint、继续中断任务、让下一 Agent 直接接手、真实应用/设备/数据库/外部系统验收，或询问长期任务真实进度时使用。不要用于脱离既有长期项目台账的单文件短修复、纯代码解释、一次性问答、独立单次 CI/PR、简单只读查询或无需连续性治理的低风险短任务；若这些动作属于当前长期项目切片，本技能继续管理状态和证据。
---

# 长任务项目编排

把长期开发从“长时间默默写代码”变成可观察、可验证、可恢复、可交接的工程过程。不要用聊天历史、代码行数、提交数量或单一百分比代替真实完成度。

## 先判定入口

先确定工作入口：`audit`、`plan`、`implement`、`resume` 或 `status`。`audit/plan` 进入审计与方案流程，`implement` 进入实施流程，`resume/status` 进入恢复或进度核验流程。`resume` 只描述恢复流程，本身不授予写权限；`plan` 即使同时持有 `repo_write`，也不能提前进入实现。

再单独确定用户授权：

- `read_only`：不创建/更新文件，不运行可能写缓存或构建产物的测试；Python 只读脚本使用 `-B`，Git 状态查询使用 `--no-optional-locks`，避免诊断本身留下字节码或可选 index 写入。
- `plan_write`：只写用户明确要求的方案/报告；明确要求时可建立 light STATUS。
- `repo_write`：修改仓库内代码、测试、台账和必要项目文件。

`repo_write` 默认不包含真实输入、数据库/AppData 写入、进程停止、push/发布、外部消息或共享资源；这些必须另有 `externalAuthorization` 明确范围。实际允许动作是“当前 workflow 所需动作 ∩ 用户请求范围 ∩ userAuthorization ∩ externalAuthorization ∩ 连续性技术门禁 ∩ 领域安全规则”。`intent/result` 不替代授权。子代理和下游技能继承的是权限上限，主代理仍按最小权限收窄。

再选复杂度。时间只是信号，高风险可以直接升级：

| 级别 | 适用情况 | 连续性材料 |
|---|---|---|
| 快速 | 约 2 小时内、单一范围、低风险 | 不建台账；Git、测试输出和最终报告即可 |
| 轻量 | 约 2-8 小时、需要可见进度、无高风险外部动作 | living plan + `STATUS.md` + Git/测试日志 |
| 标准 | 跨天、多模块，或多 Agent 带来跨阶段交接、并发写入、中断恢复需求 | state/events/evidence/checkpoints + 单写入器 |
| 加固 | 实际执行非幂等外部写入、共享资源操作、迁移/发布、数据库写入或真实设备动作，且中断后需要对账 | 标准版 + intent/result + 项目专用 lease/verifier |

多级同时命中时，按真实风险、连续性和恢复需求选择最低足够级别。不要因为用户要求“写详细一点”、使用多个只读子代理、运行一次浏览器/设备 smoke、本地 release 构建、只编写迁移代码或做一次生产只读查询，就自动建立重型台账。

## 权威顺序

冲突时固定采用：

```text
当前源码、Git、测试、构建、实际运行和外部系统当前状态
> 绑定当前源码指纹的日志、截图、报告和 hash 证据
> state/events/evidence/checkpoint
> STATUS
> 主方案和历史设计文档
> Codex 线程、摘要和模型记忆
```

旧 PID、窗口句柄、截图、测试和线程只能作为线索。

## 三种工作流

### 新项目审计

1. 提炼根本目标、用户工作流、强制约束、禁止事项和完成定义。
2. 只读核对 AGENTS、Git、源码入口、调用链、持久化、测试、构建、进程和外部现场。
3. 先交付事实矩阵、P0 风险和临时路线；初次可见结果通常控制在 20-40 分钟，不等所有资料读完。
4. 只对会改变架构或安全边界的缺口做多源研究；已有稳定结论不重复搜索。
5. `read_only` 只在回复中给方案；`plan_write`/`repo_write` 才生成 living 主方案、阶段、纵向切片、验收矩阵和建议 commit 边界。

详细读取 [discovery-and-master-plan.md](references/discovery-and-master-plan.md)。需要外部研究时再读 [research-basis.md](references/research-basis.md)。

### 已有方案实施

1. 读 `STATUS.md`；仓库存在 `AGENTS.md` 时先读它。
2. 使用 `python -B` 运行只读 resume-check、完整连续性 audit，并运行 `git --no-optional-locks status --short --ignored`；自定义台账路径必须把相同的 `--output-dir/--plan-path` 传给两个脚本。
3. 审计允许继续后，只读主方案当前 phase/slice；协议仅在异常或 STATUS 指示时读取。
4. 一次推进一个用户可观察纵向切片：最小代码改动 -> 局部测试 -> 构建 -> 启动当前版本 -> 实际 UI/API 操作 -> 必要的最小真实动作 -> 后置验证 -> 证据 -> checkpoint/commit。
5. 一个主要视图或一个执行能力完成后就实际运行，不积累数天代码后第一次接管应用。

### 中断恢复或只读进度

1. 不先修改、启动、重放副作用、commit、push、清理或停止进程。
2. 读首屏材料，核对台账 tail、checkpoint、Git drift、未决动作、证据 TTL 和外部身份。
3. `running` 动作在中断后视为结果未知；先对账，禁止重放。
4. 输出真实停点、唯一下一动作、允许/禁止操作、证据边界和恢复置信度。
5. 只问进度时保持只读，不更新“看起来更好”的状态。

交接和恢复提示词见 [handoff-and-prompts.md](references/handoff-and-prompts.md)。

## 台账工具

仅在 `repo_write` 且仓库尚无体系时 bootstrap；用户明确要求“方案 + 轻量进度页”时，`plan_write` 只允许 `--mode light`。`read_only` 不 bootstrap。`resume` 只有在已证明原任务具有 `repo_write` 或用户重新明确授权后，才可恢复安装。

先 dry-run：

```powershell
python -B <skill-dir>\scripts\bootstrap_long_task.py --repo <repo> `
  --project-name "<name>" --objective "<objective>" `
  --mode light|standard|hardened --dry-run
```

`plan_write` 必须显式传 `--plan-path` 和 `--output-dir`，dry-run 文件集合要与授权完全相同。只有用户明确授权新增仓库规则入口时才加 `--include-agents`；默认不创建 `AGENTS.md`。

确认路径和授权后去掉 `--dry-run`。中断在 bootstrap 安装期间且当前仍有 `repo_write` 授权时，只运行：

```powershell
python -B <skill-dir>\scripts\bootstrap_long_task.py --repo <repo> --resume-bootstrap
```

标准/加固模式使用唯一 writer：

```powershell
python -B <skill-dir>\scripts\progress_long_task.py --repo <repo> resume-check
python -B <skill-dir>\scripts\audit_long_task.py --repo <repo>
python -B <skill-dir>\scripts\progress_long_task.py --repo <repo> note --summary "..."
python -B <skill-dir>\scripts\progress_long_task.py --repo <repo> checkpoint --label handoff --type state_snapshot --reason "..." --safe-to-resume
```

轻量模式的 `resume-check` 只返回人工核验入口；标准/加固模式返回 `technicalGates`。任何 `technicallySafeToEdit/canEdit` 都只是连续性技术结论，不等于用户授权。

把项目验证命令先固定到 `docs/execution/profiles.json`，再用 `run-evidence --profile <name>`。通用 CLI 不允许自由文本伪造 passed，也不会解锁 `unknown_after_interruption`；加固项目必须补动作专用 verifier。完整契约和命令见 [continuity-ledger.md](references/continuity-ledger.md)。

## 并行和裁决

把源码搜索、日志、测试矩阵、UI、参考项目和资料研究分给窄范围只读子代理。子代理不可用时，用主代理并行只读工具或顺序完成同一矩阵，不因此阻塞。

主代理必须复核结论。子代理最终摘要必须说明：只读/写入、修改文件、创建/删除、缓存/日志/构建产物、网络/下载、配置/环境变量/凭据、进程/服务、测试、commit hash 和需清理项；无则写 `none`。

## 验证和副作用

分开报告代码表面能力、自动测试、当前构建、当前应用启动、真实动作、业务后置状态、并发隔离、重启持久化和失败恢复。构建通过、API 接收、消息入队、mock 或旧截图都不能单独证明产品完成。

真实输入、数据库/AppData 写入、迁移、覆盖/删除、共享资源和发布前先登记 intent；普通本地 commit 记录 hash，本地服务登记 PID/命令/归属，push 前后核对远端 ref。数据库身份不明时标记 `blocked-needs-db-identity` 并按生产库处理；生产库写入永不代执行。

真实运行、安全、UI、多实例和失败矩阵读取 [validation-and-live-operations.md](references/validation-and-live-operations.md)。

## 进度和完成

工具工作期间每 30-60 秒给短更新；完成一个小闭环或约 10-20 分钟给“完成/当前/下一步”；阶段汇报说明证据、风险、是否真实启动/执行外部动作和下一可见结果 ETA 范围。

最终前必须等待或中断所有子代理，并在当前 workflow 和授权范围内运行可执行的完整验证；`read_only` 只运行经确认无写副作用的检查，其他验证报告未运行项及原因。再运行 `git --no-optional-locks status --short --ignored`，核对文件、ignored 产物、下载、配置、进程、服务、页签和外部状态。只清理能直接证明由本轮创建的目标。报告 commit hash、push 状态、真实运行边界和已知限制。

## 技能路由

- OpenAI/Codex 官方机制：`openai-docs`。
- 现有产品 UI 审计/渐进重设计：`redesign-existing-projects`；新前端实施：`design-taste-frontend`；仅明确要求 image-first 时使用 `image-to-code`。继承当前只读/实施授权。
- GitHub 仓库/Issue/PR 总览使用 `github`，审查意见使用 `gh-address-comments`，Actions 失败使用 `gh-fix-ci`；只有明确要求 branch + commit + push + draft PR 时使用 `yeet`。仅 commit/push 不自动创建 PR。下游返回 commit、远端 ref、检查状态、PR URL 和未验证项，由主代理写回台账。
- 有数据库专用技能/连接器时，传递库身份证据、授权、影响范围、备份、事务、回查和回滚条件；没有时由主代理协调。库身份不明保持 `blocked-needs-db-identity`，生产库写入永久禁止代执行。
- 文档、PDF、表格、演示使用对应 artifact skill。

## 停止条件

只有会实质改变方案的业务选择、新的外部授权、无法确认数据库/目标身份、缺少真实安全样本/备份/回滚条件，或安全替代路径也无法解决的阻塞，才停下询问。工作量大、测试慢或资料多不是停止理由。
