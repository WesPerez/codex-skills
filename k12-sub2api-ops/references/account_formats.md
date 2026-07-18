# K12 账号格式与转换

识别未知 K12/OpenAI OAuth 包、转换为 Sub2API bundle、命名或去重时使用。不得打印原始 token、session、管理员认证或完整 Authorization header。

## 目录

- 归档检查
- 支持的布局
- 命名
- 去重
- 导入候选策略

## 归档检查

- 用 `file`、`stat`、`sha256sum` 确认真实容器和来源证据。
- ZIP 先用 `unzip -l/-t`；扩展名为 ZIP 的文件也可能实际是 RAR5，必要时使用 `unrar` 或 `7z`。
- 先读 README、manifest 和 metadata，尤其关注 refresh、recommended、分组和密码说明；最终答复不要泄露密码。
- 只读取结构和键，禁止为了检查格式输出 token 值。

## 支持的布局

### Sub2API bundle

顶层具有 `accounts` 列表，并带有 `type: sub2api-data`、`proxies` 或 `version` 等 Sub2API 特征时识别为 bundle：

```json
{
  "type": "sub2api-data",
  "version": 1,
  "exported_at": "2026-01-01T00:00:00Z",
  "proxies": [],
  "accounts": []
}
```

- 目标 API 需要 numeric timestamp 时，把顶层和 `credentials.expires_at` 的 ISO 时间统一为 Unix 秒。
- `credentials.expires_at` 存在、顶层缺失时，把规范化后的值同步到顶层；调度和 auto-pause 可能依赖顶层字段。
- 用户把 bundle 粘贴在对话中时，用 `k12_bundle_tool.py extract-pasted-session` 从 Codex session JSONL 提取第一个完整 JSON，对尾随指令文本不做拼接；输出使用 `0600`。

### Kit ZIP 中的 bundle

常见 kit 在 `data/` 下提供按角色命名的文件，例如：

- `k12_sub2api_recommended.json`
- `k12_sub2api_all.json`
- `k12_sub2api_current_batch.json`

优先服从 README/manifest 的分组定义。不要因为某个 all/full 包更大就默认导入，也不要相信文件名中的账号数量，必须实际统计。

### CPA/Codex 单账号 JSON

常见结构：

```json
{
  "type": "codex",
  "email": "user@example.com",
  "access_token": "...",
  "account_id": "...",
  "chatgpt_account_id": "...",
  "plan_type": "k12",
  "session_token": "..."
}
```

转换规则：

- `platform=openai`、`type=oauth`。
- `credentials.access_token` 来自源 `access_token`，缺失时阻止转换为可导入账号。
- 按源字段映射 `session_token`、email、account ID、workspace ID 和 user ID；JWT claims 可作为补充证据。
- `plan_type` 只能来自源字段、`chatgpt_plan_type` 或 JWT claims；没有证据时保持未知，禁止默认写成 `k12`。
- expiry 优先使用明确源字段，其次 JWT `exp`；有值时同时写 credentials 和顶层。
- 默认 `auto_pause_on_expired=true`、`concurrency=10`、`priority=5`、`rate_multiplier=1`。
- `extra` 记录来源文件和 token SHA-256，不保存额外明文秘密。

保留上游实际提供的 ID；不要制造不存在的 account/user/workspace ID。

### 多 CPA/Codex JSON 的 ZIP/RAR

- 每个 JSON 条目视为候选账号；同邮箱不代表重复。
- 同一 K12 workspace 下大量账号共享 `chatgpt_account_id` 是正常现象，不能据此合并。
- 某些源没有 expiry，不要编造；保留 `auto_pause_on_expired`。
- 用户要求“全部账号”时，转换所有结构完整条目，除非强重复或必需字段缺失；不要未经要求按上游 probe 过滤。
- 多个 CPA ZIP 且需要 manifest 时使用 `build_cpa_bundle.py`；单包通用转换使用 `k12_bundle_tool.py`。

### 分组 Sub2API ZIP

当 ZIP 内已经是多个 Sub2API bundle 组，并需要 recommended/all 输出时使用 `build_k12_bundle.py`。必须显式传入 recommended 和 optional 条目名，不从 high/low 等文件名自动推断可信度。

### 单对象、列表和 JSONL

通用工具接受单个 Sub2API/CPA 对象、对象列表和支持的 bundle。额度工具额外接受 bare token 单对象和 JSONL；转换工具仍要求能够识别账号结构。

## 命名

按顺序选择稳定、可搜索的名称：

1. 完整 email，小写。
2. 源 `name`。
3. account/workspace ID。
4. token hash 前缀。

文件名存在 `wsNN` 后缀且同邮箱重复时可保留为 `email__wsNN`。仍重名时使用 account ID 前缀、token hash 前缀或稳定序号。不要为了 name 唯一而修改 `credentials.email`。

## 去重

强标识：

- access token SHA-256；
- 同一来源中的完整 token；
- 经过验证的完全相同账号上下文。

弱标识，仅用于诊断：

- email/name；
- `chatgpt_account_id` 或 `account_id`；
- plan、状态和来源组。

导入前同时检查 active 与 soft-deleted。soft-deleted 的 token hash 命中仍是强重复。用户明确要求重新导入时要说明风险，通过 Admin API 处理，不直接改库伪造新账号。

## 导入候选策略

- “只导当前可用”：包含 quota/上游 probe 明确成功的账号，说明精确 inclusion rule。
- `usage_limit_reached` 或当前额度耗尽：凭据可能仍有效，但此刻不可用；只有用户要求包含 limited 账号时导入。
- revoked、invalidated、deactivated：可用性导入默认排除；审计保留需用户明确要求。
- 未运行 probe：只能报告格式已校验，不能声称账号可用。
