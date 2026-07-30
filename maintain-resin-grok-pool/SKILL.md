---
name: maintain-resin-grok-pool
description: 维护 Resin（用户也可能称 RELIN）中的 Grok 动态代理池：从本地大代理文件或经 LINUX DO 核验的公开批次导入 HTTP/HTTPS/SOCKS5 节点，以不调用模型账号的 CONNECT、TLS 与小流量出口探针批量验证，失败保护后通过 Resin 官方 Admin API 原子更新，定期淘汰失效节点并保留可信兜底。用户要求给 Resin/RELIN 加代理、导入 all_proxy_http、每天更新或清理七天节点、降低验证流量、让 Grok 账号独立使用动态出口或排查 Resin 池断流时使用。不要用于搜索节点以外的一般论坛研究、Grok OAuth 注册/刷新/删除、Sub2API 通用部署或非 Resin 代理工具。
---

# 维护 Resin Grok 代理池

## 目标

把不稳定的大批代理收敛为一个可审计的 Resin 入口。验证过程不使用 Grok OAuth、不调用模型生成接口，也不消耗账号 token；生产更新必须保留现有可信订阅、失败关闭并可回滚。

## 分流

- 搜索 LINUX DO 来源时，先完整使用 `find-linuxdo-node-links`；继承其 `linux-do-research` 交接、附件、敏感 URL 和楼层证据规则。个人订阅 token、单节点凭据和弱混淆地址只记录主题，不加入无人值守配置。
- 实际修改 Grok OAuth 账号的 `proxy_id`、处理 402/429 或验证指定账号时，单独使用 `grok-sub2api-ops`。真实 429 禁止新增测试。
- 本技能只管理代理来源、节点验证、Resin 订阅和维护任务，不接管 OAuth 生命周期或 Sub2API 通用数据库操作。

## 拓扑原则

- 不让 OAuth 请求逐次随机换公网 IP。每个 Grok 账号使用唯一 Resin 逻辑 Account，Resin 为它建立粘性租约；物理节点熔断后才迁移。
- Sub2API 中的 `proxy_id` 可以绑定逻辑 Resin 凭据，但不能把它误称为固定物理节点。多个 Sub2API proxy 对象可指向同一 Resin 地址并使用不同 `Platform.Account` 用户名。
- 默认接纳所有地区；先为每个已验证地区保留少量最快出口，再按全局延迟补满目标池。地区还用于分布统计和故障审计，但不替代节点可用性判断。只有用户明确要求合规或地域边界时，才配置 `allowed_regions` 或 Resin `region_filters`。
- 保留已有可信订阅作为同平台兜底。公开节点放在独立、可替换的本地订阅中，不覆盖可信订阅。Resin 的多个 `regex_filters` 是 AND 关系；合并多个来源时使用一个明确 alternation 正则，不能逐条追加来源正则。
- 重试必须有上限。连接失败由 Resin 被动熔断和下一连接换路处理；不得无限重放带业务副作用的请求。
- 动态出口主要处理传输故障、TLS/CONNECT 失败和出口信誉问题。遇到 `429` 先判定作用域并优先保持同一身份/出口延迟重试：可信 `Retry-After` 按要求退避，否则等待 30 秒，必要时再等 30 秒，总主动等待不超过 60 秒。等待后仍可能是单出口限制时，匿名公开 `GET/HEAD` 最多串行尝试三个已验证网络路径，携带登录身份时每次事件只切换一个已验证出口做一次 A/B。成功后固定路径；所有有界路径仍为 `429` 时使用论坛分类/主题 JSON、reader 原文、公开 CDN 或稍后续跑，不得并发扫出口或持续换 IP。

## 工作流

1. 只读确认实际生产对象：`resin-grok.service`、监听地址、Admin token 来源、状态库、目标 Platform、现有订阅和可信兜底。不要凭名称猜环境。
2. 检查输入权限和结构，只统计行数、格式、唯一数与哈希，不打印代理地址或凭据。凭据文件和配置必须为 `0600`。
3. 对论坛来源记录主题、楼层、日期、附件/外链状态、有效期和敏感分类。只有公开静态文件或用户明确拥有的来源可进入配置。
4. 先运行只读验证。脚本并发执行代理认证、到 `grok.com:443` 的 CONNECT 与 TLS 证书握手，再用 Cloudflare trace 小响应取得出口和地区；不发送 Grok HTTP 业务请求。
5. 检查 `passed_count`、`selected_count`、唯一出口、地区和失败分类。验证数量低于绝对阈值或相对上一批骤降时停止，不更新生产池。
6. 写入前对 Resin `state.db`、`cache.db` 使用 SQLite 在线备份并执行 `integrity_check`。只通过官方 Admin API 创建或更新受管订阅、刷新并补充 Platform 正则。
7. 更新后核对订阅内容哈希、解析节点数、Platform 路由节点数、可信订阅仍存在和服务健康。失败时用 API 恢复原订阅和 Platform 过滤器，保留恢复点。
8. 每日任务复用同一配置；内容未变化时不写生产、不重复备份。只轮换带本技能 owner manifest 的运行目录。
9. 论坛批次使用 `scripts/discover_linuxdo_proxy_batch.py` 做低频确定性发现：合并福利分类最新 JSON 与已核验持续发布作者主题页，最多核验六个候选、按主帖真实 `created_at` 选三个未过期主题；每主题最多下载两个公开附件并只保留小样本。HTTP 429 和 reader 正文内嵌 429 共享单次任务 60 秒主动等待预算：同出口先等 30 秒重试，必要时再等 30 秒；可信 `Retry-After` 超出剩余预算时保留旧源到下一轮，预算阶段结束后匿名请求才串行尝试至多三个已验证路径。不使用论坛 session，不下载全部大分片。
10. 发现器先发布按内容 hash 命名的不可变候选代文件，再原子切换 sidecar manifest；验证器以 manifest 指向的代文件为准，兼容路径只作人工查看。附件返回 `Content-Length` 时必须精确匹配，短读不进入样本。manifest 决定过期与 hash，发现失败时保留仍未过期的上批，过期后由验证器自动跳过。

## 脚本

只读验证：

```bash
python3 scripts/resin_pool_sync.py validate --config <config.json>
```

验证并生产更新：

```bash
python3 scripts/resin_pool_sync.py run \
  --config <config.json> \
  --admin-token-file <systemd-credential-or-private-token-file> \
  --confirm-production-write
```

`scripts/proxy_probe.py` 支持以下逐行格式：

- `http://[user:pass@]host:port`
- `https://[user:pass@]host:port`
- `socks5://[user:pass@]host:port`
- `user:pass@host:port`
- `host:port:user:pass`
- `host:port`

输入解析默认拒绝私网、环回、链路本地、保留地址和下载重定向到非公网目标。运行报告只保存节点指纹和出口哈希；仅 `validated-proxies.txt` 含凭据，权限必须保持 `0600`。

## 配置约束

配置至少包含：

```json
{
  "version": 1,
  "state_dir": "/var/lib/resin-pool-maintainer",
  "retain_runs": 7,
  "sources": [{"id": "local-batch", "type": "file", "path": "/private/proxies.txt"}],
  "validation": {"workers": 200, "batch_size": 500, "timeout_seconds": 5, "target_host": "grok.com", "trace_egress": true},
  "selection": {"max_nodes": 2000, "max_per_egress": 2, "min_per_region": 1, "require_egress": true, "allowed_regions": []},
  "safety": {"min_selected": 20, "min_passed": 20, "min_ratio_to_previous": 0.5},
  "resin": {
    "base_url": "http://172.17.0.1:10833",
    "subscription_name": "managed-grok-public-pool",
    "platform_id": "<verified-platform-uuid>",
    "platform_name": "GrokEU",
    "managed_regex": "^managed-grok-public-pool/",
    "platform_regex_filters": ["^(trusted-grok-local-pool|managed-grok-public-pool)/"],
    "region_filters": [],
    "backup_db_paths": ["/var/lib/resin-grok/state.db", "/var/cache/resin-grok/cache.db"]
  }
}
```

远程来源使用 `type=url` 与 `url`；有七天有效期时写入明确 `expires_at`。不要把不确定的“发帖后七天”永久配置为远程源。

## 验收与停止条件

- 完成：验证报告无秘密、选中节点达到阈值、Resin 备份可恢复、受管订阅哈希一致、Platform 同时包含可信与受管来源、Grok 账号逻辑身份映射另经 Grok 技能验收。
- 停止：来源身份或时效不清、附件只能依赖个人 cookie、有效节点骤降、API 对象漂移、备份失败、Platform 身份不符、回滚不完整。
- 不把 TLS 握手成功写成 Grok OAuth 账号可用；账号可用性只接受对应 Grok 技能规定的被动证据或必要的指定账号探针。
