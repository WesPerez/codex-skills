---
name: k12-sub2api-ops
description: 统一处理 K12/OpenAI OAuth 账号包与 Sub2API 运维：盘点和转换 CPA/Codex/ZIP/RAR/JSON bundle、按安全身份规则去重、只读探测剩余额度、生成 recommended/all 或 manifest、通过远程 Admin API 小批量导入，或在本机 Docker/Postgres 部署上备份后导入、精确绑组和验证。用户提到 K12 账号、CPA/CliProxyAPI JSON、Codex auth、Sub2API 导入、不要刷新令牌、额度还有多少、401/402、打乱/小批量导入、同邮箱不同账号或 K12 bundle 时使用。不要用于论坛搜索 space ID、浏览器 exchange 验证 workspace，或纯数据库 space 统计。
---

# K12 Sub2API 运维

## 边界

把账号文件、token、管理员认证、数据库备份和生成 bundle 当成秘密处理。不得打印凭据，不得擅自刷新 K12 token，不得把只读额度检查升级为生成请求，也不得把 preview 伪装成已执行导入。

按目标路由，避免跨风险域：

- 论坛搜索或收集 K12 space/workspace ID：使用 `$linux-do-k12-space-id`，并按需调用 `$linux-do-research`。
- 验证候选 workspace ID 是否能被当前隔离 ChatGPT session exchange：使用 `$k12check`。
- 统计 Sub2API 数据库里的 K12 space、active/deleted/401/402：使用 `$sub2api-k12-space-audit`。
- 账号包、额度、转换、导入、备份和精确绑组：使用本技能。

## 必读路由

- 所有任务先读 `references/k12_sub2api_workflow.md`。
- 识别格式、转换、命名或去重时读 `references/account_formats.md`。
- 额度、401/402、上游可用性或清理判断时读 `references/quota_and_errors.md`。
- 只有远程/通用 HTTP Admin API 导入时读 `references/sub2api_contract.md`。
- 只有本机 Docker/Postgres 主机侧导入、备份、绑组、验证或恢复时读 `references/sub2api_live_ops.md`。

## 固定工作流

1. **盘点输入。** 用 `file`、`stat`、`sha256sum` 和 `scripts/k12_bundle_tool.py inspect` 记录格式、账号数、缺失 token、plan、过期字段和重复摘要，不输出秘密。
2. **选择转换器。** 通用单包、RAR、未知 JSON、Codex session 粘贴或现有 export 归一化使用 `k12_bundle_tool.py`；多个 CPA ZIP 且需要 manifest 使用 `build_cpa_bundle.py`；固定分组 K12 ZIP 需要 recommended/all 双 bundle 时使用 `build_k12_bundle.py`。
3. **不伪造 K12 身份。** `plan_type=k12` 必须来自源字段、JWT claims 或另行验证的证据。缺少证据时保留未知并在导入前阻止，不得因文件名或用户说“K12 包”就写入。
4. **只读额度。** 用户问“还有多少有额度”时直接运行 `k12_quota_probe.py <path>...` 全量扫描供应文件；不刷新 token、不写库、不调用生成接口。按 usable、耗尽、401、402、不确定分别报告。
5. **导入前去重。** `chatgpt_account_id` 只能作为上下文，不能单独作为重复边界。优先 token hash，并检查 active 与 soft-deleted；同邮箱不同 token/account context 默认保留。
6. **选择导入轨。** 无本机 DB/JWT_SECRET、需要跨机 HTTPS、shuffle、限量或 skip-existing 时使用 `import_sub2api_bundle.py`；位于 Sub2API 主机且需要写前备份、短时 JWT、精确绑组、expiry 同步和 SQL 验证时使用 `sub2api_live_tool.py`。两者不得混成一个隐式高权限路径。
7. **写入闸门。** 任何真实写入前确认环境、账号范围、对象、回滚和外部副作用。远程导入必须先 preview，且脚本禁止 production/preproduction；主机侧生产写入仅在用户获知风险后仍明确强烈要求、环境与范围已核实、备份已成功时执行。
8. **验证和报告。** 报告转换/探测/导入的精确数量、重复项口径、备份路径/hash、分组绑定、expiry、错误分类、未测试项和恢复选项。

## 工具路由

```bash
# 通用离线检查、转换和比较
python3 scripts/k12_bundle_tool.py inspect <path>
python3 scripts/k12_bundle_tool.py convert <path> --output <bundle.json>
python3 scripts/k12_bundle_tool.py compare <candidate.json> <existing-export.json>

# 多 CPA ZIP 或固定分组 K12 ZIP
python3 scripts/build_cpa_bundle.py --source-zip <a.zip> --out <bundle.json> --manifest <manifest.json>
python3 scripts/build_k12_bundle.py --source-zip <grouped.zip> --recommended-group <high.json> --optional-group <low.json> --out-dir <data-dir>

# 只读额度
python3 scripts/k12_quota_probe.py <bundle-or-directory> [<more-paths> ...]

# 通用/远程 Admin API：默认仅 preview
python3 scripts/import_sub2api_bundle.py --bundle <bundle.json>

# 本机 Docker/Postgres：先 preflight，再在明确授权后 import
python3 scripts/sub2api_live_tool.py preflight --bundle <bundle.json> --postgres-container <container> --pg-user <user> --pg-db <db> --environment <environment>
```

额度脚本退出 `0` 表示全部结论明确，`1` 表示报告完成但包含不确定项，`2` 表示输入或 CLI 失败；退出 `1` 时仍必须读取并报告摘要。

## 清理

只清理由当前任务生成、或用户明确指定替换的 bundle、manifest、备份和临时文件。源账号包、未知下载、数据库备份、用户目录和其他技能不得因名称相似而删除。
