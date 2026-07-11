# Codex 插件排障案例手册

## 为什么存在

这个参考文档记录了本地反复排查 Codex Desktop 插件故障的路径：Chrome、Browser Use、Computer Use 或 `node_repl` 看起来已经安装，但模型无法调用官方工具。

当现场症状混乱、之前已经尝试过多种修复，或 Codex 更新/CC Switch 可能重写了有效设置时，使用它。

## 本地时间线

1. Chrome/Computer Use 插件已启用，但模型没有收到 `mcp__node_repl__js`。
2. 先确认：插件图标已安装和技能已注入还不够。模型可见工具列表是单独一层。
3. 曾发现一次早期故障：`openaiDeveloperDocs` MCP 在自定义 provider 运行中污染或挤占了工具表面。禁用它修复了那一轮问题。
4. Codex 更新后，运行时路径改变。旧配置指向陈旧的 `node_repl.exe`、`node.exe`、`node_modules` 或 Chrome `latest` junction。随后在 CC Switch 工具中加入了 `repair-runtime`。
5. Edge 起初看起来不支持，只是因为缺少 Edge Native Messaging Host 注册。添加 `HKCU\Software\Microsoft\Edge\NativeMessagingHosts\com.openai.codexextension` 后恢复了这一侧。
6. 后来的一次故障不同：Codex 日志显示已发现 `node_repl`，但当前请求仍只暴露了很小的工具集，没有直接的 `mcp__node_repl__js`。
7. 证据显示 `codex_apps` 存在且工具数量非常大，而 `node_repl` 只有 3 个工具。设置 `[features] apps = false` 后，在重启/新一轮对话后恢复了直接暴露 `mcp__node_repl__js`。
8. 随后通过 `mcp__node_repl__js` 验证官方 Chrome 插件运行时：导入内置 `browser-client.mjs`，调用 `agent.browsers.get("extension")`，并列出打开的标签页。
9. 最后一次脚本修正保留了现有可工作的 `CODEX_CLI_PATH`，而不是强行改回更旧的 `.plugin-appserver` alpha binary。现在运行时修复会清理陈旧路径和临时 `SKY_CUA_*` pipe env，同时不和有效的 Codex CLI 路径对抗。

## 官方发现

OpenAI Codex 手册说明：

- `[features]` 控制可选和实验性能力。
- `apps` 默认是 `false`。
- `apps` 是实验性选项，含义是启用 ChatGPT Apps/connectors 支持。
- Apps/connectors 有自己的 `[apps]` 控制项，并且与 MCP 和内置浏览器插件分离。

因此，`features.apps = false` 不应该禁用 Chrome、Browser Use、Computer Use 或 `node_repl`。它禁用的是 `codex_apps` 连接器工具等 ChatGPT app/connectors 支持。

## 社区证据

GitHub issue `openai/codex#28481` 报告：

- Windows 上的 Codex Desktop 26.609 中 `mcp__node_repl__js` 不可用。
- `node_repl` 已配置且运行时存在，但模型工具列表没有暴露该工具。
- Browser 和 Computer Use 工作流不可用，因为它们依赖 Node REPL。
- 后续评论显示更新的 Windows Desktop 构建也有类似故障，并出现了部分修复：注册有所改善，但路由仍有缺陷。

把它作为证据：该症状可能是 Codex Desktop 工具暴露/路由问题，不只是本机配置错误。

## 证据清单

修复前收集这些信息：

```powershell
Select-String -Path "$env:USERPROFILE\.codex\config.toml" -Pattern '^\[features\]|apps\s*=|openaiDeveloperDocs|node_repl|CODEX_CLI_PATH|BROWSER_USE'
Get-Content "$env:USERPROFILE\.codex\chrome-native-hosts-v2.json"
codex mcp get node_repl
codex mcp list
codex plugin list
```

如果当前工具列表可用，检查 `mcp__node_repl__js` 是否可直接调用。如果不能，使用工具发现搜索 `node_repl js`。如果发现也失败，但 `codex mcp get node_repl` 成功，怀疑工具暴露问题。

## 官方 Chrome 运行时探针

仅在 `mcp__node_repl__js` 可用时使用：

```js
// 先从当前插件元数据或工具返回值解析实际 skill/plugin 根目录。
const { setupBrowserRuntime } = await import("file:///<resolved-current-plugin-root>/scripts/browser-client.mjs");
await setupBrowserRuntime({ globals: globalThis });
globalThis.browser = await agent.browsers.get("extension");
const tabs = await browser.user.openTabs();
nodeRepl.write(JSON.stringify({ count: tabs.length, sample: tabs.slice(0, 5).map(t => ({ title: t.title, url: t.url })) }, null, 2));
```

带版本号的插件路径可能变化。在另一台机器运行前，先解析当前插件版本。

## 本地代理检索模式

当官方文档或 GitHub 被阻断时：

```powershell
foreach($p in 10808,7890,7897,1080) {
  "$p " + (Test-NetConnection 127.0.0.1 -Port $p -InformationLevel Quiet -WarningAction SilentlyContinue)
}

curl.exe -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://developers.openai.com/codex/codex-manual.md
curl.exe -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://api.github.com/repos/openai/codex/issues/28481
```

除非用户明确要求持久化代理配置，否则代理只用于这次查询。
如果证书校验失败，不把 `-k` 结果提升为可信证据；最多在用户明确授权的单次诊断中作为待复核线索，并在报告中标注 TLS 未验证。

## 决策树

- `mcp__node_repl__js` 可见且 Chrome 探针可用：插件链健康。
- `mcp__node_repl__js` 可见但 Chrome 探针超时：检查 Chrome/Edge 扩展、Native Messaging Host 和浏览器进程状态。
- `node_repl` 已配置但 `mcp__node_repl__js` 不可见：检查 `features.apps`、`openaiDeveloperDocs`、当前 Desktop 版本和工具表面日志。
- `node_repl` 缺失或路径陈旧：根据 `chrome-native-hosts-v2.json` 修复运行时路径。
- Edge 标签页不可见但 Chrome 可用：检查 Edge 扩展安装和 Edge Native Messaging Host 注册表。
- 修复只在 CC Switch/provider 切换前有效：把已知良好配置同步到 CC Switch provider 模板和 `proxy_live_backup`。

## 当前本地已知良好形态

```toml
[features]
apps = false

[plugins."chrome@openai-bundled"]
enabled = true

[mcp_servers.openaiDeveloperDocs]
enabled = false

[mcp_servers.node_repl]
type = "stdio"
startup_timeout_sec = 120
```

不要在机器之间盲目复制路径。运行时路径取决于安装环境。
