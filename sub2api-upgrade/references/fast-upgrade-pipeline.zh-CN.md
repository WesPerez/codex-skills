# Sub2API 快速升级流水线

## 目的与基线

历史审计表明，生产切换不是主要瓶颈：近期 5 次受控 apply（含约 39–42 MB PostgreSQL dump）约 17–21 秒。主要耗时是：

- 旧流程中 `debug` 与 `mine` 同一 SHA 各跑一次约 11–12 分钟 CI/镜像；
- 候选未一次成型导致的多轮 5–12 分钟失败 CI；
- 每次重建 debug 端口、TOTP、余额、账号配置和测试场景；
- fixture 假失败、版本基线倒退或漏测后再花数小时审计。

优化后的正常小版本升级以减少一轮 mine 构建、人工逐例和 fixture 重建为目标。2026-07-23 第一阶段真实 run `29999790284` 已验证：冷跑 8 分 56 秒、同 SHA 热跑 8 分 24 秒，旧成功 run 为 11 分 36 秒到 12 分 24 秒；cache-only Docker build 从 4 分 07 秒降到 14 秒，且始终与 CI 并行，publish 为 33/29 秒。最终候选 run `30001779447` 再把原命令不变的 unit 与 integration 拆成两个必过并行 job，push 到 workflow 完成约 6 分 31 秒；unit/integration job 分别为 5 分 19 秒和 4 分 06 秒，首次 publish 55 秒。当前关键路径是约 5 分钟的 unit，而不是 Docker 或 integration；这些只是少量样本，不承诺固定分钟数。时间目标只能由阶段打点更新，不能作为绕过门禁的 SLA。迁移、上游大改或真实回归必须以正确性为先。

2026-07-24 的 `0.1.164`（上一生产 `61d5b363fe7cd370f73517973aec361303afb77f`）按 diff 与 active inventory 选 34/44 且 34/34 通过。**必要耗时**约 CI 6.2m + promotion 31s + production 45s（约 47 MB dump）。同期浪费来自四候选重复 plan、默认 44 全开、空日志误判、release fault injection/临时 SQL 污染、无 debug 身份硬跑约 25 blocked、以及 5 次 matrix/约 31 份 manual evidence；planner/空日志修复与按 diff 34/44 已落地。提速点是一次成型、精确选例、同 SHA promotion、计划阶段窄化闭环和 apply 后立即 confirm，不是把 catalog 固化成另一个固定 case 数。

`0.1.165` 当前生产为 `322e2c9003afeffc3b5c7c2d6f61e5d02a22ee40`。本次选中 33/44 个 case，33/33 通过；CI run `30165679236` 约 9 分 42 秒，matrix seal 约 8 分 46 秒，promotion `30166630034` 42 秒，成功 apply 24 秒，apply→confirm 3 分 07 秒。plan 到 post-confirm 约 1 小时 41 分 26 秒，其中包含两次失败 apply、约 16 分钟业务中断、事故排查和人工 evidence 等待；这说明机械阶段已提速，但端到端墙钟仍受发布生命周期验证和人工证据影响。

以后需要完善：每个 run 写入 discovery/candidate/CI/debug/matrix/promotion/production/incident 的结构化起止时间；把 manual evidence 的“静态/合成 debug/真实 canary/切换后确认”类型单独统计；部署变更先完成隔离 Docker lifecycle probe，再进入 release seal；pool 行为另建 dev fault-injection 证据，不把正常成功请求当作错误路径证明。

## 证据生命周期

### 可跨升级复用

- 历史事故卡、运行时拓扑和职责到测试套件映射；
- debug 合成数据库、专属 canary 账号目录、非敏感 fixture manifest；
- 已确认的源码测试名、协议不变量、迁移 runner checksum 算法；
- 上一次稳定生产 revision、schema 与 recovery run 索引，仅作为比较基线。

### 仅同一候选 SHA 可复用

- GitHub CI run、固定镜像 tag/digest 和 OCI revision；
- L0/L1 自动测试结果；
- debug canary、日志时间窗、schema 升级与旧镜像兼容结果；
- 候选职责对照和 range-diff。

以下任一变化使相关证据失效：Git SHA、image digest、debug Compose/.env 非敏感指纹、schema、fixture manifest、canary 账号身份、官方 Codex 版本或 Router 候选版本。

### 必须实时

- 生产和 debug 容器/image ID、health/ready、Nginx 活跃槽、Watchtower 命令；
- 当前生产与候选 upstream baseline、`VERSION`、迁移集合和 checksum；
- 外部 provider canary、错误形状、日志、调度状态和旧镜像在新 schema 上的兼容性；
- 生产切换前 dump 和切换后的低风险 canary。

## 快速关键路径

### A. 候选一次成型

1. 主代理先刷新 refs、核生产 revision 并冻结 SHA；无新上游时 no-op，不派发空任务。
2. 按 [子代理编排](subagent-orchestration.zh-CN.md) 运行 Wave A：用最多 8 个只读代理并行审计上游、D1–D4、测试触发、运行事故和反向风险，全部 join 后由主代理写候选。
3. 先在本地完成职责对照、路径分类、迁移检查、`git diff --check`、版本/基线闸门和测试名映射。冻结 candidate SHA 后运行 Wave B 只读复核；主代理统一收敛一次。
4. 把所有已知修复 amend/fixup 回职责提交后再第一次推 `debug`。不用 GitHub CI 试错本可静态发现的语法、格式、未使用 import、职责遗漏或旧测试残留。

### B. CI 等待期间并行

推 `debug` 后并行执行：

- 唯一 CI waiter 用不带 `--pull` 的 `wait-branch-image.sh` 等精确 run；主代理在 join 后 `--no-wait --pull`；
- 只读代理核对 `check-debug-isolation.sh`、端口、fixture manifest、专属 canary 目录和 debug 快照位置；
- 只读代理核对选中 case、预期负例、日志时间窗需求和最终报告输入，不创建 matrix/evidence；
- 只读代理运行不触及数据库的生产 preflight，记录当前 revision/health/Watchtower；
- 主代理用最小只读汇总生成仅含 provider/feature 名称的 active inventory，不保存账号、凭据或业务明细；
- 主代理在 join 后生成 matrix、日志模板、职责表和回滚判定表。

子代理只做只读检查或 dry-run；生产 inventory、debug start/stop、snapshot apply、pull、matrix/evidence 写入仍由主代理完成。不要并行执行会争用同一 canary 账号、更新相同 fixture map、触发相同一次性 OAuth refresh 或共享日志断言的场景。等待期发现问题就停止旧 SHA，不边修改候选边继续等待。

### C. Debug 数据保留策略

保留 `/root/sub2api-debug-deploy/data/{sub2api,postgres,redis}`，无测试时只停止容器。这样下一次升级直接得到：

- 上一稳定版本真实迁移后的 schema；
- 历史合成用户、API key、分组、价格和非敏感账号配置；
- 可验证连续升级、旧数据读取、缓存兼容和后台任务启动行为的长期状态。

必须遵守：

1. 只保存合成用户/业务数据和 debug 专属 canary 凭据；禁止生产卷、生产 dump、生产日志、真实用户数据和与生产共享的 OAuth refresh 身份。
2. 为 fixture 建立非敏感 manifest：fixture 版本、对象稳定 ID、字段集合、header/proxy/model mapping 的哈希、预期余额范围、最后验证 schema。密钥值只留在权限受限的 debug 环境。
   `field_set_hash` 固定为：字段名排序后的 compact JSON（UTF-8）加一个 LF，再取 SHA-256；校验器必须重算，禁止占位 hash。
3. map 型更新提交完整非敏感字段；前后比较 manifest。缺字段导致的 403 先判 fixture 污染。
4. 每个候选启动前对 debug PostgreSQL 建自有快照；候选自动迁移后保留工作库作为下一次基线。恢复仅用于已证明的 debug 数据损坏，不能自动执行。
5. 空库全迁移由 CI integration 覆盖；debug 工作库负责连续升级与业务兼容。迁移变更时两者都必须通过。
6. Redis AOF 保留以覆盖真实升级兼容；需要冷缓存场景时使用任务专属隔离实例，不能随意 flush 长期 debug Redis。

### D. 两阶段复测

- **开发循环**：`R0 + 当前失败/受影响 case + 日志窗`，缩短定位周期。
- **发布门禁**：最终 SHA 的 `R0 + U/M diff 精确触发 case + 生产活跃能力 canary + 职责兜底 + 回滚演练 + 日志窗`。未启用能力留在 catalog，不为凑全场景执行。

**计划阶段身份闸门**：fixture 无 account 对象或活跃 provider 无 debug-only 身份时，在 plan 后立即进入合规窄化闭环，不先制造大量 blocked，也不复制生产凭据。闭环=精确 SHA CI + 同 SHA 合成协议/runtime + 生产只读 inventory/基线 + image rollback 证明 + 切换后每个活跃 provider 一次官方 Codex 有意义 canary（可复用同窗合规 evidence）。不适用于 migration/schema、认证写入或无法 image-only rollback 的变更。

**release 隔离**：`mode=release` 禁止 fault injection、临时 SQL 改库、Sub2API Test Connection。上述手段只允许独立 `mode=dev` 实验 run，其 attempt/日志/fixture 变更不得进入 seal、promotion 或生产 evidence。R0-1/R0-2 无业务日志不构成失败；R0-7 仍要求非空且归属明确的日志窗。生产 post-confirm 可把确实为空且无 fatal 的窗记录为 clean empty window，但不能拿它替代 debug R0-7。

使用 `run-debug-matrix.sh` 管理 attempt：失败或 blocked 后只有显式 `--new-attempt` 才能复测；running attempt 只能续接。release mode 的 passed case 必须带证据，R0-7/log executor 必须带日志窗，skip 必须说明原因。`run-ready` 在其他选中 case 未全部 passed/skipped 时延后 R0-7，单 case release `run` 也拒绝提前执行；补齐人工 evidence 后再跑一次。旧的 early-pass R0-7 会自动刷新，seal/verify 以 `log_window.until` 证明最终日志窗覆盖最后 passed canary。任何 commit 变化都必须重跑发布门禁。最终只接受 `seal` 生成且经 `verify-release-evidence.sh` 复核的 `release-evidence.json`。

用 `run-debug-adapter.sh run-ready` 代替逐条启动 runner。它对固定 debug 环境加跨 run 全局锁、按 plan 串行，把 R0-7 排到最后并在前置 case 未完成时保持 pending，再从 matrix state 恢复 running/pending/stale-final case；不会并发争用账号、fixture 或日志。adapter catalog 在 matrix init 时复制并绑定 hash；runner 不接收命令、URL、Compose 目录或服务名。每个 attempt 记录 `prepared -> executing -> adapter_done -> logs_done -> finished` checkpoint；`no_replay` 中断后 blocked，不自动重复生成或计费。

当前自动化状态必须如实报告：catalog 有 44 个可选场景，planner 默认只纳入 R0 与实际触发 case；只有 R0-1（身份）、R0-2（候选启动/健康/运行绑定）和 R0-7（致命日志模式扫描）已有自动 adapter。其余被选普通场景使用 `manual-verification`，被选的 R0-8/R1-M3 使用结构化回退证明。`run-ready` 返回 78 代表仍有人工门禁，不是成功。新增协议 adapter 前必须先有固定 debug fixture、确定性断言、no-replay 策略和测试；catalog 只有在脚本经过真实 debug 审计后才改回自动。

### E. 同 SHA 推进

`docker-branch.yml` 只构建 debug：full CI 与无 registry 权限的 cache-only build 并行；full CI 内 `make test-unit` 与 `make test-integration` 保持原覆盖口径，作为两个无依赖且都必过的 job 并行。只有全部 CI 与 build 成功，publish 才生成 `debug-sha-<40>`。失败候选只能写自己的 SHA cache；不可变镜像的 SLSA provenance 通过后，才把候选 layer cache 推进为 trusted cache。正式镜像启用 max provenance。

并行只允许停在完整 unit/integration job 边界。`internal/repository` integration 由包级 `TestMain` 共享一组 PostgreSQL/Redis testcontainers，且部分用例会执行 `TRUNCATE` 或真实写入；禁止再按文件/子集并行分片，也禁止在未改成独立数据库或强事务隔离前加入 `t.Parallel()`。大量无 build tag 测试会按现有 Go 语义在两条命令中重复执行，这是已知覆盖成本，不能为省时直接删掉一侧。

最终 debug 矩阵 sealed 后，`Promote Debug Image` 从 exact `debug-sha-<40>@digest` carbon-copy `mine-sha-<40>`、`mine-<12>`、`mine`，不重建、不改 labels。source/target digest 必须相同，所以 `ref.name=debug` 是正确的内容身份；mine 发布资格来自 source run artifact、promotion receipt 和 sealed evidence hash。生产 apply 必须重新读取本地 evidence 文件，不能只信 receipt 中的字符串。

新生产 apply 后**立即** `confirm-production-upgrade.sh`：传入每个 active provider 的官方 Codex 有意义 canary evidence（复用已有合规结果，非必要不重发），校验 provider 覆盖、日志窗、revision/digest/dump 与健康基线；通过后可 `--stop-debug`（只 stop 容器）。run 保持 `passed_pending_finalization` 与 rollback tag。默认 **24h**（`--min-age-minutes 1440`）后：`finalize-sub2api-upgrade.sh --list` → 目标 dry-run → `--apply`（要求 post-confirm passed）。后续成功版本上线后，对被当前生产 revision 取代的旧 pending run 用 `--retire-superseded [--min-age-hours 24] [--apply]`。禁止 `--min-age-minutes 0`。dump、配置快照和至少两个 recovery run 始终保留。

不可变 `debug-sha-<40>` 已存在时绝不覆盖。只有 BuildKit SLSA provenance、OCI index、attestation manifest 和 in-toto statement 的 subject/predicate/blob digest 共同证明内容来自本仓库 `Docker Branch Images` 的 debug/publish job、同一完整 SHA，才允许补发 metadata；这是结构化内容绑定，不宣称独立的 Sigstore 签名验证。artifact 同时记录原 publisher run 与本次成功验证 run，labels 单独不构成恢复依据。

## 时间打点

每次 evidence manifest 至少记录：

| 阶段 | 起止点 |
| --- | --- |
| discovery | 拉取 refs、Wave A 派发到全部 join/职责对照完成 |
| candidate | 开始语义重建、Wave B 复核到首次推 debug |
| ci_debug | push 到固定 debug image 通过 |
| debug_setup | isolation 检查到 fixture/snapshot 就绪 |
| matrix | 第一条 canary 到最终日志门禁 |
| promotion | sealed evidence 到 `mine-sha-<40>@digest` receipt 通过 |
| production | preflight/dump 到生产 canary 通过 |
| cleanup | debug stop 到 recovery run 收口计划完成 |

只用阶段数据优化下一轮；不要把用户 idle、真实故障定位或外部 provider 冷却混算成脚本耗时。

同时记录首次推送前的子代理数、候选 SHA 数、首次 CI 是否通过、selected/manual/blocked case 数和 apply→confirm 间隔。目标是减少候选轮次与人工返工，不是最大化代理数量。

## 失败即停的性能优化边界

可以优化：批量静态检查、CI 轮询、固定镜像验证、fixture 复用、场景选择、日志取窗、报告生成、稳定后 owner-marked 收口。

不能优化掉：语义去重判断、最终 SHA 完整 debug、真实协议 canary、迁移/回滚兼容、实时生产 preflight、dump、未解释错误定位和高风险生产授权。
