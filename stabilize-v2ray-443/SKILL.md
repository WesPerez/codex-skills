---
name: stabilize-v2ray-443
description: 稳定和修复经 Nginx TLS/WebSocket 暴露在 443 的 V2Ray、Xray、VLESS、VMess 或 Trojan 入口。用于“开代理像没网”、间歇性全挂、WS 握手失败、503/502/504、limit_conn、连接重试风暴、后端短暂停、配置生成器回写旧参数、需要可回滚生产修复或持续监控的场景。不用于搜索节点、导入账号、普通 Nginx 站点开发、纯出站代理池或只改客户端规则。
---

# V2Ray 443 稳定性修复

把用户体感拆成可验证的链路：

`客户端 -> DNS/SNI -> TLS:443 -> Nginx location -> WebSocket -> 本机 V2Ray/Xray inbound -> 路由/DNS/outbound`

目标是用证据定位真正的故障桶，按实测容量做最小生产变更，并留下回滚点、验收窗口和持续监控。默认先只读；用户已明确授权修复时仍要逐项保留备份和验证门禁。

## 硬边界

- 先确认目标角色：443 的 TLS 终结进程、对应 WS location、后端监听、对应 systemd/container unit 和日志。不要把同机的 SOCKS、其他代理池、邮件、数据库或其他 V2Ray 实例混为一谈。
- 不把“订阅 URL 能下载”当作数据面健康；也不把 `101` 后某些目标解析失败当成入口故障。
- 默认不回显或落盘完整订阅 URL、token、UUID、密码、私钥、Authorization/Cookie、WS path、客户端原始公网 IP。路径和身份只报告长度、类别或短哈希。
- 默认不执行公网探针、真实 VLESS 拨号、压测、订阅刷新、日志清空、包安装、防火墙修改、数据库操作或宽泛清理。
- 不因一条告警连环 restart/reload。相邻变更至少间隔一个验证窗口；优先 `nginx -t` 后平滑 reload，只有明确证明后端没有监听且健康检查持续失败时才考虑单次 restart。
- 任何限流放宽都必须同时检查 worker connections、nofile、内存、全局上限和同一 NAT 出口的真实并发；不得删光 `limit_conn`/`limit_req`。

## 工作流

### 1. 建立身份和基线

记录时间窗、主机/容器边界、客户端症状和允许的变更范围。只读确认：

1. 443 listener、TLS SNI/证书、Nginx master/unit。
2. WS location 的 `proxy_pass`、Upgrade 头、buffering、connect/read/send timeout、`limit_conn`/`limit_req`。
3. 后端 protocol、listen/port、network、path 的结构摘要；只输出 path 指纹。
4. 服务状态、启动/重启时间、监听和近期 access/error/journal 指标。
5. 订阅生成器、实际 snippet、校验器是否存在以及谁会覆盖谁。

使用 `scripts/analyze_ws_logs.py` 汇总明确指定的 access/error 日志；脚本默认只读且不打印原文。可用现有分钟级健康任务的 `last-status`/metrics，避免用真实凭据制造探测流量。

### 2. 按证据分流

把结论分成 **事实、推断、假设、动作**，不要跳级写“根因已确认”。优先判断：

- **入口限流**：`503` 与 `duration/request_time` 接近零，且 error log 有 `limiting connections`/`limit_req`。先查单 IP/NAT 并发、全局水位和重试风暴。
- **入口上游失败**：`502/504`、连接拒绝、upstream timeout/reset，或后端 listener/unit 不在。先查后端和 fd/内存，不改 DNS。
- **TLS 边缘失败**：443 无监听、证书/SNI 不匹配、握手错误集中出现。先验证实际 Nginx 实例和证书，不要重启其他服务。
- **客户端 churn/重试风暴**：大量短于数秒的成功或未完成 WS 会话，集中于同一 UA/IP；这是压力信号，不自动等同于服务端根因。
- **DNS/路由策略**：WS 已成功 `101`，但仅 DoH/DoT、特定域名或出站目标失败。保留安全 DNS/广告/BT 策略，除非有独立证据且用户明确要求，不用它解释入口 `503`。
- **资源压力**：worker/nofile、RSS、MemAvailable、swap、TCP 重传与故障窗口同时恶化。资源证据只能说明压力关联，不能单独证明运营商干扰。
- **配置漂移**：后端 path、Nginx location、订阅节点和生成器模板不一致；先修同源关系，再谈调参。
- **证据不足**：日志无时间戳、权限不足、多个入口未能归属时，停止变更并说明缺口。

### 3. 按测量定容量

从同一观察窗取 `C_peak_ip`（单源 IP established 峰值）、`C_peak_total`、`R_503`、成功连接时长分位数、worker 数 `W`、可用内存和预期设备数。用测量值计算，而不是复制某台机器的常数：

```text
per-IP limit  ~= ceil(alpha * C_peak_ip), alpha 取 1.5--3
worker_connections >= beta * (2 * C_peak_total / W), beta 取 1.5--2
global limit <= worker/fd/内存预算扣除同机其他业务后的安全值
```

`limit_conn` 管长连接，WS location 的 `limit_req` 管新握手速率；不要用极短 timeout 解决容量问题，否则会制造更多重连。小规格主机先提高到“503 明显下降且资源仍有余量”的档位，保留 per-IP、global 和握手速率护栏，并设明确回滚值。

### 4. 设计并执行变更

只有命中入口限流、上游故障或配置漂移的证据桶才进入变更。先写一份变更表：目标文件、旧值、拟定值、依据、回滚文件、验证命令、停止条件。

1. 备份实际生效文件；不要只改生成出的 snippet。
2. 同批更新配置生成器和 checker，使后续 render 不会回写旧策略，checker 仍验证 path/host/SNI/transport/监听的一致性。
3. 用结构化检查器或 `v2ray/xray test` 校验后端；用 `nginx -t` 校验边缘。
4. 原子替换，优先平滑 reload；reload 失败立即恢复备份。不要并行改多套 Nginx 或误杀同机其他 master。
5. 以旧订阅、TLS、WS `101`、`503` 零时长比例、后端监听、资源水位和健康任务指标做变更后窗口验收。
6. 若连续窗口仍 crit，按停止条件回滚，不靠重复重启掩盖问题。

### 5. 处理容灾和订阅

同机第二进程/第二 path 只能隔离进程或配置错误，不能称为真正第二故障域；IP、证书、主机或机房仍共因。真正容灾需要独立故障域，并在客户端明确支持自动选择。

当前是单节点分享链接时，不要把 `mux`、`keepalive`、`flow`、`reality` 或未部署的 transport 硬塞进 URI；它们不能替代入口容量，且可能破坏 v2rayN/v2rayNG。若增加备用节点，逐节点校验、保持主节点兼容、说明客户端不会自动 failover，并同步修改生成器/checker/验收。

## 交付格式

报告按以下顺序写：

1. **事实**：命中的 unit、listener、配置字段、时间窗计数和命令结果（脱敏）。
2. **推断/置信度**：入口限流、上游、TLS、DNS、客户端 churn、资源或漂移中的候选桶。
3. **未决假设和缺口**：需要客户端日志、第二故障域或更长观察窗的部分。
4. **变更**：实际修改文件、旧/新值、生成器/checker 同步情况、恢复点。
5. **验收**：`nginx -t`、后端 test、TLS/WS 端到端、旧订阅兼容、指标窗口和残余风险。

## 脚本

对已确定的 access/error 日志做脱敏统计：

```bash
python3 scripts/analyze_ws_logs.py \
  --access-log /path/to/ws-access.log \
  --error-log /path/to/nginx-error.log \
  --ss-file /path/to/ss-snapshot.txt \
  --format json
```

脚本只读输入文件；`--self-test` 使用内置合成日志，不触碰网络或系统服务。没有合适的日志格式时，报告 `gaps`，不要强行推断。

## 按需参考

- 调整并发、worker、nofile、超时、回滚和验收窗口：读取 [capacity-and-change.md](references/capacity-and-change.md)。
- 证据桶、脱敏、危险操作和停止条件：读取 [evidence-and-safety.md](references/evidence-and-safety.md)。
