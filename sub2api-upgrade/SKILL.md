---
name: sub2api-upgrade
description: 安全且尽可能快速地将此主机上的 Sub2API 升级到已验证的上游新版，语义重建 MINE 个性化差异，复用持久化隔离 debug 数据和按 diff 触发的完整验证矩阵，再执行精确 SHA 绑定、受控生产切换、回滚与收口。用户说“更新sub2”“更新 Sub2API”“升级sub2”“同步 Sub2API 最新版”“升级到最新版本”，或要求优化/审计 Sub2API 升级、debug 验证、升级耗时和测试场景时使用。不用于账号导入、通用管理 API、K12/Grok OAuth 生命周期、单独排障或纯源码审查。
---

# Sub2API 安全快速升级

把速度来自复用、并行和确定性脚本，而不是删门禁。不能承诺绝对零风险；任何未解释失败都停止。用户只说“更新sub2”时，授权执行已验证的正常生产升级、升级专属备份和本技能创建产物的收口；当前请求若指定停点则服从停点。历史会话的一次性生产写库、广泛清理或停服务授权不延续。

先读取 [运行时档案](references/runtime-profile.zh-CN.md)、[历史事故与控制](references/historical-incidents.zh-CN.md)、[当前个性化职责](references/current-customization-duties.zh-CN.md) 和 [快速流水线](references/fast-upgrade-pipeline.zh-CN.md)。取得候选 diff 后按触发套件读取 [Debug 验证矩阵](references/debug-verification-matrix.zh-CN.md)。近期会话只补充档案尚未覆盖的新失败模式；不要每次从零重读全部历史。

## 不可跳过的门禁

以下任一项失败时，不改变生产环境：

1. 无法证明目标是 `/root/sub2api-prod-deploy` 的 `sub2api-prod`，或生产应用、PostgreSQL、Redis、Router、Nginx 基线不全绿。
2. `/root/sub2api-repo` 有未知改动，`main` 不是纯 `upstream/main`，候选职责不清，或候选上游基线/版本早于当前生产。必须用 `plan-sub2api-upgrade.sh` 和源码复核阻止版本倒退；合法语义重建不要求旧 `mine` 是候选祖先。
3. 没有逐职责完成“旧实现 -> 新上游 -> 剩余差异 -> 自动测试 -> debug canary”的语义对照，或把旧补丁机械 rebase/cherry-pick。
4. 精确候选 SHA 的 CI、固定分支镜像、隔离 debug、最终完整矩阵和日志门禁任一未通过。SHA、镜像 digest、debug 配置指纹或 fixture 指纹变化都会使相关旧证据失效。
5. 新增/修改迁移没有隔离升级演练、runner 口径 checksum 核验和旧应用兼容证明；已应用迁移文件被改写时直接停止，不修补数据库 checksum。
6. 无法证明旧应用镜像在目标 schema 上可安全回退。生产脚本只在此证明成立时接受 `--rollback-image-safe`。
7. Watchtower 状态、后台写任务、数据卷或目标镜像来源不清；不得使用浮动标签替代精确 revision 证据。

不授权自动数据库恢复、删除历史备份、修改生产账号配置、停共享任务、清理归属不明资源、无 lease 强推或改写 `main`。

## 提速原则

1. **一次成型再推 debug**：先完成静态语义对照、`git diff --check`、迁移检查和测试映射，避免每个小修复都消耗一轮 5–12 分钟 CI。
2. **等待并行化**：CI 运行时并行准备 fixture 快照、负例清单、只读生产 preflight 和报告，不反复人工轮询。用 `wait-branch-image.sh` 绑定 run、SHA 和固定镜像。
3. **保留 debug 数据骨架**：停止容器但保留隔离的 PostgreSQL/Redis/Sub2API 数据目录、合成 fixture 和历史迁移状态。禁止复制生产卷、生产凭据或让同一 OAuth 身份同时由 debug/生产刷新。
4. **按 diff 选择，按职责兜底**：始终跑 `R0`；再跑变更路径触发的套件和所有保留个性化职责对应套件。中间修复可增量复测，最终 SHA 必须跑完整选中矩阵。
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

1. 读取仓库 `AGENTS.md`、`BRANCH_DEPLOYMENT.md` 和关联源码/测试；刷新 `origin`、`upstream` refs，确认工作树与分支头。
2. 记录运行中生产 revision。完成语义重建后运行：

```bash
bash scripts/plan-sub2api-upgrade.sh \
  --running-revision <current-production-sha> \
  --candidate-revision <candidate-sha> \
  --upstream-ref upstream/main
```

脚本会阻止候选上游基线或 `VERSION` 倒退，并按升级 diff 与候选个性化 diff 选择测试套件。需要落盘时，`--output-dir` 只能是 `/root/backups/sub2api/upgrade-evidence/` 的直接子目录；人工仍须审查它没有漏掉动态配置和间接调用路径。
3. 检查迁移、Compose、路由、协议转换、provider、Redis/PostgreSQL、后台任务和前端影响。新迁移只追加。
4. 候选静态审计完成后才推 `debug`，避免用远端 CI 代替本可提前发现的语法、格式和职责问题。

### 2. 等待精确 debug 镜像

```bash
bash scripts/wait-branch-image.sh \
  --branch debug \
  --expected-revision <candidate-sha> \
  --pull
```

只接受 `Docker Branch Images` 对该完整 SHA 的成功 run，以及 `debug-sha-<40sha>` 不可变镜像中匹配的 revision/ref label 和 digest。等待期间完成可并行准备；CI 失败后读取精确 job 证据，先在本地静态修完同类问题再推下一 SHA。

### 3. 复用隔离 debug 并验证

1. 先运行 `check-debug-isolation.sh`。debug 必须使用 `/root/sub2api-debug-deploy`、独立 Compose project/数据目录/网络、loopback 端口和 `:debug` 镜像，生产 Router 永不指向 debug。
2. 保留 debug 数据目录作为“连续升级数据库”：先用 `check-debug-fixture-manifest.sh` 校验非敏感 fixture，再用 `snapshot-debug-postgres.sh` dry-run；确认目标只在 `/root/backups/sub2api/debug-snapshots/` 后才 `--apply`。候选迁移后复核数据。停止用 `docker compose stop`，不因常规收口删除数据目录或卷。
3. debug 只保存合成数据和专属 canary 身份。真实 canary 凭据必须只属于 debug，不与生产共享 refresh owner；不得从生产整库复制账号、token、余额、日志或用户数据。
4. 按 [Debug 验证矩阵](references/debug-verification-matrix.zh-CN.md) 执行：
   - `R0` 永远全跑。
   - 路径触发的 `R1/R2` 全跑。
   - 每个保留个性化职责至少有一个正向 canary 和一个触达核心上游流程的回归断言。
   - 真实生成烟测遵守全局规则：使用有意义的代表任务、控制次数和预算；官方 Codex 链路只能由当前官方客户端发起；禁止 Sub2API `Test Connection` 和伪造 Codex 请求头。
5. 用 `compute-debug-config-fingerprint.sh --json` 生成统一的非敏感配置指纹，再用 `run-debug-matrix.sh` 记录可恢复 attempt。中间修复时跑 `R0 + 受影响套件 + 日志窗`；任何新 commit 都使旧 SHA 证据失效。最终 commit 使用 `mode=release` 重新跑完整选中矩阵，passed case 必须带证据，R0-7 必须带日志窗；R0-1/R0-8 使用 `references/*-evidence.template.json` 的机器契约，人工 case 使用 `manual-verification-evidence.template.json`，最后 `seal` 生成 `release-evidence.json`。
   先用 `run-debug-adapter.sh run-ready --run-dir <dir>` 串行处理全部未完成 case；它跨 run 共用 debug 全局锁，把 R0-7 固定到最后，并按 blocked(71) > failed(70) > needs_manual(78) > passed(0) 汇总。当前只有 R0-1、R0-2、R0-7 是自动 adapter；其余场景在经过真实 debug 审计并落地 case 脚本前明确为 manual。自动 pass 必须绑定同 attempt 的 adapter checkpoint；manual pass 必须是结构化 JSON，普通文字、占位证据、任意 shell/URL/path 都不能进入 release seal。中断的 `no_replay` 请求只收束为 blocked，不自动重发。
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
3. 再执行 debug 已通过的低风险生产 canary 和日志窗检查。失败时只在已证明 image rollback 兼容时回退应用；数据库恢复、配置变更和账号处置需要单独授权。
4. 报告候选 SHA、上游基线、职责对照、CI run、image digest、schema、fixture 指纹、矩阵结果、日志窗、旧/新 revision、dump sha256、健康、canary 与回退状态。

## 升级后收口

1. 仅停止本次启动且无活跃测试的 debug Compose；保留其数据目录和合成 fixture。不要停止归属不明的 Router、Nginx、数据库或任务服务。
2. 稳定窗口后先运行 `finalize-sub2api-upgrade.sh --list`，再对目标 run dry-run；确认后才加 `--apply`。finalize 只释放本 run rollback tag，保留 dump、配置和 manifest。
3. 只有至少保留两个已验证 recovery runs、候选已 finalized 且超过保留窗，才使用 `--prune --apply`。禁止 `docker system prune`、宽泛删除或清理 Git dangling objects。
4. 失败、中断、归属不明或证据不完整的目录、镜像、卷、日志、分支和备份都保留并报告。

## 运行时脚本

- `scripts/plan-sub2api-upgrade.sh`：只读验证版本/上游基线并按 diff 生成矩阵计划。
- `scripts/wait-branch-image.sh`：等待精确 GitHub run，验证固定分支镜像 revision/digest。
- `scripts/check-debug-isolation.sh`：只读检查 debug 路径、镜像、端口、数据目录与生产隔离。
- `scripts/compute-debug-config-fingerprint.sh`：从稳定隔离字段、Compose 原文件、环境键集合和配置键路径计算非敏感指纹。
- `scripts/check-debug-fixture-manifest.sh`：校验合成 fixture、字段集规范哈希与敏感信息边界。
- `scripts/snapshot-debug-postgres.sh`：默认 dry-run，只向 debug snapshot 白名单建立 PostgreSQL 备份。
- `scripts/run-debug-matrix.sh`：可恢复地记录、复测、密封最终 SHA 的 debug 证据。
- `scripts/run-debug-adapter.sh`：按固定 allowlist 串行批跑或执行单 case，保存 checkpoint、截取 debug Compose UTC 日志并恢复未完成步骤。
- `scripts/verify-release-evidence.sh`：只读复核 sealed matrix、R0、证据/日志和绑定哈希。
- `scripts/verify-promoted-image.sh`：只读核验 promotion run/receipt，并可拉取 exact digest。
- `scripts/update-sub2api.sh`：生产预检、固定 SHA 镜像、应用专属 rollout、dump、验证和受限 image rollback。
- `scripts/finalize-sub2api-upgrade.sh`：列出 run、稳定后释放 rollback tag、受控保留清理。

运行脚本前用 `bash -n scripts/*.sh`。服务器禁止本地 Go/Node 构建、包管理器和 Docker build；GitHub Actions 与已发布 image metadata 才是构建证据。
