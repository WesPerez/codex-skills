# 当前 Sub2API 个性化职责基线

此文件是 2026-07-24 对候选 `61d5b363fe7cd370f73517973aec361303afb77f`、上游 `cb24522dd53f8f363d008e3afdc8e4baf9788cab`（`0.1.164`）和生产 `13b41759f68a85d86c38fba4dad12f13b4792682`（`0.1.162`）的已核验快照。它用于缩短下一次 discovery，不能替代实时 `merge-base`、range-diff、源码、CI 和运行证据。

生产 5 个逻辑提交已经在 `0.1.164` 上按职责整理为 4 个提交。下一次升级先验证这些职责仍存在；不能因 SHA、文件名或提交数变化就判定职责消失。

## 职责总览

| ID | 候选提交 | 核心职责 | 默认验证 case |
| --- | --- | --- | --- |
| D1 | `afa331422` | 分支发布、服务器禁本地构建、debug exact image、mine digest promotion 与部署边界 | `R0-*`, `R2-2` |
| D2 | `1c1a229f6` | Grok 账号 ID 分配器与已应用迁移 175/177 | `R1-M1..M3`, `R0-8` |
| D3 | `007938754` | OpenAI-compatible passthrough、SSE/error、pool/sticky 逃逸、request-local retry、动态 Test Connection | `R1-E*`, `R1-F*`, `R1-G*`, `R1-H*`, `R1-I1/I3`, `R1-B1` |
| D4 | `61d5b363f` | Grok stream 控制、usage、tool 兼容边角和 response handling | `R1-C*`, `R1-E*`, `R1-G1`, `R1-H1` |

planner 只纳入路径真实触发且 production active inventory 允许的 case。表中是职责上限，不代表每次必须执行整个 suite；同一运行证据可以支撑多个 case。

## D1 分支发布与部署边界

- `main` 精确跟随 upstream；个性化只在 `debug`/`mine`。
- `debug` 运行完整 CI 并发布不可变 `debug-sha-<40>`；`mine` 只 carbon-copy 已 sealed 的 exact digest，不重复构建。
- promotion receipt、evidence hash、OCI revision/ref 和 digest 共同授权生产；镜像内 `ref.name=debug` 是预期内容身份。
- 生产只 recreate `sub2api`，不重建 PostgreSQL/Redis，不让 Router 指向 debug。

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
- pool 同账号重试保持 request-local，绕过重新调度和 sticky 写入；槽位不可用时换号且不能提前提交响应；
- sticky 因 error-rate、TTFT 或 concurrency-full 逃逸时，把旧账号加入当前请求的 cloned `ExcludedIDs`，避免负载均衡立即选回；pool 删除旧绑定并重绑，non-pool 保留原绑定，含 WaitPlan/HTTP/WS；
- Test Connection 不再硬编码 `hi`，从 inventory/order/temperature 等小型任务族生成一次性有意义探针，并以结构和语义验收，拒绝无意义 `ok`。

关键文件：`openai_account_scheduler.go`、`openai_gateway_handler.go`、`openai_pool_same_account_retry.go`、`openai_gateway_passthrough.go`、`openai_gateway_response_handling.go`、`openai_sse_trailing_error.go`、`account_test_probe.go`、`account_test_service.go` 及对应测试。

管理端 Test Connection 的实现虽已改善，策略上仍不得把它当常规 smoke。合规 Codex smoke 只能由官方客户端发起。

## D4 Grok Stream 与 Tool 兼容

- 保留 Grok stream wall clock、client disconnect grace、usage snapshot 和 response handling 控制。
- 保留 Chat bridge custom/function 累积、孤立 `tool_choice` 清理和必要的 completed output 兼容。
- 0.1.164 上游已用 `responses_client_tools.go`、`openai_gateway_grok_tool_protocol.go` 承接 custom/namespace/tool_search 主体，因此不重放旧 `openai_gateway_grok_tools.go` 整文件。

关键文件：`config.go`、`openai_gateway_grok.go`、`openai_gateway_response_handling.go`、`responses_to_chatcompletions.go` 及对应测试。

## 已由上游吸收

- 旧 D4 的 Codex client tools 主体由 0.1.164 上游实现承接；候选只保留上游缺失边角。
- 旧 D5 axios 安全升级已在 0.1.164 上游版本线中，不再保留重复个性化提交。
- Composite groups/routes 是 0.1.164 上游能力。候选 4 个提交不修改 Composite 或 Router；生产未创建/启用 composite 分组时，现有 OpenAI/Grok 单平台职责不迁移给 Composite。

## 每次升级的职责对照模板

| Duty | 旧实现/提交 | 新上游实现 | 剩余差异 | 决策 | CI | Debug/生产 case | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 |  |  |  |  |  |  |  |
| D2 |  |  |  |  |  |  |  |
| D3 |  |  |  |  |  |  |  |
| D4 |  |  |  |  |  |  |  |

最终提交数取实时语义结果，不为维持数量保留被上游取代的代码。已知修复应 fixup 回所属职责后，再为最终 SHA 重建 CI、image 和验证证据。
