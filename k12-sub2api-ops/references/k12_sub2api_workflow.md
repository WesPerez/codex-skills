# K12/Sub2API 完整工作流

端到端处理 K12/OpenAI OAuth 账号包时使用此文档。它负责流程和工具选择；格式细节、额度语义、远程 API 和主机侧运维分别由同目录其他 reference 负责。

## 目录

- 任务类型与来源盘点
- 转换工具与身份规则
- Recommended、Full 和额度
- 远程/主机侧导入
- Kit、替换、清理和报告

## 1. 先确定任务类型

- 只盘点、转换或比较账号包：纯离线，不连接 Sub2API。
- 查询还有多少账号有额度：只调用 ChatGPT quota GET，不生成内容、不写库。
- 远程或跨机导入：只有 Admin HTTP API，没有本机 Docker/Postgres 权限。
- 主机侧导入：Codex 位于 Sub2API 主机，可使用 Docker/Postgres、备份和精确绑组。
- 论坛找 workspace ID、浏览器 exchange 验证、数据库 space 统计：退出本技能，使用 SKILL.md 指定的独立技能。

## 2. 接收与盘点来源

对每个输入记录：

1. 路径、容器格式、大小、修改时间和 SHA-256。
2. README/manifest 中与 refresh、recommended、分批或密码相关的说明；不要在最终答复泄露密码。
3. 文档类型、账号记录数、缺失 token、plan 分布、expires 格式和 platform/type。
4. 唯一 token hash、邮箱、账号上下文和 workspace ID 数量；workspace ID 只作诊断。
5. 是否含多个来源组、低可信组、旧批次或明显无效条目。

优先运行：

```bash
python3 scripts/k12_bundle_tool.py inspect <path>
```

ZIP 扩展名可能实际是 RAR；以 `file` 和实际解析结果为准，不按文件名猜测。

## 3. 选择转换工具

### 通用工具

使用 `k12_bundle_tool.py` 处理：

- 单个 JSON/TXT、JSON list、Sub2API export；
- 单账号 CPA/Codex ZIP 或 RAR；
- 未知包的 inspect；
- ISO `expires_at` 归一化；
- 从 Codex session JSONL 提取用户粘贴的 bundle；
- candidate 与 existing export 的强标识比较。

```bash
python3 scripts/k12_bundle_tool.py convert <input> --output <bundle.json>
```

### 多 CPA ZIP 与 manifest

多个 CPA ZIP 需要一次合并、默认保留每个条目并生成独立 manifest 时使用：

```bash
python3 scripts/build_cpa_bundle.py \
  --source-zip <batch-a.zip> \
  --source-zip <batch-b.zip> \
  --out <bundle.json> \
  --manifest <manifest.json>
```

只有用户明确要求或强标识证明重复时才传 `--dedupe`。

### 固定分组 K12 ZIP

来源是已经分组的 Sub2API bundle ZIP，且要按组生成 recommended/all 双 bundle 时使用：

```bash
python3 scripts/build_k12_bundle.py \
  --source-zip <grouped.zip> \
  --recommended-group <high.json> \
  --recommended-group <mid.json> \
  --optional-group <low.json> \
  --out-dir <data-dir>
```

运行前检查脚本中的组名是否与当前归档条目一致；不一致时先调整显式组配置，禁止静默把所有组混成 recommended。

## 4. 统一身份与字段规则

- 不得根据文件名或任务描述伪造 `plan_type=k12`。
- 默认新建账号 priority 为 `5`；透传现有 Sub2API bundle 时保留明确的源值。
- 不按邮箱单独去重；同邮箱可能对应不同 token 或 account context。
- 不按 `chatgpt_account_id` 单独去重；多个成员可共享 workspace。
- token hash 是强标识；导入前同时检查 active 与 soft-deleted。
- `credentials.expires_at` 存在而顶层缺失时，在通用归一化或主机导入后同步顶层字段。
- 生成 secret JSON 时使用 `0600`，不覆盖未明确指定的文件。

## 5. Recommended、Full 和小批量

当来源包含不同可信度或大量公开账号时：

- `recommended`：只含当前证据最强、格式完整的子集，优先首次验证。
- `full`：包含低可信、重叠、更新或未探测条目，明确标记为可选。
- 不因用户要求“导入全部”而静默按 quota 过滤；不因用户要求“只导可用”而跳过 probe。
- 远程 API 轨可用固定 `--shuffle-seed` 与 `--max-accounts` 生成可复现的小批量。

preview 和 execute 必须使用相同 bundle、过滤规则、shuffle seed 和 max 数量。

## 6. 只读额度

用户问完整剩余额度数量时，直接全量运行：

```bash
python3 scripts/k12_quota_probe.py <path> [<more-paths> ...]
```

按 `(access_token, chatgpt_account_id)` 请求上下文去重。报告 raw records、unique token、unique probe context、usable、耗尽、401、402 和不确定项。具体分类和 fallback 读取 `quota_and_errors.md`。

## 7. 导入轨选择

### 远程/通用 Admin API

适用于没有本机数据库权限，或需要跨机 HTTPS、login/bearer/cookie、shuffle、limit、skip-existing 的 local/development/test 环境。

1. 无 `--execute` 运行本地 preview。
2. 需要 authenticated reconcile 时单独传 `--skip-existing --execute`。
3. 写入必须提供 `--environment` 和 `--confirm-write`。
4. 脚本禁止 production/preproduction；不要绕过。

详见 `sub2api_contract.md`。

### 本机 Docker/Postgres

适用于 agent 在 Sub2API 主机上，且需要：

- token hash 强重复检查，包括 soft-deleted；
- 写前 `pg_dump -Fc`、SHA-256 和 `0600`；
- 内存短时 admin JWT；
- Idempotency-Key；
- 只对本次导入 ID 精确绑组；
- expiry 同步和 SQL 计数验证。

先运行带显式 `--environment` 的 `preflight`。真实 `import` 需要 `--confirm-write`；production/preproduction 还需要在用户明确强烈授权后传 `--confirm-production-write`。详见 `sub2api_live_ops.md`。

## 8. Kit 交付

需要交给另一台服务器或另一个 Codex 时，可生成独立 kit：

```text
k12-sub2api-kit/
  README.md
  SERVER_CODEX_PROMPT.md
  run_on_server.sh
  data/
    *.json
    *_manifest.json
  scripts/
    import_sub2api_bundle.py
```

kit 的默认命令必须先 preview；所有 secret bundle 使用 `0600`；README 和 prompt 不包含 token、管理员密码或长期 bearer。

## 9. 替换与清理

用户说“只用这一批”时，先区分：

- 替换 kit 中的生成 bundle：可在证明归属后更新或删除旧生成物。
- 删除 Sub2API 中旧账号：这是独立的 live 变更，必须备份并明确账号范围，不能从“只用这一批”自动推导。
- 原始下载、未知归档和数据库备份默认保留。

## 10. 最终报告

至少报告：输入与来源覆盖、转换工具、生成文件、账号数、缺失 token、重复口径、quota 分类、是否 refresh、是否 live import、目标环境、备份路径/hash、分组与 expiry 验证、未测试项、清理和恢复选项。
