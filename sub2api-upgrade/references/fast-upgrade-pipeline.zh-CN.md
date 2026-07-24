# Sub2API 快速升级流水线

## 目的与基线

历史审计表明，生产切换不是主要瓶颈：近期 5 次受控 apply（含约 39–42 MB PostgreSQL dump）约 17–21 秒。主要耗时是：

- 旧流程中 `debug` 与 `mine` 同一 SHA 各跑一次约 11–12 分钟 CI/镜像；
- 候选未一次成型导致的多轮 5–12 分钟失败 CI；
- 每次重建 debug 端口、TOTP、余额、账号配置和测试场景；
- fixture 假失败、版本基线倒退或漏测后再花数小时审计。

优化后的正常小版本升级以减少一轮 mine 构建、人工逐例和 fixture 重建为目标。2026-07-23 第一阶段真实 run `29999790284` 已验证：冷跑 8 分 56 秒、同 SHA 热跑 8 分 24 秒，旧成功 run 为 11 分 36 秒到 12 分 24 秒；cache-only Docker build 从 4 分 07 秒降到 14 秒，且始终与 CI 并行，publish 为 33/29 秒。最终候选 run `30001779447` 再把原命令不变的 unit 与 integration 拆成两个必过并行 job，push 到 workflow 完成约 6 分 31 秒；unit/integration job 分别为 5 分 19 秒和 4 分 06 秒，首次 publish 55 秒。当前关键路径是约 5 分钟的 unit，而不是 Docker 或 integration；这些只是少量样本，不承诺固定分钟数。时间目标只能由阶段打点更新，不能作为绕过门禁的 SLA。迁移、上游大改或真实回归必须以正确性为先。

2026-07-24 的 `0.1.164` 发布按实际 diff 与生产活跃能力选择 34/44 个 case，最终 34/34 通过；未启用或未触发的 10 例留在 catalog 而不执行。exact digest promotion 用 31 秒，生产阶段含约 47 MB dump 与应用切换约 45 秒。该结果证明提速点是精确选例、同 SHA promotion 和保留 debug 骨架，不是把全 catalog 改成另一个固定 case 数。

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

1. 同时读取上游新增提交、旧个性化职责、当前生产 revision 和部署约束。
2. 先在本地完成职责对照、路径分类、迁移检查、`git diff --check`、版本/基线闸门和测试名映射。
3. 把所有已知修复 amend/fixup 回职责提交后再第一次推 `debug`。
4. 不用 GitHub CI 试错本可静态发现的语法、格式、未使用 import 或旧测试残留。

### B. CI 等待期间并行

推 `debug` 后并行执行：

- `wait-branch-image.sh` 等精确 run；
- `check-debug-isolation.sh` 与端口检查；
- 生成本次矩阵、预期负例和日志时间窗模板；
- 核对合成 fixture manifest、专属 canary 目录和 debug 快照位置；
- 运行只读生产 preflight，记录当前 revision/health/Watchtower；
- 用最小只读汇总生成仅含 provider/feature 名称的 active inventory，不保存账号、凭据或业务明细；
- 准备最终报告的职责表和回滚判定表。

不要并行执行会争用同一 canary 账号、更新相同 fixture map、触发相同一次性 OAuth refresh 或共享日志断言的场景。

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

生产活跃 provider 没有 debug-only 身份时，不复制生产凭据。切换前使用精确 SHA CI、同 SHA 合成协议/runtime、生产只读 inventory、切换前基线和 image rollback 证明；切换后对每个活跃 provider 各做一次受控 canary。此闭环不适用于 migration/schema、认证写入或无法 image-only rollback 的变更。

使用 `run-debug-matrix.sh` 管理 attempt：失败或 blocked 后只有显式 `--new-attempt` 才能复测；running attempt 只能续接。release mode 的 passed case 必须带证据，R0-7/log executor 必须带日志窗，skip 必须说明原因。任何 commit 变化都必须重跑发布门禁。最终只接受 `seal` 生成且经 `verify-release-evidence.sh` 复核的 `release-evidence.json`。

用 `run-debug-adapter.sh run-ready` 代替逐条启动 runner。它对固定 debug 环境加跨 run 全局锁、按 plan 串行、把 R0-7 放到最后，并从 matrix state 恢复 running/pending case；不会并发争用账号、fixture 或日志。adapter catalog 在 matrix init 时复制并绑定 hash；runner 不接收命令、URL、Compose 目录或服务名。每个 attempt 记录 `prepared -> executing -> adapter_done -> logs_done -> finished` checkpoint；`no_replay` 中断后 blocked，不自动重复生成或计费。

当前自动化状态必须如实报告：catalog 有 44 个可选场景，planner 默认只纳入 R0 与实际触发 case；只有 R0-1（身份）、R0-2（候选启动/健康/运行绑定）和 R0-7（致命日志模式扫描）已有自动 adapter。其余被选普通场景使用 `manual-verification`，被选的 R0-8/R1-M3 使用结构化回退证明。`run-ready` 返回 78 代表仍有人工门禁，不是成功。新增协议 adapter 前必须先有固定 debug fixture、确定性断言、no-replay 策略和测试；catalog 只有在脚本经过真实 debug 审计后才改回自动。

### E. 同 SHA 推进

`docker-branch.yml` 只构建 debug：full CI 与无 registry 权限的 cache-only build 并行；full CI 内 `make test-unit` 与 `make test-integration` 保持原覆盖口径，作为两个无依赖且都必过的 job 并行。只有全部 CI 与 build 成功，publish 才生成 `debug-sha-<40>`。失败候选只能写自己的 SHA cache；不可变镜像的 SLSA provenance 通过后，才把候选 layer cache 推进为 trusted cache。正式镜像启用 max provenance。

并行只允许停在完整 unit/integration job 边界。`internal/repository` integration 由包级 `TestMain` 共享一组 PostgreSQL/Redis testcontainers，且部分用例会执行 `TRUNCATE` 或真实写入；禁止再按文件/子集并行分片，也禁止在未改成独立数据库或强事务隔离前加入 `t.Parallel()`。大量无 build tag 测试会按现有 Go 语义在两条命令中重复执行，这是已知覆盖成本，不能为省时直接删掉一侧。

最终 debug 矩阵 sealed 后，`Promote Debug Image` 从 exact `debug-sha-<40>@digest` carbon-copy `mine-sha-<40>`、`mine-<12>`、`mine`，不重建、不改 labels。source/target digest 必须相同，所以 `ref.name=debug` 是正确的内容身份；mine 发布资格来自 source run artifact、promotion receipt 和 sealed evidence hash。生产 apply 必须重新读取本地 evidence 文件，不能只信 receipt 中的字符串。

新生产 run 通过后先保持 `passed_pending_finalization` 和 rollback image tag。立即完成 debug stop、证据落盘和实时复核，但不要用 `--min-age-minutes 0` 绕过稳定窗口；达到既定最小年龄后再按 `finalize-sub2api-upgrade.sh --list`、目标 run dry-run、`--apply` 的顺序释放 rollback tag。数据库 dump、配置快照和至少两个 recovery run 始终保留。

不可变 `debug-sha-<40>` 已存在时绝不覆盖。只有 BuildKit SLSA provenance、OCI index、attestation manifest 和 in-toto statement 的 subject/predicate/blob digest 共同证明内容来自本仓库 `Docker Branch Images` 的 debug/publish job、同一完整 SHA，才允许补发 metadata；这是结构化内容绑定，不宣称独立的 Sigstore 签名验证。artifact 同时记录原 publisher run 与本次成功验证 run，labels 单独不构成恢复依据。

## 时间打点

每次 evidence manifest 至少记录：

| 阶段 | 起止点 |
| --- | --- |
| discovery | 拉取 refs 到职责对照完成 |
| candidate | 开始语义重建到首次推 debug |
| ci_debug | push 到固定 debug image 通过 |
| debug_setup | isolation 检查到 fixture/snapshot 就绪 |
| matrix | 第一条 canary 到最终日志门禁 |
| promotion | sealed evidence 到 `mine-sha-<40>@digest` receipt 通过 |
| production | preflight/dump 到生产 canary 通过 |
| cleanup | debug stop 到 recovery run 收口计划完成 |

只用阶段数据优化下一轮；不要把用户 idle、真实故障定位或外部 provider 冷却混算成脚本耗时。

## 失败即停的性能优化边界

可以优化：批量静态检查、CI 轮询、固定镜像验证、fixture 复用、场景选择、日志取窗、报告生成、稳定后 owner-marked 收口。

不能优化掉：语义去重判断、最终 SHA 完整 debug、真实协议 canary、迁移/回滚兼容、实时生产 preflight、dump、未解释错误定位和高风险生产授权。
