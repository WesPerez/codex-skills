# 证据、安全与停止条件

## 证据桶

| 候选桶 | 优先证据 | 不应越界推断 |
| --- | --- | --- |
| `edge_limit` | 503/429、零时长、Nginx limit zone、并发水位 | 不直接证明攻击或运营商封锁 |
| `upstream_unavailable` | 502/504、connect refused、timeout、后端 listener 缺失 | 不应改 DNS 或客户端规则 |
| `tls_edge` | 443 无监听、SNI/证书或握手错误 | 不应重启其他 Nginx/业务容器 |
| `client_churn` | 同源/同 UA 的短会话、重试集中 | 不足以证明服务端是唯一根因 |
| `dns_policy` | WS 已 101，DoH/DoT/特定域名失败 | 不应把安全 DNS 拦截等同于 443 503 |
| `resource_pressure` | fd、内存、swap、重传与窗口同向恶化 | 单项告警不能定罪 |
| `config_drift` | 后端、Nginx、订阅、生成器字段不一致 | 不应直接全量覆盖配置 |
| `insufficient_evidence` | 无时间窗、无归属、权限/格式缺口 | 必须停在只读诊断 |

每条结论带 `fact / inference / hypothesis / action` 标签和置信度。若多个桶同时出现，按入口拒绝、上游、TLS、DNS/出站的顺序分离，不用一个“网络不稳”解释全部现象。

## 脱敏

- UUID、订阅 token、密码、私钥、完整 URL、完整 WS/gRPC path、Cookie 和 Authorization 永不进入报告、Git 或子代理消息。
- IP 用短哈希、截断网段或角色标签；只有用户明确要求且仍在本地诊断时才显示明文。
- 读取 JSON 时只取 protocol、network、listen、port、path 是否匹配、client 数量等结构字段；不要把整个配置贴到对话。
- 日志只输出计数、分位数、类别和时间范围；原始行若必须保留，只放在用户明确指定的受控目录并再次脱敏。

## 生产门禁

默认只读。进入写操作前必须能回答：

1. 改的是哪一个入口、哪一份实际生效配置、由谁生成/覆盖。
2. 旧值、备份路径、回滚动作和影响范围是什么。
3. `nginx -t`、后端 test、平滑 reload 和端到端验证如何执行。
4. 何种指标会停止变更或触发回滚。

禁止：数据库/Redis 操作、订阅 token 轮换、删除日志/证书/备份、安装包、改防火墙/MTU/系统 DNS、停 Docker 或同机无关服务、真实凭据压测、频繁 restart/reload。

允许的最小动作通常是：备份入口配置，更新实际源模板和 checker，原子替换，`nginx -t`，单次平滑 reload，等待一个完整窗口，复测并保留恢复点。只有 listener 丢失、后端 unit 明确失活且连续健康检查失败时，才考虑一次归属明确的后端 restart。

## 结果状态

- `verified`: 证据和端到端验收都通过。
- `partially_verified`: 本机链路通过，但客户端/第二故障域/长时窗未验证。
- `candidate_only`: 只有日志相关性，尚未做因果验证。
- `blocked`: 目标归属、权限、生成器来源或回滚路径不清。

不要把“脚本运行成功”“systemd active”或“订阅可拉取”单独写成 `verified`。
