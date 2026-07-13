# 多源研究依据

## 目录

1. 使用原则
2. OpenAI/Codex 官方实践
3. 耐久工作流和任务编排
4. CI、产物和并发
5. 决策记录和项目跟踪
6. Agent 持久化和上下文退化
7. 社区 issue 的使用边界
8. 本技能的综合推导

## 1. 使用原则

外部资料用于减少重复思考，但不能替代当前项目证据。本文整体最后核对于 `2026-07-13`；具体能力、页面版本和产品行为必须在使用时重新确认。链接失效时寻找官方新位置，不凭旧摘要补全。

结论分四类：

```text
official_fact       官方明确描述的能力或限制
mature_pattern      成熟系统经过实践的设计模式
community_report    公开报告的故障模式，未必普遍
empirical_observation 厂商或研究团队公开实验观察，适用范围取决于实验条件
project_inference   结合当前项目风险作出的工程判断
```

## 2. OpenAI/Codex 官方实践

每条只把官方页面明确描述的机制标记为 `official_fact`；由这些机制推导出的技能设计仍属于 `project_inference`。

- [Using PLANS.md for multi-hour problem solving](https://developers.openai.com/cookbook/articles/codex_exec_plans)
  - ExecPlan 是 living document。
  - 适用对象是复杂功能、重大重构和多小时问题，不是所有多步骤任务。
  - 保持 Progress、Surprises & Discoveries、Decision Log、Outcomes & Retrospective。
  - 后来者应能只凭计划继续。
  - 写清命令、验证、幂等和恢复方式。
  - Milestone 应是可验证的叙述，不应变成官僚化事件流水；启动系统只在适用时执行。

- [Build skills](https://developers.openai.com/codex/skills)
  - Skill 使用渐进披露；description 决定隐式触发，必须简洁并写清范围和排除项。
  - 每个 skill 应聚焦一个 job。
  - `agents/openai.yaml` 可用 `policy.allow_implicit_invocation: false` 保留显式调用并关闭隐式调用。

- [AGENTS.md](https://learn.chatgpt.com/docs/agent-configuration/agents-md)
  - 用于仓库级持久规则、构建命令和完成定义。
  - 支持从仓库根到当前目录的分层指令链；把主文件保持简洁、专项流程拆到引用文档是本技能的 `project_inference`。

- [Subagents](https://learn.chatgpt.com/docs/agent-configuration/subagents)
  - 适合并行探索、测试、日志和总结。
  - 多代理并行写共享文件会增加冲突。
  - 每个子代理都会增加 token 和运行成本；递归扇出会增加延迟和资源消耗。

- [Hooks](https://learn.chatgpt.com/docs/hooks)
  - 可在 SessionStart、PreCompact、PostCompact、Stop 等生命周期执行检查。
  - “Hook 是增强，不替代 Git、checkpoint 或外部状态对账”属于 `project_inference`。

- [Worktrees](https://learn.chatgpt.com/docs/environments/git-worktrees)
  - 隔离并行代码修改。
  - ignored 文件默认不会随 worktree/handoff 移动，官方同时提供 `.worktreeinclude` 例外；外部运行状态不会自动迁移属于 `project_inference`。

上述官方页面未描述恢复精确 PID、HWND、数据库事务、AppData 或已执行但未记录外部动作的能力，因此不能据此推断这些状态可恢复；这是基于文档边界的 `project_inference`。

## 3. 耐久工作流和任务编排

以下主要用于提取 `mature_pattern`，不是要求给普通代码项目部署完整工作流平台。

- [Temporal Event History](https://docs.temporal.io/workflow-execution/event)
- [Temporal Activities and idempotency](https://docs.temporal.io/activities)
- [Temporal Retry Policies](https://docs.temporal.io/encyclopedia/retry-policies)
- [Temporal Continue-As-New](https://docs.temporal.io/workflow-execution/continue-as-new)
- [Airflow Tasks](https://airflow.apache.org/docs/apache-airflow/stable/core-concepts/tasks.html)
- [Airflow Best Practices](https://airflow.apache.org/docs/apache-airflow/stable/best-practices.html)
- [Prefect States](https://docs.prefect.io/v3/concepts/states)
- [Dagster Run Retries](https://docs.dagster.io/deployment/execution/run-retries)

可借鉴：

- 追加历史与当前投影分离。
- workflow/run/task instance/attempt 分离。
- 外部 activity 可能执行多次，业务效果必须幂等。
- 本技能把 `running`、`failed_retryable`、`failed_terminal`、`unknown` 明确区分；这是综合中断风险得到的 `project_inference`，不是所有编排系统共享的固定状态集合。
- Temporal Continue-As-New 在同一 Workflow ID 下创建新的 Run ID 和 Event History，并保留 execution chain 关联；它不是 Parent/Child Workflow 关系。

不应照搬完整服务端、调度器、元数据库或 worker 集群，除非项目本身需要。

## 4. CI、产物和并发

以下为 `official_fact` 与 `mature_pattern` 的组合：官方文档说明具体机制，本技能只借鉴其证据绑定和并发控制思路。

- [GitHub Actions rerun](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)
- [GitHub Actions artifacts](https://docs.github.com/en/actions/tutorials/store-and-share-data)
- [GitHub Actions concurrency](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency)

可借鉴：

- 重跑绑定原始 SHA/ref，而不是默认使用最新源码。
- artifact 命名、hash 和保留期；不可变性特指当前 GitHub Actions `upload-artifact@v4` 机制，不泛化为所有产物系统。
- 使用并发键保护共享资源。
- 局部失败只重跑可重试单元，但最终完成要聚合全部关键 gate。

## 5. 决策记录和项目跟踪

ADR、issue 和 milestone 是 `mature_pattern`；它们展示决策或任务组织，不自动构成产品验收证据。

- [Microsoft ADR guidance](https://learn.microsoft.com/azure/well-architected/architect-role/architecture-decision-record)
- [GitHub engineering ADR practice](https://github.blog/engineering/architecture-optimization/why-write-adrs/)
- [GitHub sub-issues](https://docs.github.com/en/issues/tracking-your-work-with-issues/using-issues/adding-sub-issues)
- [GitHub milestones](https://docs.github.com/en/issues/using-labels-and-milestones-to-track-work/about-milestones)

可借鉴：

- 已接受 ADR 不回改，方向变化使用新 ADR supersede。
- Issue/milestone 展示任务数量，但不能替代验收证据。
- 决策记录保留当时上下文、替代方案和后果。

## 6. Agent 持久化和上下文退化

工具文档属于各自实现事实；Chroma Context Rot 属于厂商公开控制实验的 `empirical_observation`，不是同行评审论文；跨工具综合结论属于 `project_inference`。

- [LangGraph Persistence](https://docs.langchain.com/oss/python/langgraph/persistence)
- [OpenHands conversation persistence](https://docs.openhands.dev/sdk/guides/convo-persistence)
- [SWE-agent trajectories](https://swe-agent.com/latest/usage/trajectories/)
- [Aider Git integration](https://aider.chat/docs/git.html)
- [Chroma Context Rot](https://research.trychroma.com/context-rot)

综合经验：

- 对话越长不代表越可靠；噪声、长日志和无关上下文增加时，判断质量可能下降，程度取决于模型和任务。
- 运行态、证据和动作句柄必须在线程外结构化保存。
- 原始长输出外置，主线程保留摘要、路径和 hash。
- Git 适合代码恢复，不保存外部系统和 ignored 现场。

## 7. 社区 issue 的使用边界

不要在通用技能中保留没有 issue URL、编号、日期和维护者回复的笼统“社区都遇到过”结论。社区材料必须在具体项目研究中逐条登记：

- URL、标题、编号、创建/更新日期和当前状态。
- 复现环境、版本、原始日志或截图。
- 维护者回复、修复提交或关闭原因。
- 它支持什么故障模式，又不能证明什么。

表述使用 `community_report`，例如“该 issue 报告在版本 X 中出现 Y”；不得改写成官方确认、所有版本必现或厂商 SLA。论坛帖子、博客和视频评论同样只用于发现故障模式，关键能力边界仍回到官方文档和当前项目实测。

与本技能成本控制相关的公开线索包括 openai/codex [#17229](https://github.com/openai/codex/issues/17229)、[#21211](https://github.com/openai/codex/issues/21211)、[#20781](https://github.com/openai/codex/issues/20781) 和 [#28224](https://github.com/openai/codex/issues/28224)。这些报告分别涉及重复 Git 查询、无边界历史加载、重复大快照和高频日志写入；它们只用于识别同类风险，不能证明当前版本必现或给出产品承诺。

## 8. 本技能的综合推导

以下是工程推导，不是任何单一来源的强制要求：

- 单写入器维护 state、账本和 STATUS。
- 副作用前 intent、后 result，中断后 unknown。
- 证据绑定 HEAD、工作树指纹、命令、退出码、产物 hash 和环境。
- 运行观察设置 TTL；过期 PID/HWND 只作线索。
- 代码完成和真实业务完成分轴报告。
- 主代理汇总子代理，子代理默认只读。
- STATUS 由 state 生成，禁止手工维护两份真相。
- 提交、push、外部输入和清理都需要重新证明目标与归属。
- 普通自包含任务不建立长期台账；跨会话连续性才启用持久状态。
- 会话意外中断、换线程或读取旧计划本身不等于持久连续性；本技能采用显式调用，项目规则也只能路由明确属于活动 STATUS 的请求。
- 恢复先运行有界 fast check；完整历史、artifact 和 Git 指纹只在异常、高风险动作、handoff 或最终交付时核验。
- Checkpoint 放在语义恢复边界，不随每个 note、轮询或重复测试增长。
- 高层验证只覆盖低层无法证明的主张，不在多层重复同一断言。
