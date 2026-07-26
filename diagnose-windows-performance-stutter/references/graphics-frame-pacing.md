# 图形呈现与帧时间诊断

## 目录

- [先区分三条时间线](#先区分三条时间线)
- [PresentMon 采集与筛选](#presentmon-采集与筛选)
- [指标与统计](#指标与统计)
- [PresentMode、DWM 与 VRR](#presentmodedwm-与-vrr)
- [GPUView/WPA 升级路径](#gpuviewwpa-升级路径)
- [A/B 与验收](#ab-与验收)
- [限制](#限制)
- [来源](#来源)

## 先区分三条时间线

1. **应用提交**：应用多久调用一次 Present，主要看 `MsBetweenPresents`。
2. **渲染执行**：CPU/GPU 工作和等待，按版本看 `MsCPUBusy/Wait`、`MsGPUBusy/Wait`、GPU latency 等。
3. **实际显示**：帧何时真正上屏及停留多久，主要看 `MsBetweenDisplayChange`、`DisplayedTime`、`MsUntilDisplayed`、Dropped。

平均 Presented FPS 正常不表示实际显示平滑；应用可以按时提交但被丢弃、合成延迟或重复显示。

## PresentMon 采集与筛选

### 捕获前

- 记录工具版本和 CSV schema（default/v1/v2 指标会变化）。
- 锁定 PID；进程重启后新建捕获，不按相同名称拼接。
- 记录窗口/全屏状态、显示器、刷新率、VRR、VSync/tearing、分辨率、HWS 和远程/虚拟显示。
- 确认 Performance Log Users/管理员权限、输出目录归属和捕获开销。

典型 Console 选项以当前版本 `--help` 为准：

```text
--process_id <pid>
--output_file <owned-path.csv>
--write_display_metadata   # 需要显示源/层元数据时
```

不要关闭 display tracking 后再声称分析了上屏节奏。

### 多 swapchain

按 `SwapChainAddress` 分组，至少输出：

- 有效帧数、显示字段有效帧数、Dropped 数。
- `PresentMode` 分布。
- 应用提交和显示帧时间摘要。

“有效帧数最多”只是自动选择启发式。真正主链应与目标窗口、`DisplayedTime/MsBetweenDisplayChange`、非 dropped 帧、`VidPnSourceId/LayerIndex/PresentId` 和场景节奏一致。overlay、加载窗口、视频层或次级窗口都可能生成额外 swapchain。

## 指标与统计

| 字段 | 语义 | 用途 |
|---|---|---|
| `ProcessID` / `Application` | Present 来源 | 锁定实例 |
| `SwapChainAddress` | swapchain 标识 | 避免多链混算 |
| `MsBetweenPresents` | 相邻 Present 调用间隔 | 应用提交节奏 |
| `MsBetweenDisplayChange` | 相邻实际显示变化间隔 | 观感 pacing |
| `MsUntilDisplayed` | Present 到显示 | 显示排队/延迟 |
| `DisplayedTime` | 帧在屏幕停留时间；未显示可能为 NA | 重复/丢帧 |
| `Dropped` / `Dropped Frames` | 未显示帧 | 丢帧比例 |
| `PresentMode` | 实际呈现路径 | 合成、flip、overlay/独立显示 |
| `AllowsTearing` / `SyncInterval` | 同步与 tearing 条件 | VRR/VSync 解释 |
| CPU/GPU busy/wait | 版本相关的工作/等待估计 | CPU/GPU bound 候选 |

### 推荐统计

对选定 swapchain 分别计算 `MsBetweenPresents` 和可用的 `MsBetweenDisplayChange`：

- count、mean、p50、p95、p99、max。
- 目标帧预算 `T = 1000 / target_fps`。
- `interval > 1.5*T` 与 `interval > 2*T` 的比例。
- Dropped 比例、PresentMode 分布。
- 需要时另按原始时间序列计算连续长帧簇和最长簇，识别“单尖刺”与“连续顿”；当前内置分析器不输出簇指标。

用本 Skill 的只读分析器：

```powershell
powershell -NoProfile -File .\scripts\analyze_presentmon.ps1 `
  -CsvPath C:\owned\capture.csv -ProcessId 1234 -TargetFps 60
```

分析器未指定 swapchain 时会列出所有链：存在有效 `MsBetweenDisplayChange` 时优先选择该有效样本最多的链，否则回退到有效 `MsBetweenPresents` 最多的链；这只是启发式，必须阅读 warning 并人工确认。分位数使用帧时间，不把 FPS percentile 与 frame-time percentile 混为一谈。

## PresentMode、DWM 与 VRR

常见模式语义：

| 模式 | 路径提示 |
|---|---|
| Hardware: Legacy Flip/Copy | 传统独占路径 |
| Hardware: Independent Flip | 非独占但可直接 scan-out |
| Hardware Composed: Independent Flip | flip-model + hardware overlay plane |
| Composed: Flip | flip-model 经 DWM 合成 |
| Composed: Copy with GPU/CPU GDI | 窗口化复制后合成 |

- Flip model 让应用与 DWM 共享 back buffers，通常少一次复制；DirectFlip/Independent Flip/MPO 可能让窗口化链接近直出。
- DWM 把窗口内容合成到桌面；合成路径不是自动故障，但会改变显示延迟和 pacing。
- Fullscreen Optimizations 可能让看似独占的应用走优化 borderless/flip 路径；overlay 出现时 DWM 可能重新介入。
- VRR 需要受支持的 flip/tearing 路径；`DXGI_PRESENT_ALLOW_TEARING` 需与 sync interval 0 等条件配合。
- VRR 下较低但平滑的帧率不必然等于卡顿；固定刷新下同一提交节奏可能产生重复帧或撕裂。

不要无证据全局关闭 MPO、HAGS、FSO、VRR 或 DWM。先确认 PresentMode/tearing/display change 能解释故障，再分别 A/B。

## GPUView/WPA 升级路径

PresentMon 能定位帧 pacing 所在阶段，但不能总是解释调用栈或内核队列。需要时用 Windows ADK 的 WPT/GPUView 做一次短捕获。

捕获会启动 ETW logger、要求管理员并生成较大 ETL，执行前遵守与 WPR 相同的归属、磁盘、停止和清理门槛。官方建议 GPUView 捕获通常保持约 30–60 秒；仅捕获一次可复现事件。

按时间对齐检查：

- CPU context switches、Ready/Wait 和 DXGK 提交。
- GPU engines、DMA/command buffers、排队与 VSync。
- 资源 lock/bind、DWM 合成和独立 scan-out。
- 同时间窗的 DPC/ISR、磁盘、网络和后台工作。

GPU 专用事件用 GPUView；WPA 用于同一 ETL 中的 CPU、I/O 和系统时间线。不要仅因某队列存在就定罪，必须与长帧对齐。

## A/B 与验收

- 固定场景、相机/操作路径、分辨率、刷新率、全屏状态、VRR/VSync、温度和并发负载。
- 每轮锁定新 PID 与主 swapchain，记录帧数和场景阶段。
- 一次只改一个图形、电源、调度或后台变量。
- 交替/随机化 AB/BA，按轮比较 p95/p99、长帧率、Dropped 和守护负载。
- 同一轮的逐帧数据用于估计该轮分布，不是数千个独立配置试验。
- Presented 改善但 Displayed 退化、或目标改善但其他关键应用退化时，不保留候选。

## 限制

- schema 随 PresentMon 版本变化；按列头自适应，缺失列要警告。
- 非管理员可能无法解析跨用户/短命进程，名称可显示 unknown。
- OpenGL/Vulkan 某些 CPU pacing/latency 指标不完整。
- Hardware-accelerated GPU scheduling 可能让部分 GPU timing 有偏差；把它作为测量限制，不直接归因。
- 强杀旧版本 PresentMon 可能破坏输出；只停止本任务启动的捕获并优先正常中止。
- FrameView/OCAT/CapFrameX 可作 PresentMon 生态工具，但指标定义和版本行为应核对其当前文档，不能混用不同 percentile 口径。

## 来源

### PresentMon/Intel

- [PresentMon README](https://github.com/GameTechDev/PresentMon/blob/main/README.md)
- [PresentMon Console Application](https://github.com/GameTechDev/PresentMon/blob/main/README-ConsoleApplication.md)
- [PresentMon Capture Application](https://github.com/GameTechDev/PresentMon/blob/main/README-CaptureApplication.md)
- [PresentMon metrics.csv](https://github.com/GameTechDev/PresentMon/blob/main/IntelPresentMon/metrics.csv)
- [PresentMon v1.9.2 metric definitions](https://github.com/GameTechDev/PresentMon/blob/v1.9.2/README.md)

### Microsoft

- [Using GPUView](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/using-gpuview)
- [Profiling DirectX Applications](https://learn.microsoft.com/en-us/windows/win32/direct2d/profiling-directx-applications)
- [DXGI flip model](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/dxgi-flip-model)
- [For best performance, use DXGI flip model](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/for-best-performance--use-dxgi-flip-model)
- [Variable refresh rate displays](https://learn.microsoft.com/en-us/windows/win32/direct3ddxgi/variable-refresh-rate-displays)
- [IDXGISwapChain::Present](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgiswapchain-present)
- [Swap Chains in Direct3D 12](https://learn.microsoft.com/en-us/windows/win32/direct3d12/swap-chains)
- [Reduce latency with DXGI 1.3 swap chains](https://learn.microsoft.com/en-us/windows/uwp/gaming/reduce-latency-with-dxgi-1-3-swap-chains)
- [Desktop Window Manager overview](https://learn.microsoft.com/en-us/windows/win32/dwm/dwm-overview)
- [Multiplane overlay support](https://learn.microsoft.com/en-us/windows-hardware/drivers/display/multiplane-overlay-support)
- [Demystifying Fullscreen Optimizations](https://devblogs.microsoft.com/directx/demystifying-full-screen-optimizations/)

### 厂商工具

- [AMD OCAT](https://gpuopen.com/ocat/)
- [NVIDIA FrameView](https://www.nvidia.com/en-us/geforce/technologies/frameview/)
