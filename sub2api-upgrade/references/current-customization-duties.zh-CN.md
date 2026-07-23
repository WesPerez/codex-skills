# 当前 Sub2API 个性化职责基线

此文件是 2026-07-23 对 `mine@13b41759f68a85d86c38fba4dad12f13b4792682` 与当时 `upstream/main@e625ce3b3b3b955b7c3afc93221f7c5f0ae55aa8` 的已核验快照。它用于缩短下一次 discovery，不能替代实时 `merge-base`、range-diff、源码和测试审查。

下一次升级先验证这 5 个逻辑提交仍是当前生产职责；新增、删除、重写或上游吸收时更新本文件。不能因提交 SHA 或文件名变化就判定职责消失。

## 职责总览

| ID | 当前提交 | 核心职责 | 必跑套件 |
| --- | --- | --- | --- |
| D1 | `683f5ce00` | 分支发布、服务器禁本地构建、debug/mine 镜像与部署边界 | `deployment`, `core` |
| D2 | `213088124` | Grok 账号 ID 分配器与已应用迁移 175/177 | `migration`, `core` 回退 |
| D3 | `52c604556` | Codex/API-key 上游传输、SSE trailing error、池恢复、调度与 probe 一致性 | `codex_sharedchat`, `long_context`, `streaming`, `error_policy`, `scheduling`, `billing_background` |
| D4 | `4f0ff1c7f` | Grok Responses tools 双向桥、tool_choice、sticky fallback、流式限制 | `grok_tools`, `vision_media`, `streaming`, `scheduling`, `model_switch` |
| D5 | `13b41759f` | axios 安全补丁与审计例外收口 | `frontend`, `deployment` |

## D1 分支发布与部署边界

当前行为：

- `main` 只镜像上游；`debug`、`mine` 发布固定分支镜像；服务器禁止本地构建。
- debug full CI 与 cache-only Docker build 并行；full CI 内原有 unit/integration 命令作为两个必过 job 并行；全部全绿后发布不可变 `debug-sha-<40>` 和兼容 tag，并写 OCI revision/ref label 与 source-run metadata artifact。
- mine 不重复构建；只由 `Promote Debug Image` 将已验证 exact digest carbon-copy 到 mine tags，并由 sealed evidence + promotion receipt 授权生产。
- debug matrix 将 adapter catalog、fixture/config 指纹与最终 SHA/digest 一起绑定；`run-ready` 串行执行已审计 adapter 并取 UTC 日志窗，未实现的协议场景明确要求结构化人工证明，不能显示为自动通过。
- debug 与生产使用独立 Compose、数据、端口和 Watchtower 策略；生产只由受控脚本切换应用。

关键文件：`.github/workflows/backend-ci.yml`、`docker-branch.yml`、`sync-upstream-main.yml`、`AGENTS.md`、`BRANCH_DEPLOYMENT.md`。

只有当上游或另一个受控部署仓库完整承接这些服务器专属约束、并能通过固定 SHA/debug/生产脚本验证时，才可删除相应差异。上游普通 CI 或 Dockerfile 不等价于本机分支发布职责。

## D2 Grok 账号 ID 分配与迁移

当前行为：

- 保留 `175_grok_account_id_allocator.sql` 与 `177_grok_account_id_allocator_hardening.sql` 的完整文件名和 runner checksum。
- 分配器、序列/约束、并发和软删除场景由集成测试覆盖。
- 上游存在相同数字前缀但不同完整文件名的迁移，不构成直接冲突。

关键文件：`backend/migrations/175_grok_account_id_allocator.sql`、`177_grok_account_id_allocator_hardening.sql`、`grok_account_id_allocator_test.go`、repository integration test。

已应用迁移不能因上游新增等价 schema 就删除、改名、合并或改内容。上游吸收职责时也只能追加兼容迁移并证明旧数据库、全新数据库和旧应用回退都安全。

## D3 Codex 上游与池恢复

当前行为范围较大，不能按单个 helper 判断等价：

- API-key Responses 非流/流桥、compact、HTTP profile、首包/transport error 与 client cancel。
- HTTP 200 后 SSE trailing `response.failed` 的解析、错误透传和池重试。
- 同账号/池模式、sticky、scheduler cache/outbox、临时 block fast path。
- 业务 gateway、后台 Responses probe 和允许复现时管理员路径的 header/proxy/身份策略一致。
- SharedChat 所需 HTTP/1.1、账号 proxy、header/device metadata 与特定 effort 映射。

主要触达 `openai_gateway_passthrough.go`、`openai_gateway_response_handling.go`、`openai_sse_trailing_error.go`、`openai_account_scheduler.go`、`http_upstream_profile.go`、gateway handler 和相关测试。

上游替代判定必须逐子职责列源码与测试，至少真实覆盖：流式/非流式、200+failed、首包前/后、取消、同账号重试预算、SharedChat、probe 与 gateway。只看到上游有“pool retry”或“passthrough fix”标题不够。

## D4 Grok Tools 与 Sticky Fallback

当前行为：

- custom、namespace、tool_search、additional tools 转换为 Grok/xAI 可接受形状，并在流式/非流式响应恢复 Codex 类型。
- tools 被过滤为空时同步删除 `tool_choice`。
- 多轮 function output、图片 tool output、Responses Lite/cache 与 completed output 重建不丢信息。
- Grok sticky fallback、client disconnect grace、stream wall clock 和 raw Chat/Responses 边界。

主要触达 `openai_gateway_grok.go`、`openai_gateway_grok_tools.go`、`openai_gateway_response_handling.go`、`chatcompletions_responses_bridge.go`、config 与对应测试。

上游替代判定必须覆盖请求和回程双向、stream/nonstream、多轮、孤立 tool_choice、200+failed、图片与 sticky；仅采用上游单向 tool 规范化不等价。

## D5 前端 axios 安全补丁

当前行为：升级 axios 到已修补版本，并移除不再需要的 audit exception；锁文件保持一致。

关键文件：`frontend/package.json`、`frontend/pnpm-lock.yaml`、`.github/audit-exceptions.yml`。

当新上游依赖版本不低于当前修补版本、锁文件和审计均通过时直接采用上游，不保留重复提交。不要为了维持提交数重放已经被上游吸收的依赖改动。

## 每次升级的职责对照模板

| Duty | 旧实现/提交 | 新上游实现 | 仍缺差异 | 采用决策 | 自动测试 | Debug case | 证据 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| D1 |  |  |  |  |  |  |  |
| D2 |  |  |  |  |  |  |  |
| D3 |  |  |  |  |  |  |  |
| D4 |  |  |  |  |  |  |  |
| D5 |  |  |  |  |  |  |  |

最终候选职责数取实时结果，不为保留 5 个提交而保留已被上游取代的代码，也不把 D3/D4 的多个相互依赖子职责在无证据时随意拆散或合并。
