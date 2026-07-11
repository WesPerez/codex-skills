# 交接阅读顺序与提示词

## 1. “读两个文档就开工”是否足够

不够。两个首屏文档能快速定向，但不能证明现场没漂移。最小开工包是：

```text
首屏：
1. 仓库存在 AGENTS.md 时读取
2. docs/execution/STATUS.md

只读核验：
3. 使用 `python -B` 运行 progress_long_task.py resume-check
4. 使用 `python -B` 运行 audit_long_task.py
5. `git --no-optional-locks status --short`；仅对具体风险路径检查 ignored 产物

确认允许继续后：
6. 只读 docs/project-master-plan.md 当前 phase/slice 章节
```

`PROTOCOL.md` 仅在 audit 异常、存在未决动作、恢复权限不清或 STATUS 明确指示时阅读。`state/events/evidence/checkpoints` 默认交给工具核验，不要求 Agent 开工时手工通读。

需求文档如果就是主方案的一部分，不必再把整份原始聊天粘贴给 Agent。历史线程只补充动机，不能覆盖当前源码和运行结果。

## 2. 给执行 Agent 的最小输入

只需明确：

```text
仓库绝对路径
长期目标（一段话）
工作入口：audit/plan/implement/resume/status
用户授权：read_only/plan_write/repo_write
是否允许真实外部副作用
台账和主方案路径
必须运行的验证
commit/push/PR 要求
最终审计报告要求
```

不要把数万字文档复制进提示词；给路径、权威顺序和唯一当前切片。

## 3. 新项目审计提示词

```text
使用 $orchestrate-long-projects 处理这个项目。

仓库：<绝对路径>
根本目标：<一段清晰目标>
工作入口：audit 或 plan
用户授权：read_only 或 plan_write

先读取适用 AGENTS.md、README、Git、现有方案、源码入口、测试入口和运行现场。当前源码、Git、测试、构建和实际运行结果高于历史描述。

先在 20-40 分钟内给出第一版事实矩阵：真实用户工作流、代码/测试/构建/运行完成度、P0 风险、断链和唯一下一步。随后只对会改变架构或安全边界的问题做多源研究，区分官方事实、成熟案例、社区报告和本项目推导，不重复研究已有稳定结论。

`read_only` 只在回复中给方案；`plan_write` 才把 living 主方案写到用户指定路径。方案包含当前事实、调用链、数据/运行流、多余代码候选及删除前核验、目标架构、阶段、纵向切片、验收条件、测试/实机/失败矩阵、风险和 commit 边界。

未授权实施前不修改产品代码、不建立重型台账、不执行外部副作用。最终报告文件、产物、网络、配置、进程、清理、测试和 commit/push 状态。
```

## 4. 已有方案直接实施提示词

```text
使用 $orchestrate-long-projects 继续当前长期项目。

仓库：<绝对路径>
长期目标：<目标>
工作入口：implement
用户授权：repo_write（仅仓库内）
外部副作用授权：<禁止/仅指定动作/允许范围>

开工顺序：
1. 仓库存在 AGENTS.md 时读取。
2. 读 docs/execution/STATUS.md。
3. 使用 `python -B` 运行 progress_long_task.py resume-check、audit_long_task.py，并运行 `git --no-optional-locks status --short`；仅对具体风险路径检查 ignored 产物。若台账使用自定义路径，两个脚本必须传相同 `--output-dir/--plan-path`。
4. 审计允许继续后，只读主方案当前 phase/slice；只有异常时读 PROTOCOL/state/账本/checkpoint。
5. 核对当前源码、HEAD、测试、进程和外部系统；冲突时以当前事实为准。

从 STATUS 唯一下一动作继续，一次只推进一个纵向切片。每个切片按“最小代码 -> 局部测试 -> 构建 -> 启动当前版本 -> 实际 UI/API 操作 -> 必要的最小真实动作 -> 后置验证 -> evidence -> checkpoint/commit”闭环。UI 和运行能力完成一小块就实际接管验证，不积累数天代码后第一次启动。

子代理默认只读，不写共享台账、不接管真实外部系统；主代理复核结论。unknown 副作用先对账，禁止重放。不能证明属于本轮的文件、进程、页签和产物不得清理。

每个可见闭环汇报完成、当前、下一步、风险、是否启动当前版本和是否执行真实副作用。最终等待/中断所有子代理，按失败模式运行最低充分验证和 git status --short，仅按具体风险路径检查 ignored 产物，并报告文件、产物、下载、配置、进程、清理、commit hash、push 和 PR 状态。
```

## 5. 异常中断恢复提示词

```text
使用 $orchestrate-long-projects 恢复这个中断任务。

仓库：<绝对路径>
上一任务/线程 ID：<可选>
工作入口：resume
用户授权：read_only；恢复审计通过后，只有当前请求明确具有 repo_write 才能继续编辑

先不要修改文件、重新 bootstrap、启动应用、写数据库/AppData、发送输入、commit、push、清理或停止进程。

仓库存在 AGENTS.md 时先读它，再读 STATUS；使用 `python -B` 运行 progress_long_task.py resume-check、audit_long_task.py，并运行 `git --no-optional-locks status --short`，仅按具体风险路径检查 ignored 产物。若台账使用自定义路径，两个脚本必须传相同 `--output-dir/--plan-path`。只有异常时再读 PROTOCOL、state、账本尾和最新 checkpoint。重新观察进程、窗口、端口、浏览器或数据库身份；旧 PID/HWND/页签只作线索。

检查 running/unknown_after_interruption 动作、工作树漂移、过期证据、损坏 tail 和外部 lease。输出真实停点、允许/禁止动作、唯一下一步、需对账副作用和恢复置信度。

代码恢复审计通过只代表技术上可编辑；还必须有当前 `repo_write` 授权才继续。真实副作用另需明确 externalAuthorization，并重新通过目标身份、权限、备份、checkpoint、项目专用 verifier 和后置验证门。
```

## 6. 只读进度提示词

```text
使用 $orchestrate-long-projects 只读核验当前长期项目进度，不修改代码、方案或台账。

仓库存在 AGENTS.md 时先读它，再读 STATUS，使用 `python -B` 运行 resume-check 和完整 audit，运行 `git --no-optional-locks status --short`，仅按具体风险路径检查 ignored 产物，并核对必要的当前运行现场。

报告：最近完成、当前 phase/slice、唯一下一动作、blocker、适用的分层验收轴、最近当前有效 evidence、是否启动当前版本、是否执行真实外部动作、工作树/ignored 产物、运行进程、commit/push 状态，以及下一可见结果 ETA 范围和置信度。

不要给单一总百分比，不把代码存在、preflight、API 接收或旧截图写成产品完成。
```

## 7. 交接检查表

轻量模式：

- STATUS、Git、当前测试/截图和唯一下一动作一致。
- 文件、ignored 产物、进程、外部动作和清理归属有说明。
- 用户 `repo_write` 与 externalAuthorization 边界明确。

标准/加固模式再增加：

- STATUS 是当前 state/账本的精确投影。
- resume-check 和完整 audit 结果已记录。
- 最新 checkpoint 自哈希、tails 和技术门禁有效；用户授权另行核验。
- 工作树漂移、ignored 产物和文件归属有说明。
- 未决动作、外部 lease 和过期运行观察明确。
- passed evidence 绑定当前源码和固定 profile。
- 唯一下一动作可执行，禁止事项清楚。
- 主方案当前 phase/slice 入口明确。
- 子代理全部完成或已中断，审计摘要已合并。
- 文件、下载、配置、环境变量、凭据、进程、服务、页签、清理、commit/push/PR 状态已报告。
