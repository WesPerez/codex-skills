# Grok refresh-revoked 精确处置快速路径

## 目录

- 适用场景
- 先解释现象
- 路径选择
- 一次性冻结范围
- 标准执行顺序
- 删除语义
- 探针与最终烟测
- 完成条件

## 适用场景

用于“Grok 账号突然少一批”“refresh 失败后自动暂停”“删除不可恢复账号、恢复有材料账号”等明确的 OAuth 生命周期任务。目标是一次冻结证据、一次备份、逐 ID 处置，不重复全量探针或临时编写 one-shot。

## 先解释现象

`access_token` 实测约 6 小时，Sub2API 会在距离过期至少 1 小时时进入 refresh，并默认约每 5 分钟扫描一次。相近时间 mint/import 的账号会在同一刷新波进入检查，因此 UI 可能在几分钟内同时减少。

`refresh_token` 不会按 6 小时自然过期。决定性直接原因必须是 `invalid_grant`、`Refresh token has been revoked` 或等价 refresh-revoked 证据。出现这类结果后，Sub2API 会写 `status=error + schedulable=false`；usage 查询可能把 status 暂时清回 active，但不会恢复 schedulable，因此候选集合必须从不可变审计快照读取，不能随着 UI 抖动重新计算。

先区分“成员真的少了”和“可用数变少”：pause、temporary unschedulable、rate limit 或 `status=error` 会让分组的 active/available 数下降，但不会自动解除 `account_groups` 绑定；只有 Admin DELETE、明确重绑组或软删除会让成员总数下降。审计时同时记录 group total、available、error 和 unschedulable，避免把 UI 的 active 过滤误判为账号被删。

能确认的是“旧 refresh 链被 xAI 拒绝”；仅凭该结果不能断言账号被封。更深层来源按证据检查：

1. 旧 auth 是否绕过 bridge 覆盖了数据库新 refresh。
2. 是否有第二个客户端或 cron 自行 refresh，轮换后未回写 Sub2API。
3. 上游 refresh 成功后，本地 CAS/持久化是否失败。
4. xAI 是否发生服务端批量 revoke 或安全策略变更。

没有 token hash、`_token_version`、bridge push 和刷新日志对照时，将 1–4 保持为假设。

特别识别 `timeout × N → temp_unschedulable → 下一周期 permanent/revoked`：这表示一次 refresh 结果不确定。较强但仍非决定性的解释是 xAI 已处理某次超时请求并轮换 refresh token，而响应未返回或新 token 未持久化；下一周期继续使用旧 token 后得到 revoked。将此类事件标记为 `ambiguous_refresh_rotation`，不要在没有上游 request ID、token-version 或写入日志时改写成“确定被旧 auth 覆盖”或“账号被封”。

## 路径选择

- 账号已存在、refresh revoked 且保留 email/password/SSO：选择本快速路径的协议 remint。默认不启用 Playwright，也不依赖 `Xvfb :99`；只有协议失败后明确加 `--playwright-fallback` 时才进入 headless 浏览器兜底。
- 已建上游号但从未生成 auth：才使用项目 `recover_batch_oauth.py`。
- 已有 revoked auth：不要运行 `recover_batch_oauth.py`，它会因已有 `cliproxyapi_auth` 跳过。
- 不要对 remint 后的新 token 运行 `register_and_import.py --resume`；该路径按 access-token hash 判断已存在，token 改变后可能创建重复账号。

## 一次性冻结范围

1. 发现 systemd 实际 env，锁定 production、Sub2API base、PostgreSQL 容器和 Grok group；排除并存的 debug 栈。
2. 使用最近的脱敏审计快照固定 `refresh_revoked` ID，不调用 Test Connection 来生成候选。
3. 将候选分成互斥集合：
   - `delete.candidate_ids`：无 email/password/SSO/可收信邮箱等恢复能力。
   - `recover.candidate_ids`：每个 ID 唯一映射到一个受限 result 文件，且 email/password/SSO 完整，可直接走 helper。
   - 只有可收信邮箱但还需密码重置的账号另列待恢复，既不进入本 helper 的直接 recover，也不得进入 delete。
4. 从 [manifest 模板](../assets/revoked-recovery-manifest.template.json) 创建 `private/runs/<batch-id>/manifest.json`，记录 source path/hash、目标组、两组 ID 和恢复材料路径。目录 `0700`，文件 `0600`。
5. 对 live 数据只做一次精确 preflight：platform=`grok`、type=`oauth`、只绑目标组、删除候选不可调度、恢复身份按 email/sub 唯一解析到预期原 ID。revoked 行允许为 `error`，也允许因 usage 清错抖回 `active`，但此时仍必须 `schedulable=false`。

显示名可能带排序前缀，不能只按稳定名称 `grok_<email>` 查找。bridge 必须以唯一 email 或 subject 锁定原 ID、歧义即停，并保留现有显示名。

## 标准执行顺序

在技能目录运行正式 helper。`validate` 只读访问生产状态，但会在批次目录写入绑定审计分区、候选 ID、材料 hash 和代理证据的 `validate-results.json`；`status` 完全只读。所有生产写相都要求显式确认：

```bash
python3 scripts/reconcile_revoked.py \
  --project-dir /root/grok-build-auth \
  --batch-dir /root/grok-build-auth/private/runs/<batch-id> \
  --phase validate

python3 scripts/reconcile_revoked.py \
  --project-dir /root/grok-build-auth \
  --batch-dir /root/grok-build-auth/private/runs/<batch-id> \
  --phase backup --confirm-production-write

python3 scripts/reconcile_revoked.py \
  --project-dir /root/grok-build-auth \
  --batch-dir /root/grok-build-auth/private/runs/<batch-id> \
  --phase delete --confirm-production-write
```

先选 1 个映射证据最硬的账号做 canary：

```bash
python3 scripts/reconcile_revoked.py \
  --project-dir /root/grok-build-auth \
  --batch-dir /root/grok-build-auth/private/runs/<batch-id> \
  --phase remint --account-id <canary-id> --proxy-ref <healthy-ref> \
  --confirm-production-write
```

canary 必须同时满足：

- 新 auth 的 email/subject 与原账号一致。
- bridge 返回 `action=updated`，且 `account_id` 等于目标 ID。
- 写入前结构化 `/responses` preprobe 通过。
- bridge 候选保持隔离，先清旧 revoked error，再执行 Sub2API 生成的语义 postprobe。
- bridge 只在 `usable` 或 `usable_exhausted` 后临时 promote；helper 收到成功结构化证据后立即再次设为 `schedulable=false`，等待批量收口。
- live email/sub 仍各只有一行；现有显示名不被重置。

canary 成功后串行逐 ID remint。不要并发；瞬时 mint 失败最多换一个已验证健康出口重试一次。OAuth 已写入受限 auth、但 bridge 调用前出现瞬时失败时落为 `minted_pending_push`，重跑同一命令校验 path/hash/身份后直接续 push，不再次 mint。bridge 已成功但 helper 后置校验失败时再次隔离并落为 `postcheck_failed_isolated`，修正瞬时条件后重跑同一命令只做后置续核。bridge 返回不确定结果时先按 ID/token hash 对账，禁止盲目重推。若 helper 检测到本任务意外创建重复账号，只能精确删除返回的 created ID，并保留原账号。

helper 对同一批次使用非阻塞文件锁；`validate/backup/delete/remint/reverify` 任一阶段正在运行时，第二个写相会直接拒绝，避免并发 remint 或结果文件互相覆盖。

协议 remint 明确失败且需要浏览器兜底时，只对该 ID 追加 `--playwright-fallback` 重试；不要为了常规协议路径预先启动 Xvfb 或切换到整套 `server-client-full`。

全部 remint 完成后统一执行：

```bash
python3 scripts/reconcile_revoked.py \
  --project-dir /root/grok-build-auth \
  --batch-dir /root/grok-build-auth/private/runs/<batch-id> \
  --phase reverify --confirm-production-write

python3 scripts/reconcile_revoked.py \
  --project-dir /root/grok-build-auth \
  --batch-dir /root/grok-build-auth/private/runs/<batch-id> \
  --phase status
```

bridge 在每次 remint 内已经固定完成 `schedulable=false → clear-error → 语义指定账号 test → usable/quota 后 promote`，helper 随即重新隔离并保存 availability。批量 `reverify` 只验证所有 ID 均有 `action=updated + probe=passed`、身份/组/base URL/error 均精确，再逐号 promote；不得立即重复 Test Connection。任一失败只重新隔离当前账号，后续账号仍保持隔离，修复后可断点续跑。

## 删除语义

1. 写前只建立一次 PostgreSQL custom-format dump，执行 `pg_restore -l` 并记录 SHA256；`backup-results.json` 必须与 manifest 的 path/hash/bytes 一致。已有恢复点重复执行 backup 时仍重跑 `pg_restore -l`，不重复 `pg_dump`。
2. 逐 ID 调用 `DELETE /api/v1/admin/accounts/{id}`，随后 GET 必须为 404；任一偏离立即停止。
3. Admin DELETE 是软删除账号行并清除组绑定，不删除 Mailu 邮箱或本地恢复材料。
4. 删除 Sub2API 账号、邮箱和 auth 文件是三类独立授权。

helper 断点续跑时先对已有成功删除记录逐 ID 复核 GET 404，只查询和删除剩余 live ID；不会因为部分 ID 已软删除而要求重新生成整批。

## 探针与最终烟测

- 不使用 `hi`、固定单词或 exact-reply。直接 preprobe 使用带自然变化的结构化解析/计算任务并做语义断言。
- 只有用户明确授权账号恢复/故障复现时才执行 Sub2API 指定账号 test；它不是日常心跳。必须使用服务器生成的语义 probe，其结果 402/429 仍算凭据可用。
- 最终 Grok 分组烟测使用当前安装的官方 Codex CLI，保留真实客户端请求头。对 `grok-4.5` 显式使用 `model_reasoning_effort="high"`；全局 `ultra` 会被 xAI 拒绝。
- 最终成功证据必须在 Sub2API 日志中同时看到目标 Grok group、provider=`grok`、恢复账号 ID、HTTP 200 和无 Router fallback。仅看 Codex 最终输出成功不够，因为它可能来自 OpenAI fallback。

## 完成条件

- 删除集合全部 GET 404，组绑定为 0。
- 恢复集合全部 `action=updated`，没有 created/重复身份；remint 阶段全部为 `recovered_isolated`，reverify 后才全部开启调度。
- 每个恢复账号为 active、唯一目标组、官方 base URL、旧 error_message 清空。
- schedulable 标志只在指定账号测试通过后开启；quota 账号保留当前 cooldown。
- manifest、delete/remint/reverify 结果和 Codex smoke 均脱敏落盘；备份保留状态明确。
- bridge/recovery helper 测试通过，常驻 bridge 健康，无本任务残留进程。
