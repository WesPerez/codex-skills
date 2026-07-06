# LINUX DO 研究的 Edge 标签页生命周期

控制浏览器处理 LINUX DO 前使用此参考文档。浏览器控制是同一个 `linux-do-research` 技能的兜底阶段，不是普通搜索的默认路径。

## 浏览器选择

- 默认使用 Microsoft Edge。
- 除非用户明确要求 Chrome，否则不要使用 Chrome。
- 如果可用自动化模块路径包含 `chrome`，仍要确认实际控制的标签页是 Edge 标签页。插件包名可能误导。
- 除非用户明确要求现有浏览器标签页、收藏或当前标签页工作，否则在网络优先阶段产生具体证据缺口前，不要使用浏览器兜底。

## 初始审计

读取前：

1. 通过官方浏览器扩展列出打开的浏览器标签页。
2. 记录每个相关标签页的 id、标题和 URL。
3. 识别用户拥有的目标标签页：
   - 用户给出了精确 URL；
   - 用户给出了标题子串，例如“第二批”；
   - 页面标题和 URL 匹配请求。
4. 优先接管该标签页，而不是打开新标签页。

不要仅仅因为接管了用户标签页用于自动化，就关闭它。

## 临时标签页登记

当必须打开新标签页时，在内部记录：

- tab id；
- 用途；
- 请求 URL；
- 最终 URL；
- 最终标题；
- 是否已关闭；
- 任何错误；
- 为什么需要该标签页。

有效临时标签页用途示例：

- 在 `/7` 读取被 cloaked 的 6-8 楼；
- 在 `/10` 验证 9-15 楼；
- 读取链接的教程主题；
- 将论坛上传短 URL 解析为 CDN URL。

除非用户明确要求且标签页清理可管理，否则不要并行创建很多标签页。对大多数主题读取，一次一个临时标签页更安全。

## 关闭规则

只有当以下条件全部满足时，才关闭标签页：

1. tab id 在当前任务的临时标签页登记中。
2. URL/标题仍匹配记录的用途。
3. 标签页不再需要。
4. 关闭它不会移除用户原始目标标签页。

如果 close 返回后，标签页仍出现在陈旧列表中，执行一次独立的打开标签页审计。如果标签页确实已消失，就不再操作。如果仍存在且仍匹配记录的临时标签页，再关闭一次。

永远不要关闭：

- 任务开始前已存在且未明确指定关闭的标签页；
- 归属不明的标签页；
- 无关用户标签页；
- 浏览器/系统/扩展标签页；
- 另一个 agent 或另一个会话的标签页。

## 官方扩展模式

典型 Node REPL 初始化：

```js
var pluginRoot = "C:/Users/Wes/.codex/plugins/cache/openai-bundled/chrome/26.602.40724";
var browserModule = await import(pluginRoot + "/scripts/browser-client.mjs");
await browserModule.setupBrowserRuntime({ globals: globalThis });
globalThis.browser = await agent.browsers.get("extension");
var tabs = await browser.user.openTabs();
```

不要把浏览器/插件标签页导航到 LINUX DO `.json` 主题 URL，例如 `https://linux.do/t/topic/<id>.json`；使用普通主题页和主题位置页，然后提取 DOM 可见帖子。

接管现有标签页：

```js
var tab = await browser.user.claimTab("<tab-id>");
```

创建临时标签页：

```js
var temp = await browser.tabs.new();
await temp.goto("https://linux.do/t/topic/123/10");
```

关闭已知临时标签页：

```js
await temp.close();
```

## 只读页面作用域限制

在官方插件中，`tab.playwright.evaluate(...)` 是只读的，并且可能不暴露普通浏览器 API，例如 `fetch`、`XMLHttpRequest`、`NodeFilter` 或完整 `performance`。

优先在 `evaluate` 内做 DOM 提取。如果页面作用域的网络 JSON 访问失败，不要假设网站宕机；改用 DOM/主题位置提取。

## 给用户的进度更新

长时间读取时，告诉用户：

- 接管了哪个现有标签页；
- 为什么需要临时标签页；
- 临时标签页何时关闭；
- 覆盖是否完整，还是仍有缺口。

标签页尚未审计前，避免说“完成”。

## 最终标签页报告

最终答复必须包含：

- 保留的用户拥有标签页；
- 打开并关闭的临时标签页；
- 留开的标签页及原因；
- 任何关闭失败尝试及后续审计结果。
