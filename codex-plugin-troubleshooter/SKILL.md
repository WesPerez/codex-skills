---
name: codex-plugin-troubleshooter
description: 诊断并修复 Codex Desktop 插件/工具暴露问题，尤其是 Chrome、Browser Use、Computer Use、node_repl、mcp__node_repl__js、codex_apps、应用连接器、Edge/Chrome Native Messaging Host、tool_search 未命中，以及 Codex 更新或运行时路径回退问题。适用于：Codex 浏览器或桌面控制插件已安装但不可用；官方插件技能无法调用所需的 Node REPL 工具；config.toml 或 CC Switch 可能覆盖插件设置；需要通过代理或替代的官方/社区来源收集 OpenAI 文档或社区证据。
---

# Codex 插件排障

## 核心规则

修改配置前，先证明失败层级。常见陷阱是把所有插件失败都当成同一个问题。把栈拆开看：

1. 技能存在并已启用。
2. 所需 MCP 服务器已配置。
3. MCP 服务器可以启动并列出工具。
4. 当前模型可见的工具表面直接或通过工具发现暴露该工具。
5. 插件运行时可以连接 Chrome/Edge/Computer Use。
6. 浏览器/Native Host 侧可以看到标签页或应用。
7. 配置在 Codex 重启和 CC Switch/provider 切换后仍然保留。

只修复第一个断掉的层级。

## 快速流程

1. 先读取相关的内置技能：
   - Chrome：`chrome:control-chrome`
   - 内置浏览器：`browser:control-in-app-browser`
   - Computer Use：`computer-use:computer-use`
2. 检查当前可调用工具。如果存在 `mcp__node_repl__js`，就使用它。如果只存在 `js_reset` 或 `js_add_node_module_dir`，先用工具发现搜索 `node_repl js`，再判断失败。
3. 如果缺少 `mcp__node_repl__js`，检查 Codex 内部是否能看到 `node_repl` 但没有暴露给模型。这指向工具表面路由问题，而不是 Chrome 问题。
4. 检查 `~/.codex/config.toml`、CC Switch provider 模板和 `chrome-native-hosts-v2.json` 是否包含这些键：
   - `[features] apps = false`
   - `[mcp_servers.node_repl]`
   - `CODEX_CLI_PATH`
   - `NODE_REPL_NODE_PATH`
   - `NODE_REPL_NODE_MODULE_DIRS`
   - `BROWSER_USE_AVAILABLE_BACKENDS`
   - `[plugins."chrome@openai-bundled"] enabled = true`
5. 使用 Windows UI 兜底前，先通过 `mcp__node_repl__js` 验证官方运行时。
6. 执行最小的持久修复，然后开启新一轮对话/线程或重启 Codex Desktop。当前请求的工具列表不会热重载。

完整案例历史和精确命令见 `references/casebook.md`。

## 历史上下文

如果用户要求根因审计，或说“以前能用”，在下结论前先读取可用的本地历史：

- `~/.codex/attachments` 下粘贴的附件
- `~/.codex/.codex-global-state.json` 中的提示历史片段
- 用户粘贴到当前线程中的既往本地笔记或总结
- Codex/CC Switch 配置和 dry-run 输出

围绕精确症状做窄范围搜索，例如 `mcp__node_repl__js`、`node_repl`、`codex_apps`、`features.apps`、`Chrome Plugin`、`Computer Use`、`CODEX_CLI_PATH`、`openaiDeveloperDocs` 和 `NativeMessagingHosts`。不要因为个人数据就在附近就读取无关内容。

## 已知根因

- `features.apps = true` 在受影响的 Desktop 构建中可能用 `codex_apps` 连接器工具淹没工具表面，并隐藏 `mcp__node_repl__js`。官方文档说明 `apps` 默认是 `false`，只用于 ChatGPT Apps/connectors 支持。
- `openaiDeveloperDocs` MCP 曾在自定义 provider 上造成类似的模型可见工具问题。除非任务明确需要 Docs MCP 且已经验证健康，否则禁用它。
- Codex 更新可能改变内置运行时路径。需要根据当前 Native Host 注册表修复陈旧的 `node_repl.exe`、`node.exe`、`node_modules` 和 Chrome `latest` junction。
- 不要仅仅因为另一个注册表项不同，就强制重写有效的 `CODEX_CLI_PATH`。如果路径存在且可用，保留它。
- 当 Codex 扩展已安装并且 Edge 有 Native Messaging Host 注册项时，Edge 可以通过 Chrome 扩展链工作。检查该注册项前，不要断定“Edge 不支持”。
- MCP 服务器能工作还不够。模型必须实际看见或发现 `mcp__node_repl__js`。

## 官方文档与社区检索

优先使用 OpenAI 官方文档。如果直接请求遇到 `403`、`Vercel-Mitigated: deny`、超时或区域阻断：

1. 在不改持久配置的前提下检查本地代理端口：常见端口是 `10808`、`7890`、`7897` 和 `1080`。
2. 使用命令级临时代理，例如：

```powershell
curl.exe -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://developers.openai.com/codex/codex-manual.md
```

3. 如果 Windows Schannel 通过代理访问 GitHub API 时遇到吊销错误，只对这一次只读查询使用 `curl.exe -k`。
4. 用精确症状字符串搜索 GitHub issues 和论坛：
   - `mcp__node_repl__js unavailable Codex Desktop`
   - `unsupported call: mcp__node_repl__js`
   - `codex_apps node_repl tool list`
   - `Codex Desktop node_repl Chrome Computer Use`
5. 可用时也搜索官方/社区支持渠道：OpenAI docs、OpenAI Help/Community 页面、GitHub Issues、GitHub Discussions，以及 release/changelog 页面。

把社区帖子当线索，不当权威。可访问时，用本地行为和官方文档确认。

## 修复纪律

- 写入前优先做 no-op dry run。
- 编辑 `config.toml` 或 CC Switch DB/provider 模板前先备份。
- 除非断裂层级证明必要，否则不要清插件缓存、重装扩展或重置 Codex。
- 不要检查 cookies、浏览器存储、密码或会话存储。
- 修复后通过官方插件路径验证，例如 `agent.browsers.get("extension")` 和 `browser.user.openTabs()`。
