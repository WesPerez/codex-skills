# Discourse 主题与楼层提取

LINUX DO 基于 Discourse。读取主题、回复、楼层、收藏和活动页时使用此参考文档。

## 覆盖标准

除非已经具备以下内容，否则不要声称“所有楼层”或“所有回复”已读取：

- 主题 URL 和标题；
- 可用时的预期帖子数或最高可见楼层；
- 已提取楼层号列表；
- 对缺失/被 cloaked 楼层的明确处理；
- 相关时跟随链接主题/教程；
- 最终缺口列表为空，或已清楚报告。

如果用户问“你读完每个帖子了吗？”，用精确覆盖回答，不要用信心措辞。

## 仅网络 JSON

在网络优先阶段，shell/network 请求可以在无需浏览器凭据即可访问时尝试 Discourse JSON：

- 主题 URL：`https://linux.do/t/topic/2527525`
- JSON URL：`https://linux.do/t/topic/2527525.json`

JSON 可能包含：

- `title`
- `posts_count`
- `highest_post_number`
- `post_stream.posts`
- `post_stream.stream`

Cloudflare 可能阻断直接 shell 请求。如果网络 JSON 访问失败，使用 reader 页面或升级到浏览器 DOM 提取。

不要把浏览器/插件标签页导航到 `.json` 主题 URL。浏览器访问 `https://linux.do/t/topic/<id>.json` 经常被 Cloudflare 阻断并浪费时间。在浏览器兜底中，使用普通主题页面和 `/7`、`/14`、`/30` 等主题位置 URL，然后提取 DOM 可见楼层。

永远不要通过窃取浏览器 cookies 来绕过。

## DOM 提取模式

在 `tab.playwright.evaluate` 内提取有界、结构化内容：

```js
var posts = await tab.playwright.evaluate(() => {
  const strip = (html) => String(html || "")
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  return Array.from(document.querySelectorAll(
    ".topic-post[data-post-number], article[id^='post_'], [id^='post_']"
  )).map((el) => {
    const num = Number(
      el.getAttribute("data-post-number") ||
      (el.id || "").match(/post_(\d+)/)?.[1] ||
      0
    );
    const links = Array.from(el.querySelectorAll("a[href]")).slice(0, 80)
      .map((a) => ({ text: strip(a.innerHTML || a.textContent).slice(0, 160), href: a.href }));
    return {
      tag: el.tagName,
      id: el.id,
      className: el.className,
      post_number: num,
      text: strip(el.innerHTML || el.textContent).slice(0, 5000),
      links
    };
  }).filter((p) => p.post_number && p.text);
});
```

按楼层去重 wrapper div 和内部 article。存在 `ARTICLE` 版本时优先使用。忽略没有正文、只有 `由 username 于 ... 发布` 这类纯 cloaked 占位文本。

## Cloaked 或 Lazy 楼层

Discourse 经常把远处楼层渲染为占位：

```html
<div class="post-stream--cloaked" data-post-number="6" id="post_6">
```

这不表示该回复没有内容，只表示楼层未加载。

加载缺失楼层：

1. 确定缺失楼层范围。
2. 打开一个临时主题位置标签页：
   - `/7` 用于读取 6-8 楼附近；
   - `/10` 用于读取 9-15 楼附近；
   - 选择靠近缺失范围中心的楼层。
3. 短暂等待内容加载。
4. 只提取需要的范围。
5. 关闭临时标签页并验证关闭。

临时 URL 示例：

```text
https://linux.do/t/topic/2527525/7
```

不要让这些临时标签页保持打开。

## 收藏/活动页面

对于收藏页面，例如：

```text
https://linux.do/u/<username>/activity/bookmarks
```

如果已有 Edge 标签页打开，使用现有标签页。提取收藏卡片/行：

- 可见标题；
- URL；
- 分类；
- 摘要；
- 最后活动时间；
- 任何可见标签或元数据。

然后用主题工作流处理每个相关收藏主题。如果收藏很多且用户要求全部读取，维护进度表：

```text
主题 URL | 标题 | 状态 | 已读楼层 | 已跟随链接 | 附件 | 笔记
```

除非用户授权过滤，否则不要因为收藏“看起来旧”就静默跳过。

## 链接主题与教程

当链接可能包含以下内容时跟随它：

- 原始来源包；
- 教程/使用说明；
- 密码或警告；
- 上游账号生成方法；
- 删除/清理指导；
- 解读当前帖所需的回复上下文。

除非需要，否则不要跟随无关社交/profile/category 链接。

对每个跟随的链接，记录：

- 来源楼层；
- 链接文本；
- URL；
- 是否打开；
- 提取的关键事实；
- 临时标签页是否关闭。

## 楼层摘要格式

小主题逐楼总结：

```text
1: 作者 - 附件、链接、主要说明/警告。
2: 作者 - 简短回应/无新增信息。
3: 作者 - 询问来源群/无需操作。
...
```

大主题分组：

- 可执行说明；
- 警告/风险报告；
- 附件；
- 教程/链接；
- 重复感谢/噪声；
- 未回答问题。

即使最终答案很简洁，也要保留覆盖记录。

## 准确性检查

下结论前：

- 如果已知，比较提取楼层与预期 `posts_count`/最高楼层；
- 重新访问任何缺失楼层范围；
- 检查主帖和高信号回复中的链接；
- 可行时对照论坛可见大小验证下载附件大小；
- 说明任何限制，例如“读取了可见 1-15 楼；未读取较旧收藏主题”。

## 常见坑

- 只读第一页却声称读完所有回复。
- 把 cloaked 占位符当作空回复。
- 为同一 URL 打开重复标签页。
- 关闭用户原始标签页。
- 丢失临时下载/位置标签页的跟踪。
- 使用直接 shell HTTP，并把 Cloudflare 403 当作资源不可访问的证明。
- 把浏览器/插件标签页导航到主题 `.json` URL，而不是使用普通主题页和 DOM 提取。
- 打印过多页面文本，而不是提取结构化数据。
