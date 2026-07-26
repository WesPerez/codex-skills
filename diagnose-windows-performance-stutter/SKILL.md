---
name: diagnose-windows-performance-stutter
description: 以证据驱动方式诊断 Windows 上任意应用、游戏、虚拟机或桌面工作负载的卡顿、掉帧、输入延迟、音频爆音、周期性停顿与多进程争用；覆盖症状复现、只读基线、进程族 CPU 增量、调度与 ETW、内存和存储、DPC/ISR、GPU/DWM/PresentMon、虚拟化宿主与客户机双侧、Process Lasso/CPU Sets/电源策略审计、单变量 A/B、回滚和验收。用户要求排查“电脑很卡”“某进程卡”“平均 FPS 正常但顿”“多个应用互相影响”、验证优化是否有效，或审查优先级、亲和性及电源设置时使用。
---

# Windows 通用卡顿诊断

把卡顿视为一次未按时完成的工作，而不是某个 CPU 百分比。先定位错过的截止时间发生在哪一层，再决定是否改配置。

始终沿用：`症状 -> 采样 -> 证据 -> 假设 -> 单变量 A/B -> 回滚 -> 验收`。

## 强制原则

1. 默认只读。诊断请求不授权修改目标/竞争进程的优先级、Affinity、CPU Sets，也不授权修改电源、服务、注册表、驱动、虚拟机配置或应用源码。采集器只可临时降低自身优先级并在退出时恢复。
2. 区分事实、推断与未知。单点快照、平均值、论坛经验和“体感变好”都不能单独证明因果。
3. 锁定 PID 和进程族。不要仅按进程名混合重启前后实例，也不要把多进程应用只看成一个 PID。
4. 先建立可重复场景和成功指标。无法复现时先改善观测，不升优先级、不绑核。
5. 逐层增加采集成本。先做轻量基线，再按证据选择 PresentMon 或短时 ETW；记录采集器自身开销和丢失事件。
6. 每次只改变一个变量。先做临时试验，再决定是否持久化；保存原值、哈希、作用范围和精确回滚步骤。
7. 同时保护其他高优先级工作负载。候选方案只有在目标指标改善且守护指标不退化时才可保留。
8. 只清理本次明确创建的采集目录和本次启动的采集进程。归属不清的缓存、日志、进程和服务一律保留。

## 按需读取资料

- 每次都读 [evidence-model-and-cases.md](references/evidence-model-and-cases.md)，用统一证据模型、A/B 规则和成熟案例模式组织调查。
- 涉及 CPU、优先级、Affinity、CPU Sets、电源、Ready/Wait、上下文切换或 ETW 时，读 [windows-scheduler-etw.md](references/windows-scheduler-etw.md)。
- 涉及掉帧、画面顿挫、输入呈现、DWM、刷新率或 GPU 时，读 [graphics-frame-pacing.md](references/graphics-frame-pacing.md)。
- 涉及内存、硬错误、磁盘、网络、音频爆音、DPC/ISR、锁等待或挂起时，读 [io-memory-dpc.md](references/io-memory-dpc.md)。
- 涉及虚拟机、模拟器、容器或宿主与客户机并发时，读 [virtualization-contention.md](references/virtualization-contention.md)。
- 涉及 Process Lasso 或其他调度工具时，读 [process-lasso-and-tuning.md](references/process-lasso-and-tuning.md)。

## 固定工作流

### 1. 定义问题和验收标准

记录以下内容，不用“很卡”代替：

- 目标 PID、根进程、子进程和必须同时运行的关键工作负载。
- 症状类型：帧时间尖峰、输入延迟、音频中断、UI 无响应、吞吐下降、周期性冻结或整机争用。
- 可重复动作、开始和结束时间、前后台状态、供电状态、显示器/远程显示、虚拟化和采集工具。
- 主指标：例如操作延迟、任务吞吐、帧时间 p95/p99、超过帧预算的比例或音频 glitch 数。
- 守护指标：并发应用的延迟/吞吐、错误率、识别质量、虚拟机客户机任务时间等。
- 可接受差异和回滚条件。不要在看到结果后才选择最有利指标。

### 2. 保存只读基线

先记录配置与运行时两种状态：

- OS build、CPU 拓扑/逻辑处理器、内存、GPU 与驱动、显示刷新率/VRR、虚拟化方式。
- 当前 power scheme、overlay/profile、处理器最小/最大状态和可见核心停放策略；不要从方案名称推断实际参数。
- 目标及主要竞争者的优先级类、线程动态优先级、Affinity、Default/Selected CPU Sets、EcoQoS/MMCSS（可读时）。
- 调度工具的持久规则、日志命中和运行时读回。配置文件存在不等于规则已生效。
- 进程族累计 CPU 时间的增量、内存、I/O、线程/句柄，以及同一时间窗内的系统队列、上下文切换、DPC/ISR、分页和磁盘延迟。

从本 Skill 目录运行轻量采集器；它只读系统状态并写入一个新的采集目录：

```powershell
pwsh -NoProfile -File .\scripts\collect_windows_stutter.ps1 `
  -ProcessId 1234 -DurationSeconds 30 -OutputDirectory C:\path\to\owned-run
```

默认每秒采目标进程族，PDH 系统计数器和全进程热点每 10 秒采一次。采集器只把自己的 host 临时降为 `BelowNormal`，并在 `finally` 恢复；目标和竞争者不改。它只直接读取进程级优先级、Affinity 和 Default CPU Sets；线程 Selected CPU Sets、动态优先级、EcoQoS/MMCSS 仍需 API 或 ETW 补证，不能把一次采集器运行当成全部调度基线。`process-family.csv` 的 `family_process_count` 是发现的进程数，`family_cpu_queryable_process_count` 是成功读取累计 CPU 的数量；两者不等时不得把 CPU 汇总当成完整进程族。先检查 `manifest.json`、`summary.json`、warnings 与 `collector_overhead.sampling_avg_cpu_cores`，再分析 CSV。若观察开销仍会污染严格延迟场景，先用 `-SkipTopProcesses -SkipSystemCounters` 仅采目标族，再分开做短时 ETW；不要为了“数据齐全”制造卡顿。

优先使用已安装的 `pwsh`。只有机器没有 PowerShell 7，且已核对脚本来自本 Skill 的可信路径/哈希时，才用 Windows PowerShell 的单进程兼容方式；不得持久修改执行策略：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\collect_windows_stutter.ps1 `
  -ProcessId 1234 -DurationSeconds 30 -OutputDirectory C:\path\to\owned-run
```

若权限不足，保留缺口，不用空值证明“没有问题”。

### 3. 分类后再选工具

| 观察 | 首选下一步 | 不能直接得出的结论 |
|---|---|---|
| 单进程族持续消耗多个 core | CPU sampled stacks、算法/轮询频率 | CPU 高一定是 bug |
| 总 CPU 不满但目标线程 Ready 长 | CPU Usage (Precise)、Affinity/CPU Sets、竞争线程 | 机器有空闲所以不存在 CPU 争用 |
| 目标线程 Waiting 长 | 锁、I/O、消息、Sleep、依赖端 trace | 抬优先级能解决等待 |
| 周期性 CPU/I/O/DPC 峰与卡顿对齐 | 对齐任务、驱动、定时器和 ETW 时间线 | 峰值最高的进程必然是根因 |
| 平均 FPS 正常但体感顿 | PresentMon 主 swapchain 的 p95/p99、长帧率、PresentMode、Dropped | 平均 FPS 代表流畅度 |
| 内存提交逼近限制且分页与停顿对齐 | Memory/VirtualAlloc/硬错误与磁盘时间线 | 空闲内存少就一定缺内存 |
| 多个应用和虚拟机同时退化 | 宿主和客户机双侧 CPU/内存/存储/呈现指标 | 只改宿主优先级即可 |
| 音频爆音或整机瞬断 | DPC/ISR、驱动栈、同核时间对齐 | 某个驱动总 DPC 排名高就有罪 |

先用脚本排候选，再只对最有可能的分支采集。不要同时开启多个高开销 profiler。

### 4. 对齐事件并形成可证伪假设

为每个候选写四项：

```text
假设：哪一层导致哪个截止时间失败
支持证据：必须带 PID、时间窗、指标和来源
反证条件：什么结果会否定假设
最小试验：只改变哪个变量，如何回滚
```

按时间对齐，而不是比较整段平均值。卡顿点附近的 Ready、Wait、DPC/ISR、I/O、长帧和后台突发应落在同一时间轴；无法对齐时降低结论置信度。

### 5. 逐级升级采集

1. 轻量采样无法解释计算/等待/抢占时，申请一次短时 WPR CPU trace；先确认管理员权限、磁盘预算、输出路径和停止命令。
2. 图形问题用 PresentMon 锁定 PID。若有多个 swapchain，列出各链帧数并验证主链，不盲信“帧数最多”启发式。
3. 用分析脚本计算尾延迟；默认输出 JSON，不修改 CSV：

```powershell
pwsh -NoProfile -File .\scripts\analyze_presentmon.ps1 `
  -CsvPath C:\path\to\capture.csv -ProcessId 1234 -TargetFps 60
```

4. WPR/WPA 中先圈定故障时间窗，再依次看 CPU Usage (Precise)、CPU Usage (Sampled)、DPC/ISR，最后才扩展 Disk/Network/Power provider。
5. 检查 WPR/PresentMon 丢失事件、采集器 CPU、CSV 有效帧数和场景阶段。采集本身改变负载时，缩短时长或拆分采集。

### 6. 设计单变量 A/B

- 固定版本、场景、分辨率、刷新率、前后台状态、供电、温度区间和并发工作负载。
- 预热后交替或随机化 `AB/BA` 顺序，避免把配置与时间漂移混在一起。
- 每轮输出独立文件并记录配置哈希、运行时读回、场景阶段、PID、开始/结束时间和异常。
- 以“轮”为统计单位；一轮内数千帧不是数千次独立配置试验。
- 至少看逐轮方向、一致性、配对差值和噪声范围。样本太少或胜负混合时，结论是“证据不足”，不是挑最好的一轮。
- 候选必须同时满足主指标改善、守护指标不退化、错误率不升和运行时确实生效；否则回滚。

### 7. 受控应用修改

只有证据指向明确机制且用户授权修复时才修改：

1. 保存原始值、ACL/配置哈希、版本和运行时状态。
2. 优先减少已证明无价值的工作量、频率或重复计算，但不得牺牲功能正确性和质量。
3. 调度放置先试可消失的软策略，再考虑持久规则；CPU Sets 是软偏好，Affinity 是硬限制，两者冲突时硬限制优先。
4. 保持 `Normal` 为默认基线。不要用 `High`/`Realtime`、全局绑核或禁用动态 boost 作为通用优化。
5. 电源计划、overlay、PPM profile 和处理器参数分别验证；不要因为计划名称听起来更快就切换。
6. 暂停/缩减虚拟机、重启应用、停服务、清缓存、改驱动或安全功能都会影响其他工作，必须先取得相应授权和回滚窗口。
7. 写入后同时验证文件/注册表哈希、工具日志、运行时 API 读回和重启后持久性。写入成功不等于有效，也不等于有收益。

### 8. 复测并收口

用相同场景和相同采集方法复测。报告必须包含：

- 已观察事实和证据路径。
- 候选瓶颈排序、反证和仍缺的证据。
- 所有实际修改、原值、作用域、是否持久、回滚位置和运行时读回。
- 按轮的 before/after 主指标与守护指标，不只给平均值。
- 未生效、无收益或副作用方案已经回滚的证据。
- 剩余风险、适用边界和下一次最小试验。

## 禁止把经验包当结论

没有对应证据时，不执行以下动作：

- 把目标或竞争者设为 `High`/`Realtime`，或普遍降低系统进程优先级。
- 给前台程序硬绑“最快核”，把后台统一塞到少数核，或全局禁用 SMT/核心。
- 写 timer/HPET、`Win32PrioritySeparation`、MPO/HAGS 等注册表组合包。
- 清 standby list、删除缓存、停止服务、结束进程、卸载驱动或关闭安全功能。
- 仅凭论坛帖子、平均 FPS、单次最好结果、配置文件文本或一次体感永久应用修改。

论坛和案例只用于生成假设。用官方语义确认机制，用本机时间对齐和 A/B 决定是否保留。
