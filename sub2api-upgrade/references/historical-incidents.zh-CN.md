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
| 2026-07-16/17，`redis-aof-corrupt-*` 恢复资产与 session `019f6dec...` | 主机异常后 Redis AOF 尾部损坏导致 Redis 循环重启，Sub2API 继而 503。 | 应用升级不 `down`、不 pull/recreate Redis；前后检查 Redis、应用、Router 和 Nginx 完整链路。 |
| 运行态与旧文档 | Watchtower 文档曾称自动更新，实际已对 `sub2api-prod` disable，手工全量 pull 仍可能拉动浮动 PG/Redis image。 | 每次 inspect Watchtower；仅 `docker compose pull sub2api`，绝不全量 pull。 |
| 多次清理请求与全局安全规则 | 误删镜像、dump、配置、debug 或按名字宽泛清理会消除回滚能力或影响无关任务。 | 为每次升级创建明确 owner marker；只清理本 run 的 rollback tag、临时 debug 和超期 owner-marked runs；保留至少两个 recovery runs。 |

证据不足的事项不得升级为“根因”。例如 2026-07-10 的上游同步 workflow 只保留失败通知而没有完整 Actions 日志，因此未来遇到同类情况必须读取实际 run 日志，不能照搬猜测。

2026-07-17 的只读前测还确认：当前 `mine` 保留 `175_grok_account_id_allocator.sql` 和 `177_grok_account_id_allocator_hardening.sql`，而当时最新 upstream 新增另一份 `177_add_subscription_plan_currency.sql` 及 `178` 到 `181`。迁移 runner 以完整 filename 为主键，所以相同数字前缀不等于直接 filename 冲突；但必须保留所有已应用文件的原名和 checksum，并在 debug 演练这些交错迁移的实际执行顺序、schema 结果和旧镜像兼容性，不能凭编号猜测后直接部署。
