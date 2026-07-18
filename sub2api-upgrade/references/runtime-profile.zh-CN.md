# Sub2API 运行时档案

此档案记录 2026-07-18 已核验的默认部署。每次升级必须重新检查，尤其是文档与实际配置发生冲突时以实时运行态为准。

| 项目 | 已知基线 | 升级控制 |
| --- | --- | --- |
| 源码仓库 | `/root/sub2api-repo` | 先读 `AGENTS.md` 和 `BRANCH_DEPLOYMENT.md`；禁止服务器本地构建。 |
| 生产部署 | `/root/sub2api-prod-deploy`，Compose project `sub2api-prod` | 只替换 `sub2api` 服务。 |
| 应用镜像 | `ghcr.io/wesperez/sub2api:mine` | 仅接受成功 CI 发布且 label revision 匹配候选 SHA 的 image。 |
| 容器 | `sub2api-prod`、`sub2api-prod-postgres`、`sub2api-prod-redis` | 三者启动前后都应健康；不重建数据库或 Redis。 |
| 数据卷 | `./data/sub2api`、`./data/postgres`、`./data/redis` | 不执行 `compose down`，不删除/移动/覆盖这些目录。 |
| PostgreSQL | `postgres:18-alpine`，`PGDATA=/var/lib/postgresql/data` | `PGDATA` 遗失会造成空初始化风险；升级应用时不 pull PostgreSQL。 |
| Redis | `redis:8-alpine`，AOF 已开启 | 曾发生 AOF 尾部损坏；不升级、重建或清空 Redis。 |
| 内部应用 | `http://127.0.0.1:13080/health` | 期望 `{"status":"ok"}`。 |
| Router | 蓝绿槽 `codex-unified-router@13082/13083.service` | 从 `/etc/nginx/conf.d/codex-unified-router-upstream.conf` 解析当前活跃槽；`/health` 必须为 `status=ok` 且 `/ready` 必须为 `status=ready`。 |
| 公网入口 | Nginx `wooai.cc.cd` -> Router 当前槽 -> Sub2API `13080` | 用本机 `--resolve wooai.cc.cd:443:127.0.0.1` 验证实际 SNI 链路。 |
| 后台写入 | `sub2api-recovery.service`、`sub2api-metapi-balance-sync.timer` | 升级时读取状态并监控；不擅自停止共享任务。 |
| Watchtower | 运行态已见 `--disable-containers sub2api-prod` | 文档曾写为自动更新，实际状态优先；若无法证明已禁用本项目，拒绝手工 rollout 以避免竞态。 |
| Debug | `/root/sub2api-debug-deploy`；旧文档 `13082/13083` 与 Router 蓝绿槽冲突 | 使用独立 loopback 端口 `13180`，并保持数据库、Redis、目录、凭据和网络与生产隔离；启动前仍用 `ss` 实时核验。 |

生产 Compose 里的 `AUTO_SETUP=true` 在已有数据库时预期幂等；若 DB host、数据库名或数据目录异常，可能走初始设置。因此 rollout 前必须验证现有 PostgreSQL 容器、数据目录和健康状态，并先建立 dump。

不读取、打印或复制 `.env` 中的密码、JWT、TOTP key、管理 key 或账号凭据。升级 run 可以把 `.env` 的权限受限快照与数据库 dump 一同保留作回滚证据，但不能在聊天、日志或参考文件中输出其内容。
