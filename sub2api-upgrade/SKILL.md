---
name: sub2api-upgrade
description: 安全升级此主机上的 Sub2API 至已验证的上游新版，语义重建 MINE 个性化差异并以上游实现优先处理重叠，再经 debug 充分验证和受控生产切换。用户说“更新sub2”“更新 Sub2API”“升级sub2”“同步 Sub2API 最新版”“升级到最新版本”或要求把 mine 个性化覆盖到新版时使用。覆盖上游同步、职责提交收敛、debug 验证、GitHub Actions 镜像、生产切换、回滚和本次产物收口；不用于账号导入、通用管理 API、K12/Grok OAuth、单独排障或纯源码审查。
---

# Sub2API 安全升级

将“不能导致问题”落实为失败即停止的门禁，不能承诺绝对零风险。用户只说“更新sub2”时，授权本技能执行已验证的正常生产升级、升级专属备份和本技能创建产物的收口；当前请求若明确指定“生产切换前停下”或其他停点，则以当前请求为准。历史会话用于提炼长期控制，不把某次会话的一次性停点或破坏性清理要求自动延续到以后。不授权数据库恢复、删除历史备份、重写已应用迁移、无 lease 强推或改写 `main`、修改生产账号配置、停止共享服务或清理归属不明资源。

先读取 [运行时档案](references/runtime-profile.zh-CN.md) 和 [历史事故与控制](references/historical-incidents.zh-CN.md)。再只读检索近期 Sub2API 升级及与本次个性化职责相关的故障会话，把新出现的真实失败模式加入本次矩阵；不要读取或输出生产数据、凭据。每次重新核验档案事实；档案是已知基线，不是绕过实时核验的依据。

## 不可跳过的门禁

以下任一项失败时，不改变生产环境，只报告阻塞证据和最小修复路径：

1. 无法证明目标是 `/root/sub2api-prod-deploy` 的 `sub2api-prod`，或当前生产基线的应用、PostgreSQL、Redis、Router、Nginx 健康检查不全绿。
2. `/root/sub2api-repo` 有未知工作区改动、`main` 不是干净上游镜像、`mine`/`debug` 的候选提交不清楚，或 GitHub Actions 没有对候选提交成功发布对应分支镜像。
3. debug 环境不存在、与生产不隔离、未通过与改动范围相符的真实 smoke 测试，或 debug 的镜像 revision 与待发布提交不一致。
4. 新增或修改迁移却没有验证过的 schema 兼容和回滚方案。任何已应用迁移文件的改写都直接停止，不修补 checksum，不合并历史迁移。
5. 无法证明旧应用镜像在目标 schema 上可安全回退。生产脚本只在此证明成立时接受 `--rollback-image-safe`。
6. Watchtower 实际状态、目标镜像来源、运行中写任务或生产数据卷边界不清楚。
7. 推进 `debug` 前没有完成逐职责语义对照，或推进 `mine`/生产前没有让最终候选 SHA 通过完整 debug 双向回归和日志门禁。

缺少 debug 环境不是“直接上 mine”的理由。可以修复或重建隔离 debug 环境，但不得复制生产凭据或未脱敏生产数据；隔离证明不足时不部署生产。

## 合并与提交纪律

升级不是把旧 `mine` 原样 rebase/cherry-pick 到新版。先以 `merge-base` 枚举旧 `mine` 的个性化逻辑提交，再为每个提交写出“核心职责 -> 旧实现 -> 新上游实现 -> 仍缺差异 -> 验证项”的可审计对照；没有完成对照不得推 `debug`：

1. 上游已经等价或更完整实现的部分一律采用上游，不重放旧补丁；部分重叠时只补上游缺失的行为和测试。账号级 header、proxy、模型映射或其他配置能够完整表达行为时优先配置，不新增硬编码补丁。任何旧实现优于上游的判断必须有源码和测试证据。
2. 保留原有个性化功能的职责边界，而不是保留每个旧 diff hunk。废弃、冲突或已无必要的旧代码应从候选中消失，并记录被哪个上游实现取代。
3. 不用一次性 merge、盲目 rebase 或连续 cherry-pick 代替语义审计。用独立候选分支重建差异，并以 `range-diff`、逐提交 diff 和测试矩阵复核没有漏功能或带回重复实现。
4. 个性化提交保持少量、稳定、可审计的逻辑提交。目标职责数为升级前逻辑职责数与 5 的较小值；旧职责超过 5 个时按相关核心内容收敛，少于 5 个时不为凑数拆分或新增提交。debug 中发现的修复必须 amend/fixup 回所属逻辑提交，最终 `debug`/`mine` 不留下零散“修复合并问题”提交。
5. `main` 必须精确等于已核验的 `upstream/main`，不包含部署文档、分支工作流或个性化代码；个性化只叠加在 `debug`/`mine` 候选上。
6. 语义重建导致候选不是旧 `debug`/`mine` 的 fast-forward 时，先核验远端旧 SHA，再只对目标分支使用精确 `--force-with-lease=refs/heads/<branch>:<verified-old-sha>`。禁止裸 `--force`，禁止用过期 lease 覆盖并发更新，禁止改写 `main`；`mine` 只能改写为已经在 `debug` 完整验证的完全相同 SHA。

## 标准流程

### 1. 建立发布候选

1. 在 `/root/sub2api-repo` 读取 `AGENTS.md`、`BRANCH_DEPLOYMENT.md` 和本次改动关联源码/测试。
2. 仅用只读 Git 检查确认 `origin`、`upstream`、工作树、`main`、`mine`、`debug` 和候选 commit。保留用户已有改动；不要用 `reset --hard`、无证据的 `checkout` 或强推来“同步”。
3. 将 `main` 快进为纯 `upstream/main` 镜像；按“合并与提交纪律”逐职责重建个性化候选，不把旧提交机械重放到新上游。
4. 检查候选差异中的迁移、Compose、路由、协议转换、provider 适配、Redis/PostgreSQL 行为和后台任务。新迁移只能新增，不能改写已部署文件。
5. 把候选先推到 `debug`，等待该 commit 的 `Docker Branch Images` 成功。不得在服务器构建、下载依赖、运行包管理器或构建 Docker 镜像。

### 2. 在 debug 完成与改动相符的验证

本项目历史语境中用户口述的“第八个分支”即 `debug` 隔离验证分支；若实时分支布局与此不符，先核验映射，不能跳过隔离验证。

1. 只从 `ghcr.io/wesperez/sub2api:debug` 拉取 debug 应用镜像，保持 debug 的数据库、Redis、端口、数据目录、凭据和网络与生产隔离。
2. 记录 debug 容器 image revision、启动前后 schema 版本和测试结果。debug 需要生产形态数据时使用最小化脱敏副本，不能挂载生产卷。测试前快照合成 fixture 的非敏感配置；更新 map 型账号配置时提交完整非敏感字段，测试后验证或恢复 fixture，避免把测试数据损坏误判为候选缺陷。
3. 始终验证启动/迁移日志无未解释错误、`/health`、登录/鉴权路径、账号与分组读取、最小真实 Responses 请求、流式请求和受影响分组的 canary。没有配置的可审计 canary 时，不能以“看起来容器正常”代替测试。
4. 按改动补充矩阵：
   - Grok/tools：覆盖 custom、namespace、tool_search 的流式/非流式双向转换，以及 `tools` 被转换或删除后仍带 `tool_choice` 的请求，确认不会把孤立 `tool_choice` 发到上游；涉及图片桥或近期识图故障时增加真实 vision/multimodal canary。
   - Codex/SharedChat：覆盖完整 `/codex/responses`、所需 client metadata/header、非流式聚合、流式、compact、`reasoning.effort=max` 映射、HTTP/1.1 和账号级代理；实际网关请求、后台 Responses probe 和管理员账号测试三条路径都必须命中同一身份与传输策略。
   - OpenAI Responses：覆盖不支持参数的过滤或明确透传策略，不能把客户端参数错误误归因于 Sub2API。
   - 迁移：在隔离库演练升级和候选前镜像回退，确认数据、账号和任务状态兼容。
5. 执行双向回归：逐个证明所有保留的个性化职责确实生效，并证明其触达的上游核心流程仍按本次目标上游基线工作。至少覆盖普通 OpenAI Chat/Responses、流式/非流式、鉴权、调度/错误透传、已配置 provider canary；前端、后台任务或计费被差异触及时扩展对应场景。
6. 对每个“由上游取代”的旧行为，用上游测试、候选 CI 或 debug 运行证据确认等价，而不是仅凭代码看起来相似。预先列出故意触发的负例及其时间窗、预期状态码和日志；检查候选启动后及 canary 时间窗内的日志，区分这些已解释负例与候选故障。任何 panic、迁移失败、5xx、非预期 4xx、协议异常或未被负例解释的新增 error 日志都必须定位、修复并重测，不能作为“偶发”忽略。
7. 任何 debug 失败先修复，把修复收回所属逻辑提交，重建相同候选镜像并从头重跑相关矩阵；不得把“修复后未测”或只测临时 commit 的结果推进 mine。最终候选 SHA 的完整 debug 双向回归和日志门禁全部通过前，禁止推 `mine` 或切换生产。无法承诺外部服务永不故障，但发布时必须做到没有已知、未解释的候选错误。

### 3. 推进已验证版本

1. 将经过完整 debug 验证的完全相同 commit 推进 `mine`；等待该 commit 的 `Docker Branch Images` 成功，确认 GHCR `mine` image label `org.opencontainers.image.revision` 等于完整 Git SHA。若为收敛提交而重写过候选 SHA，旧 debug 结果全部失效，必须重新构建和验证新 SHA。
2. 稳态让 `debug` 与 `mine` 指向同一 commit。debug 专属实验提交、临时工作树和镜像只在当前测试结束且不再需要时收口。
3. 生产切换前读取当前服务状态、镜像 ID/revision、数据卷、Watchtower 实际命令、后台写任务状态，并建立单次 PostgreSQL 自定义格式 dump。不要回显 `.env`、token、数据库密码或 dump 内容。本机 Codex 或当前会话可能依赖生产 Sub2API 链路时，把应用 recreate 放到所有远端构建、debug 验证和回滚准备完成后的最后一步，避免中途切断自身控制链路。
4. 仅在已验证旧应用可回退时执行：

```bash
cd /root/.codex/skills/sub2api-upgrade
bash scripts/update-sub2api.sh \
  --apply \
  --expected-revision <40-char-git-sha> \
  --rollback-image-safe
```

该脚本只会 `pull sub2api` 和 `up -d --no-deps sub2api`。它拒绝全量 `docker compose pull`、`compose down`、本地构建、debug 镜像、`latest`、PostgreSQL/Redis 升级和来源不明的镜像。默认调用不带 `--apply` 时只预检。

### 4. 生产验证与回退

1. 生产脚本等待应用容器健康，并验证 `127.0.0.1:13080/health`、从 Nginx named upstream 实时解析出的 Router 活跃槽（`13082`/`13083`）`/ready`，以及经本机 Nginx/SNI 的 `https://wooai.cc.cd/ready`；不得把蓝绿槽中的某一个端口写死。
2. 再运行已在 debug 通过的低风险 canary。验证失败时脚本只会在已明确证明 image rollback 兼容时回退应用镜像；绝不自动 restore PostgreSQL。
3. 数据库恢复、配置变更、删除账号、停共享任务或任何涉及真实上游写入的补救操作需要单独明确授权和自己的恢复方案。
4. 结果至少报告：候选 SHA、CI run、旧/新 image revision、dump 路径与 sha256、健康检查、canary、是否回退和仍在等待的收口项。

## 升级后收口

把可回滚证据视为恢复资产，不把它当垃圾：

1. debug 是由本次升级启动的，且没有活跃测试时，停止该 debug Compose 项目；不停止归属不明的 debug、Router、Nginx、数据库或任务服务。
2. 生产稳定窗口结束后，使用 `scripts/finalize-sub2api-upgrade.sh --run-id <run-id> --apply`。它会重新验证当前 revision/健康状态，只删除该 run 创建且无容器引用的 rollback image tag，保留 dump、配置快照和审计记录。
3. 仅在至少保留两个已验证 recovery runs、候选 run 已 finalized 且超过保留窗口后，使用该脚本的 `--prune --apply` 删除带本技能 owner marker 的旧 run。不要使用 `docker system prune`、宽泛 `find -delete`、按名称猜测清理或删除现有 `/root/backups/sub2api` 内容。
4. 任何因失败、中断或归属不明而留下的目录、镜像、卷、日志、分支、GitHub run 或备份都保留并报告；先查归属，再决定处置。

## 运行时脚本

- `scripts/update-sub2api.sh`：生产预检、应用专属 rollout、PostgreSQL 回滚点、验证和受限 image rollback。
- `scripts/finalize-sub2api-upgrade.sh`：稳定后释放本 run 的 rollback tag，并以默认 dry-run 规划受控保留清理。

运行脚本前用 `bash -n scripts/*.sh`。不要为了“验证”在服务器运行本仓库的 Go/Node 构建或测试；CI 和已发布 image metadata 才是服务器上的构建证据。
