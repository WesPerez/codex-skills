# Windows 调度、CPU Sets、电源与 ETW

## 目录

- [先回答哪类问题](#先回答哪类问题)
- [调度语义](#调度语义)
- [CPU Sets 与 Affinity](#cpu-sets-与-affinity)
- [电源状态审计](#电源状态审计)
- [WPR/WPA 取证](#wprwpa-取证)
- [修改门槛](#修改门槛)
- [官方来源](#官方来源)

## 先回答哪类问题

按以下顺序区分机制：

1. `Running` 高：线程确实在计算，转到 Sampled stacks 或应用级 profiler。
2. `Ready` 高：线程能运行但没拿到 CPU，调查抢占、优先级、硬亲和和 CPU Sets。
3. `Waiting` 高：线程主动等待锁、I/O、消息、定时器或依赖端，抬优先级通常无效。
4. DPC/ISR 与故障时间对齐：调查驱动或设备中断；总量排名只用于找候选。
5. 从非零 C-state 唤醒与故障时间对齐：把电源/唤醒代价列为候选，再做电源 A/B。

不要用总 CPU 低排除局部调度延迟。一个关键线程在一个逻辑处理器上错过 16 ms 截止时间时，整机仍可显示大量空闲。

## 调度语义

- Windows 调度线程，不调度“整个进程”。进程优先级类只是线程基优先级的一个输入。
- Ready 表示可运行但尚未运行；Waiting 表示线程因同步或外部事件不可运行。
- 更高动态优先级线程可抢占更低优先级线程；同优先级线程按时间片轮转。
- 前台、输入完成、等待完成、MMCSS 和 AutoBoost 都可能临时提高线程动态优先级。一次进程优先级快照不能还原真实调度顺序。
- Context switch 可由时间片结束、更高优先级线程就绪或当前线程主动等待触发。切换率高不是独立根因，必须同时看 Ready/Wait、栈和时间线。
- 优先级反转发生在高优先级线程等待低优先级线程持有的锁时；继续提高等待者优先级可能恶化问题。
- `High` 可能饿死其他应用和系统工作；`Realtime` 甚至可能干扰输入与磁盘刷新。不得作为通用低延迟方案。

## CPU Sets 与 Affinity

| 机制 | 约束 | 诊断要求 |
|---|---|---|
| Process/Thread Affinity | 硬限制 | 读取实际 mask；官方建议一般避免自行限制 |
| Ideal Processor | 调度提示 | 不能据此断言线程只在该核运行 |
| Process Default CPU Sets | 进程级软偏好 | 读取 CPU Set IDs；无显式线程选择时继承 |
| Thread Selected CPU Sets | 线程级软偏好 | 可能覆盖进程默认集合，需在线程级确认 |
| Parked/Allocated CPU Sets | 系统状态 | 用 `GetSystemCpuSetInformation` 查看目标集合是否可用 |

关键规则：

- Affinity 是硬边界，CPU Sets 是软放置偏好；两者冲突时硬边界优先。
- “配置里存在 CPU Sets”不等于运行时生效。至少核对进程默认集、关键线程选择集和系统 CPU Set 状态。
- 软集合目标核被停放、保留或分配给其他目标时，调度器可能不按预期放置。
- 处理器超过 64 个逻辑处理器时还要考虑 processor groups；Windows 11/Server 2022 的默认跨组行为与旧版本不同。
- 只在证据显示特定竞争者与关键线程互相抢占，且拓扑已确认时试 CPU Sets。不要按“前半核/后半核”猜测 CCD、P/E core 或 SMT 配对。

## 电源状态审计

以下命令只读：

```powershell
powercfg /getactivescheme
powercfg /list
powercfg /aliases
powercfg /query SCHEME_CURRENT SUB_PROCESSOR
powercfg /listprofiles
```

审计时分别记录：

- 当前基础 scheme 的 GUID 和名称。
- 当前 overlay/profile；不同 Windows 版本和 OEM 暴露方式不同，不要假设某个 alias 一定存在。
- AC/DC 当前供电条件。
- `PROCTHROTTLEMIN`、`PROCTHROTTLEMAX` 及可见的 PPM/core-parking 参数。
- CPU Set `Parked` 运行时状态、频率/温度和 thermal throttling 证据。

计划名称不是证据。“平衡”“高性能”或 OEM 名称只是一组参数的标签；overlay、PPM profile、QoS、Game Mode 和厂商固件仍可能改变有效行为。只在相同场景做单变量 A/B，并保留用户明确要求的性能偏好。

## WPR/WPA 取证

### 采集前门槛

WPR 会启动 ETW logger、占用内存或磁盘并写 ETL，不属于纯只读查询。执行前：

1. 确认管理员权限、输出目录归属、可用磁盘、预期时长和用户允许的干扰。
2. 先运行 `wpr -profiles`、`wpr -profiledetails CPU` 和 `wpr -status` 确认能力及是否已有他人的 logger。
3. 默认短时 memory mode。只有明确需要长窗口时才用 file mode；后者文件可持续增长。
4. 预先写下停止和异常清理命令。只停止本任务启动的会话。

典型受控流程：

```powershell
wpr -start CPU
# 复现一次并记录故障时刻
wpr -stop C:\owned\stutter.etl "reproduction description"
```

如果无法确认当前 WPR 会话归属，不要 `-cancel` 或 `-stop`，先询问。

### WPA 固定分析顺序

1. 圈定用户记录的故障时间窗，不先看整段总计。
2. `CPU Usage (Precise)`：看关键线程的 `Ready(s)`、`Waits(s)`、`NewInPri`、`OldOutPri`、`ReadyingProcess/ThreadId`、`PrevCState` 和 CPU timeline。
3. `CPU Usage (Sampled)`：沿栈定位 Running 时间花在模块/函数的哪里。
4. `DPC/ISR`：检查同一 CPU、同一故障窗口内的驱动栈与持续时间。
5. 回看 priority、Affinity、CPU Sets 和 PPM 状态能否解释上述时间线。
6. 检查 Events Lost/Dropped；有丢失时降低置信度或用更窄 profile 重录。

`Ready(s) = SwitchIn - ReadyTime`，`Waits(s) = ReadyTime - LastSwitchOut`。阈值由业务截止时间定义；文档或 assessment 给出的毫秒值只能作为启发式，不是全球通用 SLA。

## 修改门槛

| 候选修改 | 最低支持证据 | 必须验证 |
|---|---|---|
| 改优先级 | 明确的 Ready/抢占关系，不是 Waiting | 目标和守护负载、系统响应、运行时优先级 |
| 试 CPU Sets | 竞争线程时间对齐、拓扑与当前规则已读回 | Default/Selected sets、Affinity、Parked/Allocated、重启后状态 |
| 改 Affinity | 软策略已有重复收益但仍不足 | 每个关键线程的 Ready、吞吐、热/频率与守护指标 |
| 改电源参数 | 唤醒/频率/停放证据与问题对齐 | AC/DC、overlay/profile、温度、功耗与守护指标 |

未满足门槛时保持原状态。

## 官方来源

- [Scheduling](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling)
- [Scheduling Priorities](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities)
- [Priority Boosts](https://learn.microsoft.com/en-us/windows/win32/procthread/priority-boosts)
- [Context Switches](https://learn.microsoft.com/en-us/windows/win32/procthread/context-switches)
- [Priority Inversion](https://learn.microsoft.com/en-us/windows/win32/procthread/priority-inversion)
- [Multiple Processors](https://learn.microsoft.com/en-us/windows/win32/procthread/multiple-processors)
- [Multimedia Class Scheduler Service](https://learn.microsoft.com/en-us/windows/win32/procthread/multimedia-class-scheduler-service)
- [CPU Sets](https://learn.microsoft.com/en-us/windows/win32/procthread/cpu-sets)
- [SetProcessAffinityMask](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-setprocessaffinitymask)
- [SetProcessDefaultCpuSets](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessdefaultcpusets)
- [SetThreadSelectedCpuSets](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadselectedcpusets)
- [GetSystemCpuSetInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemcpusetinformation)
- [SYSTEM_CPU_SET_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information)
- [Windows Performance Toolkit](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/)
- [WPR Command-Line Options](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/wpr-command-line-options)
- [CPU Analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis)
- [Powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options)
- [Processor power management options](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/configure-processor-power-management-options)
