# LINUX DO 统一网络优先工作流

用于 LINUX DO 研究的网络优先阶段。在任何浏览器插件提取前，把它作为默认路径。

## 代理与超时

对 LINUX DO 和 `r.jina.ai` reader/search 工作，立即从本地代理开始。不要把最初 20-30 秒浪费在此环境中通常会超时的直连请求上。

使用每条命令自己的代理设置和短超时。不要持久化全局代理变量。

PowerShell 示例：

```powershell
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 "https://r.jina.ai/http://linux.do/t/topic/2508374"
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 -A "Mozilla/5.0" "https://linux.do/t/topic/2508374.json"
```

如果本地代理不存在，或因代理连接错误失败，做一次短直连重试，通常使用 `--max-time 15`，然后转到另一个代理支持/搜索索引路径。记录哪条路径可用。默认保持 TLS 证书验证；只有明确识别为 TLS 验证失败时，才能对该单条只读公开请求做一次显式 `-k` 诊断。该结果只能作为不可信线索，不能证明内容真实性或可用性，也不能变成脚本默认值。

不要持久化全局 `HTTP_PROXY` 或 `HTTPS_PROXY`。

## 发现查询

搜索用于发现，不用于证明。好用模式：

```text
site:linux.do K12 空间ID 被封 下车
site:linux.do K12 退出 工作空间
site:linux.do K12 下车 脚本
site:linux.do "K12灵车想跑路"
site:linux.do workspace deactivated K12
```

搜索 HTML 可能很嘈杂或被 CAPTCHA 拦住。如果输出只是搜索应用外壳，不要把它当证据。

## 读取主题

先尝试主题 reader URL：

```text
https://r.jina.ai/http://linux.do/t/topic/<topic_id>
https://r.jina.ai/http://linux.do/t/topic/<topic_id>/<floor>
```

使用位置 URL 补齐缺口：

- `/7` 用于早期缺失楼层；
- `/14`、`/23`、`/30` 用于后续范围；
- 如果 reader 显示 “Skip to last reply”，使用最终可见楼层号。

跟踪：

```text
主题 URL | 标题 | 可见数量/最高楼层 | 已读楼层 | 仅占位楼层 | 缺口
```

除非已知预期/最高楼层，并且每个楼层都提取到正文或被明确说明，否则永远不要声称已读取所有楼层。

## 证据标准

最终结论应基于原帖文本，而不是搜索摘要。优先包含：

- 精确标题和 URL；
- 引用句子或短段落；
- 可用时给出楼层号或作者/日期；
- 说明主题读取是完整还是部分。

区分：

- 已验证事实：直接引用或观察到的内容；
- 推断：你基于多个事实的综合判断；
- 未解决缺口：缺失楼层、被阻断附件、陈旧 reader 输出。

## 附件

论坛直接上传链接经常因 Cloudflare 失败：

```text
https://linux.do/uploads/short-url/<id>.txt
```

尝试：

```powershell
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 -A "Mozilla/5.0" "<forum-upload-url>"
curl.exe -x http://127.0.0.1:10808 -L --max-time 30 "https://r.jina.ai/http://linux.do/uploads/short-url/<id>.txt"
```

如果两者都失败，报告可见文件名、可见大小、来源主题/楼层、尝试过的方法，以及需要浏览器升级来解析它。不要说附件不存在。

只在附件对任务必要时下载。使用明确输出路径并记录字节数。如果文件可能包含 token/账号，只检查结构、数量、键和存在性布尔值。

## 网络何时足够

以下情况网络研究已经足够：

- 原始主题正文和相关回复可读；
- 覆盖完整，或缺口与答案无关；
- 关键链接/附件已读取或不需要；
- 结论可由直接引用支撑。

## 何时升级

在以下情况升级到浏览器兜底：

- 用户要求每个楼层，而 reader 输出有占位符；
- 关键附件/链接被阻断；
- 截图包含唯一重要证据，且无法从 alt text 解释；
- 论坛内容看起来私有，或 reader 输出与其他证据冲突；
- 否则答案会依赖摘要或猜测。

升级前写下：

- 使用过的查询；
- 尝试过的主题 URL 和楼层位置 URL；
- 使用的代理/直连路径；
- 已覆盖的楼层和链接；
- 需要浏览器帮助的精确缺口。

Cloudflare `403`、reader 空页或单一搜索缓存失败都不是资源不存在的证据。先交叉检查普通主题 URL、规范 reader URL、定向楼层 URL 和无需认证的网络 JSON；仍有影响结论的缺口时才升级浏览器。

## 浏览器升级护栏

使用浏览器插件兜底时，不要通过导航到 `.json` 主题 URL 来读取 LINUX DO，例如：

```text
https://linux.do/t/topic/<topic_id>.json
```

这些浏览器导航常被 Cloudflare 阻断。改用普通主题 URL 和主题位置 URL：

```text
https://linux.do/t/topic/<topic_id>
https://linux.do/t/topic/<topic_id>/<floor>
```

然后提取 DOM 可见帖子，并打开定向位置页面补齐缺失楼层。网络阶段在无需浏览器凭据可达时仍可尝试 shell/network JSON；禁止项专门针对浏览器/插件兜底导航。
