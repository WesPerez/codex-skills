# Sub2API Debug 验证矩阵

## 使用方法

1. `R0` 永远全跑。
2. 用 `plan-sub2api-upgrade.sh` 根据“当前生产 -> 候选”升级 diff 和“候选 upstream base -> 候选”个性化 diff 选择套件。
3. 人工补上动态配置、账号 extra、Router、Nginx、定时任务和间接调用路径触发的套件。
4. 开发循环可以只重跑 `R0 + 受影响套件`；最终 SHA 必须跑所有选中套件。
5. 每例记录：`case_id`、SHA、image digest、配置/fixture 指纹、UTC 起止、执行器、请求类别、预期、实际、日志窗、状态、证据路径。

用 `run-debug-matrix.sh` 固化记录：running attempt 可续接；failed/blocked 后必须显式新 attempt。开发循环用 `mode=dev`；最终 SHA 用 `mode=release`，每个 passed case 必须提供证据文件，R0-7/log executor 必须提供任务归属的 debug 日志窗，skip 必须有原因。只有 `seal` 生成且经 `verify-release-evidence.sh` 复核的 `release-evidence.json` 可进入 promotion 和生产 apply。

先用 `run-debug-adapter.sh run-ready` 串行处理全部可执行项；R0-7 始终最后运行，跨 run 也禁止并发争用同一 debug Compose/fixture。当前仅 R0-1、R0-2、R0-7 有自动 adapter；其他场景在 case 脚本完成真实审计前保持 manual。自动 passed 必须绑定同 run/case/attempt 的 adapter checkpoint、evidence/log hash；manual passed 必须使用 `kind=manual-verification` 的结构化 JSON。runner 不接受任意命令、URL、日志路径或服务名，不确定的真实请求禁止自动重放。

release 模式中三类证据有机器契约：R0-1 必须是 `candidate-identity`，并把真实 workflow run 写入 sealed `source_run_id`；R0-8/R1-M3 必须是 `rollback-compatibility`；其余 manual case 必须是 `manual-verification`，绑定 case、attempt、revision、digest、debug target、verifier、procedure 和全部通过的 assertions。自动 evidence 还必须来自同 attempt 的 adapter checkpoint。空文件、普通文字、模板占位或手写自动证据不能 seal。

验证分四层：

| 层 | 证据 | 作用 |
| --- | --- | --- |
| L0 | GitHub Actions full CI | 编译、lint、unit/integration、前端和部署脚本 |
| L1 | 合成 fixture/契约测试 | 协议形状、错误分类、调度和计费不变量 |
| L2 | 隔离 debug 真实 canary | 真实上游、账号配置、迁移、日志和运行时组合 |
| L3 | 官方 Codex 客户端 | metadata、工具、模型切换、Router 和完整多轮语义 |

CI 绿不能替代 L2/L3；L2 的 raw HTTP 也不能冒充官方 Codex L3。

## R0 发布阻断门禁

| ID | 场景 | 核心断言 |
| --- | --- | --- |
| R0-1 | 候选身份 | CI run、`debug-<12sha>`、revision/ref label、digest、容器 image ID 全部绑定最终 SHA |
| R0-2 | 候选启动与运行绑定 | 容器使用精确候选镜像，健康且 loopback `/health` 正常；迁移完整性由 R1-M1/M2 与 R0-6 人工关联审查兜底 |
| R0-3 | 基础业务 | health、鉴权、API key、账号/分组/设置只读、合成余额和 fixture manifest 正常 |
| R0-4 | Responses | 真实流式/非流式请求有合法 output、usage、completed 终态和合理首包 |
| R0-5 | Chat/错误 | 普通 Chat 路径和一条预设负例形状正确，不发生错误分类串线 |
| R0-6 | 职责双向回归与关联日志审查 | 每个职责及上游默认流程通过；预期负例按 request 关联，且无未解释 4xx/5xx、终态缺失或错误串线 |
| R0-7 | 致命日志模式门禁 | 完整 canary 窗内无 panic、fatal、迁移/checksum、OOM 或 `response.failed`；finish、seal、verify 都会重扫 |
| R0-8 | 回退兼容 | 候选迁移后旧应用镜像可以健康启动并完成核心只读路径；否则禁止 image-only rollback |

## 长文本、Compact 与上下文

触发：`compact`、`context`、`long_context`、Responses wire、计费迁移、模型窗口或 Router 压缩改动。

- `R1-A1`：`/responses/compact`、body signal 和 remote compact v2；compact 保持 unary JSON，错误前后 keepalive 形状可解释。
- `R1-A2`：构造中等长度、内容有意义且含多个不相邻哨兵的会话；压缩前后询问哨兵和工具结果，不能只比较 HTTP 200。
- `R1-A3`：可控超限负例返回客户端错误，不把 context-window 当瞬时 5xx 连环换号。
- `R1-A4`：long-context billing 字段、migration、usage 和管理边界一致。

真实长文本不为消耗额度而填充随机内容。优先复用脱敏小样本，以结构和语义断言验收。

## 图片与多模态

触发：`image`、`vision`、`media`、Chat/Responses bridge、tool output image、Composer 或 batch image。

- `R1-B1`：CI/合成 fixture 覆盖 URL、base64、Anthropic block、tool output image 和非法 part。
- `R1-B2`：用一张小型、清晰、答案唯一的固定图片做 Grok/OpenAI vision；流式/非流式答案一致。
- `R1-B3`：Composer 桥必须同时看到视觉请求与后续模型请求，禁止以大 body + 200 推断“已识图”。
- `R1-B4`：只有 generation/media/batch 路径被改时才执行真实生成，并核验尺寸、任务终态、usage 和计费。

## 迁移与 Schema

触发：`backend/migrations`、Ent schema、repository schema、启动 auto setup 或数据库驱动改动。

- `R1-M1`：枚举生产/debug 已应用文件，按 migration runner 的 `TrimSpace` 后内容算法计算 checksum；完整文件名与 checksum 不得变化。
- `R1-M2`：CI 覆盖空库全迁移；持久 debug 数据库从上一稳定 schema 增量升级，数据与 fixture manifest 保持。
- `R1-M3`：候选迁移后运行旧应用镜像做健康和核心只读验证。失败时记录 schema forward-only，生产禁止 `--rollback-image-safe`。

同数字前缀不是冲突依据，完整文件名才是 migration identity。禁止直接修改 `schema_migrations` 消除不一致。

## Tools、Tool Choice 与多轮

触发：`tools`、`tool_choice`、`additional_tools`、`namespace`、`tool_search`、Responses Lite、cache、function continuation。

- `R1-C1`：只提供会被过滤的 tools 并带 `tool_choice`；过滤后两者同时消失，上游不再报孤立 choice。
- `R1-C2`：custom、namespace、tool_search 分别覆盖流式与非流式；核验类型、名称、call ID、arguments delta/done、completed output。
- `R1-C3`：至少一轮真实 tool call + output + 下一轮回答；图片 tool output 被提升时内容不能丢。
- `R1-C4`：Responses Lite 的 additional tools、namespace choice 与 Grok cache 工具不能互相覆盖。

相关仓库测试优先查：`openai_gateway_grok_tools*`、`responses_namespace*`、`chatcompletions_responses_bridge_custom_tools*`、`openai_codex_function_call_id*`、`openai_tool_continuation*`。

## 模型切换与 Reasoning

触发：模型映射、effort、provider routing、catalog、Router 或上下文压缩。

- `R1-D1`：仅由官方 Codex 客户端完成同一会话 `Sol -> 另一 GPT -> Grok -> Sol`。在前序轮放置事实哨兵和工具结果，切换后验证召回、角色顺序、tool continuation 和模型实际路由。
- `R1-D2`：SharedChat 的特定 `gpt-5.6-sol + max -> xhigh` 映射生效；其他 host/model/effort 不变。
- `R1-D3`：未知或不可用模型返回明确错误，不静默 fallback。

模型切换测试验证网关没有丢客户端传入的上下文，不宣称不同模型共享内部状态。

## 流式、取消与终态

触发：SSE、nonstream aggregation、failover、timeout、keepalive、HTTP bridge 或 pool。

- `R1-E1`：下游非流请求从上游 stream 聚合为一个 JSON；下游流请求保持事件边界、usage 和 completed。
- `R1-E2`：首包前失败可以按策略切换；首包后不得混入另一账号流；客户端取消后不继续计费或误报 502。
- `R1-E3`：覆盖裸 5xx 与 HTTP 200 后 `response.failed`/rate-limit。二者都必须进入正确的重试或透传路径。

## Codex 与 SharedChat

触发：Codex route、API-key passthrough、headers、device ID、proxy、HTTP/1.1、compact 或 Responses Lite。

- `R1-F1`：官方 Codex -> 临时隔离 Router（需要时）-> debug Sub2API；保留官方 `originator`、UA、版本和 `x-codex-*` 元数据。
- `R1-F2`：SharedChat 非流聚合、流式、compact、max 映射、HTTP/1.1、SOCKS/账号 proxy 一次覆盖。
- `R1-F3`：网关业务请求、后台 Responses probe，以及仅在明确故障复现授权时的管理员路径，必须使用一致身份与传输策略。

禁止用 `curl` 复制官方头冒充 L3，禁止把 Sub2API `Test Connection` 当 smoke。

## 错误、调度与池模式

触发：error passthrough、failover、pool、sticky、scheduler、retry、rate limit、Router。

- `R1-G1`：401、402、429、瞬时 5xx、context-window、no-account 的状态、消息、冷却和 failover 策略分别正确。
- `R1-G2`：明确 Router 与 Sub2 谁拥有重试；总尝试预算有上限，不能双层乘法放大。
- `R1-H1`：session sticky、冷却后的 fallback、跨组隔离和首包后不换流。
- `R1-H2`：池模式同账号重试覆盖裸 5xx 与 200+SSE failed；核验服务端实际尝试数和客户端 N/总预算体验。
- `R1-H3`：snapshot/outbox/cache 重建无丢事件、重复风暴或多实例不一致。

## 计费、Probe 与后台任务

触发：usage、billing、quota、probe、refresh、scheduler outbox、cleanup 或后台 worker。

- `R1-I1`：canary 后 usage、输入/输出/cache token、余额和金额可按配置复算。
- `R1-I2`：debug 只用专属 OAuth 身份；刷新无风暴、无 permanent reject，绝不与生产共享一次性 refresh token。
- `R1-I3`：probe fixture 更新完整 map；前后非敏感 hash 相同，probe 与真实 gateway 结果不矛盾。

不要为了门禁频繁生成请求，也不要主动调用管理端 Test Connection。

## 前端、认证与部署

- `R1-J1`：前端改动至少由 CI typecheck、关键 vitest 与相关视图契约覆盖；账号 extra UI 更新必须保持完整 map。
- `R2-1`：认证/OAuth/API key 改动覆盖回调、session、权限和限速。
- `R2-2`：部署/Compose/workflow 改动覆盖 shell tests、loopback、project name、只 pull app、PGDATA、数据卷和 Watchtower 边界。
- `R2-3`：Claude/Gemini/其他 provider 只在已配置且相关路径受影响时做最小真实 canary。

## 日志判定

每轮在 canary 前记录 UTC `since`，结束后记录 `until`。预期负例必须提前登记 case ID、状态码、request ID/可脱敏关联键和日志模式。以下默认阻断：

- panic、fatal、migration/checksum failure、循环重启、OOM；
- 未登记的 5xx 或权限/协议类 4xx；
- HTTP 200 但 SSE 含 `response.failed`、缺 completed 或 usage 明显不完整；
- 跨账号/跨组串流、首包后 failover、重复计费；
- fixture 字段意外丢失、refresh token owner 冲突。

外部限流或供应商故障可解释但不能静默忽略：记录状态、request ID、retry-after 和对候选正确性的影响，决定阻塞、换专属 canary 或等待，而不是循环轰炸。
