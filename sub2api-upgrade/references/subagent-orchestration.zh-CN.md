# Sub2API 升级子代理编排

## 目标

用最多 8 个子代理缩短 discovery、静态复核和 CI 等待墙钟，同时让主代理独占所有共享写入、高风险判断与生产动作。把并发用在独立只读取证，不把共享工作区、debug 身份或生产系统变成并发写集。

## 硬边界

1. 令 `N = min(8, 当前可用子代理槽)`；按独立证据包数量派发，不为占满槽位制造任务。无新上游时在派发前 no-op 停止。
2. 子代理默认用 `explorer`、只读、`fork_turns="none"`，不得再派生子代理。任务消息必须自包含冻结 SHA、路径、范围、禁止项、停止条件和证据格式。
3. 主代理独占：fetch 后的 ref 冻结、Git checkout/commit/rebase/fixup/push、evidence 写入、debug Compose/fixture/snapshot/matrix、promotion、生产 preflight/apply/confirm、rollback、finalize 和清理。
4. 子代理禁止：改文件/分支/远端、启动或停止容器、连接生产数据库、读取凭据、对 Sub2API 或上游 provider 发 canary/probe/生成请求、调用 Test Connection、占用 canary/OAuth 身份、写 evidence 目录或执行任何 apply。
5. 主代理写入时不允许子代理读取可变工作树。子代理只读阶段主代理不得同时修改其输入；使用完整 SHA/固定路径，不使用会移动的 `HEAD`、`debug`、`mine` 或 `upstream/main` 名称作为审计输入。
6. 子代理结论不是放行证据。主代理必须复核文件/行号、命令结果、run ID、SHA/digest 和不确定点；结论冲突时不投票，以实时运行态、sealed evidence、源码/测试、官方文档的顺序裁决。
7. 测试默认由主代理统一执行。审查/探索代理只读现有测试与 CI 结果，不启动测试套件、后台进程或长等待。只有唯一 CI waiter 可执行明确的前台 wait；若主代理明确委派单个有界 stub 测试，必须保证无其他测试并发、记录准确 PID/命令并只收束自身进程。禁止 `pkill`、按名称杀进程或清理其他代理产物。

## S0：主代理快速闸门

在大规模派发前完成：读取运行时档案与职责基线；核实目标部署；刷新一次 `origin`/`upstream`；记录生产 revision/digest、running upstream base、`upstream/main` SHA、分支头和工作树状态。

- 若 `upstream/main` 没有超出 running upstream base 的新提交，且用户没有指定额外修复，报告“已是最新可验证上游”并停止；不要创建候选、跑 CI 或启动 8 个空任务。
- 若目标/运行态/工作树不清，停止并先解决闸门；不要把含糊输入分发给多个代理。
- 闸门通过后冻结上述 SHA。在本轮只读扇出结束前不再 fetch、checkout 或移动 refs。

## Wave A：发现扇出（最多 8 个只读代理）

按实际 diff 合并或省略空任务；大版本/多职责变更可全部启用：

| 槽 | 独立证据包 | 必须返回 |
| --- | --- | --- |
| A1 | 新上游提交与风险面 | 提交/路径分类、潜在间接路径、证据行号 |
| A2 | D1 发布/工作流/部署职责 | 旧实现→新上游→剩余差异→测试 |
| A3 | D2 migration/schema/rollback | 已应用文件、runner checksum、expand/contract 或 forward-only 风险 |
| A4 | D3 OpenAI/Responses/pool/retry | 语义重叠、保留差异、协议/调度 case |
| A5 | D4 Grok/tools/stream | 语义重叠、保留差异、tools/stream case |
| A6 | 测试与 plan 触发 | 路径→suite/case、漏掉的动态/间接路径；不得缩减最终门禁 |
| A7 | 运行拓扑与事故卡 | 只读文件/服务证据、Watchtower/Router/Nginx/任务风险；不连生产 DB |
| A8 | 独立反向审查 | 版本倒退、遗漏职责、错误假设、最可能导致第二次 CI 的问题 |

等待全部相关结果。主代理去重并填写职责表；任一职责证据不足时停止。不要让子代理直接编辑候选。

## 主代理单写与 Wave B：冻结候选复核

1. 主代理独自语义重建候选，完成 `git diff --check`、迁移/版本检查和测试映射；把已知修复收回职责提交。
2. 创建本地候选提交并记录完整 candidate SHA。暂停写入，按非空风险面把精确 SHA 分给 1–6 个只读复核代理；可覆盖职责语义、migration/rollback、测试/plan、workflow/deploy、协议风险和独立反向审查，小改动应合并职责而非凑数量。
3. 等待全部复核后只做一轮合并修复。SHA 改变时只复派受影响职责与独立 reviewer；不得带着未解释分歧推 debug。
4. 主代理运行最终 `plan-sub2api-upgrade.sh`。将 plan 的三类 diff、active inventory 和人工间接路径与子代理结果交叉核对。

这两波的目的，是在第一次远端 CI 前找到语义遗漏；不得让多个代理并发写不同职责后再赌合并无冲突。

## Wave C：CI 等待窗

推送 `debug` 后可复用已完成线程做 follow-up，但总并发仍不超过 `N`：

| 任务 | 权限/停止点 |
| --- | --- |
| 精确 CI waiter | 只运行不带 `--pull` 的 `wait-branch-image.sh`；返回 run/SHA/status，失败即停 |
| debug readiness | 只读 isolation、端口、fixture manifest 与 snapshot dry-run；不得 start/stop/apply |
| matrix preparation | 核对选中 case、负例、人工断言和身份闸门；不得写 run/evidence |
| production refresh | 只读文件/HTTP/服务状态；active inventory 和任何生产 DB 查询仍由主代理完成 |
| report/recovery preparation | 预填职责表、回滚判定与命令参数；不得触发 promotion |
| CI failure triage | 仅在失败后读取精确 job 日志，归纳同类静态问题；不得自动重推 |

进入 debug 前等待相关准备完成，由主代理用 `--no-wait --pull` 对同一成功 run/SHA 拉取镜像并重新验 digest。CI 等待期间不得修改候选；若发现问题，取消进入 debug，主代理统一修复并产生新 SHA。

## 共享运行态与生产阶段

- Debug：主代理或唯一受控执行者串行占用全局锁；所有 canary、fixture、OAuth、日志窗和 matrix evidence 都不并发写。子代理只能在主代理给出的脱敏原始结果上做只读分析。
- Promotion/production：主代理独占。可用 1 个只读 reviewer 复算命令参数或 receipt，但不得由它触发 workflow、pull/apply、canary、rollback 或 finalize。
- 任何 `no_replay`/计费请求中断都保持 blocked，不因空闲槽自动重发。

## 派发与回报契约

每个任务写明：`Goal`、`Scope`、冻结 `Context`、`Permissions`、`Constraints`、`Stop conditions`、`Evidence required`、`Output contract`、`Join policy`。回报只包含：结论、证据指针、不确定点、主代理待办；大日志留在子线程。

审查任务明确写入“仅静态读取，不运行测试”；测试任务由主代理单独排队。不要让“可运行本地测试”成为多个 reviewer 同时启动同一套件的默认权限。

关键波次使用 `wait_all`。只在范围漂移、重复劳动、写集冲突、门禁失败或用户改变停点时 steer/interrupt。结束前取得结果并完成或明确终止本次启动的全部子代理。

## 性能验收

把收益记在既有阶段时间中：比较 `discovery + candidate` 到第一次 push 的墙钟、首次 CI 通过率、候选 SHA 数、matrix manual/blocked 数和 apply→confirm 间隔。子代理 token/数量不是成功指标；首次候选更完整、等待窗被有效覆盖且没有新增冲突才是。

## 设计依据

- [Codex Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents.md)：并行优先读密集探索，主线程汇总摘要，写密集任务谨慎隔离。
- [GitHub concurrency](https://docs.github.com/en/actions/using-jobs/using-concurrency)：发布/提升不取消在途 run；等待和准备可分离。
- [Docker GitHub Actions cache](https://docs.docker.com/build/ci/github-actions/cache/)：cache 只加速，不替代 provenance 与 digest 证明。
- [Google SRE Release Engineering](https://sre.google/sre-book/release-engineering/) 与 [Canarying Releases](https://sre.google/workbook/canarying-releases/)：不可变工件、可观测窗口、失败快返和小步发布。
- [Microsoft Test Impact Analysis](https://learn.microsoft.com/en-us/azure/devops/pipelines/test/test-impact-analysis)：影响分析必须有安全兜底，不能覆盖多机动态路径的最终门禁。
- [Argo Rollouts Analysis](https://argo-rollouts.readthedocs.io/en/stable/features/analysis/)：把 canary 信号、失败阈值和 promote/abort 分开记录。
