# 历史事故与控制

以下是从本机 Codex history/session、部署文档和现存恢复资产中提炼的已证实模式。它们是控制依据，不是对任何未知故障的过度归因。

| 时间/证据 | 已证实现象或根因 | 固化控制 |
| --- | --- | --- |
| 2026-06，部署文档与历史会话 | 服务器本地下载、编译和构建镜像会长时间占用内存、磁盘和 CPU。 | 只让 GitHub Actions 构建；服务器只拉已发布的分支 image。 |
| 2026-06-22，history `019eeb98...` | fork/上游关系和分支同步不清，曾出现 `mine` 落后上游而误判最新。 | 每次核验 `origin`/`upstream` refs、干净工作树和候选 SHA；`main` 保持纯上游镜像。 |
| 2026-07-15，session `019f651b...` 用户原始升级要求 | 明确要求将个性化与上游逐项对比：重复能力以上游为准，只保留上游缺失部分；差异整合为 5 个以内职责提交，后续修复合回原提交。 | 禁止机械 rebase/cherry-pick；为每个旧职责建立语义对照，默认维持原职责数量且不超过 5 个，debug 修复 amend/fixup 回所属提交。 |
| 2026-07-18，session `019f7492...` 用户再次确认 | “第八个分支”是当前语境下对 debug 分支的口述；要求个性化叠加后无已知报错，并同时验证个性化功能生效与其触达的上游核心流程未回归。 | 将最终 SHA 的 debug 双向业务矩阵和日志检查设为推 mine/生产前的硬门禁，不能只依赖上游发布质量或 CI。 |
| 2026-07-14，session `019f6067...` | `sanitizeGrokResponsesTools` 删除 `tools` 后提前返回，遗留 `tool_choice`，xAI 拒绝请求。 | provider/tools 改动必须在 debug 覆盖“无 tools + tool_choice”请求；容器健康不能代替协议测试。 |
| 2026-07-14/15，history `019f6067...`、`019f651b...` | 客户端 `reasoning.context` 不受某些上游支持；SharedChat/Codex 还受 client metadata、header、`max` effort、HTTP/2/SOCKS 路由和账号代理影响。 | 区分客户端/上游/网关根因；对受影响端点执行真实 Responses canary，不以单个 HTTP 200 推断完整兼容。 |
| 2026-07-15，history `019f651b...` | 生产问题本可在带隔离数据的 debug 环境复现，却曾在 mine 后才发现。 | debug 真实验证是生产门禁；debug 缺失时先恢复隔离能力，不直接发布。 |
| 2026-07-15，同一会话的 SharedChat 反复回归 | 单看 CI/容器健康没有覆盖真实 API-key Codex 路径；后续才定位 `max -> xhigh`、HTTP/1.1/SOCKS 与账号级 headers/proxy 等组合条件。 | 对每个保留的个性化职责执行真实 canary，并同时验证其触达的上游核心流程；临时修复收回原逻辑提交后必须用最终 SHA 重新构建和重测。 |
| 2026-07，session `019f5a35...` 的 Grok 识图故障 | 纯文本和工具链正常不能证明 Composer/vision 图片桥正常。 | Grok 图片桥、识图或多模态路径被差异触及时，在 debug 增加最小真实图片 canary，并核验视觉请求与后续模型请求的实际形状。 |
| 2026-07-14，session `019f609a...` | 已应用的 migration `175/177` 不能压缩、合并或改写 checksum；过程提交过多也影响审计。 | 新迁移只追加；发布前检查迁移差异；个性化保持少量逻辑提交。 |
| 2026-07-14，同一 session 的 checksum 事故 | 迁移运行器对 `strings.TrimSpace` 后的 SQL 内容计算 SHA256；把原始文件 `sha256sum` 当作数据库 checksum 曾造成启动失败。 | checksum 核验必须使用迁移运行器的实际算法；不得因口径误判而改写已应用迁移或直接修补生产 `schema_migrations`。 |
| 2026-07-14，同一 session 的运行链路要求 | Codex 会话可能依赖正在升级的 Sub2API；中途 recreate 会切断自身控制链路。 | 把生产应用 recreate 放在 CI、debug、dump 和回滚准备完成后的最后一步；不在准备阶段反复重启生产。 |
| 2026-07-18，0.1.160 隔离 debug | 用不完整 `credentials` map 触发 probe 时，非敏感 `header_overrides` 被正常替换掉，造成 403；补齐完整 fixture 后 probe 为 200。 | 测试前后核对合成账号的非敏感配置；map 型更新提交完整非敏感字段；先排除 fixture 损坏，再判断候选代码有缺陷。 |
| 2026-07-18，session `019f7492...` debug 起环 | 端口与 Router 蓝绿槽冲突、TOTP 编码不符和合成用户余额为零分别造成启动或 403，重复修环境耗时约 0.5–1.5 小时。 | 保留隔离 debug 数据骨架；每次先跑路径/端口/fixture manifest 检查，不从零建库。 |
| 2026-07-20/21，sessions `019f7f89...`、`019f8005...` | 只用裸 HTTP 500 mock 证明“同账号重试 10 次”，没有覆盖 HTTP 200 后 SSE `response.failed`/rate-limit 终态；真实客户端仍很快收到失败。 | 池模式必须覆盖裸错误与 200+SSE failed 两种形态、首包前/后边界、同账号重试计数、客户端可见延迟与日志；mock 绿不能替代真实流式 canary。 |
| 2026-07-20/21，同一事故审计 | 候选从旧 `0.1.160` 分支构建并 force 到 `mine`，覆盖了运行中的 `0.1.161` 基线；代码修复本身不能证明没有版本倒退。 | 推 debug/mine 前自动比较生产与候选的 upstream merge-base 和 `VERSION`；候选基线较旧直接停止。语义重建可不保留旧 mine 祖先，但不得丢更晚 upstream。 |
| 2026-07-20/21，Router 与 Sub2 双层重试 | 两层各自重试/回退会放大请求次数、等待和错误噪声，单看其中一层日志容易误判。 | 调度、池或错误策略变更时同时核对 Sub2 与 Router 审计；明确唯一重试 owner、总预算和首包后禁止换流。 |
| 2026-07-21，Actions 与升级 run 计时 | 当前 full CI + 镜像约 11–12 分钟，debug/mine 同一 SHA 各跑一次；生产 dump+应用切换约 17–21 秒。 | 优化 CI 等待、一次成型和未来同 SHA promotion，不削减生产 dump、debug 矩阵或 revision 门禁。 |
| 2026-07-23，runs `29999790284`、`30001779447` | unit 与 integration 在同 job 串行时占 7 分 46 秒到 8 分 13 秒；保持两条命令不变并拆为独立必过 job 后，首次完整 debug workflow 约 6 分 31 秒。integration step 从 2 分 47 秒升到 3 分 56 秒，可能与失去 unit 的本地编译热身以及跨 run 冷启动、网络和 Testcontainers 波动有关，但仍被 5 分 11 秒的 unit 关键路径覆盖。 | 只在完整 unit/integration job 边界并行，并用 workflow contract 锁定两条命令、Go 版本和 cache；不按文件分片共享 PostgreSQL/Redis 的 repository integration，不用削减覆盖换速度。 |
| 2026-07-24，`0.1.164` 发布复盘 `upgrade-20260724T035638Z-61d5b363fe7c` | **必要耗时**约 CI 6.2m + promotion 31s + production 45s。**浪费**来自：四候选重复 plan、默认按 catalog 44 全开、空日志误判、release 中 fault injection/临时 SQL 污染 evidence、无 debug-only 身份却硬跑 live 导致约 25 blocked、以及 5 次 matrix/约 31 份 manual evidence 重复劳动。 | planner 与空日志口径已修，按 U/M diff + active inventory 选 34/44；fixture 无 account 或无 debug-only 身份时计划阶段即窄化闭环，禁止复制生产凭据；`mode=release` 禁止 fault injection、临时 SQL、Test Connection（仅独立 dev run，不得进 release evidence）；apply 后立即 `confirm-production-upgrade.sh`（复用官方 Codex 有意义 canary，核 revision/digest/dump/日志窗，可安全 stop debug）；24h 后 finalize；后续成功版本对被取代 pending run 用 `--retire-superseded`。 |
| 2026-07-25，对同一 `0.1.164` evidence 的时序复审 | `run-ready` 虽把 R0-7 排在列表最后，但当其他 case 先落为 `needs_manual` 时仍会提前跑 R0-7；该 run 的 R0-7 早于后补 manual pass 约 3 分钟，不能证明覆盖最终 canary 窗。生产 `passed_at` 到 post-confirm 还间隔约 71 分钟。 | 其他选中 case 未全部 `passed/skipped_not_triggered` 时保持 R0-7 pending，单 case release run 也拒绝提前执行；补齐人工 evidence 后再次 `run-ready`，旧 early-pass 自动刷新，seal/verify 以 `log_window.until` 检查覆盖最终 passed attempt。apply 后把 provider canary 与 confirm 保持在同一切换窗，不把正常 idle 算成必要发布耗时。 |
| 2026-07-25，本技能并行审查验收 | reviewer 子代理重复启动多组相同 stub 套件；收束时主代理的唯一全量套件以 `143` 退出，浪费约 5 分钟且结果无效。 | reviewer/explorer 默认只做静态读取；测试由主代理统一排队。只有明确委派的单个有界测试可运行，且不得与主测试重叠；只按准确 PID 收束自身进程，禁止 `pkill` 或按名称清理。 |
| 2026-07-25，0.1.165 池模式语义收敛 | 旧 MINE 用全池 cooldown bypass、request-local pin、sticky rebind 和 audit helper 解决瞬时冻结，但与上游调度主干产生较大分叉。 | 以后需要完善：以 `521db6869`/`51f354f5c` 的 status-aware pool 语义为默认，保留协议层 SSE/终态/预算能力；对 sticky 防抖、pool 元数据识别、运维审计和总重试预算用独立 dev fault-injection 与调度日志继续验证，不恢复旧的全池宽绕过。 |
| 2026-07-25/26，`0.1.165` 两次生产 apply | `upgrade-20260725T170048Z-322e2c9003af` 与 `upgrade-20260725T172616Z-322e2c9003af` 均为 `rollback_failed`。第一次因 Compose v5 拒绝内置 `bridge` 的静态 IP/alias；第二次又叠加停态 `network connect` 不能形成 live sandbox，以及自定义 entrypoint 没有显式保留 `/app/sub2api` CMD，候选和回退容器进入重启环，约 `17:26Z–17:41:48Z` 发生应用中断。PostgreSQL/Redis 没有重建，失败尝试没有应用候选迁移；随后 `upgrade-20260725T180420Z-322e2c9003af` 在 `18:04:50Z` 通过，`18:07:57Z` 完成 OpenAI/Grok post-confirm。 | 以后需要完善：把 Compose/entrypoint/network 生命周期作为 release 输入，在 sealed evidence 前完成隔离、无凭据的 `created -> process spec -> start/gate -> live attach -> exact IP -> command` 正例和空 CMD、停态-only attach、错误 IP 负例；R2-2 必须绑定该证据，而不是只看静态合同。保留三个 run 的 manifest、dump、回滚镜像和 incident 记录，直到 recovery 链完成收口；继续补齐阶段计时、失败 run 终态时间和 pool 故障注入证据。 |
| 2026-07-21/22，session `019f8005...` 清理复盘 | 旧分支、早期镜像和备份被清得过深，部分职责提交只剩 dangling object，无法证明能力已完整承接。 | 未完成职责替代证明和两个 recovery run 保留前，不删旧 refs/镜像/dump，不运行即时 Git GC。 |
| 2026-07-16/17，`redis-aof-corrupt-*` 恢复资产与 session `019f6dec...` | 主机异常后 Redis AOF 尾部损坏导致 Redis 循环重启，Sub2API 继而 503。 | 应用升级不 `down`、不 pull/recreate Redis；前后检查 Redis、应用、Router 和 Nginx 完整链路。 |
| 运行态与旧文档 | Watchtower 文档曾称自动更新，实际已对 `sub2api-prod` disable，手工全量 pull 仍可能拉动浮动 PG/Redis image。 | 每次 inspect Watchtower；仅 `docker compose pull sub2api`，绝不全量 pull。 |
| 多次清理请求与全局安全规则 | 误删镜像、dump、配置、debug 或按名字宽泛清理会消除回滚能力或影响无关任务。 | 为每次升级创建明确 owner marker；只清理本 run 的 rollback tag、临时 debug 和超期 owner-marked runs；保留至少两个 recovery runs。 |

证据不足的事项不得升级为“根因”。例如 2026-07-10 的上游同步 workflow 只保留失败通知而没有完整 Actions 日志，因此未来遇到同类情况必须读取实际 run 日志，不能照搬猜测。

2026-07-08 到 07-11 的快速升级会话通常在 8–24 分钟完成，但证据主要是 CI、镜像和 `/health`，不能证明跑过真实 Grok tools、SharedChat 或流式负例。07-14 的 `tool_choice` 事故说明这类速度不可作为目标流程。

2026-07-17 的只读前测还确认：当前 `mine` 保留 `175_grok_account_id_allocator.sql` 和 `177_grok_account_id_allocator_hardening.sql`，而当时最新 upstream 新增另一份 `177_add_subscription_plan_currency.sql` 及 `178` 到 `181`。迁移 runner 以完整 filename 为主键，所以相同数字前缀不等于直接 filename 冲突；但必须保留所有已应用文件的原名和 checksum，并在 debug 演练这些交错迁移的实际执行顺序、schema 结果和旧镜像兼容性，不能凭编号猜测后直接部署。
