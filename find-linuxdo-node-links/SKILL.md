---
name: find-linuxdo-node-links
description: 搜索、筛选并核验 LINUX DO 中近期可用于 Clash、Mihomo、Clash Verge、Clash Meta、CFA、V2Ray、V2RayN、Xray、sing-box、Shadowrocket 等客户端的免费节点、公益订阅、机场兑换活动、配置文件和订阅聚合资源。用户提到搜节点、免费机场、翻墙订阅、Clash/V2Ray 可导入链接、CFA/CA 节点、每日节点分享、公益订阅恢复、跟随帖子外链、检查订阅是否仍可用或要求完整显示 URL 时使用。
---

# LINUX DO 节点检索

## 目标

快速找到近期、高信号、可验证的节点资源，同时区分公开静态配置、注册后生成的个人订阅、临时共享凭据、失效资源和工具项目。输出可直接使用的公开 URL，并避免扩散个人订阅 token。

## 必须交接

本技能是 `linux-do-research` 的领域入口。开始时完整读取：

- `C:\Users\Wes\.codex\skills\linux-do-research\SKILL.md`
- 其中要求的 `linux-do-research/references/network_workflow.md`
- 跟随外链或附件时读取 `linux-do-research/references/attachments_and_links.md`
- 声称覆盖所有回复时读取 `linux-do-research/references/discourse_extraction.md`

本技能只补充节点领域的快速路径、判定标准和安全边界，不替代 LINUX DO 的浏览器、附件和楼层审计规则。

## 快速流程

1. 记录当前日期、客户端和用户要求的时间范围。`CA` 没有其他上下文时按 CFA/Clash for Android 处理，并在结果中说明该假设。
2. 先运行 `scripts/discover_topics.ps1` 读取固定标签索引，不从通用搜索引擎开始。默认保持 TLS 验证；只有明确的单标签 TLS 故障诊断才显式使用 `-AllowInsecureTlsFallback`，且降级结果不单独作为可用性证据。
3. 优先检查 `免费节点`、`订阅节点`、`机场`，再按需要检查 `Clash` 和 `V2Ray` 标签。
4. 对候选主题使用 reader URL 读取原帖；搜索摘要和标签标题只用于发现，不用于证明。
5. 提取主帖及高信号回复中的外链、附件、协议、客户端、流量、到期日、人数/IP 限制和失效反馈。
6. 按“公开静态配置 > 当前兑换活动 > 公益站入口 > 临时个人分享 > 工具项目”的顺序整理。
7. 只对非敏感 URL 运行 `scripts/probe_public_urls.ps1`。默认使用 `HEAD`，不下载订阅正文；记录最终 URL、curl 退出码及超时、代理、TLS 等失败分类。
8. 关键入口只在图片、附件或登录页面中时，按 `linux-do-research` 的升级规则继续；无法取得证据时给原帖，不猜域名。
9. 输出所有允许公开的完整 URL，使用纯文本代码块，避免 Markdown 链接隐藏地址。

## 候选分类

使用以下状态，避免把“搜到”写成“可用”：

- `verified-direct`：公开静态 Clash/YAML、V2Ray 文本或明确的公共订阅，当前返回成功状态。
- `verified-registration`：官网可达，需注册、兑换或登录后生成个人订阅。
- `topic-only-sensitive`：原帖包含账号级 token、UUID、密码或临时单节点凭据，只给原帖。
- `attachment-browser-required`：论坛附件存在，但网络请求被 Cloudflare 阻断，需要从原帖点击或用浏览器解析。
- `reported-working`：回复称可用，但当前环境没有独立验证。
- `reported-broken`：回复出现 token error、订阅失败、人数已满、IP 过多或明确过期。
- `tool-not-nodes`：订阅转换、测速、聚合、代理池项目，本身不提供节点。
- `unresolved`：标题或截图有线索，但缺少可验证入口。

## 安全边界

不要输出或重建疑似个人订阅秘密，包括：

- 含长随机十六进制、UUID、Base64 或高熵路径段的个人订阅 URL；
- `token`、`auth`、`key`、`secret`、`password`、`uuid` 等查询参数；
- 带流量余额、到期日、账号信息的订阅接口；
- 作者通过“删除某段文字”“解码后使用”等方式弱混淆的账号级地址；
- 单个 `vmess://`、`vless://`、`trojan://`、`hysteria2://` 或 `ss://` 凭据，除非它是明确公共、长期、无账号归属的项目测试资源。

即使帖子公开，也不要把个人订阅 token 从论坛搬到回答中。提供原帖 URL、资源属性和获取说明即可。不要借助浏览器 cookie、localStorage、sessionStorage 或认证 header 提取入口。

## 验证要求

- 主题证据：标题、主题 URL、发布日期、实际读取的楼层、关键回复。
- URL 证据：HTTP 状态、最终 URL、内容类型、内容长度、最后修改时间；不打印订阅正文。
- 时效证据：帖子发布时间与最近活动时间分开记录。
- 失效证据：优先引用作者或实际用户的明确反馈，不根据“帖子旧”单独判死。
- 兑换活动：验证官网和备用域名是否可达，说明兑换步骤和经过回复确认的答案。
- 附件：只报告文件名、大小、来源楼层和访问状态；下载后也不要打印节点凭据。

详细查询、失败恢复和经验见 `references/search-and-evidence.md`。详细敏感 URL 判定和输出模板见 `references/security-and-output.md`。

## 停止条件

满足以下条件即可交付，不为追求“全网所有”无限搜索：

- 已检查固定标签页和用户指定关键词；
- 已读取所有高信号候选的原帖；
- 已跟随与可用性直接相关的外链或附件；
- 已明确哪些是直接配置、注册活动、敏感个人分享、失效资源和工具；
- 所有公开 URL 已完整显示；
- 未解决缺口已说明为何影响或不影响结论。

不要声称“所有节点”或“所有帖子”，除非已证明索引范围、分页和楼层覆盖。通常使用“截至当前检索到的高信号结果”。

## 交付格式

按以下顺序输出：

1. `可直接导入`：客户端类型、完整 URL、验证时间、HTTP 状态。
2. `注册或兑换后使用`：原帖、官网、备用站、步骤、兑换码及有效性证据。
3. `原帖内获取`：敏感个人订阅，只给主题 URL 和资源属性。
4. `已失效或有失效迹象`：给出证据，防止用户重复尝试。
5. `持续更新入口`：固定标签 URL。
6. 简短审计：网络方法、代理、浏览器是否使用、楼层/附件缺口、文件和标签页处理。

最终提醒免费节点可能记录 DNS、目标地址或流量元数据，不建议用于重要账号、支付或敏感数据。
