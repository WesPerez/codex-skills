# 容量定档与生产变更

这份参考只在已经确认入口角色后读取。它提供计算方法，不提供某台主机的固定答案。

## 取样

在同一个 UTC/本地时区窗口保存：

- `101/499/502/503/504` 及其他状态计数。
- `503` 中零时长占比，以及有 `request_time` 时的 p50/p95。
- 单源 IP（默认哈希或 /24 聚合）和全局 established 峰值。
- Nginx worker 数、`worker_connections`、`worker_rlimit_nofile`/服务 nofile。
- `MemAvailable`、RSS、swap、TCP 重传和后端 listener/unit 状态。

不要把一分钟的单点读数当成容量基线；至少包含一次正常窗口和一次故障/恢复窗口。若日志只保留 tail，注明截断和采样偏差。

## 计算

令：

- `P` = 单源 IP 的实测峰值并发；
- `G` = 全局实测峰值并发；
- `W` = 实际 worker 数；
- `a` = NAT、全局模式和测量误差余量，通常 1.5--3；
- `b` = 反代 client+upstream 双计和其他连接余量，通常 1.5--2；
- `S` = 为同机其他站点、管理面和故障恢复保留的资源。

建议起点：

```text
per_ip_limit = ceil(a * P)
worker_connections >= ceil(b * (2 * G + S) / W)
global_limit <= min(fd_budget, memory_budget, worker_budget) - S
```

`fd_budget` 至少受 Nginx nofile、systemd LimitNOFILE 和内核限制共同约束；`memory_budget` 要按实测每连接 RSS/缓冲和最坏重连风暴估算。若没有可信的 `P/G`，先延长观测，不要猜一个大常数。

调参顺序：

1. 确认 503 是否来自 limit zone，而非 upstream timeout。
2. 先修 worker/nofile 的硬天花板，再调整 per-IP/global 上限。
3. 为新握手保留单独的 `limit_req`；不要对已升级 WS 施加业务带宽限速。
4. 观察 CPU、内存、fd、established、503 比例和重试频率。
5. 只有资源稳定且仍有证据时再扩大一档；任何“无限制”方案都停止。

## 变更表模板

```text
窗口:
证据:
目标文件:
旧值 -> 新值:
计算输入(P/G/W/nofile/memory):
生成器/checker 是否同步:
备份/恢复点:
预检命令:
生效动作:
成功条件:
停止/回滚条件:
```

文件操作应为临时文件校验后原子替换。Nginx 先 `nginx -t` 再平滑 reload；后端配置先用对应二进制 test，再按 unit 设计重载或单次 restart。reload/restart 后必须重新检查实际 listener，而不是只看 systemd 的 `active`。

## 验收窗口

至少验证：

1. TLS SNI 握手成功，旧订阅仍能建立 WS `101`。
2. `503`、零时长 503、`limiting connections` 与 upstream failure 的变化符合预期。
3. 后端 listener、服务日志、worker/fd、内存和 TCP 重传无新的 crit。
4. 生成器再次运行后，实际 snippet 和订阅没有回到旧值。
5. 若任一成功条件不满足，按恢复点回滚并保留失败证据。

## 容灾判断

同机双进程、双 path 或本地 upstream 只能降低单进程/单配置故障，不能抵御主机、IP、证书、上游网络或机房故障。把它标为“进程冗余”，不要写成 HA。真正的第二故障域需要独立主机/网络/证书边界，并配合客户端可验证的 fallback/url-test 机制。
