---
name: sub2api-account-organizer
description: 按有效上游 URL 或用户指定类别安全整理 Sub2API 管理员账号列表，通过可回滚的显示名称前缀让同类账号在默认 name 升序中连续出现，并可按原账号名称中已有的标记指定 URL 组与组内顺序、排除指定平台。适用于用户说账号列表太乱、同 URL/同中继/同机场/同供应商账号被穿插、想按名称中的若干字符串排序、想排除 Grok 等平台、想整理或撤销账号显示顺序，或为了列表归类而提出交换/修改 accounts.id。默认只预览；生产应用只允许修改 accounts.name 与 updated_at，并同步调度显示缓存。不要用于真正的主键修复、账号删除、调度优先级调整、OAuth 凭据导入或分组绑定。
---

# Sub2API 账号整理

把“列表看起来连续”当作显示问题处理。优先利用账号页现有的 `ORDER BY name ASC, id ASC`，不要为显示顺序修改主键或调度优先级。

## 不变量

- 只把 `accounts.name` 作为显示排序键；允许数据库自动更新 `updated_at`，并把 `scheduler_outbox(account_changed)` 作为唯一关联表写入，用于刷新名称缓存。
- 不修改 `accounts.id`、`priority`、`schedulable`、`status`、`credentials`、`extra`、代理、分组、用量、日志、序列或其他业务关联表。
- 不删除或恢复账号，不处理软删除账号，不刷新 token，不测试上游。
- 不递归替换 JSON 中的 `account_id`，不清 Redis，不停服务。
- 把 `credentials.chatgpt_account_id`、`extra.crs_account_id` 视为外部标识，绝不作为本地主键修改。
- 如果用户坚持在 ID 升序视图中连续排列，说明该需求需要新的纯展示字段或前端排序功能；本技能不得退化为主键换号。

## 选择策略

默认执行“URL 名称前缀”方案：

1. 从管理员 API 获取全部未删除账号的脱敏响应；`credentials.base_url` 会保留。脚本若发现敏感 token 或私钥键意外返回，会在落盘前中止。
2. 计算有效路由类别：Spark 影子继承母账号；Anthropic OAuth/SetupToken 优先启用的 `extra.custom_base_url`；已知会忽略存储 URL 的 OAuth 类型按运行时默认端点归类；其余优先 `credentials.base_url`，没有 URL 时按 `platform/type/default` 归类。
3. 为同一类别生成可排序前缀。默认使用 `[@url:api.example.com:4f21ab93c2] `；用户指定名称标记顺序且 URL 组不超过 36 个时使用紧凑前缀 `!<URL组base36><组内标记base36>-`，例如 `!00-原名`，同时保证 URL 组连续和组内标记顺序。类别按 scheme/host/port/path 计算并忽略 query、userinfo、fragment；前缀不含原始 URL。
4. 保留原名称作为 `base_name`；超过 100 字符时只截断写回名称，完整原名仍保存在权限为 `0600` 的计划中。
5. 用名称升序查看账号；同一前缀的账号会连续出现。

用户明确给出账号 ID 与类别时，可用 overrides 覆盖 URL 自动分组。不要根据邮箱域名、名称相似、创建时间或“看起来像同类”自行合并。

## 工作流

### 1. 只读发现

先完整阅读 [references/runtime-runbook.zh-CN.md](references/runtime-runbook.zh-CN.md)。确认部署环境、管理 API 地址和账号范围。生产、预发布或身份不明环境均按生产处理。

使用管理员 API而不是账号导出接口抓取列表；账号导出会包含 token，不适合本任务。调用：

```bash
python3 scripts/fetch_redacted_accounts.py \
  --output /root/backups/sub2api/account-organizer/<run-id>/accounts.before.json
```

脚本从 `SUB2API_BASE_URL` 和 `SUB2API_ADMIN_API_KEY` 或 `SUB2API_JWT` 读取认证，不打印认证值，并自动分页。

### 2. 生成预览计划

```bash
python3 scripts/plan_account_names.py plan \
  --input /root/backups/sub2api/account-organizer/<run-id>/accounts.before.json \
  --output /root/backups/sub2api/account-organizer/<run-id>/plan.json
```

如有人工类别，使用 `--overrides overrides.json`。格式为账号 ID 到类别标签的对象，例如 `{"2011":"sharedchat","2048":"sharedchat"}`。

如需排除平台并指定名称标记顺序，按顺序重复参数：

```bash
python3 scripts/plan_account_names.py plan \
  --input accounts.before.json \
  --output plan.json \
  --exclude-platform grok \
  --name-bucket 'any-' \
  --name-bucket claude \
  --order-marker 6945 \
  --order-marker 1223 \
  --order-marker 2548
```

URL 组取组内最靠前的标记作为组顺序；同一 URL 内的账号再按各自最靠前的标记排序。一个名称命中多个标记时取用户列表中最靠前者。排除平台的账号不改名，也不进入 SQL。

`--name-bucket` 是标记之上的原名类别顺序。例如先传 `any-`、再传 `claude`，则包含 `any-` 的 URL 组优先；同一 URL 内先排完 Any，再排 Claude，两个类别内部各自按 `--order-marker` 顺序。类别和标记会合并编码到同一个 base36 字符中，排序码保持三字符，随后用一个 `-` 与原名分隔。

标记只能从剥离本技能旧前缀后的原始 `base_name` 中匹配，采用 Unicode 规范化后的不区分大小写子串比较。绝不把用户给出的标记补进原本不包含它的名称；未命中标记的账号只获得三字符排序码和一个分隔符 `-`，并排在其 URL 组内已命中账号之后。若一个 URL 组包含多个标记，必须保持 URL 组完整：组按最靠前标记定位，组内再按标记顺序排列。

向用户报告：环境、账号总数、变更数、类别数、每类的安全标签和 ID 列表、唯一会变化的数据库列、回滚文件路径。不要输出完整 URL、query、凭据、token 或整份账号响应。

### 3. 生产写入确认

默认停在预览。只有用户在看过目标 ID、影响范围和回滚方式后，仍明确要求应用，才允许生产写入。既往“帮我整理一下”不能替代这一步的生产 DML 确认。

写入前重新抓取账号并运行：

```bash
python3 scripts/plan_account_names.py verify \
  --plan /root/backups/sub2api/account-organizer/<run-id>/plan.json \
  --accounts /root/backups/sub2api/account-organizer/<run-id>/accounts.before-latest.json \
  --expect before
```

任何账号增删、名称变化、有效路由类别变化、平台/类型/调度保护指纹变化都必须中止并重新生成计划。

### 4. 生成和执行受控 SQL

```bash
python3 scripts/render_name_update_sql.py \
  --plan /root/backups/sub2api/account-organizer/<run-id>/plan.json \
  --direction apply \
  --output /root/backups/sub2api/account-organizer/<run-id>/apply.sql
```

生成器只产生固定结构 SQL：事务级 advisory lock、旧名称乐观条件、活动账号检查、精确更新 `name/updated_at`、逐 ID 写入 `scheduler_outbox`。它不会连接数据库。按运行手册发现真实 PostgreSQL 容器、用户、数据库和 schema 后再执行；不得假定容器名。

### 5. 验证

重新通过管理 API抓取列表，运行 `verify --expect after`。再确认：

- 所有目标账号仍可见，ID、platform、type、priority、status、schedulable、group_ids、proxy_id 和 parent_account_id 的保护指纹未变。
- 按 `name asc` 获取列表时，每个 URL 类别连续。
- `scheduler_outbox` 已存在相应 `account_changed` 事件或已被消费；调度快照中的名称最终刷新。
- 健康检查正常。不要为验收发送真实上游请求。

### 6. 回滚

使用同一计划生成 `--direction rollback` SQL。回滚也会检查当前名称必须等于计划中的新名称；用户后来手动改名的账号会使整个事务中止，避免覆盖人工修改。回滚后重新抓取并执行 `verify --expect before`。

## 停止条件

遇到以下任一情况立即停止：

- 用户真实目标是修复本地主键、跨系统 ID 对齐或消除主键冲突，而不是列表显示。
- 账号页被持久化为 `id` 排序且用户拒绝改用 `name asc`。
- 运行库不是 PostgreSQL、缺少 `scheduler_outbox`、schema 不明，或账号表结构与运行手册前提不符。
- 管理 API 响应包含未脱敏敏感字段，或 URL 只能通过完整凭据导出获得。
- 计划涉及软删除账号、名称超过约束且无法安全截断、未知父账号，或相同 ID 重复出现。
- 生产写入未得到明确确认。

## 用户可直接这样说

- “用 `$sub2api-account-organizer` 预览把所有相同 URL 的账号放在一起。”
- “把 2011、2048、2053 视为同一类，先给我看整理方案，不要应用。”
- “应用刚才确认的账号整理计划。”
- “撤销上一次 Sub2API 账号名称整理。”
