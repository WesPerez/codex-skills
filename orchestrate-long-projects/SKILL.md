---
name: orchestrate-long-projects
description: 显式维护复杂软件项目的持久连续性。仅在用户调用 $orchestrate-long-projects，或适用项目规则明确指定当前请求属于活动长期项目时使用；并且必须确有长期台账、跨阶段写入交接或未知非幂等外部动作需要恢复。普通会话/任务意外中断后新会话读取旧内容继续、仅阅读摘要或旧计划、单次本地代码续作、一般测试/CI/PR 和无恢复风险的任务不要使用。
---

# 长期项目连续性

本技能只解决需要持久状态的项目恢复、交接和未知副作用对账。普通会话上下文续接不是项目恢复；它不替代读取旧会话、handoff、代码分析、计划、实现或测试。

## 双重入口

两道门必须同时通过。

### 1. 显式路由门

至少满足一项：

- 用户调用 `$orchestrate-long-projects`。
- 适用 `AGENTS.md` 或项目规则明确说明当前请求属于活动长期项目，并要求使用本技能。

仅出现“继续上次”“上个会话中断”“读取之前的规划”“跨天了”等自然语言，不算显式路由。未通过时立即退出，正常读取旧会话、摘要、handoff、Git 和相关文件即可。

### 2. 持久连续性门

显式路由后还要至少满足一项：

- 当前请求确实推进或恢复活动 `STATUS.md`/`state.json` 指向的长期项目切片。
- 用户明确要求从现在开始建立可跨会话恢复的长期台账。
- 多 Agent 或多人会跨阶段写入同一项目，需要可靠 handoff 和冲突边界。
- 非幂等外部动作已经或即将发生，中断后必须判断是否生效，避免重复执行。

未通过第二道门也退出本技能，不 bootstrap、不写 STATUS、不运行 resume-check/full audit。

特别排除：普通会话意外中断后新开会话读取旧内容继续；上次只留下未提交本地代码；只重跑确定性的测试/构建；只阅读或总结旧计划；活动长期项目所在仓库中的无关小任务。这些都使用普通任务流程。

边界不清时读取 [invocation-boundaries.md](references/invocation-boundaries.md)，默认不使用本技能。

## 授权边界

单独确定：

- `read_only`：只读状态和源码，不创建/更新文件，不运行会写缓存或构建产物的命令。
- `plan_write`：只写用户要求的长期方案或轻量状态页。
- `repo_write`：修改仓库代码、测试和已授权台账。
- `externalAuthorization`：数据库、真实输入、AppData、发布、push、共享资源或其他外部状态的窄范围授权。

`repo_write` 不自动包含外部动作。连续性技术门禁也不等于用户授权。数据库身份不明时按生产库处理；生产写入永不代执行。

## 选择连续性级别

| 级别 | 适用情况 | 持久材料 |
|---|---|---|
| 快速退出 | 单次、自包含、无需恢复 | 不使用本技能 |
| 轻量 | 跨会话但无复杂并发或高风险动作 | canonical plan + `STATUS.md` |
| 标准 | 多模块、跨阶段交接、机器校验或明显中断风险 | state/events/evidence/checkpoints + 单写入器 |
| 加固 | 非幂等外部写入、数据库迁移、发布、共享目标或真实设备动作 | 标准版 + intent/result + 项目专用 verifier/lease |

选择最低足够级别。只读子代理、一次本地构建、普通浏览器 smoke 或用户要求“写详细一点”都不会自动升级。

## 开工路径

### 轻量

1. 读取适用 `AGENTS.md`、`STATUS.md` 和 canonical plan 的当前切片。
2. 运行一次 `git --no-optional-locks status --short`。
3. 核对唯一下一动作、用户授权和未决外部动作后继续。

轻量模式不运行 Python `resume-check` 和完整 audit，除非检测到部分安装、状态冲突或用户明确深审计。

### 标准或加固

1. 读取适用 `AGENTS.md` 和 `STATUS.md`。
2. 运行 `python -B <skill-dir>/scripts/progress_long_task.py --repo <repo> resume-check`。
3. fast check 返回 `safe_for_code_only` 时，可在当前 `repo_write` 授权内继续代码工作。
4. 只有命中升级条件时运行 `audit_long_task.py` 和必要的精确 Git/外部状态核验；旧台账若仅缺 fast 字段，full audit 只负责诊断，确认无其他异常后在 `repo_write` 下执行 `render` 迁移。
5. 允许继续后只读 canonical plan 当前 phase/slice，不默认通读 PROTOCOL、全账本或全部 checkpoint。

完整 audit 升级条件固定为：

- fast check blocked/ambiguous，或旧台账缺少 fast 数据；旧数据先 full 诊断，再显式 `render` 迁移。
- tail、checkpoint、STATUS 或 schema 完整性异常。
- 存在 `unknown_after_interruption`、未决外部动作或无法解释的 Git drift。
- 准备 external/live/destructive 动作。
- 阶段完成、handoff、发布、push 或最终交付前。
- 用户明确要求 deep/full audit。

除此之外不自动运行 full audit，也不追加重复的独立 `git status`。

## 推进切片

一次只推进一个用户可观察切片：

1. 明确范围、非目标、失败模式和验收条件。
2. 做最小代码/文档改动。
3. 为每个失败模式选择最低充分验证。
4. 只有变更触及构建、启动、UI/API、持久化或外部系统时才升级到对应验证。
5. 在真实停止点更新状态并留下恢复所需的最小证据。

不要把“局部测试 -> 构建 -> 启动 -> UI/API -> 真实动作 -> 后置验证”当成每个切片的固定链。详细验证工具箱见 [validation-and-live-operations.md](references/validation-and-live-operations.md)。

## 台账节奏

仅在这些语义边界写 durable 状态：

- 切片开始或完成。
- 路线、范围、授权或 blocker 变化。
- 长暂停、handoff、上下文压缩或异常中断。
- 高风险外部动作 intent 前、result 后或结果未知。
- commit/push/发布前后。

普通 `rg`、无变化轮询、重复测试和细小 note 不创建 checkpoint。不可变 checkpoint 只用于 handoff、长暂停、阻塞、高风险动作、commit/push 前和切片真正完成时。

标准/加固工具和命令见 [continuity-ledger.md](references/continuity-ledger.md)。首次建立体系时先 dry-run；`read_only` 不 bootstrap，`plan_write` 只允许明确授权的 light 模式。

## 证据和副作用

`run-evidence` 只用于标准/加固模式下需要绑定当前源码的固定验证命令。代码存在、构建成功、API 接收、消息入队、mock 或旧截图都不能替代其未覆盖的真实业务结果，但也不因此要求所有任务执行真实系统验证。

非幂等外部动作使用：

```text
intent -> execute -> result -> postcondition evidence
```

中断后的 `running` 视为 `unknown_after_interruption`，必须先由项目专用 verifier 对账，禁止重放。

## 并行

只把边界清晰、可并行、主要只读的探索、测试和资料核验交给子代理。子代理不写共享台账、不接管真实外部系统；主代理汇总精简结论。并行无法带来明显信息或时延收益时不使用。

## 完成和交接

轻量模式：运行本次变更需要的最低充分验证和一次 Git 状态核对，更新 STATUS/plan 的真实停点。

标准/加固模式：在完成、handoff、发布或 push 前运行一次完整 audit；核对当前证据、未决动作、Git drift、进程/页签/下载/配置和外部状态。只清理能直接证明由本任务创建的目标。

最终报告分开说明：代码表面能力、测试、构建、当前运行、真实动作、后置状态、持久化/恢复和未验证项。不要用单一百分比代替真实完成度。

## 按需引用

- 不确定是否应调用本技能时读取 [invocation-boundaries.md](references/invocation-boundaries.md)。
- 用户明确要求长期项目审计或 canonical plan 时读取 [discovery-and-master-plan.md](references/discovery-and-master-plan.md)。
- 恢复、台账和工具契约读取 [continuity-ledger.md](references/continuity-ledger.md)。
- handoff 或提示词模板读取 [handoff-and-prompts.md](references/handoff-and-prompts.md)。
- 外部研究会改变架构或安全边界时读取 [research-basis.md](references/research-basis.md)。
- 当前切片触及运行、UI、数据库、并发、失败恢复或发布时读取 [validation-and-live-operations.md](references/validation-and-live-operations.md)。

不要为了“全面”一次性读取全部引用。
