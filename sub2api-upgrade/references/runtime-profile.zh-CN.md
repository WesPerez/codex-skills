# Sub2API 运行时档案

此档案记录 2026-07-23 已核验的默认部署。每次升级必须重新检查，尤其是文档与实际配置发生冲突时以实时运行态为准。

| 项目 | 已知基线 | 升级控制 |
| --- | --- | --- |
| 源码仓库 | `/root/sub2api-repo` | 先读 `AGENTS.md` 和 `BRANCH_DEPLOYMENT.md`；禁止服务器本地构建。 |
| 生产部署 | `/root/sub2api-prod-deploy`，Compose project `sub2api-prod` | 只替换 `sub2api` 服务。 |
| 应用镜像 | Compose 浮动配置为 `ghcr.io/wesperez/sub2api:mine` | rollout 权威只接受 `mine-sha-<40>@digest`、成功 promotion receipt 和本地 sealed evidence；exact promotion 保留镜像内 `ref.name=debug`。 |
| 容器 | `sub2api-prod`、`sub2api-prod-postgres`、`sub2api-prod-redis` | 三者启动前后都应健康；不重建数据库或 Redis。 |
| 数据卷 | `./data/sub2api`、`./data/postgres`、`./data/redis` | 不执行 `compose down`，不删除/移动/覆盖这些目录。 |
| PostgreSQL | `postgres:18-alpine`，`PGDATA=/var/lib/postgresql/data` | `PGDATA` 遗失会造成空初始化风险；升级应用时不 pull PostgreSQL。 |
| Redis | `redis:8-alpine`，AOF 已开启 | 曾发生 AOF 尾部损坏；不升级、重建或清空 Redis。 |
| 内部应用 | `http://127.0.0.1:13080/health` | 期望 `{"status":"ok"}`。 |
| Router | 蓝绿槽 `codex-unified-router@13082/13083.service` | 从 `/etc/nginx/conf.d/codex-unified-router-upstream.conf` 解析当前活跃槽；`/health` 必须为 `status=ok` 且 `/ready` 必须为 `status=ready`。 |
| 公网入口 | Nginx `wooai.cc.cd` -> Router 当前槽 -> Sub2API `13080` | 用本机 `--resolve wooai.cc.cd:443:127.0.0.1` 验证实际 SNI 链路。 |
| 后台写入 | `sub2api-recovery.service`、`sub2api-metapi-balance-sync.timer` | 升级时读取状态并监控；不擅自停止共享任务。 |
| Watchtower | 运行态已见 `--disable-containers sub2api-prod` | 文档曾写为自动更新，实际状态优先；若无法证明已禁用本项目，拒绝手工 rollout 以避免竞态。 |
| Debug | `/root/sub2api-debug-deploy`，Compose project `sub2api-debug`，当前过渡端口 `127.0.0.1:13180` | 无活跃测试时容器停止；保留独立 `data/sub2api`、`data/postgres`、`data/redis` 作为连续升级合成数据骨架。启动前仍实时核验端口和隔离。 |

生产 Compose 里的 `AUTO_SETUP=true` 在已有数据库时预期幂等；若 DB host、数据库名或数据目录异常，可能走初始设置。因此 rollout 前必须验证现有 PostgreSQL 容器、数据目录和健康状态，并先建立 dump。

不读取、打印或复制 `.env` 中的密码、JWT、TOTP key、管理 key 或账号凭据。升级 run 可以把 `.env` 的权限受限快照与数据库 dump 一同保留作回滚证据，但不能在聊天、日志或参考文件中输出其内容。

旧分支镜像 workflow 对 `debug`、`mine` 各跑一轮完整 CI/build，近期成功 run 每轮约 11 分 36 秒到 12 分 24 秒。第一阶段优化的真实 debug run `29999790284` attempt 1 墙钟 8 分 56 秒：串行 unit/integration job 8 分 13 秒、并行 cache-only Docker build 4 分 07 秒、verify-gated publish 33 秒；同 SHA attempt 2 热跑墙钟 8 分 24 秒，Docker build 14 秒、publish recovery 29 秒、串行 unit/integration 7 分 46 秒。

最终候选 run `30001779447` 把原命令不变的 unit 与 integration 拆为两个必过并行 job，push 到 workflow 完成约 6 分 31 秒：unit job 5 分 19 秒（测试 step 5 分 11 秒）、integration job 4 分 06 秒（测试 step 3 分 56 秒）、cache-only build job 34 秒（build step 11 秒）、首次 publish 55 秒。integration 比串行 step 更慢，这与失去同 runner 的 unit 编译热身以及跨 run 冷启动、网络和 Testcontainers 波动一致，但仍被 unit 关键路径覆盖；总墙钟较第一阶段冷跑再省约 2 分 25 秒。当前长尾是不可跳过的 unit 测试；mine 改用 exact digest promotion 后不再重复整轮 CI/build。以上均为少量样本，不是固定 SLA，且并行会略增 runner 分钟。生产 dump 与应用切换近期约 17–21 秒，不能通过跳过验证转移风险。

2026-07-24 的 `0.1.164` 实际发布进一步验证了按 diff 收敛：候选 `61d5b363fe7cd370f73517973aec361303afb77f` 的 planner 从 catalog 44 例中选择 34 例，按未启用能力或未触发路径跳过 10 例；最终 34/34 通过。debug image 来源 run `30042473976`，promotion run `30065333387` 用 31 秒完成 exact digest carbon-copy；生产 run `upgrade-20260724T035638Z-61d5b363fe7c` 含 47,050,600 字节 PostgreSQL dump、应用 recreate 和运行态门禁约 45 秒。切换后官方 Codex `gpt-5.6-sol` 与 `grok-4.5` 各一次结构化 canary 均通过，阻断日志模式为 0。34/44 是该 diff 与当时 active inventory 的结果，不得固化成后续版本的固定数量。
