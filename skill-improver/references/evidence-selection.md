# 风险驱动的证据选择

仅在结论依赖外部产品事实、工程实践或社区案例时读取本文。结构、文本或本地可复现行为不需要重新研究这些来源。

## 核心原则

验证目标不是达到最高层，而是用最快、可靠、可定位的证据降低具体风险。不同证据层是路由，不是累计清单；更高层只证明低层无法观察的主张。

来源冲突时采用：当前可复现产品行为 > 产品官方文档 > 正式标准 > 大型工程实践 > 专家经验 > 社区线索。安全、权限和生产边界始终服从更严格规则。

## 来源治理

最后核验：2026-07-13。

| 来源 | 直接支持 | 不可外推边界 |
|---|---|---|
| [OpenAI Codex Build skills](https://developers.openai.com/codex/skills) | 渐进披露、description 隐式触发、`allow_implicit_invocation`、单技能单职责、触发测试 | 不定义本技能的 E0-E4，也不证明任意第三方脚本可用 |
| [OpenAI Codex manual](https://developers.openai.com/codex/codex-manual.md) | 长任务、项目、AGENTS、子代理和上下文成本的当前产品说明 | 不能替代当前仓库或运行现场证据 |
| [Using PLANS.md for multi-hour problem solving](https://developers.openai.com/cookbook/articles/codex_exec_plans) | ExecPlan 适用于复杂功能/重大重构和多小时工作；里程碑应可验证且避免官僚化 | 不要求普通任务建立完整台账 |
| [Microsoft unit testing best practices](https://learn.microsoft.com/dotnet/core/testing/unit-testing-best-practices) | 快速、隔离、可重复、自校验的低层测试反馈 | 不定义 Codex 技能授权边界 |
| [Google: Just Say No to More End-to-End Tests](https://testing.googleblog.com/2015/04/just-say-no-to-more-end-to-end-tests.html) | E2E 通常更慢、更不稳定、更难定位，数量应少 | 70/20/10 不是通用硬规则，不能跳过高影响真实集成 |
| [Practical Test Pyramid](https://martinfowler.com/articles/practical-test-pyramid.html) | 多粒度证据与避免重复测试 | 专家经验，不是产品规范 |
| [Temporal Continue-As-New](https://docs.temporal.io/workflow-execution/continue-as-new) | 历史接近阈值时滚动，checkpoint 放在语义边界 | Temporal 数值限制不能直接变成 Codex 阈值 |
| [Airflow Best Practices](https://airflow.apache.org/docs/apache-airflow/stable/best-practices.html) | 幂等、确定输入、小控制消息和外部大产物引用 | Git 工作树不是数据库事务 |
| [Prefect result persistence](https://docs.prefect.io/v3/develop/results) | 持久化是按需能力，不必成为所有任务默认 | 默认设置不是安全或审计标准 |

社区材料只用于发现候选故障模式。例如 openai/codex [#17229](https://github.com/openai/codex/issues/17229)、[#21211](https://github.com/openai/codex/issues/21211)、[#20781](https://github.com/openai/codex/issues/20781) 和 [#28224](https://github.com/openai/codex/issues/28224) 报告了重复 Git 查询、无边界历史加载、重复大快照和高频日志写入等性能现象。它们是版本相关报告，不是官方承诺；只有当前技能代码存在同类机制时才作为优化线索。

## 选择示例

### 只修改 description

风险是误触发或漏触发。使用 E0 结构校验和 2-4 个触发推演；通常不需要网络、真实系统或子代理。

### 修改本地脚本

风险是编码、参数、退出码、路径和输出格式。使用 E0 + E1；只有核心行为依赖实时外部响应时再增加一个 E3。

### 修改工具或文件契约

风险是上下游字段、错误语义和交接丢失。使用 E0 + E2 的固定 fixture 或隔离集成测试；不要因为存在两个技能就自动使用 E4。

### 修改浏览器、认证或数据库流程

先用 E0-E2 覆盖解析、参数和安全门。只有已确认只读或隔离、可回滚的环境才执行一个最小 E3。生产写入永不作为验证。

## 停止条件

- 当前主张已有一个能够直接观察它的最低充分证据。
- 更高层只会重复同一断言，不会改变决策。
- 外部资料只支持背景，当前本地行为已经可复现。
- 安全门、环境或授权阻止升级，且已记录残余风险。

证据在技能、依赖、运行环境、接口格式或相关失败模式变化后失效。纯措辞和无关引用修改不会自动使所有运行证据失效。
