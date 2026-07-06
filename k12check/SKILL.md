---
name: k12check
description: 安全验证 ChatGPT/OpenAI K12 workspace account UUID 的可用性。适用于 Codex 需要检查 K12 workspace IDs 当前是否可访问、比较 S1/S2/S3/S4 候选列表、解析本地 K12-ID 或 K12-ACCOUNT 证据、运行最低风险的 exchange_workspace_token 检查，或解释为什么未认证探测无法证明可用性。默认模式禁止 invite/join、leave/delete 和凭据导出，除非用户明确授权更高风险动作。
---

# K12 检查

## 目的

用实际可行的最低风险方式验证 K12 workspace ID。把“可用”定义为：当前 ChatGPT 会话可以交换到目标 workspace ID，并且返回 token 的 claims 中 `plan_type`/`chatgpt_plan_type` 是 `k12`。

## 状态标签

- `offline-evidence`：本地文件证明某个 workspace 过去曾以 K12 导出，但未运行 live check。
- `unauthenticated-inconclusive`：未登录 HTTP 探测只返回通用 auth/403 行为，无法区分真实 ID 和伪造 ID。
- `exchange-only-available`：live exchange 返回了请求的 account ID 和 K12 plan。
- `exchange-only-no-access`：live exchange 没有返回请求的 account ID。
- `accessible-not-k12`：live exchange 返回了请求的 account ID，但 plan 不是 K12。
- `authenticated-required`：live proof 需要测试账号的 ChatGPT 会话。
- `explicit-join-required`：证明是否可加入需要 `POST /backend-api/accounts/{id}/invites/request`；除非用户明确授权该副作用，否则停止。
- `blocked-no-safe-session`：没有可安全使用的浏览器/session。

## 安全规则

- 默认只做 exchange-only 检查。除非用户在解释风险后明确要求那个具体动作，否则不要调用 `POST /backend-api/accounts/{id}/invites/request`、`DELETE /backend-api/accounts/{id}/users/{userId}`，不要导出凭据、复制 token，或运行会执行这些动作的 bookmarklet。
- 除非用户明确授权，否则不要用用户日常登录的 ChatGPT 账号做 live check。优先使用隔离浏览器 profile 中的一次性/测试账号。
- 记住，同一个 Edge InPrivate 窗口中的标签页共享一个临时 session。若要真正隔离，启动单独的 Edge profile，例如 `msedge --inprivate --user-data-dir=<temp-dir> --remote-debugging-port=<port> https://chatgpt.com/`，记录 PID/profile/port；除非明确由当前会话创建且安全可关闭，否则不要清理。
- 永远不要打印 access token、refresh token、session token、cookies、完整邮箱或浏览器存储。只报告目标 ID、来源标签、状态、HTTP code、返回 account 前缀、plan 和简短备注。
- exchange endpoint 可能改变该浏览器 session 中当前 ChatGPT workspace 上下文。捕获起始 account ID，并在可行时恢复。报告恢复失败或未尝试恢复的情况。
- 未认证探测不是证明。如果真实 ID 和伪造 UUID 都返回相同的 `403` 或通用 HTML response，报告 `unauthenticated-inconclusive`。

## 工作流

1. 规范化候选 ID。
   - 接受类似 `uuid | S1, S2, S3` 的粘贴行。
   - 将全角或长破折号变体规范化为 `-`。
   - 去重 UUID，同时保留第一个来源标签。

2. 有本地证据时先检查本地证据。
   - `K12-ID.txt` 只能证明某个 ID 曾被收集。
   - `K12-ACCOUNT.txt` 或包含 `chatgpt_account_id` 和 `plan_type: k12` 的导出 JSON，证明该 account 过去曾以 K12 导出。
   - 解析证据时不要输出存储的 token。

3. 判断 live checking 是否安全。
   - 如果没有安全的已认证 session，用 `authenticated-required` 或 `blocked-no-safe-session` 停止。
   - 如果用户想知道“这个账号是否已经能用这个空间？”，使用 exchange-only。
   - 如果用户想知道“某个账号能否加入这个未知空间？”，解释证明需要 `invites/request`，并标记 `explicit-join-required`。

4. 运行 exchange-only 检查。
   - 当可通过 Chrome DevTools Protocol 访问 ChatGPT 页面时，使用内置脚本。
   - 保持 `--restore-current` 启用，除非用户明确希望停留在最后一个成功 workspace。
   - 如果使用浏览器插件标签页而不是 CDP，遵循相同逻辑：先 `GET /api/auth/session`，然后对每个 ID 请求 `GET /api/auth/session?exchange_workspace_token=true&workspace_id=<id>&reason=setCurrentAccount`，只解码返回 JWT claims 中判断 `chatgpt_account_id` 和 plan 所需的信息，并隐去所有 token。

5. 按状态报告结果。
   - `exchange-only-available`：返回 account ID 等于目标，且 plan 是 `k12`。
   - `accessible-not-k12`：返回 account ID 等于目标，但 plan 不是 `k12`。
   - `exchange-only-no-access`：response 返回另一个 account、没有目标 token、出错或超时。
   - 包含使用的方法，以及是否恢复了浏览器上下文。

## 脚本

对隔离 Edge/Chrome CDP port 运行确定性的 exchange-only 检查时，使用 `scripts/check_k12_workspaces.mjs`：

```powershell
node C:\Users\DELL\.codex\skills\k12check\scripts\check_k12_workspaces.mjs `
  --ids-file C:\Users\DELL\Desktop\K12\K12-ID.txt `
  --cdp http://127.0.0.1:9223
```

有用选项：

- `--ids "uuid | S2"` 可以重复使用，或包含多行。
- `--ids-file <path>` 读取粘贴的 ID 列表。
- `--cdp http://127.0.0.1:<port>` 指向 remote-debugging browser。
- `--json` 输出机器可读且已脱敏的结果。
- `--no-restore-current` 跳过恢复起始 workspace。
- `--self-test` 在不触碰网络或浏览器的前提下验证解析器行为。

脚本有意不提供 invite/join 或 credential-export 模式。
