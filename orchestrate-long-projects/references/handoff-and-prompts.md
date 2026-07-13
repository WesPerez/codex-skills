# 交接阅读顺序与提示词

以下提示词只用于已经通过显式路由门和持久连续性门的项目。普通会话/任务意外中断后，新会话读取旧消息、摘要或简单 handoff 继续，不调用本技能，直接使用普通任务提示即可。完整边界见 [invocation-boundaries.md](invocation-boundaries.md)。

## 1. 最小交接包

给接手 Agent 的输入只包含：

```text
仓库绝对路径
长期目标和当前可观察结果
连续性级别：light / standard / hardened
用户授权：read_only / plan_write / repo_write
externalAuthorization 的允许与禁止范围
STATUS、canonical plan 和台账路径
唯一下一动作
必须运行的验证
commit/push/PR 要求
```

不要复制完整聊天、全部账本、长日志或所有历史 checkpoint。当前源码和运行结果高于历史描述。

## 2. 轻量项目恢复

```text
使用 $orchestrate-long-projects 继续这个已存在的轻量长期项目。

仓库：<绝对路径>
用户授权：<read_only/plan_write/repo_write>

先读适用 AGENTS.md、STATUS.md 和 canonical plan 当前切片，运行一次 git --no-optional-locks status --short。核对唯一下一动作、工作树变化、用户授权和未决外部动作后继续。

不要运行 Python resume-check 或完整 audit，除非发现部分安装、状态冲突、无法解释的 drift，或用户明确要求 deep/full audit。
```

## 3. 标准/加固项目实施

```text
使用 $orchestrate-long-projects 继续当前长期项目。

仓库：<绝对路径>
用户授权：repo_write（仅仓库内）
外部副作用授权：<禁止/仅指定动作/允许范围>

先读 AGENTS.md 和 STATUS.md，再运行 progress_long_task.py resume-check。fast 返回 safe_for_code_only 时直接从唯一下一动作继续；只有 fast blocked/ambiguous、旧台账缺 fast 数据、tail/checkpoint/STATUS 异常、unknown 动作、高风险外部动作、handoff/完成/发布/push 前，才运行 audit_long_task.py 和必要的精确 Git/外部状态核验。旧台账若 full 诊断确认仅缺 fast 字段，在 repo_write 下执行 render 迁移后重跑 fast。

一次推进一个切片。按失败模式选择最低充分验证；只有变更触及对应边界时才构建、启动、操作 UI/API、执行真实动作或验证业务后置状态。只在语义停止点写台账和 checkpoint。

子代理默认只读，不写共享台账、不接管真实外部系统。unknown 副作用先对账，禁止重放。不能证明归属的文件、进程、页签和产物不得清理。
```

## 4. 异常中断恢复

```text
使用 $orchestrate-long-projects 恢复这个中断任务。

仓库：<绝对路径>
用户授权：read_only；只有当前请求明确具有 repo_write 才能继续编辑

先不要修改、启动、重放副作用、commit、push、清理或停止进程。读 AGENTS.md 和 STATUS.md，运行 fast resume-check。

若存在 unknown_after_interruption、未闭合 intent/result、Git drift、tail/checkpoint/STATUS 异常或旧台账缺 fast 数据，运行完整 audit，并重新核对目标身份和外部后置状态。旧 PID、窗口句柄和页签只作线索。

输出真实停点、允许/禁止动作、唯一下一步、需对账副作用和恢复置信度。code-only 技术结论不授予真实副作用权限。
```

## 5. 只读进度

```text
使用 $orchestrate-long-projects 只读核验当前已存在的长期项目进度。

light：读 STATUS、canonical plan 当前切片，并运行一次 git status --short。
standard/hardened：读 STATUS 并运行 fast resume-check；只有结果异常、证据新鲜度是本次问题核心，或用户明确要求 deep/full audit 时才运行完整 audit。

报告最近完成、当前切片、唯一下一动作、blocker、最近源码绑定证据、是否启动当前版本、是否执行真实外部动作、Git/运行现场和 commit/push 状态。不要给单一总百分比。
```

## 6. 新增长期项目

只有用户明确要求跨会话连续性时才建立：

```text
使用 $orchestrate-long-projects 为这个多小时/跨天项目建立最小连续性材料。

仓库：<绝对路径>
长期目标：<结果、约束、验证>
用户授权：plan_write 或 repo_write
级别：light / standard / hardened

先 dry-run bootstrap，核对文件集合与授权。light 只建立 canonical plan + STATUS；standard/hardened 才建立机器台账。默认不创建 AGENTS.md，不把任务专用长规则写入全局指导。
```

## 7. 交接检查

light：STATUS、canonical plan、Git 摘要、唯一下一动作和授权一致。

standard/hardened：在正式 handoff 前运行完整 audit；确认最新 checkpoint、未决动作、当前源码绑定 evidence、外部身份、工作树、进程/页签/下载/配置和 commit/push 状态。大日志和历史证据保留路径/hash，不复制进提示词。
