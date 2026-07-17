# Sub2API 账号显示整理运行手册

## 目录

1. 设计依据
2. 环境与授权门禁
3. 只读清单获取
4. URL 归类规则
5. 计划审查
6. 生产应用
7. 验证与回滚
8. 禁止事项

## 1. 设计依据

当前源码中的事实：

- 管理员账号页前端默认 `name asc`，并把排序偏好保存在 `account-table-sort`：`frontend/src/views/admin/AccountsView.vue:193-197,559-592`。
- 后端默认 `ORDER BY name ASC, id ASC`：`backend/internal/handler/admin/account_handler.go:484-485`、`backend/internal/repository/account_repo.go:724-765`。
- `accounts.priority` 明确参与调度；不得作为显示顺序：`backend/ent/schema/account.go:105-108`。
- `accounts.id` 是主键并被数据库、Redis、日志和调度引用；不得为列表整理而换号。
- `accounts.name` 不参与账号选择，只用于管理搜索、显示、日志标签和通知文案。改名会改变以后日志中的显示名，但不会改变路由、计费或凭据。
- 管理响应通过 `RedactCredentials` 去除 token、api_key、私钥等敏感子键，同时保留非敏感 `credentials.base_url`：`backend/internal/handler/dto/credentials_redact.go:6-28`。
- 通用 `PUT /accounts/:id` 会先读取整个账号再整体保存。仅为改名调用该接口存在与并发 token 刷新的丢失更新窗口，因此生产批量整理使用精确列 SQL，不使用通用 PUT。

## 2. 环境与授权门禁

每次运行都重新发现，不把下面基线当作证明：

- 源码基线：`/root/sub2api-repo`
- 生产部署基线：`/root/sub2api-prod-deploy`
- 备份/审计根建议：`/root/backups/sub2api/account-organizer/<UTC-run-id>`

执行前确认并记录：

- production / pre-production / test / development / local；无法证明时按 production。
- Compose project、应用容器、PostgreSQL 容器、数据库名、数据库用户和 schema。
- 操作类型：预览是管理员 API 只读；应用是生产 DML，只更新 `accounts.name/updated_at` 并插入 `scheduler_outbox`。
- 目标账号 ID 数量、旧名称、新名称和回滚计划。

生产写入需要用户在看到预览后明确确认。不得把创建技能、要求分析或笼统的“整理一下”视为生产 DML 授权。

## 3. 只读清单获取

优先运行本技能的 `fetch_redacted_accounts.py`。它：

- 只调用 `GET /api/v1/admin/accounts`。
- 自动按 ID 升序分页，页大小不超过服务端 1000 限制。
- 从环境变量读取管理认证，不把认证写进参数、计划或标准输出。
- 把响应保存为 `0600` 文件。

不得使用 `accounts export`，因为导出包含 token。若 API 响应意外包含 `access_token`、`refresh_token`、`api_key`、私钥或完整 service account，立即停止并保护/清理本任务明确创建的响应文件。

## 4. URL 归类规则

按以下顺序计算类别：

1. 人工 override：用户明确指定的 ID 集合优先。
2. Spark shadow：继承 `parent_account_id` 对应母账号的类别。
3. Anthropic OAuth/SetupToken：仅在 `custom_base_url_enabled=true` 且 `custom_base_url` 非空时使用自定义 URL，否则归入平台/类型默认类。
4. OpenAI 非 APIKey：运行时固定官方端点，忽略可能残留的 `credentials.base_url`。
5. Grok OAuth：运行时固定 CLI gateway，忽略存储 URL。
6. 其他账号：使用非空 `credentials.base_url`；为空时按 `platform/type/default`。

URL 比较会规范化 scheme/host、默认端口和尾部斜杠，并按 scheme/host/port/path 归类。query、userinfo 与 fragment 均忽略：它们经常含 token 或部署参数，不应把同一中继拆成多个显示类别。完整 URL 不进入 plan，只保留 SHA256。不要用代理 URL 代替上游 URL。

指定名称标记顺序时：

- 只在原始 `base_name` 中查找标记，不把标记写入未命中的名称。
- URL 组按组内最靠前的标记排序；同组账号再按各自最靠前的标记排序；无标记排最后。
- 同一 URL 组包含多个标记时不得拆组，因此全局标记分段与 URL 连续冲突时，以 URL 组完整为先。
- `--exclude-platform` 指定的平台不改名、不进入 SQL；验证时如果其他账号新增或改成非排除平台，计划失效并要求重建。
- 指定标记顺序且 URL 组不超过 36 个时，使用紧凑前缀：`!` + 一位 URL 组 base36 + 一位组内标记 base36 + `-` 分隔符。不要把 URL、哈希或标记正文写进可见名称。
- 需要防止同 URL 内的名称类别交叉时，使用有序的 `--name-bucket`。组内最后一位字符编码“名称类别序号 × 标记跨度 + 标记序号”，因此可先完整排列 Any，再排列 Claude，同时仍保持三字符前缀。

## 5. 计划审查

计划包含：

- 账号 ID、旧名称、新名称、完整原始 `base_name`。
- URL 类别的安全标签、哈希和账号 ID 列表。
- `platform/type/priority/status/schedulable/group_ids/proxy_id/parent_account_id/quota_dimension/concurrency/rate_multiplier` 的保护指纹，以及不含原始 URL 的路由类别指纹。
- 截断标志、输入摘要哈希、忽略的软删除 ID。

计划不包含原始 URL、token、credentials、extra 或管理员认证。

审查时重点检查：

- 每个类别是否确实符合用户意图。
- 影子账号是否与母账号同类。
- 是否存在过长名称截断；完整原名仍能从计划恢复。
- 变更数是否与用户指定范围一致。
- 管理页面需要使用 `name asc`；如果本地保存的是 `id` 排序，名称前缀不会改变 ID 排序结果。
- 活跃影子账号若引用已软删除或列表中缺失的母账号，必须停止；不得读取或恢复软删除母账号来强行完成整理。

## 6. 生产应用

生成 SQL 后先静态检查文件头中的 plan SHA256、direction、schema。SQL 固定执行：

1. `BEGIN`，设置 5 秒锁超时和 2 分钟语句超时。
2. 获取 `sub2api.accounts.display_organizer` transaction advisory lock。
3. 从 base64 JSON 建立事务内临时计划表。
4. 校验所有账号存在、未软删除、当前名称等于计划旧名称。
5. 只更新 `accounts.name` 和 `accounts.updated_at`。
6. 为每个 ID 插入 `scheduler_outbox(account_changed)`，让缓存刷新新名称。
7. 核对更新行数并提交；任何不匹配会整笔回滚。

执行时通过已确认的 PostgreSQL 容器和数据库环境使用 `psql -v ON_ERROR_STOP=1`。不要把 SQL 内容打印到聊天，不要从 shell history 传密码，不要持久化全局代理或环境修改。

此更新不需要停止应用，因为：

- 单次 UPDATE 只写显示列；账号行锁很短。
- 旧名称条件防止覆盖并发人工改名。
- 不读取后整体回写 credentials，因此不会覆盖并发 token 刷新。

若锁超时或账号数量大到不能在 2 分钟内完成，保持回滚并重新评估，不提高超时强行执行。

## 7. 验证与回滚

应用后：

1. 重新抓取管理员 API 清单。
2. 运行 `verify --expect after`；任何保护指纹变化都要报告。
3. 用 `sort_by=name&sort_order=asc` 读取账号，确认相同前缀连续。
4. 做应用健康检查；不发送测试请求到真实上游。
5. 检查目标 ID 的 outbox 事件已存在或已消费，不要求清理历史 outbox。

回滚：

1. 从原 plan 生成 `--direction rollback`。
2. 再次确认生产写入。
3. SQL 要求当前名称仍等于计划新名称；只要一个账号被人工改名，整笔中止。
4. 回滚后重新抓取并运行 `verify --expect before`。

保留 plan、apply.sql、rollback.sql 和验证摘要，权限保持 `0600`。不要自动删除审计材料；只有用户明确要求且能证明归属时才清理。

## 8. 禁止事项

- 禁止修改或交换 `accounts.id`。
- 禁止使用 `priority`、`account_groups.priority` 模拟显示排序。
- 禁止通过 DELETE/重新导入达到排序效果。
- 禁止调用通用账号 PUT 做大批量逐行改名。
- 禁止输出完整管理员账号响应、原始 URL query 或认证信息。
- 禁止全量 Redis flush、服务重启、数据库约束/触发器禁用。
- 禁止在未知 schema 或未知环境上执行生成的 SQL。
