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

处理 OA 工作区浏览器任务时，先应用项目浏览器规则：除非用户明确要求 Chrome，默认浏览器是 Microsoft Edge。官方内置 skill、插件包或后端名称里出现 `Chrome`，只是插件/包名标签，不等于当前被控制的用户页签就是 Google Chrome。

## 快速流程

1. 先读取相关的内置技能：
   - Chrome：`chrome:control-chrome`
   - 内置浏览器：`browser:control-in-app-browser`
   - Computer Use：`computer-use:computer-use`
2. 检查当前可调用工具时，不只看聊天 UI 顶层命名空间，也要检查活跃运行时暴露的嵌套工具清单，例如 orchestrator 工具里的 `ALL_TOOLS`。如果任何可调用表面存在 `mcp__node_repl__js`，就使用它。如果只存在 `js_reset` 或 `js_add_node_module_dir`，先用工具发现搜索 `node_repl js`，再判断失败。
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

针对 Edge/OA 验收，在任何修复动作前先做这组无写入验证：

1. 通过 `mcp__node_repl__js` 和官方 `browser-client.mjs` 启动扩展桥。
2. 调用 `browser.user.openTabs()`。
3. 根据返回的页签 URL、标题、路由、最近打开时间，以及用户指定的浏览器识别目标；不要根据 `agent.browsers.list().name`、`codex/toolSurface.backend` 或插件目录名判断真实浏览器。
4. 如果目标 Edge 页签存在，接管该返回的页签对象并继续；不要切到 `mcp__chrome_devtools`。
5. 如果目标 Edge 页签不存在，先只读检查 Edge 扩展安装、Edge Native Messaging Host 注册、插件运行时可见性和当前工具暴露面。不要在 Chrome 后端会话里调用 `browser.tabs.new()` 后把新建的 Chrome 标签当成 Edge 证据；只有证明真实目标浏览器后，或用户明确接受 Chrome，才允许新开页签。

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
- `openaiDeveloperDocs` MCP 曾在自定义 provider 上造成类似的模型可见工具问题。只把它视为待核验的历史根因；本技能不得自行安装、启用或测试它。只有用户明确要求且 `openai-docs` 技能允许时，才交由该技能处理。
- Codex 更新可能改变内置运行时路径。需要根据当前 Native Host 注册表修复陈旧的 `node_repl.exe`、`node.exe`、`node_modules` 和 Chrome `latest` junction。
- 不要仅仅因为另一个注册表项不同，就强制重写有效的 `CODEX_CLI_PATH`。如果路径存在且可用，保留它。
- 当 Codex 扩展已安装并且 Edge 有 Native Messaging Host 注册项时，Edge 可以通过 Chrome 扩展链工作。检查该注册项前，不要断定“Edge 不支持”。
- 官方内置浏览器 skill 或扩展后端可能显示为 `Chrome`，但 `browser.user.openTabs()` 返回的仍可能是 Microsoft Edge 用户页签。不要只凭 `agent.browsers.list().name`、`codex/toolSurface.backend` 或插件包名判断真实浏览器；要结合返回页签的 URL/标题/最近打开时间、可见浏览器窗口标题、扩展安装和 Native Host 证据识别。
- 如果任务明确要求 Edge，`mcp__chrome_devtools` 不是可接受替代方案。应走 `mcp__node_repl__js` 官方扩展路径，并接管 `browser.user.openTabs()` 返回的页签对象。
- 之前一次 OA 失败的原因是跳过“默认 Edge”的项目规则，把官方插件里的 `Chrome` 命名当成 Google Chrome 证据。这不是运行时故障；正确的第一个问题是：`openTabs()` 实际返回了哪个浏览器/哪个页签？
- MCP 服务器能工作还不够。模型必须实际看见或发现 `mcp__node_repl__js`。

## Edge 事件笔记

当 OA 任务围绕浏览器选择失败时，先检查这个事故模式，再动配置：

- 原因：代理跳过了项目规则“默认使用 Microsoft Edge”，看到官方插件/后端命名里的 `Chrome`，就误以为被控制浏览器是 Google Chrome；但官方扩展链可能返回 Edge 用户页签。这是浏览器识别错误，不是 Edge 不可用的证明。
- 错误恢复：切到 `mcp__chrome_devtools`、使用独立 Chrome DevTools 会话，或把 Chrome 控制页面当成 Edge 验收等价物。
- 正确恢复：使用 `mcp__node_repl__js`，导入内置 `browser-client.mjs`，获取 `agent.browsers.get("extension")`，调用 `browser.user.openTabs()`，按返回 URL/标题/最近打开时间选择匹配的 Edge/localhost OA 页签，并接管这个返回的页签对象。
- 如果 `openTabs()` 里没有目标 Edge 页签，只读诊断 Edge 扩展安装、Edge Native Messaging Host 注册、插件运行时可见性和当前工具暴露面。在证明断裂层级前，不要重装、清缓存、改注册表或重写配置。
- 如果登录阻塞目标路由，且用户已授权使用已记住凭据或开发/测试账号，浏览器问题还没有结束。应通过可见登录交互或已认证 Edge 页签继续；禁止检查浏览器密码库、cookies、local storage、profile 或 token 文件。

## 官方文档与社区检索

优先使用 OpenAI 官方文档。如果直接请求遇到 `403`、`Vercel-Mitigated: deny`、超时或区域阻断：

1. 在不改持久配置的前提下检查本地代理端口：常见端口是 `10808`、`7890`、`7897` 和 `1080`。
2. 使用命令级临时代理，例如：

```powershell
curl.exe -x http://127.0.0.1:10808 -L -A "Mozilla/5.0" https://developers.openai.com/codex/codex-manual.md
```

3. 如果 Windows Schannel 通过代理访问 GitHub API 时遇到吊销错误，优先更换受信任网络路径或使用能正常校验证书的客户端。不得把 `curl.exe -k` 的结果当作可信证据；用户明确授权单次降级时，也只能作为待复核线索并记录 TLS 未验证。
4. 用精确症状字符串搜索 GitHub issues 和论坛：
   - `mcp__node_repl__js unavailable Codex Desktop`
   - `unsupported call: mcp__node_repl__js`
   - `codex_apps node_repl tool list`
   - `Codex Desktop node_repl Chrome Computer Use`
5. 可用时也搜索官方/社区支持渠道：OpenAI docs、OpenAI Help/Community 页面、GitHub Issues、GitHub Discussions，以及 release/changelog 页面。

把社区帖子当线索，不当权威。可访问时，用本地行为和官方文档确认。

## 修复纪律

- 写入前优先做 no-op dry run。
- 编辑 `config.toml`、注册表或 CC Switch DB/provider 模板前先备份并记录原值、目标值、备份路径、恢复命令和需要重启的组件；不能验证备份可读时不写入。
- 除非断裂层级证明必要，否则不要清插件缓存、重装扩展或重置 Codex。
- 不要检查 cookies、浏览器存储、密码或会话存储。
- 修改后先验证配置/注册表持久化，再按最小范围重启或开启新任务，记录是否需要用户完成交互式重启。验证失败时按已记录原值回滚并再次核验；不做宽泛缓存清理。
- 修复后通过当前插件技能解析出的运行时入口验证，不使用固定缓存版本路径。确认工具暴露和最小只读探针健康后，把实际浏览器任务交还 `chrome:control-chrome` 或适用的官方浏览器技能；只有浏览器外桌面操作才交给 `computer-use:computer-use`。
- 最终报告必须包含断裂层级、变更前后值、备份/回滚、重启、验证结果、未解决风险和交接目标。
