# K12/Sub2API 完整工作流

端到端处理 K12 账号包时使用此参考文档。它基于已经验证过的 LINUX DO K12 包和 Sub2API 导入流程。

## 操作原则

- 为不方便操作或非技术用户优化：产出 kit 或 prompt，让另一台服务器上的 Codex 能用最少人工动作运行。
- 如实报告覆盖情况。除非已经记录覆盖并补齐缺口，否则不要说“所有收藏”或“所有楼层”都已读取。
- 把 OAuth 账号 JSON 当作凭据。
- 在日志和最终输出中隐去 access token、id token、refresh token、session token、cookies 和 bearer token。
- 不要读取浏览器 cookies、localStorage、session storage 或 profile 文件来获取凭据。
- 未经明确授权，不要在论坛发帖、点击“refresh token”、批量刷新账号或修改远程服务。
- 不要因为包存在就全部导入。优先分阶段导入和校验。

## 来源接收

对每个候选文件或下载：

1. 记录绝对路径、大小、修改时间、来源 URL/topic，以及来源帖中的任何密码/说明。
2. 使用结构化 zip 读取器检查 zip 结构。
3. 检查 JSON 键，而不是 token 值。
4. 统计 JSON 条目并分类来源格式。
5. 识别来源帖中的明确警告，尤其是“不要刷新 token”或“小批量/随机导入”建议。
6. 记录此来源与现有 bundle 在邮箱和 account id 上是否重叠。对于 CPA 单账号 zip，不要把邮箱重叠本身当成重复证明。

永远不要只依赖文件名。必须验证内部结构。

## 已知来源经验

之前验证过的包集有这些结论：

- `1334个-不要去刷新令牌.zip` 是最佳初始来源。
- 来源帖的密码/说明包括 `密1122` 和“不要刷新令牌”。
- 1022 CPA 包与 1334 包重叠，不应在初始阶段一起导入。
- Outlook workspace 创建不可靠/失效，但已下载的 OAuth 凭据仍可能可导入。
- 一个较新的第二批主题 `2527525` 包含两个 100 账号 CPA zip 文件：
  - `kxj_k12_batch_001_100_cpa.zip`
  - `kxj_k12_batch_002_100_cpa.zip`
- 第二批有 200 个唯一 Gmail 账号，与 1334 bundle 没有邮箱重叠，验证运行中没有缺失 access token。
- 后来的 `batch1.zip` 示例包含重复邮箱但 account id 不同；这些条目应保留，不按邮箱去重。
- 后来的 `50个.zip` 示例包含 50 个 CPA JSON 文件，构建 bundle 时应保留为 50 个条目。
- 第二批回复建议不要一次导入全部。使用随机/小切片。

不要假设未来工作区中存在这些精确文件。每次都重新验证。

## Bundle 生成策略

当来源材料足够时，至少创建两类输出：

1. Recommended bundle：
   - 只包含高可信账号；
   - 用作第一次服务器导入；
   - 足够小，便于测试和恢复。
2. Full 或 optional bundle：
   - 可信度较低、更新、重叠或批量包；
   - 清楚标为可选；
   - 只有在 recommended bundle 可用后才导入。

对论坛公开共享且易失的 K12 账号，优先使用当前批次 bundle 和打乱的小批量导入：

```bash
export K12_BUNDLE="data/k12_sub2api_current_batch.json"
export K12_SHUFFLE=1
export K12_MAX_ACCOUNTS=10
bash run_on_server.sh
```

首次线上测试时，`K12_MAX_ACCOUNTS` 可以更小。

## 重复处理规则

对 CPA 单账号 zip 文件：

- 默认保留每个 JSON 条目；
- 除非用户明确要求，否则使用 builder 的不去重模式；
- 报告重复邮箱和唯一 account-id 数量；
- account id 不同时保留同邮箱条目。

对分组 bundle zip：

- 构建 recommended/all bundle 时跨组谨慎去重；
- 不要只按 `chatgpt_account_id` 或 `account_id` 去重，因为有些 K12 包让许多不同用户共享一个 workspace/account id；
- 如果不确定，保留条目并解释重复风险，而不是静默丢弃。

## 替换模式

当用户说“delete previous accounts”、“only add this batch”、“只加入这一批”或等价表达时：

1. 除非明确要求，不要删除原始下载。
2. 只有在确认旧的生成 bundle JSON/manifest 文件由当前/之前的 kit 工作流产生后，才从工作 kit 的 `data/` 目录移除它们。
3. 生成新的当前批次 bundle，推荐命名为 `data/k12_sub2api_current_batch.json`。
4. 生成匹配的 manifest，推荐命名为 `data/k12_current_batch_manifest.json`。
5. 更新 `run_on_server.sh` 默认 `K12_BUNDLE` 为当前批次 bundle。
6. 更新 `README.md` 和 `SERVER_CODEX_PROMPT.md`，使服务器侧 Codex 默认只导入当前批次。
7. 重建交付 zip，并确认其中不包含旧批次 bundle 名称。
8. 精确报告从 kit 中删除了什么，以及保留了哪些源归档。

## 校验命令

使用结构化校验，不要打印 token 值：

```bash
python scripts/import_sub2api_bundle.py \
  --base-url http://127.0.0.1:3000 \
  --bundle data/k12_sub2api_recommended_312.json \
  --max-accounts 3
```

对第二批或易失包：

```bash
python scripts/import_sub2api_bundle.py \
  --base-url http://127.0.0.1:3000 \
  --bundle data/k12_sub2api_current_batch.json \
  --max-accounts 3 \
  --shuffle \
  --shuffle-seed 12345
```

预期 preview 摘要：

- `platforms` 包含 `openai`；
- `plan_types` 包含 `k12`；
- `missing_access_token` 为 `0`；
- sample identities 只显示邮箱/name，不显示 token。

## 服务器 Kit 模式

推荐目录结构：

```text
k12-sub2api-kit/
  README.md
  SERVER_CODEX_PROMPT.md
  run_on_server.sh
  data/
    k12_sub2api_recommended_*.json
    k12_sub2api_all_*.json
    k12_sub2api_current_batch.json
    *_manifest.json
  scripts/
    build_k12_bundle.py
    build_cpa_bundle.py
    import_sub2api_bundle.py
  docs/
    cpa_tutorial_summary.md
```

`README.md` 应解释给人看的使用方式。

`SERVER_CODEX_PROMPT.md` 应告诉服务器侧 Codex 按顺序准确执行什么，并在报告中隐去秘密。

`run_on_server.sh` 应：

- 使用 `SUB2API_BASE_URL`，谨慎默认为 localhost；
- 使用 `K12_BUNDLE` 并设置安全默认值；
- 支持 `K12_MAX_ACCOUNTS`；
- 支持 `K12_SHUFFLE` 和固定 `K12_SHUFFLE_SEED`，使 preview 和 execute 选择同一批账号；
- 先运行 preview，再执行。

## CPA 教程关系

LINUX DO CPA 教程讲的是本地 CliProxyAPI 使用方式：

1. 下载 CPA/CliProxyAPI；
2. 把 `config.example.yaml` 复制为 `config.yaml`；
3. 设置 `secret-key`；
4. 运行 CPA；
5. 登录 `http://localhost:8317/management.html#/login`；
6. 上传 `.json` 账号文件；
7. 创建 API key；
8. 把 Cherry Studio/Codex/OpenAI-compatible clients 指向 `http://localhost:8317`。

对 Sub2API 部署而言，CPA 是背景知识。如果目标是 Sub2API 导入，就把 JSON 文件转换成 Sub2API bundle 并直接导入。除非用户特别要求 CPA，否则不要部署 CPA。

## 最终答复要求

对 K12/Sub2API 工作，始终报告：

- 读取了哪些来源，以及是否还有未读收藏/楼层；
- 下载文件及其路径；
- 生成/修改的文件；
- 生成的账号数量；
- 重复/重叠数量；
- 缺失 token 数量；
- 是否刷新 token：通常为 `no`；
- 是否执行 live import：通常为 `no`，除非已明确授权；
- 用于校验的命令；
- 如果使用浏览器，报告打开/关闭的标签页；
- 已执行或有意未执行的清理；
- 运行中的进程/服务；
- 如果创建了 commit，报告 commit hash。
