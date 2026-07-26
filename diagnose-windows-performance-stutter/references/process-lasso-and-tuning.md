# Process Lasso 与调度工具的证据化使用

## 目录

- [定位](#定位)
- [官方机制](#官方机制)
- [审计顺序](#审计顺序)
- [修改梯度](#修改梯度)
- [运行时验证](#运行时验证)
- [社区案例模式](#社区案例模式)
- [来源](#来源)

## 定位

把 Process Lasso 视为规则执行器和观测层，不是“最佳优先级生成器”。先判断卡顿属于计算、Ready、Waiting、DPC、存储、呈现还是虚拟化，再决定它是否是合适的修改入口。

默认保留 ProBalance 的保守行为。没有日志、运行时读回和 A/B 时，不叠加永久优先级、Affinity、CPU Sets、Performance Mode、Efficiency Mode 和 CPU Limiter。

## 官方机制

### ProBalance

- 目标是高负载下保持系统响应，不是减少总 CPU 工作量。
- 典型动作是临时把造成竞争的后台 Normal 进程降低到 Below Normal；无竞争时通常不动作。
- 默认会忽略若干前台或已非 Normal 的情况，设计上较保守。
- 先看 `Restrained` 状态、日志和 Insights 是否真实作用及是否误伤，再添加排除项。
- 不要预先把所有“重要”进程加入排除；进程仍应通过守护指标证明需要排除。

### Performance Mode 与电源

- Performance Mode 可在指定进程运行时切换性能电源计划，并与 ProBalance 行为联动；具体动作随版本和设置变化，以当前文档、UI 和日志为准。
- 只让真正定义性能场景的少量目标触发。后台常驻进程触发会把机器长期留在性能模式。
- 分开验证“触发规则”“实际电源 scheme/overlay”“处理器参数”和性能收益，不能从 GUI 标记推断电源已切换。

### 优先级

- Bitsum 官方方向是必要时降低不重要竞争者，不是把关键目标抬到 High/Realtime。
- Windows 已有前台、输入完成和动态线程 boost。通常保持 Dynamic Thread Priority Boost。
- `Above Normal` 也会改变抢占关系，不是免费性能；需要 Ready 证据和守护负载复测。
- GPU priority、I/O priority 与 CPU priority 是不同机制，不因设置 CPU priority 就自动解决存储或呈现等待。

### CPU Sets 与 Affinity

- Affinity 是硬限制；CPU Sets 是软偏好，调度压力大时可允许溢出。
- 性能试验通常先选 CPU Sets；Affinity 更适合确需硬限制的兼容/隔离场景。
- 某些进程会在启动后自设优先级或 Affinity；先确认应用语义和保护层，不默认用 Forced Mode 对抗。
- 超过 64 个逻辑处理器时，processor groups 让 Affinity 更复杂，CPU Sets 通常更适合作为软放置工具。
- System Reserved CPU Sets 是全局且强硬的机制，可能残留并改变 core parking；不进入通用自动优化路径。

### Forced Mode

- 普通持久规则通常在进程创建/匹配时应用；Forced Mode 持续检查并重应用被覆盖的规则。
- 默认关闭是有意设计，因为进程自设调度参数可能有自身理由。
- 只有日志证明规则被同一进程/外部工具反复覆盖，且短时 A/B 证明重应用有净收益时才考虑。

## 审计顺序

1. 确认 Governor、GUI/session agent 的实际状态和版本；进程存在不等于 Governor 正常执行。
2. 导出或备份当前配置，计算哈希，记录作用范围（per-user/per-machine）。
3. 从 Rules 列和配置列出所有匹配目标及其父/子进程的规则。
4. 从 Status、Log Viewer、Insights 确认谁被 restrain、何时触发 Performance Mode、哪些规则失败或被重写。
5. 用 Windows API 读取当前进程的 PriorityClass、关键线程动态优先级、Affinity、Default/Selected CPU Sets 和电源状态。
6. 查多个执行器：应用自身、launcher、IFEO、任务计划、其他调度/电源工具、脚本和安全软件是否也在写。
7. 对比“配置意图、执行日志、运行时状态、用户故障时间”四条证据。

常见 Rules 列符号（版本可能变化，最终以当前文档/UI 为准）：

| 符号 | 含义 |
|---|---|
| `X` | ProBalance 排除 |
| `g` | 触发 Performance Mode |
| `H/A/N/B/I/R` | CPU 优先级规则 |
| `0-63` | Affinity |
| `(0-63)` | CPU Sets |
| `E/e` | Efficiency Mode on/off |
| `L` | CPU Limiter |

## 修改梯度

从低风险到高风险逐级试验，每级只动一个变量：

1. 保持默认 ProBalance，仅验证它是否在正确时间作用。
2. 只对性能场景试 Performance Mode，并核对实际电源状态。
3. 对已证明抢占目标的非关键竞争者，短时试 Below Normal；同时看其吞吐与正确性。
4. 对已证明的拓扑争用试软 CPU Sets，并保留越界能力。
5. 只有规则被反复覆盖且有收益证据时试 Forced Mode。
6. 只有软策略重复有效但不足，且硬隔离的守护指标通过时，才试窄 Affinity。

以下不进入默认梯度：Realtime、普遍 High、System Reserved CPU Sets、全局前台排除、关闭所有保守 ProBalance 选项、大面积硬绑核、CPU Limiter 作为“无代价优化”。

## 运行时验证

写入后立即和延迟复查：

- 配置哈希、备份和 ACL 是否符合预期。
- Rules/Status/日志是否命中正确 PID，是否有访问拒绝或持续重应用风暴。
- Windows API 读回的 priority/Affinity/CPU Sets 是否与规则一致。
- Performance Mode 退出/进入时实际 scheme、overlay/profile 是否恢复正确。
- 进程重启、Governor 重载和系统重启后状态是否持久。
- A/B 主指标和其他高优先级工作负载的守护指标。

若规则未生效，先解决生效链路；不要继续叠加第二条规则。若生效但收益不重复，恢复原配置。

## 社区案例模式

论坛只用于提出这些可检验问题：

1. **高逻辑核兼容问题**：老程序在核数过多时启动失败，窄 Affinity 可作为兼容补丁；这不证明绑核能普遍提升性能。
2. **进程自设或保护层拒绝修改**：规则工具显示意图但 OS/目标未接受；应先验证运行时状态和应用自身配置，不直接开 Forced Mode。
3. **调度改善但间歇卡仍复发**：说明响应性工具可能缓解症状，根因仍可能是磁盘、服务、驱动或外部依赖。
4. **I/O 饥饿看起来像 CPU 卡顿**：界面无响应但 CPU 不高时，应测磁盘队列/延迟和 I/O priority，而不是继续抬 CPU priority。
5. **工具粒度不匹配**：进程级规则无法替代用户/会话级配额或 hypervisor 资源控制。

可复核社区线索：

- [High-core-count compatibility fixed with an affinity limit](https://gaming.stackexchange.com/questions/417419/how-to-start-witcher-2-on-a-system-having-a-lot-of-cpu-cores-e-g-16-cores-and)
- [A protected application rejects thread/priority changes](https://gaming.stackexchange.com/questions/391120/battlefield-2042-is-limiting-threads-and-process-priority)
- [A server still hangs after a scheduler utility improved responsiveness](https://serverfault.com/questions/96932/how-do-i-determine-what-is-hanging-my-server)
- [High/Realtime priority request and its narrow anecdotal context](https://superuser.com/questions/1579898/run-a-program-with-high-or-realtime-priority-yes-ive-read-the-other-threads)
- [Disk I/O starvation and I/O priority](https://stackoverflow.com/questions/10114340/programatically-prioritise-disk-i-o-in-win7)

这些案例证据弱于官方机制和本机 trace，不复制其中的具体进程配置。

## 来源

- [Process Lasso Documentation](https://bitsum.com/docs/pl/)
- [How ProBalance Works](https://bitsum.com/how-probalance-works/)
- [Process Lasso FAQ](https://bitsum.com/process-lasso-faq/)
- [Process Lasso Setup Guide](https://bitsum.com/docs/process-lasso-setup-guide/)
- [How do I Tweak My PC For Maximum Performance?](https://bitsum.com/docs/how-do-i-tweak-my-pc-for-maximum-performance/)
- [Conservative By Default](https://bitsum.com/docs/conservative-by-default-check-those-probalance-options/)
- [Forced Mode](https://bitsum.com/docs/new-docs-on-forced-mode/)
- [The Process Lasso Rules Column](https://bitsum.com/docs/the-process-lasso-gui-rules-column/)
- [How To Keep Processes Off E-Cores](https://bitsum.com/docs/how-to-keep-processes-off-e-cores/)
- [Process Lasso CPU Sets and Alder Lake](https://bitsum.com/product-update/process-lasso-10-4-cpu-sets-and-adler-lake/)
- [Microsoft Scheduling Priorities](https://learn.microsoft.com/en-us/windows/win32/procthread/scheduling-priorities)
- [Microsoft CPU Sets](https://learn.microsoft.com/en-us/windows/win32/procthread/cpu-sets)
- [Microsoft Priority Boosts](https://learn.microsoft.com/en-us/windows/win32/procthread/priority-boosts)
