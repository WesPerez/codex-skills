# 证据模型、实验设计与可迁移案例

## 目录

- [证据等级](#证据等级)
- [调查台账](#调查台账)
- [采样与归因规则](#采样与归因规则)
- [A/B 设计](#ab-设计)
- [可迁移案例模式](#可迁移案例模式)
- [论坛与案例的使用方式](#论坛与案例的使用方式)

## 证据等级

按以下顺序提高结论强度：

| 等级 | 证据 | 能支持什么 |
|---|---|---|
| E0 | 用户体感、单点截图、论坛建议 | 生成候选假设 |
| E1 | 配置文件、工具 UI、一次计数器快照 | 说明可能存在某设置，不证明运行时生效或因果 |
| E2 | PID 锁定的时间序列、进程族 CPU 增量、日志与故障时刻对齐 | 排候选和选择下一种 trace |
| E3 | ETW/PresentMon/应用 profiler 栈、宿主与客户机双侧证据 | 解释计算、等待、抢占、呈现或资源争用机制 |
| E4 | 随机/交替顺序的重复单变量 A/B，配置和运行时读回一致 | 支持保留或回滚候选修改 |
| E5 | 重启、持续运行和多个真实场景复验，守护指标不退化 | 支持持久应用 |

官方文档主要确认“机制语义”，本机 trace 确认“这次是否发生”，A/B 确认“这项修改是否有净收益”。三者不能互相替代。

## 调查台账

每轮维护一张精简台账：

```text
目标与根 PID：
进程族边界：
症状与用户事件时间：
可重复场景：
主指标 / 守护指标：
当前配置哈希与运行时读回：
本轮唯一变量：
最新证据路径：
支持 / 反证：
下一次最小动作：
回滚命令与验收：
```

任何结论都附带 PID、时间窗、采样方法和证据路径。进程重启后创建新一轮，不把相同名称的新 PID 接到旧累计量上。

## 采样与归因规则

### CPU 与进程族

- 用两次以上累计 CPU 时间之差除以墙钟时间，报告 `CPU cores used`；不要把任务管理器单点百分比当因果。
- 同时输出目标进程族和全系统 top competitors。多进程应用只看根 PID会漏掉渲染、服务、沙箱或工作进程。
- 按每个 PID 的开始时间防止 PID 重用；访问被拒绝是证据缺口，不是零负载。
- 全机 CPU 低不排除单核、单 CCD、单线程、优先级或硬 affinity 造成的局部截止时间失败。
- 不用 100–250 ms 的 PowerShell 全进程轮询追亚秒级尖刺；它容易制造观察者效应。轻量采样确定周期后，改用短时 ETW/PresentMon 获取细粒度时间线。

### 时间对齐

- 用户按键或可见卡顿时刻、PresentMon 长帧、ETW Ready/Wait、DPC/ISR、磁盘 I/O 和后台任务必须用同一时钟对齐。
- 只有在故障窗口内同步出现，机制才进入高置信候选。整段总量排名不能建立时间因果。
- 周期性峰值先比较周期是否一致，再看调用栈/任务来源。

### 配置生效

至少做四类验证：

1. 持久载体：文件、注册表或工具规则已按预期写入，哈希与备份明确。
2. 执行日志：负责应用规则的服务/工具记录命中，无反复重写或访问失败。
3. 运行时 API：priority、Affinity、CPU Sets、电源状态等真实读回符合候选。
4. 延迟复查：进程重启、服务重载或系统重启后仍符合预期。

缺少任一层都要说明，不能把“命令退出码为 0”写成“优化已生效”。

## A/B 设计

### 试验单位

- 一次完整复现场景是一轮。帧、采样点或线程事件是轮内相关观测，不是独立配置样本。
- 每轮预热、时长、场景阶段、并发工作、输入、分辨率、刷新率、供电和采集方式保持一致。
- 环境明显漂移时本轮标为无效，不用删除不利结果的方式“清洗”。

### 顺序与重复

- 交替或随机化 `AB/BA`；固定“候选先、基线后”会把升温、缓存、网络和后台负载漂移混入配置效果。
- 对低风险、短场景可先做 2 个探索对；要持久应用调度、电源或虚拟化修改时，通常需要更多配对轮次和一致方向。
- 预先声明停止条件。不要一直测到出现想要的结果。

### 指标与判断

- 帧体验：p95/p99、超过 1.5x/2x 帧预算的比例、Dropped、PresentMode；平均 FPS 只作辅助。
- 交互/任务：请求或操作延迟分位数、吞吐、错误/超时。
- 音频：glitch 次数/时刻与 DPC/ISR 对齐。
- 守护负载：使用同类尾延迟、吞吐和正确性指标，不只检查“进程还在”。
- 比较逐对差值、中位差和胜负方向。收益小于基线自身波动或胜负混合时判为证据不足。
- 报告绝对值和差值；不要只给百分比改善。

### 回滚判据

出现以下任一情况立即恢复原值：

- 候选未真实生效，无法解释结果。
- 主指标没有可重复改善。
- 任一高优先级守护指标明显退化、功能错误或质量下降。
- 出现输入、音频、系统响应、温度、功耗或稳定性副作用。
- 试验引入了第二个未控制变量。

## 可迁移案例模式

这些是调查模板，不是可直接套用的设置。

### 1. CPU 未满但出现周期性停顿

现象：总 CPU 有余量，目标每隔固定时间停一下。

路径：

1. 采样目标进程族与 top competitors 的 CPU core 增量和 I/O 速率。
2. 对齐周期，确认是目标自己的定时工作、竞争者突发，还是 DPC/ISR。
3. 若目标关键线程 Ready 长，检查优先级和放置；若 Waiting 长，查锁/I/O/消息。
4. 只对已证明的周期任务做频率、批量或调度 A/B，并保持功能输出一致。

反例：仅因总 CPU 低就给目标硬绑核；这可能把局部竞争变得更严重。

### 2. 平均 FPS 正常但画面不顺

现象：平均帧率达标，体感仍有顿挫。

路径：

1. PresentMon 锁 PID，列出 swapchain 并识别实际主链。
2. 比较 `MsBetweenPresents` 和 `MsBetweenDisplayChange` 的 p95/p99、长帧比例、PresentMode、Dropped。
3. 帧提交正常但 display change 尾部异常时，转向 DWM/compositor、刷新率、VRR 和显示拓扑。
4. 帧提交本身异常时，用 ETW sampled/precise 对齐 CPU/GPU/等待。

反例：用几千帧当作几千个 A/B 样本，或只比较一轮平均 FPS。

### 3. 多个关键应用同时卡顿

现象：两个或更多工作负载都必须运行，任何一个都不能被牺牲。

路径：

1. 为每个工作负载定义独立主/守护指标和进程族。
2. 用同一时间窗采样，确认 CPU、内存提交、存储、DPC 或呈现链是否共同恶化。
3. 先减少确认无价值的重复工作；再试软放置或资源配置。
4. 候选只有在 Pareto 意义上不伤害其他关键负载时保留。

反例：为了一个前台目标把另一个必须运行的工作负载统一降优先级或禁止启动。

### 4. 调度工具规则看起来正确但体感更差

现象：UI/配置显示规则存在，实际卡顿没有改善或更糟。

路径：

1. 对比持久规则、工具日志命中、运行时 priority/Affinity/CPU Sets 和重启后状态。
2. 查找多个工具或父进程重复重写优先级/亲和的日志。
3. 清晰区分 Performance Mode、电源切换、ProBalance、CPU Sets 和 Affinity，每次只测一个机制。
4. 若运行时读回不一致，先解决生效链路，不分析性能收益。

反例：继续叠加规则，直到无法确定哪项在起作用。

### 5. 驱动 DPC/ISR 嫌疑

现象：音频、输入或整机出现短促中断，进程 CPU 无明显峰值。

路径：

1. 记录故障时刻，用短时 ETW 看 DPC/ISR 的 CPU、持续时间和驱动栈。
2. 要求多次故障都与同一候选时间对齐。
3. 再做可回滚的驱动版本、设备状态或电源管理 A/B；先准备恢复方式。

反例：依据第三方工具的累计最高执行时间直接卸载或禁用设备。

## 论坛与案例的使用方式

按以下规则消费论坛信息：

1. 提取可检验机制，不复制设置包。例如“某 overlay 导致频率变化”应转成频率/帧时间 A/B，而不是直接切计划。
2. 检查 OS build、硬件拓扑、驱动版本、显示模式和复现场景是否匹配。
3. 优先选择包含 ETL、PresentMon、性能计数器、before/after 原始数据和回滚结果的帖子。
4. 用 Microsoft 或厂商官方文档确认 API/设置语义；论坛只解释可能的现场组合。
5. 失败案例同样保留。适用边界比“成功调参清单”更有价值。
6. 不把点赞、回复数量、作者身份或单机成功当作因果强度。

## 成熟案例线索

以下链接用于理解调查模式，不提供可直接套用的配置：

| 模式 | 线索 | 等级与局限 |
|---|---|---|
| DPC/ISR 与音画中断 | [LatencyMon 工具说明](https://www.resplendence.com/latencymon)、[网络栈 DPC 的 WPA 调查](https://superuser.com/questions/1172843/high-dpc-latency-windows-10-unable-to-fix)、[NIC DPC 线索](https://stackoverflow.com/questions/31161246/dpc-latency-caused-by-nic) | 厂商工具 + 社区；最终需 WPR/WPA 驱动栈复核 |
| 平均 FPS 掩盖微卡 | [PresentMon](https://github.com/GameTechDev/PresentMon)、[CapFrameX](https://www.capframex.com/) | 工具链；指标口径以 PresentMon 当前 schema 为准 |
| 多应用全局输入延迟 | [高核心数/虚拟化组合的单机案例](https://superuser.com/questions/1368076/severe-input-latency-lag-on-threadripper-2990wx) | 单机论坛报告，只支持检查共享层，不支持一律关闭虚拟化 |
| 低吞吐但磁盘 100% | [高磁盘利用率与慢 I/O 案例](https://superuser.com/questions/591250/windows-8-extremely-high-disk-usage-and-slow-io)、[间歇磁盘 100% 案例](https://superuser.com/questions/1042422/windows-10-hard-disk-usage-100-computer-hangs) | 多因症状；必须用延迟/队列/发起者分叉 |
| 固定节奏卡顿 | [热/功耗周期案例](https://superuser.com/questions/918543/stutter-while-gaming-every-3-4-seconds-in-windows-using-macbook-pro-2012-macboo)、[周期性 DPC/pagefault 调查](https://superuser.com/questions/193479/high-dpc-latency-and-slow-hard-pagefaults-on-gigabyte-ga-ep35c-ds3r-motherboard) | 旧硬件社区案例；价值在“先找周期源” |
| Soft 与 hard page fault 混淆 | [Soft page fault 讨论](https://superuser.com/questions/376215/getting-gratuitous-amounts-of-soft-page-faults-when-loading-games-and-watching-f) | 社区解释；正式语义和结论以 Microsoft memory/WPT 文档为准 |
| 电源驻留/核心停放 | [Microsoft CPU Analysis](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/cpu-analysis)、[ParkControl 说明](https://bitsum.com/parkcontrol/) | 官方机制 + 有产品立场的厂商经验；只做计划级 A/B |

社区案例常缺少回滚再复现、随机顺序和原始数据，因此最多提升到 E0–E2。复现同一机制并完成本机配对 A/B 后，才能提高结论等级。
