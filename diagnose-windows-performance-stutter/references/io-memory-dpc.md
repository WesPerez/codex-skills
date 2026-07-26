# 内存、存储、网络、音频、DPC/ISR 与等待链

## 目录

- [证据三元组](#证据三元组)
- [内存与分页](#内存与分页)
- [存储](#存储)
- [网络](#网络)
- [音频与 DPCISR](#音频与-dpcisr)
- [无响应与 dump](#无响应与-dump)
- [阈值政策](#阈值政策)
- [官方来源](#官方来源)

## 证据三元组

对每个资源候选同时记录：

1. 数值：哪个 PID/设备/计数器异常。
2. 持续时间：瞬时、周期性还是整段持续。
3. 相关证据：是否与用户事件、目标延迟、I/O、Ready/Wait 或其他资源在同一时间窗出现。

只满足一项时，把它保留为线索，不写成根因。

## 内存与分页

| 观察 | 联合检查 | 正确解释 |
|---|---|---|
| `Available MBytes` 下降 | Commit/Limit、工作集、standby/modified、hard faults | Available 包含可回收缓存；低值本身不等于泄漏 |
| Commit 接近 Limit | 系统和进程 private bytes、pagefile 使用、分配失败 | Commit 受 RAM + pagefile 限制；pagefile 大小没有通用答案 |
| Hard faults 上升 | Available、磁盘读取延迟、目标停顿、文件映射/冷启动 | Hard fault 表示需要磁盘取页，不等于硬件损坏或泄漏 |
| Standby 很大 | Available、modified、缓存命中和压力下回收 | Standby 是可快速重用的缓存，不应默认清空 |
| 长时间 private/pool bytes 单调增长 | 稳态基线、对象/句柄、应用场景 | 用长周期 PerfMon 证实泄漏，再转到应用/驱动工具 |

只有 `Available` 紧张、modified list 较大且现有 pagefile 使用也高等联合证据出现时，才把 pagefile 配置列为候选。不要运行“内存清理”或清 standby list 作为诊断步骤；这会改变缓存状态并污染 A/B。

建议指标：

- `Memory\Available MBytes`
- `Memory\Committed Bytes` / `Commit Limit` 或 `% Committed Bytes In Use`
- `Memory\Page Reads/sec`、Hard Faults 时间线
- Process `Private Bytes`、Working Set、Pool Paged/Nonpaged Bytes
- Paging Files `(*)\% Usage`

## 存储

优先看服务延迟和故障时间对齐，不先看 Active Time：

- `PhysicalDisk\Avg. Disk sec/Read`
- `PhysicalDisk\Avg. Disk sec/Write`
- `PhysicalDisk\Avg. Disk sec/Transfer`
- `Current/Avg. Disk Queue Length`
- WPA Storage I/O 的进程、文件、I/O 类型、flush 和栈

`% Disk Time`/“磁盘 100%”在并发、SSD 和驱动实现下容易误导。队列高也可能是正常批量吞吐；只有延迟、队列、目标停顿和发起者同时对齐，才支持存储瓶颈。

调查顺序：

1. 确定受影响卷和物理设备映射。
2. 对齐目标进程 I/O 速率、系统磁盘延迟与卡顿时刻。
3. 用 WPA 查具体进程、文件、同步 I/O、flush、过滤驱动或分页 I/O。
4. 区分设备服务时间、文件系统/过滤器等待和应用同步设计。
5. 再做驱动、过滤器、缓存、I/O 批量或设备配置的单变量 A/B。

## 网络

网络型“卡”优先区分吞吐、排队、丢包、重传和依赖端响应：

| 指标 | 用途 |
|---|---|
| Interface Bytes/Packets per second | 容量与流量形态 |
| Output Queue Length | 本机发送排队线索 |
| Packets Discarded/Errors | 链路、驱动或过滤问题 |
| TCP Segments Retransmitted/sec | 重传与拥塞线索 |
| Connection Failures/Reset | 连接层失败 |
| Interrupts/sec、DPCs Queued/sec | 网卡驱动中断路径候选 |

Microsoft 文档把 Output Queue Length 大于 2 作为延迟提示，但仍需结合接口速度、持续时间、重传和目标请求延迟。不要因一次峰值就改 offload、MTU、RSS 或驱动参数。

## 音频与 DPC/ISR

音频 glitch 可能来自应用缓冲、音频引擎/APO、驱动缓冲、硬件、CPU 抢占或 DPC/ISR。按层取证：

1. 记录每次爆音/中断的精确时刻和输出设备。
2. 同窗看目标音频线程 Ready/Wait、CPU、DPC/ISR 和设备驱动栈。
3. 检查多次事件是否稳定落到同一驱动和同一机制。
4. 再试驱动版本、设备电源管理、缓冲或 offload 的单变量 A/B。

ISR 应快速返回并把延后工作交给 DPC；DPC/ISR 的存在完全正常。只有持续时间/频率与用户故障对齐才构成问题证据。

Windows 驱动文档中的 DPC 100 microseconds、ISR 25 microseconds 是驱动质量目标，DPC watchdog 的实际触发条件另有语义；不要把它们当成所有用户态卡顿的报警阈值。

LatencyMon 等第三方工具可快速给出驱动候选，但其综合评分不是 Microsoft 根因证据。用 WPR/WPA 的 DPC/ISR timeline、CPU 和栈复核后再行动。

## 无响应与 dump

### 等待链

窗口 `Not Responding` 时先区分高 CPU、用户态等待链和内核/驱动问题。Windows Wait Chain Traversal 可观察 ALPC、COM、critical section、mutex、SendMessage 及进程/线程 wait 等用户态链。

WCT/资源监视器的等待链不是完整内核死锁分析。若链终止在未覆盖的内核对象、驱动或外部依赖，转到 ETW、应用日志或调试器。

### ProcDump 边界

ProcDump 适合已锁定 PID 的间歇 hang、CPU spike 或异常现场，不适合替代系统级 DPC、磁盘和无目标进程的调查。

执行前必须确认：

- 用户授权对目标进程抓 dump。
- dump 类型、次数、触发器、输出目录和磁盘预算。
- dump 可能包含凭据、文本、图像或业务数据，按敏感数据处理。
- 捕获可能短时挂起目标并触发安全软件。

优先最小足够的 mini/triage dump；只有调用栈/堆证据明确需要且接受隐私与体积成本时使用 full dump。只清理本任务明确创建的 dump。

## 阈值政策

| 文档值 | 允许的表达 | 禁止的表达 |
|---|---|---|
| CPU 持续约 80% 的 high-CPU 指引 | 值得进一步调查的场景提示 | 低于 80% 就不存在 CPU 问题 |
| I/O 10–15 ms | SQL/传统 I/O 语境的近似经验值 | 所有 HDD/SSD/NVMe/SMB 的统一好坏线 |
| DPC 100 us / ISR 25 us | 驱动质量目标 | 任一超过就证明用户卡顿根因 |
| NIC output queue >2 | 网络发送排队提示 | 单次超过就改网卡配置 |

始终优先同机正常基线、业务截止时间、持续性和相关时间线。

## 官方来源

### 内存

- [Memory Performance Information](https://learn.microsoft.com/en-us/windows/win32/memory/memory-performance-information)
- [Page State](https://learn.microsoft.com/en-us/windows/win32/memory/page-state)
- [How to determine the appropriate page file size for 64-bit versions of Windows](https://learn.microsoft.com/en-us/troubleshoot/windows-client/performance/how-to-determine-the-appropriate-page-file-size-for-64-bit-versions-of-windows)
- [Performance Tuning for Cache and Memory Manager Subsystems](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/subsystem/cache-memory-management/)
- [Determining Whether a Leak Exists](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/determining-whether-a-leak-exists)
- [Using Performance Monitor to Find a User-Mode Memory Leak](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/using-performance-monitor-to-find-a-user-mode-memory-leak)

### 存储与网络

- [Troubleshoot slow SQL Server performance caused by I/O issues](https://learn.microsoft.com/en-us/troubleshoot/sql/database-engine/performance/troubleshoot-sql-io-performance)
- [Common In-Depth Analysis Issues](https://learn.microsoft.com/en-us/windows-hardware/test/assessments/common-in-depth-analysis-issues)
- [Performance Tuning for SMB File Servers](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/file-server/smb-file-server)
- [Network-Related Performance Counters](https://learn.microsoft.com/en-us/windows-server/networking/technologies/network-subsystem/net-sub-performance-counters)

### 音频、DPC/ISR 与等待

- [Low Latency Audio](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/low-latency-audio)
- [Glitch Reporting for Offloaded Audio](https://learn.microsoft.com/en-us/windows-hardware/drivers/audio/glitch-reporting-for-offloaded-audio)
- [Introduction to DPC Objects](https://learn.microsoft.com/en-us/windows-hardware/drivers/kernel/introduction-to-dpc-objects)
- [Bug Check 0x133: DPC_WATCHDOG_VIOLATION](https://learn.microsoft.com/en-us/windows-hardware/drivers/debugger/bug-check-0x133-dpc-watchdog-violation)
- [Recording for Basic System Diagnosis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/recording-for-basic-system-diagnosis)
- [Wait Chain Traversal](https://learn.microsoft.com/en-us/windows/win32/debug/wait-chain-traversal)
- [Using WCT](https://learn.microsoft.com/en-us/windows/win32/debug/using-wct)
- [Guidance for troubleshooting high CPU usage](https://learn.microsoft.com/en-us/troubleshoot/windows-server/performance/troubleshoot-high-cpu-usage-guidance)
- [ProcDump](https://learn.microsoft.com/en-us/sysinternals/downloads/procdump)
