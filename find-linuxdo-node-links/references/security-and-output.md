# 敏感 URL 与输出规范

## 目录

- 敏感识别
- 允许公开
- 验证方式
- 输出模板
- 审计清单

## 敏感识别

满足任一项时默认标记 `topic-only-sensitive`：

- URL 查询含 `token`、`auth`、`key`、`secret`、`password`、`uuid`、`access_token`。
- 路径含 24 位以上连续十六进制、标准 UUID 或长 Base64URL 字符串。
- 响应头出现个人流量、到期或账号信息，如 `Subscription-Userinfo`。
- 作者称“自用”“备用节点”“还剩多少 G”“多少天到期”“限制人数/IP”。
- 作者要求删除插入文字、Base64 解码、拼接路径或通过图片遮挡 token。
- URL 是单节点协议凭据：`vmess://`、`vless://`、`trojan://`、`hysteria2://`、`ss://`。

不要在回答、日志摘要或测试输出中打印秘密值。已经在工具输出中看到也不代表可以转发。

## 允许公开

通常可完整显示：

- LINUX DO 主题、标签和楼层 URL；
- 项目官网、备用站、GitHub 仓库；
- 明确面向公众长期发布的静态 `.yaml`、`.txt` 配置文件；
- 论坛附件短 URL，但注明 Cloudflare/登录限制；
- 不含账号凭据的客户端和教程链接。

如果静态文件 URL 的路径也像个人 token，按敏感处理，不因扩展名放行。

## 验证方式

默认仅请求响应头：

```powershell
& scripts/probe_public_urls.ps1 -Url @(
  "https://example.com/config.yaml",
  "https://example.com/"
)
```

需要从新的 `powershell.exe` 进程调用时，逐个 URL 调用，或先在该进程内构造数组；不要把逗号分隔值作为一个 `-Url` 字符串传入。

脚本发现疑似秘密时输出 `SKIPPED_SENSITIVE` 和输入序号，不请求目标，也不回显原始 URL。脚本不提供绕过开关；用户拥有且明确授权的订阅地址也应交给不会记录或回显秘密的专用客户端验证，不通过本公共 URL 探测器处理。

记录：

```text
CheckedAt | Status | FinalUrl | CurlExitCode | Classification | ContentType | ContentLength | LastModified
```

不要下载节点正文来“确认里面有几个节点”。如果用户确实要求结构检查，只统计协议、节点数量和字段存在性，不打印服务器、端口、UUID、密码或完整节点名。

## 输出模板

```text
截至 YYYY-MM-DD HH:mm（Asia/Shanghai）检索到的高信号结果：

可直接导入
- 类型：Clash/Mihomo
  URL：https://...
  状态：HTTP 200，最后修改时间 ...
  来源：https://linux.do/t/topic/...

注册或兑换后使用
- 名称：...
  原帖：https://linux.do/t/topic/...
  官网：https://...
  备用：https://...
  步骤：注册 -> 兑换 -> 生成个人订阅
  证据：主帖...；回复...

原帖内获取
- https://linux.do/t/topic/...
  原因：个人共享订阅含账号级 token，不二次扩散。
  属性：协议、地区、流量、到期、客户端。

已失效或有失效迹象
- https://linux.do/t/topic/...
  证据：token error / 到期 / 人数已满。

持续更新入口
- https://linux.do/tag/2138-tag/2138
- https://linux.do/tag/193-tag/193
- https://linux.do/tag/558-tag/558
- https://linux.do/tag/clash/1043
- https://linux.do/tag/v2ray/1570
```

用户要求“把 URL 全部显示出来”时，使用代码块逐行展示，不把地址藏进 Markdown 标签。仍然不输出敏感个人订阅值，并直接说明省略原因。

## 审计清单

- 已写明当前日期和时区。
- 已报告使用的命令级代理。
- 已说明是否使用浏览器或登录态。
- 已区分帖子发布时间和最近活动时间。
- 已说明读取的楼层范围和未读缺口。
- 已跟随与可用性直接相关的外链。
- 已报告附件状态和下载文件。
- 已完整显示所有允许公开的 URL。
- 未打印个人订阅 token、节点凭据或订阅正文。
- 未声称无法证明的“全部”。
- 已提醒免费节点的隐私和稳定性风险。
