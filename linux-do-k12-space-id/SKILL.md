---
name: linux-do-k12-space-id
description: 快速执行 LINUX DO K12 ChatGPT/OpenAI workspace/space ID 收集流程。适用于 Codex 需要搜索或总结 LINUX DO 帖子中的 K12 空间ID、工作区ID、workspace IDs、Gmail/Outlook K12 IDs、带来源标记的近期 K12 space IDs，或按发帖顺序排列的 K12 ID 列表，并避免在被阻断的直连请求上浪费时间。
---

# LINUX DO K12 空间 ID

## 核心规则

将本技能与 `linux-do-research` 配合使用，但保持路径收窄：代理优先的网络读取、候选主题发现、reader 验证、UUID 提取、来源标记和最终审计。尝试本地代理前，不要把时间耗在直连 `linux.do`/`r.jina.ai` 等待上。

默认每个网络请求都使用：

```powershell
curl.exe -x http://127.0.0.1:10808 -L --max-time 35 "<url>"
```

如果代理不存在或返回代理连接错误，做一次短直连重试（`--max-time 15`），然后继续使用其他代理支持/搜索索引路径。不要持久化 `HTTP_PROXY` 或 `HTTPS_PROXY`。

## 快速流程

1. 把“最近的 N 个帖子”理解为主题发布时间顺序，而不是回复/活跃顺序。
2. 从已知高产发现路径开始：
   - K12 聚合主题的 reader：`https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/2514402`；
   - 通过代理支持的 DDG/其他搜索 HTML 运行搜索查询：
     - `site:linux.do/t/topic K12 空间ID`
     - `site:linux.do/t/topic K12 工作区ID`
     - `site:linux.do/t/topic K12 gmail 空间`
     - `site:linux.do/t/topic "空间Id是"`
     - 从相关主题表发现的精确标题。
3. 从所有 `https?://linux.do/t/topic/<id>` URL 中提取候选主题 ID。有标题文本时保留标题。
4. 抓取后按验证过的 `Published Time` 排序。在获得已验证时间戳前，只能临时用 topic ID 降序近似。
5. 用 Jina reader URL 抓取每个候选：
   `https://r.jina.ai/http://r.jina.ai/http://linux.do/t/topic/<id>`
6. 对每个主题记录：
   - topic ID、标题、URL、`Published Time`；
   - reader 返回的是原帖文本、private/404、rate limit，还是空内容/TLS 失败；
   - 从可见文本、附件文件名和解码后的混淆内容中提取的 UUID；
   - 状态警告，例如 `已失效`、`结束`、`deactivated_workspace`、`Payment Required`、`429`，或回复中说不可用。
7. 按 UUID 去重，但保留每个出现来源。
8. 输出来源映射和纯文本 ID 列表：
   `uuid | source(s) | status/note`。

## 避免事项

- 不要从直连 `linux.do/search.json` 或直连论坛搜索页开始；它们常返回 Cloudflare、429 或长时间等待。
- 不要把 `/latest` 当作发帖顺序。它是回复/活跃顺序。只用它发现近期主题 URL，然后验证每个主题的 `Published Time`。
- 不要把搜索摘要当作最终证据。除非 reader 页面确认内容，否则标记为 `search-snippet only`。
- 不要为了找 space ID 而下载账号 bundle 或附件。像 `sub2api-workspace-<uuid>.zip` 这样的附件文件名足以记录推断出的 workspace ID；除非正文确认，否则标记为 filename-derived。
- 不要解码或打印 access token、OAuth 凭据或完整账号 JSON。只提取非秘密 ID 和来源元数据。
- 除非用户要求浏览器/登录态读取，或最终答案否则会明显错误，否则不要使用浏览器兜底。如果使用浏览器兜底，遵循 `linux-do-research` 的标签页生命周期规则。

## 提取规则

用以下规则识别 UUID 样式的 space ID：

```text
\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b
```

当 UUID 出现在这些内容附近时，视为更强证据：

- `空间`、`空间ID`、`空间Id`、`工作区`、`工作区ID`、`workspace`；
- 例如 `sub2api-workspace-<uuid>.zip` 的文件名；
- 明确说 `空间Id是 <uuid>` 的回复。

当 UUID 只出现在这些内容中时，视为较弱/推断证据：

- 通用 `sub2api_<uuid>_*.zip` 文件名；
- `request id`、`chatgpt_account_id` 或账号 JSON 字段；
- 错误日志。此类情况只有在上下文清楚把它关联到 workspace/space ID 时才包含，或标明不确定原因。

处理 LINUX DO K12 帖子中常见的混淆：

- 移除 base64 字符串中插入的 `编码或解码` 等标记词；
- 规范化空白；
- 当解码后文本包含 UUID 时解码 base64 片段；
- 记录这些 ID 是从可见帖子文本解码得到的。

## 辅助脚本

标准流程使用 `scripts/collect_k12_space_ids.py`：

```powershell
python "C:\Users\Wes\.codex\skills\linux-do-k12-space-id\scripts\collect_k12_space_ids.py" --limit 30
```

有用选项：

```powershell
python "...collect_k12_space_ids.py" --limit 30 --extra-id 2531263 --extra-id 2531087
python "...collect_k12_space_ids.py" --candidate-id 2533655 --candidate-id 2531263 --candidate-id 2531087
python "...collect_k12_space_ids.py" --json
```

该脚本代理优先，不写文件，不下载附件，并打印带来源标记的结果。运行后，如果用户要求最大覆盖，对任何高价值的 private、failed 或 search-snippet-only 主题做人工检查。

## 最终报告

包含：

- 精确排序依据：优先使用已验证的 `Published Time`，必要时使用 topic ID 兜底；
- 来源映射，包含 topic ID、标题、URL 和发布时间；
- 带来源标签的去重 ID 文本列表；
- 无法验证的 private/404 或不可读近期候选；
- 是否使用代理；
- 是否打开/关闭任何浏览器标签页；
- 下载文件：通常为 `none`；
- 生成文件：通常为 `none`；
- 配置/环境变化：通常为 `none`。
