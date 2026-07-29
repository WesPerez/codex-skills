---
name: metapi-add-site-account
description: 快速、安全地把用户提供的中转站 URL 与 Session Cookie 接入本机 MetAPI，完成站点查重或创建、Cookie 身份验证、账号新增或精确重绑，并定向验收余额刷新和签到。用户提到给 MetAPI/MetaAPI 添加站点、添加账号、导入 Cookie/Session、刷新余额、测试签到，或后续反复发送“站点 + Cookie”要求直接接入时使用。不要用于 API Key 批量导入、OAuth 账号生命周期、Sub2API 账号整理、MetAPI 升级或一般源码开发。
---

# MetAPI 站点与 Session 账号接入

## 目标

使用当前生产 MetAPI 的正式管理 API，以最少步骤完成“站点 + Session Cookie”接入和定向验收。优先运行 `scripts/add_site_account.sh`；只有部署布局或 API 契约已经变化时才手工调用接口。

## 硬性约束

- 把 Cookie、管理员 Token、API Key 和代理凭据视为秘密。不得回显、写入技能/仓库/普通日志，也不得放在进程命令行参数中。
- 通过脚本的隐藏标准输入传入 Cookie。不要使用 `--cookie <值>`、命令行 `curl -H "Cookie: ..."` 或持久化环境变量。
- 写入前核实运行容器、端口、数据卷和目标数据库。默认布局为容器 `metapi`、管理地址 `http://127.0.0.1:4000`、SQLite `/root/metapi-deploy/data/hub.db`；证据不一致时停止使用默认值。
- 管理 Token 可能被 SQLite `settings.auth_token` 覆盖。优先从已核实的运行库做精确只读查询，不要只信 compose 或容器环境变量。
- 只使用管理 API 写入。不要直接向生产 SQLite 插入或更新站点、账号、余额、签到日志。
- 先按规范化 URL 查重站点。先验证 Session 身份，再按同站点用户名精确查重账号；唯一匹配时重绑，零匹配时新增，多匹配时停止，禁止猜测。
- 只刷新和签到本次目标账号。禁止调用全量余额刷新或 `/api/checkin/trigger`。
- 按用户的长期偏好，技能默认启用账号签到并执行一次定向签到测试；只有用户明确要求不签到时才关闭。余额刷新始终执行。
- 遇到 `403`、ACW/ESA/Cloudflare 盾、超时或限流时，不要高频重试。复用现有 MetAPI adapter、系统代理和 AnyRouter helper；记录脱敏错误并最多做一次有依据的重试。

## 快速流程

1. 只读确认生产实例：
   - `docker inspect metapi` 核对端口、数据卷、compose 工作目录和镜像。
   - 核对 `127.0.0.1:4000` 只绑定本机。
   - 核对 SQLite 路径来自容器 `/app/data` 的实际挂载。
2. 启动脚本，并让执行工具保持 TTY 会话：

```bash
METAPI_SITE_URL='https://example.com/' \
METAPI_SITE_NAME='站点显示名' \
bash /root/.codex/skills/metapi-add-site-account/scripts/add_site_account.sh
```

   默认启用签到；用户明确要求不签到时加入 `METAPI_ENABLE_CHECKIN=0`。
3. 脚本提示时，通过执行会话的标准输入发送 Cookie 和换行。不要把 Cookie 拼进上述命令。
4. 脚本会依次执行：
   - 获取有效管理员 Token并验证管理 API；
   - `GET /api/sites` 按 URL 查重；
   - 必要时 `POST /api/sites/detect` 和 `POST /api/sites`；
   - `POST /api/accounts/verify-token` 验证 Session 并识别用户名；若站点要求用户 ID，自动从 Cookie 的 Gob payload 提取并逐个正式验证；
   - 精确重绑已有账号，或 `POST /api/accounts` 新建账号；
   - 等待后台初始化任务进入终态；
   - 定向 `POST /api/accounts/:id/balance`；
   - 定向 `POST /api/checkin/trigger/:id`；
   - 读取账号快照与最新签到日志，输出无凭据摘要。
5. 使用脚本返回的 JSON 验收，不以单个 HTTP 200 代替业务结果。

## 可选参数

通过一次性环境变量覆盖非秘密配置：

- `METAPI_BASE_URL`：管理地址，默认 `http://127.0.0.1:4000`。
- `METAPI_DB_PATH`：运行 SQLite，默认 `/root/metapi-deploy/data/hub.db`。
- `METAPI_SITE_URL`：必填站点 URL。
- `METAPI_SITE_NAME`：站点不存在时使用；未填则从域名生成。
- `METAPI_PLATFORM`：已知平台时可传 `new-api` 等；未填则调用站点检测。
- `METAPI_PLATFORM_USER_ID`：只有站点明确需要正整数用户 ID 时填写。
- `METAPI_ENABLE_CHECKIN=0`：显式关闭账号签到和签到测试；默认值为 `1`。

## Cookie 中的用户 ID

不要观察原始 Cookie 猜 ID。New API 常见 Session 值是外层 Base64，解码后结构为：

```text
<timestamp>|<base64-gob-payload>|<signature>
```

再次 Base64 解码中间段即可得到 Go `gorilla/sessions` 的 Gob payload。站点用户 ID 存在字段名 `id`、类型 `int` 后，对应字节标记为 `id\x03int\x04`；后续是 Gob 长度、分隔符和有符号整数编码。使用 `scripts/extract_session_user_ids.mjs` 从隐藏标准输入读取 Cookie并输出候选，不要手工抄取。

主脚本已自动执行以下逻辑：

1. 先不带用户 ID 验证 Cookie。
2. 仅当接口明确返回 `needsUserId` 时，本地解析 Gob 的精确 `id` 字段。
3. 精确字段不存在时，才补充 payload 中与 `id`、`uid`、`user` 或 `_` 相邻的 4–8 位数字。
4. 最多取 8 个候选，逐个调用正式验证接口；只采用返回 `tokenType=session` 的 ID。
5. 全部候选失败才要求人工提供 `METAPI_PLATFORM_USER_ID`，禁止用连续数字暴力枚举。

## 验收标准

- 站点 URL 唯一，没有重复创建。
- Cookie 验证结果为 `tokenType=session`，目标账号为 `active`，`canRefreshBalance=true`。
- 余额刷新返回数值余额，最终快照的 `lastBalanceRefresh` 已更新。
- 授权签到时，返回成功、今日已签到或等价的幂等成功状态；最新签到日志属于目标账号，且最终 `lastCheckinAt` 已更新。
- 若签到带来奖励，最终余额应反映签到后的再次刷新；报告奖励与余额变化时只报告数值，不报告凭据。
- 最终回复只给站点 ID、账号 ID、用户名、余额、签到结果、奖励和时间字段；明确说明 Cookie 未回显、未写入技能。

## 失败处理

- 站点检测失败：让用户或源码证据明确平台后再创建，不猜平台。
- Session 验证失败：若明确缺用户 ID，先执行内置 Gob 提取和正式验证；仍失败才停止，不绕过正式 API 直接落库。
- 同站点出现多个同名账号：停止并列出脱敏 ID，要求用户明确目标。
- 创建成功但初始化或验收失败：保留已创建记录并准确报告部分成功；不要擅自删除，因为删除属于额外破坏性操作。
- 管理 Token、数据库或运行实例身份不清：按生产环境处理并停止写入。
