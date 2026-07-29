---
name: reverse-browser-api-flows
description: 从浏览器登录态、Cookie/localStorage/sessionStorage、Network 请求、前端 JavaScript bundle 和实际响应中还原可验证的网页 API 流程，并把授权范围内的签到、状态查询、数据读取或重复操作实现为安全、幂等、可定时化的 adapter。用户提到网页抓包、接口逆向、Cookie 插件没有值、token 在哪里、前端接口参数、验证码离线识别、油猴脚本改造、浏览器操作迁移到 requests/curl、多个站点统一定时任务，或需要分析某个网页动作背后的 API 时使用。
---

# 浏览器 API 流程逆向

## 总则

先还原事实链，再写自动化。把页面文字、前端 bundle、Network 请求、服务端响应和生产复核分开记录；不要根据框架习惯猜接口、登录态或成功条件。

对 endpoint、method、header、storage key 和 body 字段实行严格证据契约：给出精确值时，必须同时给出当前页面的精确 asset URL、本地 SHA-256 与文件位置，或 HAR/Network 中的请求位置。没有直接证据就写 `unknown`，不得用“可能是 A 或 B”“不同版本也许是 C”“或等价字段”补全答案。bundle 中孤立字符串只能算 `candidate`，必须检查实际调用点；不得编造 fallback asset URL、接口变体或响应字段。

只处理用户有权使用的账号和站点。验证码只做本地、有限重试的授权流程自动化；禁止枚举答案、绕过第三方风控、扩大请求频率或批量操作未授权账号。

执行具体任务前完整读取 [references/workflow.md](references/workflow.md)。需要引用公开依据、LINUX DO 经验或核对事实来源时，再读取 [references/sources.md](references/sources.md)。

## 核心流程

1. 明确目标动作、账号范围、允许的外部副作用、运行频率和代理要求。
2. 识别登录态载体：Cookie、HttpOnly Cookie、localStorage、sessionStorage、IndexedDB、页面内存或自定义请求头。
3. 用 Network 证据定位状态接口和动作接口，记录 method、URL、必要 header、body、响应字段和调用顺序。
4. 从当前 HTML 记录带 hash 的精确 asset URL，下载原始 bundle，计算 SHA-256，并实际运行静态扫描。
5. 建立证据矩阵，分别标记 `observed`、`correlated`、`candidate` 或 `unknown`；用调用上下文解释抓包，不用孤立字符串替代抓包。
6. 先复现只读状态请求，再执行一次最小动作请求，最后再次读取状态验证。
7. 将每个站点封装为独立 adapter；统一入口只负责锁、选择、状态汇总、日志和退出码。
8. 把凭据放到仓库外的 root-only 配置；日志、状态文件和测试夹具不得含 token、Cookie 或完整上游响应。
9. 为读路径、已完成路径、认证失败、验证码失败、提交成功和模糊响应补离线测试。
10. 部署定时任务时保留精确回滚入口，生产验收通过后再停用旧调度。

## 工具选择

- 有浏览器插件时，优先复用用户指定的 Microsoft Edge 页签和 Network 证据；不要为了纯网页任务使用 Computer Use。
- 没有浏览器工具时，先读取公开 HTML、静态资源和 bundle，再用用户明确提供的登录态做最小请求验证。
- 对保存的 HTML 先运行 `scripts/inventory_html.py --page-url <页面URL> <html>`，由解析器输出页面 SHA-256、原始 asset 路径、解析后的精确 URL 和位置；不要手抄文件名。
- 扫描本地 bundle 必须运行 `scripts/scan_bundle.py` 或等价的精确搜索；它输出 artifact SHA-256、候选路由、storage key、header 名及文件位置。随后用 `rg` 查看命中位置的原始调用代码，不能只引用扫描汇总。
- 对压缩成单行的公开 bundle，运行 `scripts/extract_context.py --needle <候选字符串> <bundle...>` 提取定长调用上下文；输出含源码，只能用于公开或已脱敏 artifact，不得提交凭据型输出。
- 把静态分析结论写入任务临时 `evidence-report.json`，每个非 `unknown` 结论引用 artifact SHA-256、原样 `needle` 和精确位置，再运行 `scripts/verify_evidence.py evidence-report.json`。只有实际退出码为 0 的报告才可交付；验证器只证明引用存在，不替代对调用语义的判断。
- `observed` 和 `candidate` 的 `value` 必须原样出现在至少一条引用 needle 中；URL 拼接、变量追踪、默认 method 或跨位置映射统一标为 `correlated`。
- 审计 HAR 可运行 `scripts/summarize_har.py`；默认不输出 header 值、Cookie、查询参数值或请求正文。
- 研究 LINUX DO 时调用 `linux-do-research` 的网络优先流程，只引用实际打开并读取的真实主题。

## 验收标准

- 每个关键结论都标明 `observed`、`correlated`、`candidate` 或 `unknown`，并指向 Network、bundle、源码、测试或实际状态复核中的精确位置。
- 公开静态资源结论包含当前 HTML 的精确 asset URL、本地 SHA-256 和命中位置；不得出现未下载的备用 URL。
- HTML 中直接出现的 asset URL 和扫描出的静态字符串必须按其实际证据级别报告，不能因为缺少 Network 而全部降成 `unknown`；只有运行语义保持 `unknown`。
- 所有非 `unknown` 静态结论都通过 `verify_evidence.py`；报告中不存在的行、偏移、字符串或错误哈希会使验收失败。
- 自动化先查状态，仅在需要时提交；重复运行不会重复领取或重复签到。
- 验证码失败会申请新挑战并有限重试，不会猜测或穷举。
- 一个站点失败不会阻断其他站点，但最终退出码和状态文件会准确反映失败。
- 定时任务在受限服务环境中实际运行成功，timer 的下一次触发时间、旧 timer 状态和 root-only 配置权限均已核验。
