# 虚拟化与宿主/客户机争用

## 目录

- [平台先分流](#平台先分流)
- [双侧证据](#双侧证据)
- [固定决策树](#固定决策树)
- [vCPU 与调度](#vcpu-与调度)
- [内存、存储与显示](#内存存储与显示)
- [嵌套虚拟化](#嵌套虚拟化)
- [安全因果试验](#安全因果试验)
- [官方来源](#官方来源)

## 平台先分流

不要混用平台计数器和阈值：

| 平台 | 宿主真相 | 限制 |
|---|---|---|
| VMware ESXi/vSphere | `esxtop` 的 `%RDY/%CSTP/%RUN/%WAIT`、memory、DAVG/KAVG/GAVG | 官方争用指标完整 |
| VMware Workstation | Windows 宿主计数器 + 客户机计数器 + VM 配置 | Type-2，无 `esxtop` 或同名 `%READY` 面板 |
| Hyper-V | Hyper-V Hypervisor Logical/Virtual/Root Virtual Processor 及内存/磁盘计数器 | 普通 Task Manager CPU 不代表物理 CPU 真相 |

ESXi 指标可帮助理解 Workstation 的机制，但不能声称 Workstation 实测了不存在的 `%RDY`。

## 双侧证据

至少在同一时间窗记录：

### 宿主

- 物理/逻辑 CPU 利用率、队列、Ready 类指标（平台支持时）。
- 所有运行中 VM 的 vCPU、内存与活动状态。
- Available/commit、balloon/swap 或动态内存状态。
- 物理存储延迟、队列、VM 文件所在卷和其他 I/O 发起者。
- GPU/3D、远程显示、虚拟显示和 compositor 路径（工作负载需要时）。
- Hyper-V/VBS/Host VBS mode、nested virtualization 和安全隔离状态。

### 客户机

- vCPU 利用率与队列、关键进程 CPU/Ready/Wait。
- Available/commit、page inputs/hard faults。
- 虚拟磁盘延迟和队列。
- 真实任务吞吐、延迟与错误率。

客户机 CPU 100% 可能是真忙，也可能受宿主调度；客户机 CPU 不高也可能在等存储或被宿主排队。必须双侧解释。

## 固定决策树

1. **宿主是否持续饱和？**
   - ESXi 看 load 与 `%RDY`；Hyper-V 看 Hypervisor Logical Processor；Workstation 看 Windows 宿主 CPU/queue 和并发 VM。
   - 宿主已饱和时，不要继续给 VM 加 vCPU。
2. **客户机真忙还是被调度？**
   - Run/VP 持续满且宿主有余量：客户机工作负载可能需要更多并行能力。
   - Ready/co-stop 高或宿主已满：更像过配与调度排队。
   - Wait 高：先查 I/O、设备和外部依赖。
3. **内存是否在回收或换页？**
   - balloon、swap、guest page inputs、host available/commit 与卡顿对齐时，先解决内存。
4. **存储是否高延迟？**
   - 同时核对设备、hypervisor、客户机感知三层延迟（平台支持时）。
5. **前四层正常后再查 3D/显示。**
6. **最后确认嵌套/VBS 路径。** 它可能带来额外开销，但不授权关闭安全功能。

## vCPU 与调度

### VMware ESXi

- `%READY` 表示 VM 已准备运行但得不到物理 CPU。Broadcom KB 把持续低于约 5% 作为正常参考，必须先排除 CPU limit/resource pool limit。
- `%CSTP` 表示多 vCPU 共调度等待；官方 KB 把持续超过约 3% 作为“可试减一个 vCPU”的信号。
- `%RUN` 高是实际计算；`%WAIT` 高更倾向 I/O/设备等待。
- load average 接近 1 表示物理 CPU 资源用满的参考语义；结合 Ready 和工作负载，不用单点定罪。

### Hyper-V

- 用 `Hyper-V Hypervisor Logical Processor(*)\% Total Run Time` 表示物理处理器负载；官方把 `_Total` 持续超过约 90% 作为宿主过载提示。
- 某 VM 的全部 Virtual Processor 高而宿主未过载时，才评估加 vCPU 和应用并行度。
- 宿主已过载、只有部分 VP 高或 root VP 的 DPC/interrupt 高时，先查过配、vRSS/vNUMA、网络或存储。
- Hyper-V 文档建议评估工作负载，避免过配和欠配；SMT 场景常建议偶数 vCPU，但仍需实测。

### Workstation

- 读取 VM 的 vCPU/cores 配置、宿主持续负载和客户机并行利用率。
- 不用 ESXi `%RDY<5%` 冒充 Workstation 官方阈值。
- 减 vCPU 是待机/关机配置变更，只有宿主争用与额外 vCPU 长期无用的证据同时存在时才申请试验。

减 vCPU 不适用于：客户机所有 VP 持续满且宿主有余量、存储 Wait 主导、内存换页主导、嵌套开销主导，或没有维护窗口。

## 内存、存储与显示

### 内存

- ESXi：看 memory overcommit、`MCTLSZ` balloon 与 `SWCUR` swap，并先排除错误 memory limit。
- Hyper-V：看 host Available、Dynamic Memory Balancer、guest Free+Standby 和 Pages Input/sec；Smart Paging 使用磁盘，显著慢于内存。
- Workstation：官方文档警告超过 maximum recommended memory 可能引发 swap，拖慢宿主与 Workstation。
- 增减 VM 内存通常影响业务且可能要求关机；先确认客户机工作集和宿主 commit，不用“分得越多越快”。

### 存储

- ESXi 用 `DAVG`（设备）、`KAVG`（VMkernel）和 `GAVG`（客户机感知），满足 `DAVG + KAVG = GAVG`。Broadcom 把持续超过约 10 ms 作为深入调查提示。
- Hyper-V 官方瓶颈指南把持续超过约 50 ms 作为存储延迟提示，并要求结合队列。
- 这些是平台文档的场景阈值，不可跨平台套用；现代 NVMe 仍应以同机基线和业务截止时间为主。

### 3D/显示

- 只有工作负载依赖 3D/视频且 CPU、内存、存储证据不足时，才测试 3D 路径。
- Workstation 3D 加速依赖兼容虚拟硬件、VMware Tools 和 graphics memory；开或关都可能更差，必须 A/B。
- Hyper-V GPU-P/DDA 是专用 GPU 分配路径，不是所有桌面 VM 的默认答案。
- 同时核对宿主 DWM、远程桌面/串流、显示刷新率和客户机帧时间，避免把显示链问题误判为 vCPU。

## 嵌套虚拟化

- 嵌套会增加 CPU、存储和网络路径层级；Microsoft 明确不建议性能敏感工作负载无评估使用。
- Workstation Host VBS Mode 可能比传统模式慢，且有 nested、PMC 等限制。
- 是否关闭 Hyper-V/VBS/内存完整性涉及安全和兼容性，不属于性能诊断默认授权。
- 先记录当前路径和官方支持矩阵，再用受控、可恢复环境验证；不要直接修改启动项或安全功能。

## 安全因果试验

优先级从低到高：

1. 同窗采集宿主/客户机计数器并对齐业务延迟。
2. 在不改 VM 状态的情况下固定并发负载，重复基线。
3. 经授权后只改变一个资源参数或减少一个非关键并发工作负载。
4. 暂停、挂起、关机、迁移、改 vCPU/内存、禁用 hypervisor/VBS 都是有副作用操作；先确认业务影响、恢复步骤和维护窗口。
5. 复测并立即恢复原值；只有重复收益且守护指标不退化时再讨论持久化。

“暂停另一台 VM 后变好”只能证明该并发状态具有因果贡献，不能自动证明应永久禁止它运行。最终方案必须满足所有必须并发的工作负载。

## 官方来源

### VMware/Broadcom

- [Troubleshooting ESX/ESXi virtual machine performance issues](https://knowledge.broadcom.com/external/article?legacyId=2001003)
- [Troubleshooting a VM that has stopped responding: VMM and Guest CPU usage comparison](https://knowledge.broadcom.com/external/article?legacyId=1017926)
- [Determining if multiple virtual CPUs are causing performance issues](https://knowledge.broadcom.com/external/article?legacyId=1005362)
- [Using esxtop to identify storage performance issues for ESXi](https://knowledge.broadcom.com/external/article?legacyId=1008205)
- [Configuring Virtual Machine Processor Settings](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/using-vmware-workstation-pro/configuring-virtual-machine-hardware-settings/configuring-virtual-machine-processor-settings.html)
- [Adjusting Virtual Machine Memory](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/using-vmware-workstation-pro/configuring-virtual-machine-hardware-settings/adjusting-virtual-machine-memory.html)
- [Configuring Display Settings](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/using-vmware-workstation-pro/configuring-virtual-machine-hardware-settings/configuring-display-settings.html)
- [Running Workstation on a Hyper-V Enabled Host](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/using-vmware-workstation-pro/running-workstation-on-a-hyper-v-enabled-host.html)
- [Limitations of Host VBS Mode](https://techdocs.broadcom.com/us/en/vmware-cis/desktop-hypervisors/workstation-pro/17-0/using-vmware-workstation-pro/running-workstation-on-a-hyper-v-enabled-host/limitations-of-host-vbs-mode.html)

### Microsoft Hyper-V

- [Detecting bottlenecks in a virtualized environment](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/detecting-virtualized-environment-bottlenecks)
- [Hyper-V Configuration](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/configuration)
- [Hyper-V processor performance](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/processor-performance)
- [Manage Hyper-V hypervisor scheduler types](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/manage/manage-hyper-v-scheduler-types)
- [Hyper-V Memory Performance](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/memory-performance)
- [Hyper-V Dynamic Memory Overview](https://learn.microsoft.com/en-us/windows-server/virtualization/hyper-v/dynamic-memory)
- [Hyper-V storage I/O performance](https://learn.microsoft.com/en-us/windows-server/administration/performance-tuning/role/hyper-v-server/storage-io-performance)
- [What is Nested Virtualization?](https://learn.microsoft.com/en-us/virtualization/hyper-v-on-windows/user-guide/nested-virtualization)
