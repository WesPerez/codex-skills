# K12 账号格式

检查、转换或校验 K12 账号包时使用此参考文档。永远不要打印原始 token 值。

## Sub2API Bundle JSON 格式

结构：

```json
{
  "exported_at": "2026-07-05T00:00:00+00:00",
  "proxies": [],
  "accounts": [
    {
      "platform": "openai",
      "type": "oauth",
      "name": "account-name",
      "credentials": {
        "access_token": "...",
        "email": "user@example.com",
        "id_token": "...",
        "refresh_token": "",
        "plan_type": "k12",
        "chatgpt_account_id": "...",
        "account_id": "...",
        "expires_at": 1783946504
      }
    }
  ]
}
```

此工作流的最低要求：

- 顶层 `accounts` 是列表；
- 每个账号使用 `platform=openai`；
- 每个账号使用 `type=oauth`；
- 每个账号都有 `credentials.access_token`；
- 每个账号都有 `credentials.plan_type=k12`；
- 每个账号都有身份字段，例如 `credentials.email` 或 `name`。

有用的可选字段：

- `auto_pause_on_expired: true`
- `concurrency: 10`
- `priority: 1`
- `rate_multiplier: 1`
- `extra.source`
- `extra.email`
- `credentials.id_token`
- 如果源中存在，则包含 `credentials.refresh_token`
- `credentials.client_id`
- `credentials.expires_at`

## CPA 单账号 JSON

论坛 CPA zip 包中常见结构：

```json
{
  "access_token": "...",
  "account_id": "...",
  "email": "user@gmail.com",
  "expired": "2026-07-15T04:07:22+00:00",
  "id_token": "...",
  "last_refresh": "2026-07-05T04:07:22+00:00",
  "refresh_token": "",
  "type": "codex"
}
```

把一个文件转换为一个 Sub2API 账号：

- `platform`：`openai`
- `type`：`oauth`
- `name`：清理后的邮箱本地部分
- `credentials.access_token`：源 `access_token`
- `credentials.email`：源 `email`
- `credentials.id_token`：源 `id_token`
- `credentials.refresh_token`：源 `refresh_token`，不存在时为空字符串
- `credentials.chatgpt_account_id`：源 `account_id`
- `credentials.account_id`：源 `account_id`
- `credentials.expires_at`：从 `expired` 解析出的 Unix timestamp
- `credentials.plan_type`：只复制源中的 `plan_type` / `chatgpt_plan_type`；源缺失时保持为空并阻止执行导入，不能仅因包名或论坛描述推断为 `k12`
- `extra.source`：源 zip basename
- `extra.source_entry`：原始 zip 条目路径
- `extra.source_type`：源 `type`
- `extra.last_refresh_at`：从 `last_refresh` 解析出的 timestamp

不要假设 `refresh_token` 存在。许多共享 CPA 文件只有 access/id token。

对 CPA 单账号 zip 文件，默认保留每个 JSON 条目。不要仅因为邮箱重复就移除条目。重复邮箱可能合法地拥有不同 `account_id` / `chatgpt_account_id`，除非用户要求去重，或按 account id 和 token 证明条目完全相同，否则应作为独立账号导入。

## 分组 K12 Bundle Zip

有些 zip 文件包含多个 Sub2API 风格的 bundle JSON 文件，例如：

- `k12_5h_high_36.json`
- `k12_5h_mid_73.json`
- `k12_5h_full_203.json`
- `k12_5h_low_1022.json`

处理方式：读取命名 JSON 条目，并谨慎合并它们的 `accounts` 列表。需要谨慎去重，因为这些分组 bundle 经常有意让许多邮箱重复使用同一 workspace id。

典型策略：

- recommended bundle：high + mid + full 组；
- all bundle：high + mid + full + low 组；
- manifest：记录每组输入数量、添加数量和跳过的重复项。

## 身份与去重

只有当去重明确属于任务时，才使用此身份函数：

1. 使用精确的 email、精确 account id 和完整 access token 组成复合身份；字段缺失时保留空位，不将同邮箱不同 account/token 合并；
2. 比较疑似完全重复文件时使用完整 token 的内存比较，日志和 manifest 中绝不输出 token；
3. 分组 bundle 也不得只按 email 去重；没有完整重复证据时保留条目；
4. 没有更好身份字段时，使用顶层 `name`。

原因：这里有两种相反的失败模式。有些 K12 dump 让许多不同用户共享同一个 ChatGPT workspace/account id，所以只看 account id 会合并掉有效账号。另一些 CPA zip 可以包含同一邮箱但不同 account id，所以只看邮箱也会合并掉有效账号。去重必须感知格式，并基于证据。

## 安全检查秘密

使用数量和键名，而不是输出 token：

- zip 条目名；
- 顶层 JSON 键；
- credential 键；
- `HasAccessToken=true/false`；
- `HasRefreshToken=true/false`；
- 只有在可接受时才给邮箱/name 样例；
- 只有在需要时才给 token 字符串长度。

隐去匹配这些名称的键：

- `access_token`
- `refresh_token`
- `id_token`
- `session_token`
- `authorization`
- `cookie`
- `bearer`

## 校验清单

对每个生成的 bundle：

- 账号数量与 manifest 一致；
- 除非明确请求去重，否则账号数量与源条目数量一致；
- 重复邮箱以 account-id 数量报告，而不是自动删除；
- `missing_access_token = 0`；
- 所有 `platform` 值都是 `openai`；
- 所有 `type` 值都是 `oauth`；
- 所有 plan type 都是 `k12`；
- bundle 没有意外包含 cookies 或浏览器会话存储；
- 没有把原始 token 打印到日志或文档。
