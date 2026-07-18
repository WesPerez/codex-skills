# Sub2API 主机侧 K12 运维

仅当 Codex 位于 Sub2API 主机，能够访问 Docker/Postgres 和部署 `.env`，并需要写前备份、精确绑组或 SQL 验证时使用。远程/无数据库权限的 HTTP 导入使用 `sub2api_contract.md`。

## 目录

- 环境、认证和强重复扫描
- 写前备份与导入 API
- 精确绑组、expiry 和验证
- UI 等价额度与 401/402 清理
- 恢复与报告

## 环境确认

写入前从 compose、容器和环境文件核实：

- production/preproduction/test/development/local；无法证明非生产时按生产处理。
- Postgres container、database、user/schema。
- Sub2API base URL 和真实 Admin API 前缀。
- bundle 账号数、token hash、目标 group、预计新增/跳过范围。
- backup 目录、磁盘空间、恢复命令和可能的锁/外部副作用。

示例名称只能作占位，禁止根据容器名猜环境。

## 主机侧助手

```bash
python3 scripts/sub2api_live_tool.py preflight \
  --bundle <bundle.json> \
  --postgres-container <container> \
  --pg-user <user> \
  --pg-db <database> \
  --environment <environment>

python3 scripts/sub2api_live_tool.py import \
  --bundle <bundle.json> \
  --postgres-container <container> \
  --pg-user <user> \
  --pg-db <database> \
  --env-file <deployment.env> \
  --base-url http://127.0.0.1:<port> \
  --backup-dir <secure-backup-dir> \
  --group openai \
  --environment <environment> \
  --confirm-write
```

`preflight` 只运行强重复扫描和结构检查，不备份、不导入、不绑组，但仍要求显式声明已核实的环境。`import` 是写入路径，必须使用 `--confirm-write`；production/preproduction 还需用户明确强烈授权并传 `--confirm-production-write`。

## 认证

主机助手从 `.env` 读取 `JWT_SECRET`，从数据库读取管理员行，在内存生成短时 Admin JWT；token 不落盘、不输出。若当前 schema 存在 `token_version`，按当前实现纳入签名/失效逻辑。

不要把这条高权限认证路径暴露为远程默认模式；远程场景使用用户提供的 bearer/cookie/login 客户端。

## 强重复扫描

候选身份至少包含 name、email 和 access token SHA-256。查询 active 与 soft-deleted：

- token hash 命中是强重复，默认中止；只有用户明确允许时使用 `--allow-token-duplicates`。
- name/email 命中用于诊断，不自动合并同邮箱不同账号。
- `chatgpt_account_id` 不作为重复边界。

## 写前备份

任何 import 前运行 `pg_dump -Fc`，备份文件：

- 放在明确的安全目录；
- mode `0600`；
- 记录绝对路径、size、SHA-256 和生成时间；
- 在备份失败、空文件或 hash 无法取得时停止写入。

备份可能包含生产秘密和业务数据，不打印内容、不随意上传、不在任务结束时自动删除。

## 导入 API

主机助手使用当前部署的 `/api/v1/admin/accounts/data` 语义，body 包含 bundle 并固定 `skip_default_group_bind: true`，每个不同 bundle 使用新的 Idempotency-Key。

API 前缀可能受反向代理影响。执行前以源码、OpenAPI 或实际部署路由证明；不要把远程客户端的 `/admin/accounts/data` 和主机路径假设为必然等价。

## 精确绑组

导入后按 token hash 解析本次候选对应的数据库 account IDs，只对这些精确 ID 写 `account_groups`：

- group 默认 `openai`，但先核实现有组名和 priority 约定。
- 禁止为了方便给所有 K12 账号全局绑组，除非用户明确要求该范围。
- 如果解析出的 ID 数量与候选不一致，停止后续写入并报告，不猜测缺失 ID。

## Expiry 同步

仅对本次导入 IDs，把 numeric `credentials.expires_at` 同步到缺失的顶层 `expires_at`。不要覆盖明确的顶层值，也不要修改不属于本次范围的账号。

## 导入后验证

至少验证：

- bundle 候选数与解析 ID 数；
- active/deleted 命中；
- K12/OpenAI OAuth 数量；
- 精确 group binding 与缺失 binding；
- 顶层 expiry 缺失数；
- status/schedulable/error_message 分布；
- 401/402 和其他 active errors。

数据库 active/schedulable 不证明上游正常。用户要求账号“正常”或 usable-only 时，再运行 UI 等价 quota probe。

## UI 等价额度

以下路径用途不同：

- `POST /api/v1/admin/accounts/today-stats/batch`：数据库支持的账号当日统计，通常不能发现上游停用。
- `/admin/accounts/:id/test`：账号测试，不足以覆盖 K12 quota 402。
- `/admin/accounts/:id/usage?source=active&force=true`：usage 刷新，仍不等价于 quota card。
- `/api/v1/admin/openai/accounts/:id/quota`：调用 ChatGPT `/backend-api/wham/usage`，可暴露 test/usage 漏掉的 401/402。

完整刷新顺序：先对目标 ID 请求 `today-stats/batch`，再请求 active usage、OpenAI quota，只有用户问“正常/可用”时再请求 `/test`。判断导入账号是否正常时以 quota 路径为关键证据，并把外层 502 中 `OPENAI_QUOTA_UPSTREAM_ERROR`/`upstream returned 402` 识别为上游 402，而不是普通网关错误。

## 401/402 清理

只有用户明确授权清理时执行：

1. 写前备份。
2. 用 UI 等价 quota 结果解析精确 account IDs。
3. 通过 Admin API 删除精确 401/402 目标。
4. 仅清理由这些 IDs 产生的 scoped 残留；按当前 schema 逐表确认后覆盖 `account_groups.account_id`、`scheduled_test_plans.account_id`、目标 plan 的 `scheduled_test_results.plan_id`、`usage_logs.account_id`、`ops_error_logs.account_id`、`ops_system_logs.account_id`、`scheduler_outbox.account_id`、`scheduler_outbox.payload->>'account_id'` 和 `channel_account_stats_pricing_rules.account_ids`。
5. 验证删除数、剩余 active/deleted/error 分布。

不得按 email、workspace ID、关键词或模糊状态批量删除。

## 恢复

恢复数据库是独立高风险操作，不因导入出现噪音自动执行。需要恢复时先停止进一步写入，记录失败点，核实备份 hash、目标环境、停机/锁风险和恢复范围，并取得用户明确确认。优先按部署的审批和维护窗口执行。

## 报告

报告 preflight、备份路径/hash、导入 API/Idempotency-Key 是否使用（不输出值）、导入与解析数量、绑组、expiry、验证、quota、清理和剩余恢复选项。
