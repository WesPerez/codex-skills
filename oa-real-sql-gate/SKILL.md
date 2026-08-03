---
name: oa-real-sql-gate
description: 真实开发/测试数据库 SQL 门禁。用于修改 OA MyBatis XML、SQL、DAO 或数据库相关代码后，证明 SQL 能通过 MyBatis 解析并在真实开发/测试 Oracle schema 上执行，且不留下脏数据。
---

# OA 真实 SQL 门禁

## 目的

在宣布任何 OA SQL 改动完成之前，必须先通过本门禁。Mockito DAO/Service 测试不够：它们不会解析 MyBatis XML，不会生成 `BoundSql`，也不能证明 Oracle 表、字段、schema 路由、函数或动态 SQL 分支在真实开发库中存在。

本门禁只负责基础 SQL 安全和证据，不单独证明业务一致性。

- 判断数据逻辑是否符合老 OA 业务规则时，使用 `oa-business-logic-compare`。
- 需要真实页面、接口、下载或副作用验收时，使用 `oa-real-browser-driver`。
- 后端/Mapper 修复通过 SQL 门禁后，如仍需 IDEA/DevTools 重启和浏览器 Network/console 复验，使用 `oa-dev-verification-gate`。

## 代码与样例边界

本门禁只拥有 SQL 解析、真实库执行安全、样例和恢复证据。涉及 Mapper/DAO/Service 源码修复、暂存、提交、还原或清理时，遵守 `oa-business-logic-compare` 的“任务边界、提交边界与还原边界”。`-Mode changed` 只能用来发现需要校验的已变更 Mapper，不代表可以提交、还原或清理整批工作树差异；样例文件和报告也只有在用户明确要求交付时才提交。

## 可执行闭环原则

本门禁应产出下一步可执行的数据库动作，而不是只给一个 `blocked` 标签。

默认链路：

1. 执行任何 SQL 前，先确认数据库身份和 schema。
2. 为选中的 Mapper/XML 生成 MyBatis `BoundSql`。
3. 用安全参数在真实开发/测试 schema 执行 SELECT 路径。
4. 参数缺失时，从源码条件和只读数据库查询中寻找候选样例，再更新 `real-sql-gate-samples.yml`。
5. 检测到 DML 时一律阻断，但必须输出缺失项：环境身份、样例 id、原始行快照查询、计划变更、预期影响行数、读回查询、恢复 SQL、恢复验证 SQL。
6. 当前共享执行器不能强制验证环境身份、影响上限、触发器/自治事务/DB link 副作用和敏感读回，因此本技能禁止传入 `-AllowDml`。需要写入时只生成计划，交由具备独立审批、范围校验和可审计回滚的专用流程执行。
7. SQL/代码改动通过后，交给 `oa-dev-verification-gate` 编译/重载，再交给浏览器/动作证据做真实验收。

任何 DML、写入型过程、不可逆序列推进、生产/未知库风险、无界副作用、缺少授权或恢复要素不足都必须使用 `blocked`。

## 跨技能交接契约

本门禁负责数据库执行安全和 SQL 证据。其他 OA 技能应把本报告视为数据库契约：

- 输入：Mapper id 或 XML 路径、必要的 DAO/Service 上下文、companyCode/数据源预期、参数来源、样例 id、SQL 类型、预期影响表、调用方提供的样例覆盖计划，以及调用方是否准备浏览器动作、后端重载或业务一致性检查。
- 输出：报告路径、数据库身份/schema、选中数据源、生成的 `BoundSql`、参数集、对象元数据结果、只读执行结果、副作用分类、DML 计划和最终状态。
- 返回状态按执行器实际值解释为 `pass`、`needs-data`、`blocked`、`failed`；报告中的细分原因必须写清环境、授权、范围或恢复要素缺口。
- SELECT 或安全 SQL 解析得到 `pass` 时，交回 `oa-business-logic-compare` 做一致性判断；如后端运行时需要重载，交给 `oa-dev-verification-gate`。
- 得到 `needs-data` 时，必须写清所需表、字段、分支和样例条件，方便调用方继续只读找样例。
- 任何 `blocked-*` 都必须写清缺少的安全要素；阻断解除前，不要要求浏览器/动作技能点击副作用路径。

## 必用命令

从 `E:/IdeaProjects/oa` 运行共享工具：

```powershell
# 仅检查已变更 Mapper XML
.\.agents\tools\real-sql-gate\run-new-oa-mybatis.ps1 -Mode changed

# 检查一个精确 Mapper statement
.\.agents\tools\real-sql-gate\run-new-oa-mybatis.ps1 -Mapper 'com.nfrc.modules.commons.system.system.dao.SysCompanyDatabaseDao.selectAllList'

# 检查一个 XML 文件
.\.agents\tools\real-sql-gate\run-new-oa-mybatis.ps1 -Xml 'src/main/resources/mybatis/system/system/SysCompanyDatabaseMapper.xml'
```

`-Xml` 会校验该 XML 中的所有 statement。若包含 INSERT / UPDATE / DELETE，当前版本预期结果必须为 `blocked`；授权和恢复计划也不会把本技能升级为执行器。

SQL 通常通过 `@ApiNeedCompanyCode` 到达租户数据源时，使用租户数据源：

```powershell
.\.agents\tools\real-sql-gate\run-new-oa-mybatis.ps1 -Mapper '<namespace.id>' -CompanyCode '010'
```

共享样例文件：

```text
E:/IdeaProjects/oa/.agents/skills/oa-real-sql-gate/real-sql-gate-samples.yml
```

必要时覆盖样例文件：

```powershell
.\.agents\tools\real-sql-gate\run-new-oa-mybatis.ps1 -Mapper '<namespace.id>' -Samples 'E:/IdeaProjects/oa/.agents/skills/oa-real-sql-gate/real-sql-gate-samples.yml'
```

报告输出到：

```text
E:/IdeaProjects/oa/.agents/reports/real-sql-gate/real-sql-gate-report.md
```

除非任务明确要求证据产物，否则不要提交生成的报告。

## 数据源规则

- 数据库 URL、用户、密码、driver、schema、companyCode 路由输入必须来自用户授权来源：当前会话输入、用户批准的 prompt/dialog、为本次运行设置的环境变量，或用户明确指定/确认的项目文件、配置文件、凭据文件。若用户已指定读取位置，直接读取，不要为了强制交互中断长任务。未经授权不得搜索任意已提交配置文件中的凭据。
- 当前执行器会在未显式提供连接信息时尝试读取项目开发配置；因此启动前必须由用户明确指定或确认连接来源。未确认时不得运行执行器，即使只计划 SELECT。
- `sqlGate.companyCode=010` 会用默认连接从 `SYS_COMPANY_DATABASE` 解析真实动态数据源。
- 不得在回答、日志、报告、截图或文档中打印数据库用户名、密码或 token。
- `@ApiNeedCompanyCode` 链路中的普通租户 SQL 不得硬编码租户 schema 前缀。遇到 `ORA-00942` 时，先检查 schema 路由，不要直接补 schema 名。
- 任何可写检查前，必须记录真实数据库身份：`USER`、`CURRENT_SCHEMA`、数据库名/服务标签。看起来像正确用户表或权限表还不够；SQL 必须打到 Service/Mapper 路径实际使用的数据源。
- 权限和登录路径可能跨数据源：认证可能读新 OA 表，业务权限可能读老 OA 租户表。备份、DML、读回和恢复必须全部针对实际读取的 schema/table。

## SQL 类型策略

### SELECT

必须满足：

1. MyBatis XML 能解析。
2. statement 能生成 `BoundSql`。
3. SQL 能在真实开发/测试 Oracle 数据库执行。
4. 报告记录 Mapper id、XML 路径、数据源 key/schema、参数来源、行数和对象元数据检查。

如果没有安全参数集，先用与 Mapper where/join 条件一致的只读查询寻找样例。仍找不到时，标为 `needs-data`，写清需要的表/字段/分支。不要伪造参数来换绿色结果。

### INSERT / UPDATE / DELETE

当前版本一律阻断，不得通过本技能启用执行。

不要使用 `-AllowDml`、样例中的 `allowDml` 或 `rollbackVerifySql` 作为执行授权。这些开关不足以证明数据库环境、精确影响范围、触发器/自治事务/外部系统副作用及敏感数据输出安全。发现 DML 时仅生成 `BoundSql`、参数与恢复计划，标为 `blocked`。

`sqlGate.reportOnly=true` 只影响进程退出码，不能把 `FAILED`、`NEEDS_DATA` 或 `BLOCKED` 转为通过；门禁判定必须读取报告结论，且不得用该选项绕过阻断。

### 存储过程 / 副作用

不要执行包含 commit、审批流、打印完成、文件生成、下载记录、权限授予、状态流转等副作用的过程或 SQL；本技能只检查源码/元数据并生成计划。

无需额外审批即可做：

- `all_objects`、`all_source`、`all_arguments` 等元数据查询。
- 只读函数，但必须先检查函数体/源码确认无副作用。
- 序列元数据检查，例如通过 `all_sequences` / `all_objects` 确认 `SEQ_*` 存在。禁止执行 `SEQ_*.NEXTVAL`，并检查 MyBatis `<selectKey>`、KeyGenerator 和触发器是否会间接推进序列；Oracle sequence 不会被事务回滚恢复。

## 已变更 SQL 范围

`run-new-oa-mybatis.ps1 -Mode changed` 会检查新 OA git 仓库：

- `git diff --name-only`
- `git diff --name-only --cached`
- 未跟踪文件

它会选择 `src/main/resources/mybatis` 下变更的 `*Mapper.xml`。若无法安全隔离精确变更 statement，就校验该 XML 中所有 statement，这是有意设计。

新增 SQL 调用的 DAO 或 Service 变更，仍需要人工用 `-Mapper '<namespace.id>'` 精确选择。

## 样例文件

使用工作区级文件：

```text
E:/IdeaProjects/oa/.agents/skills/oa-real-sql-gate/real-sql-gate-samples.yml
```

最小结构：

```yaml
samples:
  com.example.Dao.selectSomething:
    companyCode: "010"
    params:
      param:
        ksid001: "real_sample_id"
```

DML 仅记录计划，不得 opt in 执行：

```yaml
samples:
  com.example.Dao.updateSomething:
    companyCode: "010"
    params:
      id: "real_test_row"
      status: "002"
    writePlan:
      expectedAffectedRows: 1
      snapshotSql: "select status from SOME_TABLE where ID = ?"
      readbackSql: "select status from SOME_TABLE where ID = ?"
      restoreSql: "update SOME_TABLE set status = :original_status where ID = ?"
      restoreVerifySql: "select status from SOME_TABLE where ID = ?"
```

样例参数记录规则：

- 业务分支和浏览器覆盖范围由调用方提供；本门禁只记录样例参数、companyCode、数据源和该样例对应的调用方分支标签。
- 只读发现候选数据时，可以记录它可能覆盖的分支，但不能据此宣布页面或业务闭环完成。
- 一个样例无法满足调用方分支条件时，添加多个具名样例，并记录每个样例对应的分支标签。
- 不要用编造 id 只为了生成 `BoundSql`。没有安全数据时，返回 `needs-data` 并写清需要的表/字段/样例。
- 临时开发/测试权限更新计划必须包含原始行快照查询、update/insert、预期影响行数、读回查询、恢复语句、恢复验证查询。即使齐全，当前 SQL gate 仍保持 `blocked`，只把计划交给专用写入流程。

## 测试数据构造策略

本门禁只负责生成测试数据计划和验证其只读前置证据，不直接构造或调整测试数据。业务覆盖分支由 `oa-real-browser-driver` 或 `oa-business-logic-compare` 提供。

1. 先找数，后造数：
   - 用只读 SQL 按调用方覆盖计划、Mapper where/join、权限门、状态和日期范围寻找现有候选样例。
   - 找不到覆盖分支的数据时，返回 `needs-data`，并列出缺少的分支条件。
   - 找不到数据时生成造数/改数计划，但保持 `blocked`，不在本技能中执行。
2. 构造/调整数据前必须具备：
   - 数据库身份：`USER`、`CURRENT_SCHEMA`、数据库名/服务标签。
   - 覆盖计划：本次要证明的页面/控件/分支。
   - 最小影响表和字段：从 Service/Mapper/过程追踪得出，不靠猜表名。
   - 原始快照：更新/删除前能精确定位原行；插入新行时记录生成主键、关联键和清理条件。
   - 执行 SQL、预期影响行数、读回 SQL、恢复 SQL、恢复验证 SQL。
3. 计划要求：
   - 优先修改一条可控 dev/test 行的最少字段，而不是大范围改角色、状态或日期。
   - 需要插入 fixture 时，所有主表、明细表、日志/权限/附件关联都必须有可删除或可恢复的键；无法界定完整关联时保持 `blocked`，并把原因写为 `unbounded-side-effect`。
   - 不执行会提交审批流、打印完成、下载记录、库存/二维码状态、外部 deep link 状态或不可逆序列推进的过程，除非外层已有精确授权和恢复边界。
4. 专用写入流程完成后，调用方必须回传执行、读回和恢复证据；本门禁只审查这些证据，不把执行器退出码当作写入安全证明。
5. 生产库或身份不明库永远不造数、不改数，只能输出只读诊断 SQL 或 `needs-data`。

## 报告模板

门禁报告必须包含：

- 结论：pass / failed / needs-data / blocked。
- 范围：变更 XML、显式 Mapper id 或显式 XML。
- 数据库标签和当前 schema，省略凭据。
- SQL 清单：Mapper id、SQL 类型、XML 文件、数据源/schema、判定。
- 执行细节：参数来源、执行模式、行数或影响行数。
- 可行时提供 `all_objects` / synonym 等对象元数据检查。
- 发现 DML 时提供阻断原因与完整写入/恢复计划；不得声称已执行。
- 失败项和未验证项。

## 完成标准

- 相关 Mapper XML 已通过 MyBatis 解析。
- 每个选中 statement 已生成 `BoundSql`，或明确标为 `needs-data`。
- SELECT 已在真实开发/测试数据库执行。
- DML 已回滚/恢复，或明确标为 `blocked` / `needs-data`。
- 生成报告不含凭据。
- 业务正确性结论由 `oa-business-logic-compare` 支撑，不能只依赖 SQL Gate。
