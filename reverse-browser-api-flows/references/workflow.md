# 浏览器 API 还原与自动化工作流

## 目录

1. 范围与证据
2. 登录态定位
3. Network 与 bundle 取证
4. 最小复现
5. 验证码
6. Adapter 设计
7. 凭据、日志与状态
8. 定时化与迁移
9. 测试与故障分类

## 1. 范围与证据

开始前记录：

- 用户要完成的真实动作，以及只读检查和写入动作的边界；
- 账号数量、凭据来源、目标站点、代理出口和时区；
- 是否允许立即执行一次生产动作；
- 是否需要浏览器前台交互，还是只需复现 API；
- 站点是否有服务条款、频率限制或验证码。

证据优先级：

1. 实际 Network 请求和响应；
2. 服务端状态接口在动作前后的变化；
3. 当前部署版本的前端 bundle；
4. 对应版本的公开源码或官方文档；
5. 论坛经验和搜索摘要。

论坛内容用于发现路径和常见做法，不能覆盖站点实测。

为每个关键结论维护证据表，至少记录：`claim`、`status`、`observed value`、`source URL`、`artifact SHA-256`、`artifact path:line:column` 或 HAR entry、`verification`。`status` 只使用：直接由 Network/真实响应证明的 `observed`、当前 bundle 调用上下文与直接证据互证的 `correlated`、仅由静态字符串发现的 `candidate`、证据不足的 `unknown`。禁止把框架惯例、相邻字符串、旧版文件名或搜索摘要写成当前站点事实。

## 2. 登录态定位

按下表逐项检查，不要因为 Cookie 插件为空就判断“没有登录态”。

| 载体 | 典型证据 | 自动化方式 | 注意 |
|---|---|---|---|
| 普通 Cookie | Network 的 `Cookie`、Application/Cookies | Cookie jar 或显式 cookie | 核对 Domain、Path、Secure、SameSite |
| HttpOnly Cookie | Network 有 Cookie，但 `document.cookie` 看不到 | 复用浏览器会话或用户明确提供的值 | JS 不能读取，不代表请求不会携带 |
| localStorage | bundle 中 `getItem`，Application/Local Storage | 取对应 key 的值并还原自定义 header | 按 origin 隔离，通常跨浏览器会话保存 |
| sessionStorage | bundle 中 `sessionStorage` | 当前标签页会话内提取 | 通常随标签页会话结束 |
| IndexedDB | Application/IndexedDB、bundle 数据层 | 仅在确有必要时解析结构化记录 | 不要全库导出 |
| 页面内存 | 初始化接口、状态管理 store、闭包变量 | 找刷新或交换接口，不抓内存快照作为长期方案 | 常有短期 token |
| 自定义 header | Network 中 `Authorization`、`x-user-token` 等 | 精确复现 header 名和值 | header 名可能来自 bundle，值可能来自任一存储 |

先确认凭据是否仍有效。认证失败必须作为独立结果，不得通过重复提交掩盖。

## 3. Network 与 bundle 取证

### Network

围绕一次人工动作记录：

- 动作前的状态请求；
- 点击动作触发的请求；
- 验证码或预检请求；
- 动作后的刷新/验证请求；
- method、scheme/host/path、query 名、必要 header 名、body schema、HTTP 状态；
- 成功、已完成、认证失败、验证码错误的响应字段。

优先用“Copy as cURL”或 HAR 作为原始证据，再做脱敏。不要直接把整份 HAR 提交到仓库。

### Bundle

从 HTML 的 `<script src>` 找到当前 hash 版本的 bundle，搜索：

```text
/api/
/user/api/
/frontend-api/
localStorage
sessionStorage
Authorization
x-user-token
captcha_id
checked_in_today
can_checkin
```

bundle 适合确认：

- storage key 与 header 名的映射；
- endpoint、method 和 body 字段；
- 页面如何判定“已完成”；
- `Origin`、`Referer` 或页面来源检查；
- 错误文案和功能开关。

不要只凭字符串附近的代码猜服务端校验规则。用实际请求验证。

公开 bundle 取证必须保留完整链路：页面 URL -> 当前 HTML 与 SHA-256 -> 精确 asset URL -> 本地原始文件与 SHA-256 -> 命中位置。先运行 `scripts/inventory_html.py` 盘点 HTML，再运行 `scripts/scan_bundle.py` 并查看每个命中的原始调用点。路由字符串本身不能证明 method；storage key 本身不能证明请求头；header 名本身不能证明 token 来源。模板字符串中含 `${...}` 的路由只能按动态候选报告，除非调用代码能还原完整 URL。

若 bundle 是超长单行文件，不要用会输出整行的普通搜索结果代替调用点。对公开或已脱敏文件运行 `scripts/extract_context.py`，分别提取 endpoint、header 和 storage key 的有限上下文；从请求封装追踪“storage getter -> header setter -> endpoint 调用”。HTML 中原样出现的 asset URL 属于 `observed`，扫描命中的孤立字符串属于 `candidate`，不能因为没有登录态就把它们全部写成 `unknown`。

将报告保存为 JSON：根对象包含非空 `claims` 数组；每项包含 `claim`、`status`、可选 `value` 和 `evidence`。每条 evidence 必须包含 `file`、文件实际 `sha256`、在该文件中原样出现的 `needle`，以及 `character_offset` 或 1-based `line` + `column`。`unknown` 的 evidence 必须为空，其他状态至少一条。运行 `scripts/verify_evidence.py` 并保留其 `valid`、计数和报告哈希；不要手写“已验证”。验证器防止伪造引用，但 `correlated` 仍需人工核对调用链。

`observed`/`candidate` 的 `value` 必须是引用 needle 中原样出现的字符串；完整 URL 若由页面 base URL 与相对路径拼接、header 若由变量 getter 映射、GET 若由省略 method 推导，都使用 `correlated` 并引用推导链的每个位置。`unknown` 的 value 必须为 `null`。

证据表逐项列出登录态载体、storage key、header 名、状态 endpoint + method、动作 endpoint + method、body schema、成功字段和已完成字段。不要从其中一项推导另一项；例如精确路径存在时，method 仍可为 `unknown`。缺少 Network/HAR 时，明确说明公开资源只能证明哪些静态事实。

报告结论时只给一个由证据支持的当前值。若 Network 与 bundle 不一致，分别记录版本和时间，不选择一个“看起来更合理”的值。若只有公开资源而没有登录态，不得声称接口已经实际成功调用。

## 4. 最小复现

按以下顺序推进：

1. 只读身份或状态接口；
2. 带完整必要 header 的只读接口；
3. 动作接口的单账号、单次请求；
4. 再次读取状态；
5. 只有状态已改变才宣告成功。

逐步删除非必要 header，保留最小集合。常见必要项包括：

- 登录 Cookie 或 token header；
- 站点自定义用户 ID header；
- `Origin`、`Referer`、`User-Agent`；
- `Content-Type` 与准确 JSON body。

对 POST 不做无界自动重试。响应模糊时先查状态；状态未变化才申请新挑战或进入下一次有限重试。

## 5. 验证码

优先从图像结构判断最小可靠方案：

1. 检查尺寸、颜色数量、alpha、字符位置、字体是否固定；
2. 若字符颜色和干扰颜色可分离，先做精确像素分离；
3. 若字体来自公开位图或固定模板，使用模板匹配；
4. 否则使用本地 OCR，并组合裁剪、放大、灰度、二值化和字符白名单；
5. 用置信度、候选间距和长度规则决定是否提交；
6. 失败后申请新 captcha，禁止对同一挑战枚举答案；
7. 设置低次数上限并保留失败状态。

模板匹配适合“固定字体 + 固定缩放 + 干扰只覆盖、不新增同色像素”的验证码。评分可优先惩罚无法被模板解释的额外像素，再比较缺失像素；若候选差距过小则放弃。

运行时不得依赖交互式大模型会话。模型可用于开发期视觉取证，但生产路径必须是本地、确定性或明确配置的独立服务。

## 6. Adapter 设计

推荐接口：

```python
class SiteAdapter:
    def run(self, check_only: bool = False) -> list[CheckinResult]:
        ...
```

每个 adapter 自己拥有：

- base URL、认证和必要 header；
- 状态解析；
- 动作请求；
- 验证和有限重试；
- 只含脱敏字段的结果。

统一入口只负责：

- 读取配置；
- 全局文件锁；
- 选择和隔离 adapter；
- 结构化日志；
- 原子写状态；
- 综合退出码。

多账号站点逐账号返回结果。凭据失效的账号应独立标记；不要让它阻断其他有效账号，也不要让已知失效账号使 timer 永久失败，可先禁用并记录刷新需求。

## 7. 凭据、日志与状态

- 生产凭据放 `/etc/...` 或同等仓库外路径，`root:root 0600`；
- 状态放 `/var/lib/...`，目录 `0700`、文件 `0600`；
- 配置示例只放占位符；
- 日志禁止输出 Cookie、token、验证码 ID、完整响应、邮箱或用户 UUID；
- 状态只保留奖励、余额、已完成标志、重置时间和脱敏账号标签；
- HTTP session 默认禁用环境代理继承，只有明确站点使用明确代理；
- 不持久化全局 `HTTP_PROXY`/`HTTPS_PROXY`。

## 8. 定时化与迁移

定时任务必须具备：

- 绝对路径和固定运行时；
- 非阻塞全局锁；
- 网络上线依赖、总超时和受控重试；
- `Persistent=true` 处理错过的日历触发；
- `RandomizedDelaySec` 避免固定时刻拥塞；
- 幂等状态检查，允许一天多次运行；
- systemd hardening 与精确 `ReadWritePaths`；
- 新服务手工验收后再停用旧 timer。

迁移前记录旧 unit 的 FragmentPath、启用状态和下一次触发。回滚入口必须能精确恢复，不用模糊搜索删除 timer。

## 9. 测试与故障分类

离线测试至少覆盖：

- 已完成时不 POST；
- 未完成时提交一次并复核；
- 401/403 归类认证失败；
- 非 JSON、错误 schema 和 5xx；
- 验证码正确、低置信度和重试耗尽；
- 多账号部分失败；
- 日志/状态不含测试 secret。

生产验收依次检查：

1. `--check` 只读运行；
2. 单站真实动作；
3. 全站统一入口；
4. systemd service；
5. timer 下一次触发；
6. 旧 timer 已停用；
7. root-only 配置和状态权限。

故障分类使用：认证、权限/来源检查、验证码、业务已完成、配额/频率、代理/DNS/TLS、服务端 5xx、响应 schema 变化。每类设置不同处理，不做统一无限重试。
