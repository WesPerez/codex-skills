# 当前 Sub2API 个性化职责基线

此文件是 2026-07-25 `0.1.165` post-confirm 后的职责快照：**当前生产** `322e2c9003afeffc3b5c7c2d6f61e5d02a22ee40`（`0.1.165`）；上游基线 `2730c1c43b29be003925b033f3f9e645e726bb8c`；**上一生产** `61d5b363fe7cd370f73517973aec361303afb77f`（`0.1.164`）。它用于缩短下一次 discovery，不能替代实时 `merge-base`、range-diff、源码、CI 和运行证据。

旧 MINE 的 4 个逻辑职责在 `0.1.165` 上按实时语义重建为 3 个提交：D1 发布/CI/文档、D2 DB/Grok ID、D3+D4 合并后的 gateway 兼容残差。下一次升级先验证职责和替代关系仍成立；不能因 SHA、文件名或提交数变化就判定职责消失。不触碰 Router/Composite 职责，除非实时 diff 明确触及且已单独对照。

## 职责总览

| ID | 候选提交 | 核心职责 | 默认验证 case |
| --- | --- | --- | --- |
| D1 | `0294dea1a` | 分支发布、服务器禁本地构建、debug exact image、mine digest promotion，以及 Compose/entrypoint/network 生命周期边界 | `R0-*`, `R2-2` |
| D2 | `7a70c75ef` | Grok 账号 ID 分配器与已应用迁移 175/177 | `R1-M1..M3`, `R0-8` |
| D3 | `322e2c900` | OpenAI-compatible passthrough、SSE/error、SharedChat、动态 probe，以及采用上游替代后的 pool/retry 语义 | `R1-E*`, `R1-F*`, `R1-G*`, `R1-H*`, `R1-I1/I3`, `R1-B1` |
| D4 | `322e2c900` | Grok stream 控制、usage、tool 兼容边角、response handling 和 first-output 预算 | `R1-C*`, `R1-E*`, `R1-G1`, `R1-H1` |

planner 只纳入路径真实触发且 production active inventory 允许的 case。表中是职责上限，不代表每次必须执行整个 suite；同一运行证据可以支撑多个 case。

## D1 分支发布与部署边界

- `main` 精确跟随 upstream；个性化只在 `debug`/`mine`。
- `debug` 运行完整 CI 并发布不可变 `debug-sha-<40>`；`mine` 只 carbon-copy 已 sealed 的 exact digest，不重复构建。
- promotion receipt、evidence hash、OCI revision/ref 和 digest 共同授权生产；镜像内 `ref.name=debug` 是预期内容身份。
- 生产只 recreate `sub2api`，不重建 PostgreSQL/Redis，不让 Router 指向 debug。
- 生产代理 bridge 属于 D1 发布输入：Compose 保持 default-only，显式声明 entrypoint/CMD，运行态 attach 后才允许迁移和应用进程继续。

关键文件：`.github/workflows/backend-ci.yml`、`docker-branch.yml`、`promote-debug-image.yml`、`sync-upstream-main.yml`、`deploy/verify-image-provenance.py`、`AGENTS.md`、`BRANCH_DEPLOYMENT.md`。

## D2 Grok 账号 ID 分配与迁移

- 保留 `175_grok_account_id_allocator.sql` 与 `177_grok_account_id_allocator_hardening.sql` 的完整文件名和 runner `TrimSpace` checksum。
- 分配器、序列/约束、并发和软删除由单元/集成测试覆盖。
- 上游相同数字前缀但不同完整文件名不是 migration identity 冲突。

已应用迁移不得删除、改名、合并、改内容或直接修补 `schema_migrations`。候选 schema 必须同时证明连续升级和旧应用 image-only rollback 兼容。

## D3 OpenAI-compatible、Pool 与 Test Connection

职责包含：

- API-key Responses/Chat 的 stream/nonstream、compact、HTTP profile、首包边界和 client cancel；
- HTTP 200 后 SSE `response.failed` 的解析、错误透传和池重试；
- pool 同账号重试遵循上游 status-aware cooldown、retry count 和 session hash；槽位不可用时换号且不能提前提交响应；
- 旧 MINE 的 request-local pin、`SkipStickyBinding`、pool audit、sticky `ExcludedIDs`/rebind 和 scheduler `pool_mode` projection 不再作为当前职责实现，避免与上游调度语义重复或过宽；
- Test Connection 不再硬编码 `hi`，从 inventory/order/temperature 等小型任务族生成一次性有意义探针，并以结构和语义验收，拒绝无意义 `ok`。

关键文件：`openai_account_scheduler.go`、`openai_gateway_handler.go`、`openai_gateway_passthrough.go`、`openai_gateway_response_handling.go`、`openai_sse_trailing_error.go`、`openai_pool_sse_failover_test.go`、`account_pool_mode_test.go`、`account_test_probe.go`、`account_test_service.go` 及对应测试。

管理端 Test Connection 的实现虽已改善，策略上仍不得把它当常规 smoke。合规 Codex smoke 只能由官方客户端发起。

## D4 Grok Stream 与 Tool 兼容

- 保留 Grok stream wall clock、client disconnect grace、usage snapshot 和 response handling 控制。
- 保留 Chat bridge custom/function 累积、孤立 `tool_choice` 清理和必要的 completed output 兼容。
- 当前 `0.1.165` 上游树已用 `responses_client_tools.go`、`openai_gateway_grok_tool_protocol.go` 承接 custom/namespace/tool_search 主体，因此不重放旧 `openai_gateway_grok_tools.go` 整文件。

关键文件：`config.go`、`openai_gateway_grok.go`、`openai_gateway_response_handling.go`、`responses_to_chatcompletions.go`、`gateway_service.go` 及对应测试。

## 池模式取舍与后续完善

本次冻结问题的上游替代关系已经明确：OpenAI 采用 `521db6869` 的“仅对账号配置的 retryable 状态跳过 model cooldown”，Grok 采用 `51f354f5c` 的 pool 5xx 处理；这比旧 MINE 的“整个 pool 一律绕过 cooldown”更精确，能保留 non-retryable 状态的保护。上游基础 same-account retry、`PreserveStickyBinding` 和 `ensureOpenAIPoolModeSessionHash` 继续保留。

池模式仍保留的个性化/兼容职责包括：`pool_mode_retry_count` 与 `pool_mode_retry_status_codes` 的账号级配置、裸 5xx 和 200+SSE `response.failed` 的错误分类与 trailing-event 处理、首包前 failover/首包后不换流、first-output 预算、usage/终态保护，以及对应的 pool/SSE/错误策略测试。删除的是调度选择层的重复实现，不是这些协议和错误处理能力。

与旧 MINE 相比，当前主动舍弃的是 request-local 选号 pin、30 秒 slow-failure cutoff、pool attempt audit/exhausted 结构、sticky 失败后的 `ExcludedIDs`/rebind，以及 scheduler cache 的 `pool_mode` projection。它们不是静默漏合并，而是采用上游主干后移除的重复或过宽路径；代价是 sticky 逃逸后重新选号、pool 元数据识别和运维可观测性的行为需要继续用独立 dev 故障注入、调度日志和真实 pool 配置完善证明。

因此当前结论是：**对“瞬时冻结”这个问题，上游方案更优**，因为它按 retryable 状态精确跳过 cooldown，代码更少、与上游主干一致，也避免旧 MINE 的全池宽绕过；**旧 MINE 在 sticky 逃逸防抖、pool 运维审计和强制同账号选择上更丰富**，但这些行为没有被上游完全等价复制，且会增加调度复杂度和分叉面。非 pool 个性化职责以及 Grok、迁移、发布职责均保留。后续升级仍需验证上述取舍不会引入重新选回旧账号、retry status 配置遗漏或总重试预算放大的行为差异。

## 0.1.165 保留确认

| 范围 | 当前决策 |
| --- | --- |
| 发布/文档/工作流 | D1 完整保留；源码仓库文档归 D1，技能文档和生产部署文件按各自仓库/部署边界管理 |
| 迁移/Grok ID | D2 的 `175/177` 字节级保留；上游 `187–190` 同时保留 |
| OpenAI 非 pool | API-key passthrough、SharedChat、HTTP profile、SSE trailing、probe、first-output 等保留 |
| Grok/工具/流 | wall/grace、usage、tool choice/accumulator、completed 终态和 response handling 保留；上游已有主体不重复实现 |
| Pool 协议层 | retry count/status codes、错误分类、SSE/终态、首包和预算保护保留 |
| Pool 调度层 | 采用上游 status-aware retry/cooldown；旧 pin/rebind/audit/projection 有意退出当前实现，按后续验证方向管理 |

## 已由上游吸收

- 旧 D4 的 Codex client tools 主体已由当前上游树承接；候选只保留上游缺失边角。
- 旧 D5 axios 安全升级已在当前上游版本线中，不再保留重复个性化提交。
- Composite groups/routes 已在当前上游树中。候选三个提交不修改 Composite 或 Router；生产未创建/启用 composite 分组时，现有 OpenAI/Grok 单平台职责不迁移给 Composite。

## 每次升级的职责对照模板

| Duty | 旧实现/提交 | 新上游实现 | 剩余差异 | 决策 | CI | Debug/生产 case | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 |  |  |  |  |  |  |  |
| D2 |  |  |  |  |  |  |  |
| D3 |  |  |  |  |  |  |  |
| D4 |  |  |  |  |  |  |  |

最终提交数取实时语义结果，不为维持数量保留被上游取代的代码。已知修复应 fixup 回所属职责后，再为最终 SHA 重建 CI、image 和验证证据。
