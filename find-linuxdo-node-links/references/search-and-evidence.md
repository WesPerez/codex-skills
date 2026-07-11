# 检索与证据经验

## 目录

- 固定入口
- 最短发现路径
- 搜索查询
- 主题读取
- 链接与附件
- 时效和失效判断
- 网络交接
- 已验证经验

## 固定入口

优先访问 reader 版本：

```text
https://linux.do/tag/2138-tag/2138   免费节点
https://linux.do/tag/193-tag/193     订阅节点
https://linux.do/tag/558-tag/558     机场
https://linux.do/tag/clash/1043      Clash
https://linux.do/tag/v2ray/1570      V2Ray
```

reader 形式：

```text
https://r.jina.ai/http://linux.do/tag/2138-tag/2138
```

标签页通常比通用搜索更及时，还能同时给出回复数、浏览量和最近活动时间。

## 最短发现路径

1. 拉取五个固定标签页。
2. 合并 topic ID 并去重。
3. 标题优先级：`恢复`、`七月/当月`、`分享`、`自用节点`、`配置`、`免费兑换码`、`公益订阅`。
4. 降低优先级：求助、推荐付费机场、客户端教程、代理共享、订阅转换工具。
5. 根据标签页活动信息读取最近 30 天的高信号主题；如果结果不足，再扩大到 90 天。
6. 对仍活跃的长期主题保留，不因发布时间早而排除。

运行：

```powershell
powershell -ExecutionPolicy Bypass -File scripts/discover_topics.ps1 -LimitPerTag 30
```

脚本输出是候选索引，不是可用性结论。

## 搜索查询

固定标签不足时，依次尝试：

```text
site:linux.do "节点分享" clash v2ray
site:linux.do "免费节点" Clash
site:linux.do "公益订阅" 恢复
site:linux.do "订阅链接" V2Ray
site:linux.do "c.yaml" "v.txt"
site:linux.do "Clash Meta" 免费节点
site:linux.do "V2rayN" 节点分享
site:linux.do "机场分享" 到期
```

在此环境中 Yahoo 经 Jina reader 曾比 Google、Bing、DuckDuckGo 更稳定：

```text
https://r.jina.ai/http://search.yahoo.com/search?p=<URL编码查询>
```

已知问题：

- Google reader 可能只返回跳转提示。
- Bing/Brave/DuckDuckGo 可能触发 CAPTCHA。
- `s.jina.ai` 可能要求 API key。
- LINUX DO `/search` 经 reader 可能返回 `429`。
- 搜索摘要可能泄露已过期直链，只当发现线索。

## 主题读取

使用：

```text
https://r.jina.ai/http://linux.do/t/topic/<topic_id>
https://r.jina.ai/http://linux.do/t/topic/<topic_id>/<floor>
```

记录：

- `Published Time` 与主题列表的最近活动时间；
- 主帖声明的流量、到期、协议、国家、客户端；
- 回复中的“可用”“速度不错”“token error”“订阅失败”“人数太多”“IP 太多”；
- 主帖是否编辑、删除或变成私密；
- 是否有 `Skip to last reply`、占位楼层或 `Load more posts below`。

没有完整读取所有楼层时，只说“主帖和高信号可见回复”。

## 链接与附件

链接分为：

1. 静态文件：`.yaml`、`.yml`、`.txt`、`.json`。
2. 公开官网和备用域名。
3. 账号级订阅接口。
4. 论坛上传附件。
5. GitHub 或部署教程。

静态文件先用 `scripts/probe_public_urls.ps1` 做 `HEAD`，保持 TLS 验证且不打印正文。服务器不支持 `HEAD` 时，按 `linux-do-research/references/network_workflow.md` 对单个公开、非敏感 URL 使用带范围限制的 GET；不要把 `-k` 设为默认值。

论坛短附件常被 Cloudflare 阻断。不要判定附件不存在；报告 `attachment-browser-required`，必要时按 `linux-do-research` 使用浏览器解析 CDN URL。

图片只在包含唯一入口、兑换题或关键状态时读取。图片没有域名时不要猜测项目地址。

## 时效和失效判断

强有效证据：

- 当前 HTTP `200`/`206`；
- 文件有近期 `Last-Modified`；
- 作者当天宣布恢复；
- 最近回复明确已使用；
- 官网和备用站均可达。

强失效证据：

- 到期日已过；
- 接口返回 `token is error`；
- 作者宣布停止；
- 多个回复报告人数/IP 限制；
- 主题明确限制人数且已满；
- 页面变成 404/private，且无其他入口。

弱证据，不能单独下结论：

- 帖子较旧；
- 没有近期回复；
- Cloudflare `403`；
- reader 没显示附件或图片；
- 搜索引擎没有收录。

## 网络交接

代理、规范 reader URL、TLS 诊断、Cloudflare 判定、搜索失败恢复和浏览器升级统一由 `linux-do-research/references/network_workflow.md` 管理。本技能只传递候选标签/主题 URL、已尝试方法、curl 退出码、楼层/附件缺口和节点领域敏感性分类，不另建一套网络规则。

## 已验证经验

- “免费节点”标签通常给出真正的共享节点和当月兑换活动。
- “订阅节点”标签噪声较多，混有 AI 订阅、客户端问题和付费推广，需要标题分类。
- 每日或短期匿名分享经常含个人 token；越“可直接粘贴”，越要先检查归属和泄露风险。
- 当月兑换活动通常比旧的匿名直链稳定，虽然多一步注册，但不会共用同一账号级 token。
- 公开静态 `.yaml`/`.txt` 可以直接给出；个人订阅 URL 即使公开在论坛，也只给原帖。
- 回复比主帖更能判断失效：常见信号是 `token error`、订阅失败、IP 过多和人数满。
- 工具项目要单独归类，不能用“支持 Clash/V2Ray”包装成节点来源。
