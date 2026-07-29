# 证据来源

以下来源用于支持通用方法，不替代目标站点的实际 Network、bundle 和状态复核。

## 官方文档

- [MDN: Window.localStorage](https://developer.mozilla.org/en-US/docs/Web/API/Window/localStorage)
  - `localStorage` 按 origin 提供存储，数据可跨浏览器会话保存。
- [MDN: Set-Cookie](https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Set-Cookie)
  - `HttpOnly` 禁止 JavaScript 通过 `document.cookie` 读取，但 Cookie 仍会随 `fetch`/XHR 请求发送；`SameSite` 控制跨站请求携带行为。
- [Chrome DevTools: Network panel](https://developer.chrome.com/docs/devtools/network/)
  - Network 面板用于查看请求日志、Headers、Preview、Response、Initiator 和 Timing，并支持按请求属性过滤。
- [Go x/image basicfont](https://github.com/golang/image/blob/master/font/basicfont/basicfont.go)
  - `Face7x13` 来源于公共领域 X11 misc-fixed 字体，源码定义 `Width: 6`、`Height: 13`；适合核对固定像素验证码字形。
- [systemd.timer](https://www.freedesktop.org/software/systemd/man/latest/systemd.timer.html)
  - `OnCalendar=` 定义日历触发，`Persistent=` 补跑错过的日历任务，`RandomizedDelaySec=` 添加随机延迟，`AccuracySec=` 控制触发精度。目标主机也可用 `man systemd.timer` 核对已安装版本。

## LINUX DO 实读主题

- [【青龙脚本】上汽大众签到脚本](https://linux.do/t/topic/1363979)
  - 已读取首帖。帖子展示了每日签到、状态查询、Token 缓存与刷新、首次验证码登录、设备认证和 cron 调度；附带代码按 JWT 过期时间管理 token，并生成请求签名。支持“自动化应把认证生命周期、设备身份和调度作为独立职责”的经验结论。
- [〖开源〗微信公众号文章材料整理工具](https://linux.do/t/topic/2534283)
  - 已读取 1-5 楼。主题标注 `mitmproxy`，首帖说明配合微信 PC 客户端减少人工采集步骤；作者在第 3 楼称 v1 的抓包处理较典型、v2 使用 requests 多进程协同。支持“抓包证据可转成独立 requests 工作流，但需控制范围和并发”的经验结论。
- [分享一个官号 Codex 用量可视化油猴脚本](https://linux.do/t/topic/2268948)
  - 已读取首帖及可见回复。脚本在已登录的官方 analytics 页面请求官方接口，作者明确说明不展示或保存 accessToken/Cookie，只使用当前登录会话。支持“页面脚本可复用浏览器会话，而无需导出长期凭据”的经验结论。
- [[油猴脚本] 为 cpa 的 Codex 供应商增加排序、复制和测活](https://linux.do/t/topic/2412002)
  - 已读取 1-2 楼。首帖明确脚本只修改前端展示、不写回配置，同时增加受控 API 测试按钮。支持“UI 增强、只读测试和配置写入必须分清副作用边界”的经验结论。

## 本技能形成时的网络审计

- 按 `linux-do-research` 网络优先流程，先尝试命令级代理 `http://127.0.0.1:10808`；当时代理端口不可连接。
- 直接访问 Linux.do 搜索 JSON 被 Cloudflare 403，Jina 搜索端点返回 429；未使用浏览器、Cookie、localStorage 或论坛登录态。
- 通过 `r.jina.ai/http://linux.do/tags`、相关 tag 页面发现真实主题，再用主题 URL 读取正文。
- 未发帖、未回复、未点赞、未下载附件，也未创建浏览器标签页。
