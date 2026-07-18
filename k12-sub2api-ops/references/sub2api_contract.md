# Sub2API 导入契约

## 目录

- 已知 API 契约与认证
- Preview 与执行导入
- 跳过现有账号
- Base URL 发现与导入后验证
- 失败处理与安全边界

导入 K12 bundle 到 Sub2API 或编写服务器侧指令时使用此参考文档。

## 已知 API 契约

已验证的前端/API 事实：

- 登录端点：`POST /auth/login`
- 账号导出/导入端点：`GET /admin/accounts/data?include_proxies=false`
- 账号导入端点：`POST /admin/accounts/data`
- 认证 header：`Authorization: Bearer <auth_token>`
- 导入 payload 结构：

```json
{
  "data": {
    "exported_at": "...",
    "proxies": [],
    "accounts": []
  },
  "skip_default_group_bind": false
}
```

响应可能被包装为：

```json
{
  "code": 0,
  "data": {}
}
```

把非零 `code` 视为 API 错误。

## 认证选项

使用以下之一：

1. `SUB2API_AUTH_TOKEN`：管理员 bearer token。
2. `SUB2API_LOGIN` 和 `SUB2API_PASSWORD`：通过 `/auth/login` 登录。
3. `SUB2API_COOKIE`：只有在用户/服务器明确提供时使用。不要提取浏览器 cookies。

尝试的登录 payload：

- 当 login 包含 `@` 时，使用 `{ "email": login, "password": password }`；
- `{ "username": login, "password": password }`；
- `{ "account": login, "password": password }`。

不要打印秘密。

## 先预览

Preview 不发送任何网络请求，只做本地 bundle 检查。它应该：

- 加载 bundle；
- 汇总账号数量、platforms、plan types、缺失 access token 数量；
- 只打印样例身份，不打印 token 值；
- 不登录、不拉取现有账号；authenticated reconcile 是单独的已授权执行阶段；
- 可选择应用 shuffle 和 max account 限制。

示例：

```bash
python3 scripts/import_sub2api_bundle.py \
  --base-url "$SUB2API_BASE_URL" \
  --bundle data/k12_sub2api_recommended.json \
  --max-accounts 3
```

如果 auth 缺失但请求了 `--skip-existing`，要明确失败，而不是静默导入重复项。

## 执行导入

只有 preview 成功且用户已授权 live import 后才执行：

```bash
python3 scripts/import_sub2api_bundle.py \
  --base-url "$SUB2API_BASE_URL" \
  --bundle data/k12_sub2api_recommended.json \
  --skip-existing \
  --environment test \
  --confirm-write \
  --execute
```

对易失包：

```bash
python3 scripts/import_sub2api_bundle.py \
  --base-url "$SUB2API_BASE_URL" \
  --bundle data/k12_sub2api_current_batch.json \
  --skip-existing \
  --shuffle \
  --shuffle-seed "$K12_SHUFFLE_SEED" \
  --max-accounts 10 \
  --environment test \
  --confirm-write \
  --execute
```

Preview 和 execute 使用同一个 shuffle seed。包装脚本应生成一个 seed 并复用。

## 跳过现有账号

用以下请求拉取现有账号数据：

```http
GET /admin/accounts/data?include_proxies=false
Authorization: Bearer <token>
```

收集身份键时使用 email + chatgpt/account id 的复合身份；同邮箱不同 account id 必须保留。只有二者都缺失时才以 name 兜底。

导入前过滤 bundle 账号并报告：

- 看到的现有账号；
- 现有身份键；
- 跳过的现有账号；
- 剩余账号。

## 服务器 Base URL 发现

优先使用显式 `SUB2API_BASE_URL`。

如果缺失，谨慎尝试可能的本地 URL：

- `http://127.0.0.1:3000`
- `http://127.0.0.1:8080`

如果服务器有部署配置，只读检查它以找到反向代理或服务端口。

不要为了查找 API 而修改服务配置。

## 导入后验证

通过 API 或 admin UI 验证：

- 账号存在；
- platform 是 OpenAI；
- auth type 是 OAuth；
- plan type 是 K12；
- 导入账号没有全部 paused；
- 可以测试少量样例；
- 没有触发批量 refresh。

执行前记录目标环境、base URL、认证主体、账号数、是否跳过现有账号和回滚方案。执行后重新读取最小必要的账号摘要，核对新增数量与字段；失败或部分成功时停止扩大批次，并以复合身份 reconcile 后再决定是否重试。

精确报告错误和部分导入。

## 失败处理

如果 API 返回错误：

- 保留 bundle 文件；
- 不要用更大的批次重试；
- 只有在安全且获授权时，才用 `--max-accounts 1` 重试；
- 检查 auth 是否过期；
- 检查 payload 结构是否变化；
- 检查服务器侧校验是否拒绝缺失的可选字段；
- 永远不要通过刷新所有 token 来“修复”。

如果导入部分成功：

- 拉取现有账号；
- 使用 `--skip-existing`；
- 解释状态后再用更小批次继续。

## 安全边界

无需额外授权即可执行：

- 读取本地 bundle 文件；
- 运行 preview 模式；
- 只读检查服务器配置；
- 校验 JSON 结构；
- 生成命令/prompt。

需要明确授权：

- live import `--execute`；
- 编辑 Sub2API 配置；
- 重启服务；
- 删除/暂停账号；
- 刷新 token；
- 导出 live account data 超出身份计数范围。

除非用户给出狭窄、明确且安全的指令，否则禁止：

- 提取浏览器 cookies；
- 读取浏览器 localStorage/sessionStorage 作为 auth；
- 发布账号 bundle；
- 打印 token；
- 写生产数据库。
