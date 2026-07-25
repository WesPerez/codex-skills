---
name: sub2api-upgrade
description: 安全且尽可能快速地将此主机上的 Sub2API 升级到已验证的上游新版；由主代理语义重建 MINE 个性化差异，复用持久化隔离 debug 数据、生产只读活跃能力清单和按 diff 精确触发的验证 case，并按受影响职责动态启用最多 8 个无冲突只读子代理完成发现与复核，再执行精确 SHA 绑定、受控生产切换、回滚与收口。用户说“更新sub2”“更新 Sub2API”“升级sub2”“同步 Sub2API 最新版”“升级到最新版本”，或要求优化/审计 Sub2API 升级、debug 验证、升级耗时和测试场景时使用。不用于账号导入、通用管理 API、K12/Grok OAuth 生命周期、单独排障或纯源码审查。
---

# Sub2API 安全快速升级

把速度来自一次成型、按职责动态扩缩的安全只读扇出、等待重叠、复用和确定性脚本，而不是删门禁。不能承诺绝对零风险；任何未解释失败都停止。用户只说“更新sub2”时，授权执行已验证的正常生产升级、升级专属备份和本技能创建产物的收口；当前请求若指定停点则服从停点。历史会话的一次性生产写库、广泛清理或停服务授权不延续。

先读取 [运行时档案](references/runtime-profile.zh-CN.md)、[历史事故与控制](references/historical-incidents.zh-CN.md)、[当前个性化职责](references/current-customization-duties.zh-CN.md)、[快速流水线](references/fast-upgrade-pipeline.zh-CN.md) 和 [子代理编排](references/subagent-orchestration.zh-CN.md)。取得候选 diff 后按触发套件读取 [Debug 验证矩阵](references/debug-verification-matrix.zh-CN.md)。近期会话只补充档案尚未覆盖的新失败模式；不要每次从零重读全部历史。

**当前生产基线（2026-07-25 post-confirm）**：`0.1.165` / `322e2c9003afeffc3b5c7c2d6f61e5d02a22ee40`；上一生产 `0.1.164` / `61d5b363fe7cd370f73517973aec361303afb77f`。成功 run 为 `upgrade-20260725T180420Z-322e2c9003af`，状态为 `passed_pending_finalization`；下一次升级仍以实时 inspect 为准。

### 0.1.165 复盘基线

本次候选以 `2730c1c43b29be003925b033f3f9e645e726bb8c` 为上游父提交，仅保留三个职责提交：`0294dea1a`（发布/CI/文档）、`7a70c75ef`（Grok ID 与迁移）和 `322e2c900`（gateway 兼容残差，合并旧 D3/D4）。`AGENTS.md` 与 `BRANCH_DEPLOYMENT.md` 属于发布职责，不属于 gateway；技能文档和生产 Compose 属于本技能/部署层，不计入这三个源码提交。

池模式采用上游更精确的 status-aware cooldown 与 same-account retry（OpenAI `521db6869`、Grok `51f354f5c`），同时保留账号级 retry count/status codes、SSE `response.failed`/trailing 处理、首包和终态保护、first-output 预算及相关测试。移除的是 MINE 的 request-local pin、pool audit、sticky rebind/ExcludedIDs 和 scheduler `pool_mode` projection。对瞬时冻结而言上游方案更优；旧 MINE 的 sticky 防抖和运维审计更丰富但没有完全等价的上游替代。后续升级需要继续用独立 dev fault-injection 和真实调度证据完善这些行为边界；不能把“源码等价”扩大解释为“每个旧实现都原样保留”。

## 默认并发编排

每次真实升级先由主代理完成快速闸门：核实目标与生产 revision，刷新一次 refs，冻结完整 SHA、分支头和工作树状态。若 `upstream/main` 没有超出 running upstream base 的新提交且无额外修复，直接报告 no-op；不要创建候选、跑 CI 或机械启动 8 个代理。

闸门通过后按实际受影响职责和 [子代理编排](references/subagent-orchestration.zh-CN.md) 执行：

1. **Wave A 发现**：按实际非空职责启用 1–8 个只读 `explorer`，大版本可分别审计上游风险、D1–D4、测试/plan、运行事故与反向风险。全部使用冻结 SHA；子代理不 fetch、不 checkout、不写文件、不碰容器/数据库/凭据/远端。
2. **主代理单写**：等待全部结果，合成职责表后由主代理独自语义重建和提交。不得多个代理同时修改共享工作树。
3. **Wave B 候选复核**：冻结 candidate SHA，暂停写入，按非空风险面启用 1–6 个只读复核代理检查职责、迁移、测试映射、部署和独立反向风险；小改动可合并职责。只合并一次修复；SHA 改变后定向复核受影响职责，未解释分歧不得推 debug。
4. **Wave C 等待重叠**：CI waiter 只查精确 run、不 pull；其他只读代理核对 isolation/fixture/snapshot dry-run、matrix/负例、生产状态与报告输入。主代理在 join 后拉镜像，并独占 matrix/evidence 写入和共享 debug。
5. **共享状态串行**：Git 写入、本地/CI 测试调度、debug Compose/fixture/canary/matrix/evidence、promotion、生产 apply/confirm/rollback/finalize 始终由主代理独占。审查代理不启动测试或后台进程；空闲槽不能用来并发争用这些资源。

最多 8 是容量，不是配额。只有独立证据包能覆盖关键路径或外部等待窗时才派发；主代理复核所有证据并在结束前收齐或终止全部子任务。

## 不可跳过的门禁

以下任一项失败时，不改变生产环境：

1. 无法证明目标是 `/root/sub2api-prod-deploy` 的 `sub2api-prod`，或生产应用、PostgreSQL、Redis、Router、Nginx 基线不全绿。
2. `/root/sub2api-repo` 有未知改动，`main` 不是纯 `upstream/main`，候选职责不清，或候选上游基线/版本早于当前生产。必须用 `plan-sub2api-upgrade.sh` 和源码复核阻止版本倒退；合法语义重建不要求旧 `mine` 是候选祖先。
3. 没有逐职责完成“旧实现 -> 新上游 -> 剩余差异 -> 自动测试 -> debug canary”的语义对照，或把旧补丁机械 rebase/cherry-pick。
4. 精确候选 SHA 的 CI、固定分支镜像、隔离 debug、最终完整选中矩阵和日志门禁任一未通过。最终矩阵必须含 R0、U/M diff 精确触发的 case、生产活跃能力触发的真实 canary 与人工补充的间接路径；不得用未启用能力凑全 catalog。若候选或部署输入触及 Compose、entrypoint、command、network、代理或进程生命周期，必须在 release seal 前完成无凭据的真实 Docker lifecycle probe，并把 create/start/live-attach/进程参数/负例证据绑定到 R2-2；静态 `compose config` 或停态 inspect 不能替代。SHA、镜像 digest、debug 配置指纹或 fixture 指纹变化都会使相关旧证据失效。
5. 新增/修改迁移没有隔离升级演练、runner 口径 checksum 核验和旧应用兼容证明；已应用迁移文件被改写时直接停止，不修补数据库 checksum。
6. 无法证明旧应用镜像在目标 schema 上可安全回退。生产脚本只在此证明成立时接受 `--rollback-image-safe`。
7. Watchtower 状态、后台写任务、数据卷或目标镜像来源不清；不得使用浮动标签替代精确 revision 证据。

不授权自动数据库恢复、删除历史备份、修改生产账号配置、停共享任务、清理归属不明资源、无 lease 强推或改写 `main`。

## 提速原则

1. **一次成型再推 debug**：先完成静态语义对照、`git diff --check`、迁移检查和测试映射，避免每个小修复都消耗一轮 5–12 分钟 CI。
2. **等待并行化**：CI 运行时并行准备 fixture 快照、负例清单、只读生产 preflight 和报告，不反复人工轮询。用 `wait-branch-image.sh` 绑定 run、SHA 和固定镜像。
3. **保留 debug 数据骨架**：停止容器但保留隔离的 PostgreSQL/Redis/Sub2API 数据目录、合成 fixture 和历史迁移状态。禁止复制生产卷、生产凭据或让同一 OAuth 身份同时由 debug/生产刷新。
4. **按 case 选择，按职责兜底**：始终跑 `R0`；分别从纯上游差异、旧 MINE 职责和候选 MINE 差异触发 case，再用脱敏的生产只读 active inventory 启用当前真实在用能力的 live canary。测试文件和生产总 diff 只作审计，不独立触发运行时 case。`--suite`、`--all-suites`、`--permanent-canaries` 是显式扩大范围，会有意绕过自动门控，正常升级不使用。中间修复可增量复测，最终 SHA 必须跑完整选中矩阵。
5. **只缓存稳定证据**：职责映射、合成 fixture、已验证测试名可跨升级复用；实时健康、外部 canary、日志、schema、镜像和回退兼容不能跨 SHA 复用。
6. **生产最后动**：远端构建、debug、dump 与回退准备全部完成后，才 recreate 生产应用；生产切换本身不是主要耗时点。

## 合并与提交纪律

1. 以 `merge-base` 枚举旧 `mine` 职责。上游等价或更完整的能力采用上游；部分重叠只补缺失行为和测试。能由账号级 header、proxy、模型映射等配置完整表达时优先配置。
2. 保留职责，不保留每个旧 hunk。记录每个删除的旧实现被哪个上游实现取代，并以测试或运行证据证明等价。
3. 个性化提交保持少量、稳定、可审计。职责提交数不超过旧职责数与 5 的较小值；debug 修复 amend/fixup 回所属职责，最终历史不留零散修复提交。
4. `main` 精确等于已核验 `upstream/main`；部署文档、工作流和个性化代码只在 `debug`/`mine`。
5. 非 fast-forward 时先核验远端旧 SHA，只对目标分支使用精确 `--force-with-lease=refs/heads/<branch>:<verified-old-sha>`。禁止裸 `--force`；`mine` 只能指向 debug 完整验证过的相同 SHA。

## 标准流程

### 1. 建立候选与计划

1. 读取仓库 `AGENTS.md`、`BRANCH_DEPLOYMENT.md` 和关联源码/测试；由主代理刷新一次 `origin`、`upstream` refs，确认工作树与分支头，记录运行中生产 revision。无更新时 no-op 停止；有更新时冻结全部输入 SHA。
2. 按默认编排完成 Wave A；主代理汇总职责对照并独自语义重建。完成静态检查并创建候选提交后冻结 candidate SHA，执行 Wave B。主代理等待全部复核，统一修复后才生成最终计划：

```bash
bash scripts/plan-sub2api-upgrade.sh \
  --running-revision <current-production-sha> \
  --candidate-revision <candidate-sha> \
  --upstream-ref upstream/main \
  --active-inventory <non-sensitive-production-capabilities.json>
```

先用最小只读汇总建立 active inventory；它只允许环境、时间、来源、provider 名和 feature 名，不得包含账号 ID、名称、凭据、token、连接信息或业务明细。脚本会阻止候选上游基线或 `VERSION` 倒退，分别记录 upstream、running customization、candidate customization 三类来源，并按精确规则选到 case。未提供 inventory 时需要真实 provider/feature 的 case 默认不选；可用 `--suite` 明确补充，`--all-suites` 仅用于有证据支持的全 catalog 审计。需要落盘时，`--output-dir` 只能是 `/root/backups/sub2api/upgrade-evidence/` 的直接子目录；人工仍须审查它没有漏掉动态配置和间接调用路径。
3. 检查迁移、Compose、路由、协议转换、provider、Redis/PostgreSQL、后台任务和前端影响。新迁移只追加。人工把动态配置与间接路径补入 plan；不以子代理多数意见替代证据。
4. 候选静态审计与 Wave B 全部完成后才推 `debug`，避免用远端 CI 代替本可提前发现的语法、格式、职责和测试映射问题。

### 2. 等待精确 debug 镜像

```bash
bash scripts/wait-branch-image.sh \
  --branch debug \
  --expected-revision <candidate-sha>
```

把此无 pull waiter 交给唯一只读子代理，并在等待期间按 Wave C 完成互不争用的准备。join 后由主代理用同一命令追加 `--no-wait --pull`，只接受 `Docker Branch Images` 对该完整 SHA 的成功 run，以及 `debug-sha-<40sha>` 不可变镜像中匹配的 revision/ref label 和 digest。CI 失败后读取精确 job 证据，先在本地静态修完同类问题再推下一 SHA；等待期发现候选问题也先停止，禁止边改 SHA 边继续等待旧 run。

### 3. 复用隔离 debug 并验证

1. 先运行 `check-debug-isolation.sh`。debug 必须使用 `/root/sub2api-debug-deploy`、独立 Compose project/数据目录/网络、loopback 端口和 `:debug` 镜像，生产 Router 永不指向 debug。
2. 保留 debug 数据目录作为“连续升级数据库”：先用 `check-debug-fixture-manifest.sh` 校验非敏感 fixture，再用 `snapshot-debug-postgres.sh` dry-run；确认目标只在 `/root/backups/sub2api/debug-snapshots/` 后才 `--apply`。候选迁移后复核数据。停止用 `docker compose stop`，不因常规收口删除数据目录或卷。
3. debug 只保存合成数据和专属 canary 身份。真实 canary 凭据必须只属于 debug，不与生产共享 refresh owner；不得从生产整库复制账号、token、余额、日志或用户数据。
   **计划阶段身份闸门**：fixture 无 account 对象，或某活跃 provider 无 debug-only 身份时，在 `plan-sub2api-upgrade.sh` 后立即采用合规窄化闭环，不先把需要 live 身份的 case 跑成大量 blocked，也不复制生产凭据。窄化闭环=精确 SHA 全量 CI + 同 SHA 合成协议/runtime + 生产只读 inventory 与有意义基线 + 已证明 image rollback + 切换后每个活跃 provider 一次官方 Codex 有意义 canary。证据必须区分切换前 contract 与切换后 live confirmation；迁移、数据库写路径、认证写入和无法 image-only rollback 的变更不能用此闭环替代 debug 实证。
4. 按 [Debug 验证矩阵](references/debug-verification-matrix.zh-CN.md) 执行：
   - `R0` 永远全跑。
   - 三类差异精确触发且生产能力条件满足的 `R1/R2` 全跑；同一真实请求可以为多个 case 提供证据。
   - 每个保留个性化职责至少有一个正向 canary 和一个触达核心上游流程的回归断言。
   - 真实生成烟测遵守全局规则：使用有意义的代表任务、控制次数和预算；官方 Codex 链路只能由当前官方客户端发起；禁止 Sub2API `Test Connection` 和伪造 Codex 请求头。
5. 用 `compute-debug-config-fingerprint.sh --json` 生成统一的非敏感配置指纹，再用 `run-debug-matrix.sh` 记录可恢复 attempt。中间修复时跑 `R0 + 受影响套件 + 日志窗`；任何新 commit 都使旧 SHA 证据失效。最终 commit 使用 `mode=release` 重新跑完整选中矩阵，passed case 必须带证据，R0-7 必须带日志窗；R0-1/R0-8 使用 `references/*-evidence.template.json` 的机器契约，人工 case 使用 `manual-verification-evidence.template.json`，最后 `seal` 生成 `release-evidence.json`。
   **release 隔离**：`mode=release` 禁止 fault injection、临时 SQL 改库和 Sub2API Test Connection。这些只可在独立 `mode=dev` 实验 run 中使用，且其日志、fixture 变更与 attempt **不得** 并入 release seal / promotion / 生产 evidence。R0-1/R0-2 未产生业务日志不等于失败；R0-7 仍须有非空、归属明确的日志窗且不得含 fatal 模式。生产 post-confirm 的日志窗单独归档，空窗可记录为 clean empty window，不能反向充当 debug R0-7 证据。
   先用 `run-debug-adapter.sh run-ready --run-dir <dir>` 串行处理全部未完成 case；它跨 run 共用 debug 全局锁，并按 blocked(71) > failed(70) > needs_manual(78) > passed(0) 汇总。只要其他选中 case 尚未全部 `passed/skipped_not_triggered`，runner 就把 R0-7 保持为 pending，单 case release `run` 也拒绝提前执行；补齐结构化 manual/rollback evidence 后再次运行 `run-ready`，让 R0-7 扫到最终 canary 窗。旧 run 若已有过早的 passed R0-7，`run-ready` 自动创建最终 attempt；seal/verify 按 adapter checkpoint 的真实 `log_window.until` 拒绝未覆盖其他最终 passed attempt 的证据。当前只有 R0-1、R0-2、R0-7 是自动 adapter；其余场景在经过真实 debug 审计并落地 case 脚本前明确为 manual。manual evidence 必须明确写出它是 CI/静态审查、合成 debug、真实 canary 还是切换后确认，不能用 `executor=canary` 或 `executor=official-codex` 的名称替代实际请求证据。自动 pass 必须绑定同 attempt 的 adapter checkpoint；manual pass 必须是结构化 JSON，普通文字、占位证据、任意 shell/URL/path 都不能进入 release seal。中断的 `no_replay` 请求只收束为 blocked，不自动重发。
6. 预列故意负例的 UTC 时间窗、预期状态码和日志形状。任何 panic、迁移失败、HTTP 200 后的 `response.failed`、非预期 4xx/5xx、协议终态缺失或新增未解释 error 都必须定位。

### 4. 推进同一 SHA

1. 只有最终 debug 完整通过后，才让 `mine` 指向完全相同 SHA。若收敛提交改变 SHA，旧 debug 证据全部失效。
2. 先用 `verify-release-evidence.sh` 重新计算 sealed evidence，并使用其 `source_run_id`；该值来自 R0-1 的实际 Docker workflow run。再从 `mine` ref 调度 `Promote Debug Image`，输入同一 SHA、source run、exact digest 和 evidence SHA。workflow 只 carbon-copy `image@digest`，不重建、不改 config；因此 promoted 镜像内 `ref.name=debug` 必须保留。

```bash
evidence_json="$(bash scripts/verify-release-evidence.sh \
  --evidence <matrix-run-dir/release-evidence.json> \
  --expected-revision <sha> \
  --expected-digest <digest>)"
evidence_sha="$(jq -r '.sha256' <<<"$evidence_json")"
source_run_id="$(jq -r '.source_run_id' <<<"$evidence_json")"
gh workflow run promote-debug-image.yml \
  --repo WesPerez/sub2api \
  --ref mine \
  -f expected_revision=<sha> \
  -f source_digest=<digest> \
  -f source_run_id="$source_run_id" \
  -f verification_evidence_sha256="$evidence_sha"
```

3. 用 `verify-promoted-image.sh --pull` 核验 promotion run、唯一 receipt artifact、evidence SHA 和 `mine-sha-<40>@digest`。禁止手工 retag，禁止用浮动 `:mine` 或短 SHA 当发布权威。
4. 稳态让 `debug`、`mine` 同 SHA。临时 debug 提交仅在本次测试完成后按精确 lease 收口。

### 5. 生产切换与验证

1. 运行生产脚本 dry-run 预检；再次实时核验服务、数据卷、Watchtower、后台写任务和当前 image revision。
2. 仅在旧镜像回退兼容已在 debug 证明时执行：

```bash
bash scripts/update-sub2api.sh \
  --apply \
  --expected-revision <40-char-git-sha> \
  --expected-digest <sha256:64-hex> \
  --promotion-run-id <github-actions-run-id> \
  --verification-evidence <matrix-run-dir/release-evidence.json> \
  --rollback-image-safe
```

脚本先重新验算 sealed matrix 与 promotion receipt，并实时确认 `origin/mine`、`origin/debug` 仍等于候选，再拉取 `mine-sha-<40>@digest`、建立 PostgreSQL dump，只 recreate `sub2api`，并在运行态复核 image ID、revision、digest、内容身份、Router 活跃槽和 Nginx/SNI。它不更新 PostgreSQL/Redis，也不自动恢复数据库。

生产若依赖宿主机代理 bridge，还必须把部署层网络生命周期视为本次发布输入：Compose 显式保留应用 CMD，入口 gate 在原 entrypoint/迁移前等待，脚本只对运行中容器接入内置 bridge，并核验实际容器进程配置、精确 IP 和代理可达性。任何 Compose/entrypoint/network 变更都要在 release seal 前用无凭据候选容器完成真实生命周期探针；探针必须包含“created -> process spec -> start/gate -> live attach -> exact IP -> application command”正例，以及空 CMD、停态-only attach 和错误 IP 的负例。`compose config`、dry-run 或停态 inspect 不能替代。
3. **apply 后立即确认**（不得拖到 24h finalize）：对每个 active inventory provider 用当前官方 Codex 客户端做一次有意义 canary（复用本切换窗内已有合规 evidence，非必要不重发），再：

```bash
bash scripts/confirm-production-upgrade.sh \
  --run-id <upgrade-id> \
  --canary-evidence <provider-a.json> \
  --canary-evidence <provider-b.json> \
  [--require-providers a,b] \
  [--stop-debug]
```

脚本只校验/归档，不发模型请求、不用 Test Connection、不改生产服务。它核验每个 required provider 的 live confirmation、切换后日志窗、revision/digest/image、dump 与健康/Router/Nginx 基线；`--require-providers` 只能断言与 active inventory 完全一致，不能缩小覆盖；通过后可安全 `--stop-debug`（只 stop 容器，保留数据目录）。无共享凭据闭环下，post-confirm 是发布完成的硬条件。失败时只在已证明 image rollback 兼容时回退应用；数据库恢复、配置变更和账号处置需要单独授权。
4. 报告候选 SHA、上游基线、职责对照、CI run、image digest、schema、fixture 指纹、矩阵结果、日志窗、旧/新 revision、dump sha256、健康、post-confirm canary 与回退状态。不修改 Router 或 Composite 职责/配置，除非本次候选源码明确触及且已单独对照。

## 0.1.165 经验与后续完善方向

本次 `upgrade-20260725T170048Z-322e2c9003af` 与 `upgrade-20260725T172616Z-322e2c9003af` 均进入 `rollback_failed`；第二次造成约 `17:26Z–17:41:48Z` 的应用中断。根因分别是内置 bridge 不接受静态 IP/alias、停态 `network connect` 不形成可用 live sandbox，以及覆盖 entrypoint 时未显式保留 `/app/sub2api` CMD。PostgreSQL/Redis 未重建，失败尝试未应用候选迁移；成功 run `upgrade-20260725T180420Z-322e2c9003af` 于 `18:04:50Z` 通过，`18:07:57Z` 完成 OpenAI/Grok post-confirm。主证据为 `/root/backups/sub2api/upgrade-runs/upgrade-20260725T180420Z-322e2c9003af/incident-and-resolution.json`。

以后需要完善的方向：把生产 Compose/entrypoint/network 生命周期作为 release 输入；为 R2-2 固化隔离网段的真实 lifecycle probe 和负例；为 discovery、失败 run、人工 evidence 和 apply→confirm 记录结构化阶段时间；保持职责快照与实时 diff 同步，并继续验证已舍弃的旧 pool 增强在真实调度和运维观测上的影响。事故记录、dump、失败 run 和回滚资产必须保留到 recovery 链完成收口，不能用“脚本合同通过”代替运行态证据。

## 升级后收口

1. 仅停止本次启动且无活跃测试的 debug Compose；保留其数据目录和合成 fixture。不要停止归属不明的 Router、Nginx、数据库或任务服务。
2. 默认 **24h** 稳定窗（`--min-age-minutes 1440`）后：`finalize-sub2api-upgrade.sh --list` → 目标 run dry-run → `--apply`。finalize 要求 post-confirm 已 passed；只释放本 run rollback tag，保留 dump、配置和 manifest。禁止 `--min-age-minutes 0` 绕过。
3. 后续成功版本已上线且当前生产 revision 覆盖旧链时，对仍 `passed_pending_finalization` 的旧 run 使用 `finalize-sub2api-upgrade.sh --retire-superseded [--min-age-hours 24] [--apply]` 只释放被取代链上的 rollback tag。
4. 只有至少保留两个已验证 recovery runs、候选已 finalized 且超过保留窗，才使用 `--prune --apply`。禁止 `docker system prune`、宽泛删除或清理 Git dangling objects。
5. 失败、中断、归属不明或证据不完整的目录、镜像、卷、日志、分支和备份都保留并报告。

## 运行时脚本

- `scripts/plan-sub2api-upgrade.sh`：只读验证版本/上游基线，消费脱敏 active inventory，按 U/M diff 精确选 case（禁止默认全 catalog）；无 debug 身份时在计划阶段标记窄化闭环。
- `scripts/wait-branch-image.sh`：等待精确 GitHub run；无 `--pull` 时只返回 run/SHA 状态，主代理使用 `--no-wait --pull` 后再验证固定分支镜像 revision/digest。
- `scripts/check-debug-isolation.sh`：只读检查 debug 路径、镜像、端口、数据目录与生产隔离。
- `scripts/compute-debug-config-fingerprint.sh`：从稳定隔离字段、Compose 原文件、环境键集合和配置键路径计算非敏感指纹。
- `scripts/check-debug-fixture-manifest.sh`：校验合成 fixture、字段集规范哈希与敏感信息边界。
- `scripts/snapshot-debug-postgres.sh`：默认 dry-run，只向 debug snapshot 白名单建立 PostgreSQL 备份。
- `scripts/run-debug-matrix.sh`：可恢复地记录、复测、密封最终 SHA 的 debug 证据。
- `scripts/run-debug-adapter.sh`：按固定 allowlist 串行批跑或执行单 case，保存 checkpoint、截取 debug Compose UTC 日志并恢复未完成步骤。
- `scripts/verify-release-evidence.sh`：只读复核 sealed matrix、R0、证据/日志和绑定哈希。
- `scripts/verify-promoted-image.sh`：只读核验 promotion run/receipt，并可拉取 exact digest。
- `scripts/update-sub2api.sh`：生产预检、固定 SHA 镜像、应用专属 rollout、dump、验证和受限 image rollback。
- `scripts/confirm-production-upgrade.sh`：apply 后只读归档 post-confirm；校验 canary evidence、日志窗、revision/digest/dump 与基线，可选安全 stop debug。
- `scripts/finalize-sub2api-upgrade.sh`：列出 run；默认 24h 后释放 rollback tag；`--retire-superseded` 处理被当前生产取代的旧 pending；受控 prune。

运行脚本前用 `bash -n scripts/*.sh`。服务器禁止本地 Go/Node 构建、包管理器和 Docker build；GitHub Actions 与已发布 image metadata 才是构建证据。
