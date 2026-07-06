---
name: k12-sub2api-ops
description: 为 Sub2API 准备、校验、转换、记录并导入 K12 OpenAI OAuth 账号包，并按格式感知方式处理重复项。适用于用户提到 K12 账号、CPA/CliProxyAPI JSON 文件、Codex auth JSON、Sub2API 账号导入、LINUX DO K12 包、“不要刷新令牌”包、打乱/小批量 K12 导入、同邮箱不同账号包，或需要可直接在服务器运行的 K12/Sub2API 方案。
---

# K12 Sub2API 运维

## 核心规则

把 K12 账号文件当成敏感凭据处理。不要打印 token，不要发布 bundle，不要读取浏览器 cookies/localStorage，不要批量刷新 token；除非用户已经明确授权导入路径并提供或确认管理员认证，否则不要导入到正在运行的 Sub2API 实例。

## 必读材料

任何真实的 K12/Sub2API 任务，都要先读 `references/k12_sub2api_workflow.md`，再做判断或编辑。

分类输入文件或转换 CPA/Codex JSON 时，读取 `references/account_formats.md`。

导入、编写服务器指令或调试 Sub2API API 调用时，读取 `references/sub2api_contract.md`。

如果任务需要读取 LINUX DO 收藏、主题、楼层、回复或附件，也使用 `$linux-do-research`；本技能处理 K12/Sub2API 决策，不负责论坛导航。

## 工作流

1. 在不暴露秘密的前提下盘点源文件：
   - 列出 zip 条目和 JSON 键；
   - 统计账号数量；
   - 隐去 token 值；
   - 记录源路径和大小。
2. 分类每个来源：
   - Sub2API bundle JSON：顶层 `accounts`；
   - CPA 单账号 JSON：顶层 `access_token`、`email`、`id_token`、`expired`；
   - 包含许多 CPA JSON 文件的 zip；
   - 包含 high/mid/full/low 等分组 Sub2API bundle 的 zip。
3. 需要时转换为 Sub2API bundle 结构。
4. 按来源格式处理重复项：
   - 对 CPA 单账号 zip 文件，默认保留每个 JSON 条目，因为同一邮箱可能映射到不同 `account_id`；
   - 只有在用户明确要求，或确认同一邮箱和同一 account id/token 是重复项时才去重；
   - 对分组 bundle zip，根据 `references/account_formats.md` 的规则谨慎去重。
5. 校验每个生成的 bundle：
   - `accounts` 存在且为列表；
   - `platform=openai`；
   - `type=oauth`；
   - `credentials.plan_type=k12`；
   - `missing_access_token=0`；
   - 报告唯一邮箱和唯一 account-id 数量，并解释任何重复邮箱，而不是盲目删除。
6. 优先分阶段导入：
   - 先导入 recommended/high-confidence bundle；
   - 测试少量账号；
   - 首次导入成功后，再导入更新或可信度较低的包；
   - 对易失的公开包，使用打乱的小批量。
7. 如果用户要求替换旧账号或“只用这一批”，从 kit 中移除旧的生成 bundle 文件，更新 `run_on_server.sh`/文档，使默认使用当前批次；除非用户明确要求删除源下载，否则保留源下载。
8. 精确记录服务器侧 Codex 可以安全执行什么。

## 可复用脚本

从技能路径运行内置脚本，或把它们复制到工作 kit 中使用。

- `scripts/build_cpa_bundle.py`：把一个或多个 CPA 单账号 zip 文件转换为 Sub2API bundle。
- `scripts/build_k12_bundle.py`：把分组 K12 bundle zip 条目合并为 recommended/all Sub2API bundle；如果源包分组名称不同，需要调整组名。
- `scripts/import_sub2api_bundle.py`：通过 Sub2API admin API 预览/导入 Sub2API bundle。

执行 `--execute` 前始终先跑 preview 模式。

## 交付清单

可行时，在可直接运行的 kit 中包含这些文件：

- `data/*.json` Sub2API bundle；
- manifest JSON，包含来源、数量、重复项和警告；
- `scripts/import_sub2api_bundle.py`；
- 用于所用来源格式的重建脚本；
- `run_on_server.sh` 或等价的服务器命令包装器；
- `README.md`；
- `SERVER_CODEX_PROMPT.md`。

## 报告

报告来源覆盖、生成文件、账号数量、缺失 token 数量、重叠/重复处理、校验命令、实际执行的导入、下载文件、配置变化、运行中进程和清理决策。
