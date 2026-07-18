# 上游额度、可用性与错误分类

查询 K12/OpenAI OAuth 剩余额度、解释 401/402/429，或决定 usable-only 导入范围时使用。

## 安全原则

- `GET https://chatgpt.com/backend-api/wham/usage` 是只读额度查询，不生成内容。用户问完整数量时直接扫描供应文件的全部 probe context，无需先抽样或重复确认。
- `/backend-api/codex/responses` 属于生成探测，可能消耗额度；只在用户明确要求端到端模型可用性时使用最小样本。
- 不刷新 token，不打印 token、email、workspace/account ID、完整 header 或 response body。
- 使用有界并发、超时、重试和检查时间；结果随额度窗口重置而变化。

## 固定额度命令

```bash
python3 scripts/k12_quota_probe.py <batch-a.json> [<batch-b.txt> ...]
```

默认：10 workers、单请求 15 秒、瞬时错误最多重试一次。只对 network、5xx 和没有明确账号额度原因的 429 重试；尊重并封顶 `Retry-After`。显式额度结论、401 和 402 不重试覆盖。

按 `(access_token, chatgpt_account_id)` probe context 去重。相同 token 配不同 workspace header 必须分别探测；不同 token 即使共享 workspace 也不能合并。报告 raw records、unique token 和 unique context。

## 精确分类

- `usable_now`：HTTP 200，`rate_limit.allowed == true` 且 `limit_reached != true`。
- `current_quota_exhausted`：HTTP 200 且 `allowed == false`、`limit_reached == true` 或 `spend_control.reached == true`。
- HTTP 429 只有 body 精确标识 `usage_limit_reached`、`workspace_member_credits_depleted` 或 `spend_control_reached` 时才归为额度耗尽。
- `invalid_or_revoked`：HTTP 401，但 body 没有精确标识 `account_deactivated`。
- `deactivated`：HTTP 402，或 HTTP 401 明确标识 `account_deactivated`。
- `request_rate_limited`：重试后仍为 429，且没有账号额度原因；这是不确定，不是额度耗尽证明。
- `upstream_error`、`network_error`、`unexpected_http`、`inconclusive`：5xx、网络、JSON/字段形状变化或其他未知响应；不得并入 usable 或 exhausted。

`workspace_member_credits_depleted` 表示凭据被接受但当前 workspace/member quota 不可用，算当前耗尽，不算 token 失效。未来的 `credentials.expires_at` 只能证明元数据未过期，不能证明有额度。

## 输入与退出码

额度脚本支持 JSON object/list、Sub2API bundle、bare token 对象、命名 TXT JSON、JSONL、支持的 ZIP/RAR，以及包含 `.json/.txt/.jsonl` 的目录。目录中的非 JSON TXT 会跳过；ZIP/RAR 应直接作为路径参数。

- exit 0：所有 context 得到明确账号状态。
- exit 1：报告已完成，但至少一个 context 属于传输/协议不确定。
- exit 2：输入或 CLI 无法处理。

exit 1 仍要读取并报告摘要。

## 固定 fallback

1. 仅重试有界的瞬时 network、5xx 和无额度 reason 的 429。
2. 账号已导入 Sub2API、用户要求 UI 等价状态时，使用 `/api/v1/admin/openai/accounts/:id/quota`；读取 `sub2api_live_ops.md`。
3. quota contract 或字段形状变化时标记不确定，检查当前 Sub2API quota 实现或当前上游行为，不从数据库 status 猜结论。
4. 只有用户要求生成链路可用性时才调用 Codex response probe，不作为自动 fallback。

## 生成探测语义

端到端生成探测可使用 ChatGPT backend Codex endpoint，具体 model/payload 可能变化。常见结果：

- 200 且出现 `response.completed`/`response.done`：当前生成可用。
- 429 `usage_limit_reached`：凭据有效但当前 limited。
- 401 `token_invalidated`：token 无效或撤销。
- 401 `account_deactivated`：账号禁用。
- 402：workspace/billing 状态禁用。
- timeout/5xx：重试少量后仍不确定。

不要用固定极简 prompt 高频探测；遵循全局模型/API probe 规则。

## 报告

额度任务先给 `usable_now` 总数，再给 exhausted、invalid/revoked、deactivated 和 inconclusive；多文件同时给 per-file 与 combined。usable-only 导入必须说明包含规则，例如仅 200 usable，或按用户要求包含 limited。
