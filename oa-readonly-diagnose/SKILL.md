---
name: oa-readonly-diagnose
description: 为 OA 页面、弹窗、列表、按钮禁用、审批页空白、数据少/查不到、权限过滤、生产现象不一致等问题生成最少步骤的只读诊断 SQL。用于 Codex 从老 OA JSP/FRAME/函数/过程或新 OA Vue/API/Mapper 源码还原真实查询、过滤、脱敏、分页、按钮状态和副作用边界，再给用户一段可直接在生产/目标库执行的只读 SQL 包；用户回传结果集后由 Codex 判定根因。适用于“我只想执行 SQL 给你结果”“步骤越少越好”“生产库只读排查”“把页面逻辑变成诊断 SQL”“审批 OALS 断链只读诊断”等场景。
---

# OA 只读 SQL 诊断

## 定位

本技能是 OA 生产/目标库只读排查的统一入口。目标是把一次排查压缩成最少用户动作：

1. Codex 读源码、配置和参考案例，还原真实页面/接口逻辑。
2. Codex 输出一段可复制执行的只读 SQL 包，参数集中在顶部。
3. 用户在目标库执行并回传结果集。
4. Codex 根据结果集给出根因、证据和下一步最小动作。

不要为每个业务特例新建独立技能。业务特例沉淀到 `references/`；只有出现全新的工具链、安全边界或验证模式时，才考虑独立技能。

## 安全边界

- 生产库和身份不明库只允许只读：`SELECT`、`WITH`、数据字典/元数据查询。
- 禁止输出可直接执行的 `INSERT`、`UPDATE`、`DELETE`、`MERGE`、DDL、写入型过程、审批流转、下载完成、打印完成、状态变更。
- 第一段 SQL 必须返回库身份列：`USER`、`CURRENT_SCHEMA`、`DB_NAME`。如果是多结果集脚本，第一组也必须返回。
- 不输出账号、密码、token、完整连接串。生产结果可能包含姓名、客户、审批意见和业务正文时，只选择诊断必需列，并要求用户回传前脱敏或改传行数、状态和哈希；不要索取无关完整结果集。
- 调用函数前必须从源码、导出或既有证据判断其无明显写副作用；不确定时只查 `ALL_SOURCE/USER_SOURCE` 或把函数列为未验证项。
- SQL 必须有业务边界：主键、编号关键词、登录人、日期范围、状态或 `FETCH FIRST`/`ROWNUM` 上限，避免生产大范围扫描。
- 不让用户执行“先更新再查”“临时改状态验证”“跑过程看看”的动作。

## 输入处理

接受任一线索并自行补链路：

- 页面截图、页面标题、按钮文字、弹窗标题、字段名、列表列名。
- 老 OA `forwardName`、JSP、FRAME id、`taskStr`、`commitIDArrStr`、业务过程/函数名。
- 新 OA 路由、Vue 文件、API URL、Controller、Service、DAO、Mapper id。
- 业务编号、项目编号、客户名、流水号、当前登录用户、公司/部门、状态、时间范围。

如果缺关键参数，最多问一次。低风险缺口使用 SQL 参数占位，例如 `替换为当前登录YHID001`、`CAST(NULL AS VARCHAR2(64))`。

## 参考库选择

按需读取以下参考，不要一次性加载无关案例：

- `references/case-old-oa-project-handover-popup.md`：老 OA 项目交接“项目编号选择”弹窗，`KS009` 候选、负责人有效性过滤、`XM041` 已选禁用状态。
- `references/case-old-oa-approval-oals.md`：老 OA 审批页空白、OALS 流水分裂、`OA001/OA003/OA010` 断链、PC/移动端审批痕迹不一致。
- `references/approval-oals-diagnostic-sql.md`：OALS 审批断链只读 SQL 模板。只有遇到审批/OALS 线索时读取。

需要老 OA JSP/FRAME 证据链时，可调用 `oa-jsp-sql-trace` 的方法还原 JSP -> `nf:*` 标签 -> `FRAME_QUERY/FRAME_LIST/FRAME_TASK_QUERY_WHERE/FRAME_COMMIT` -> SQL/函数/过程。需要新老 OA 行为一致性审计时，交给 `oa-business-logic-compare`。需要真实浏览器动作验收或开发库 SQL 门禁时，交给对应专用技能；本技能不替代那些验证模式。

## 诊断模型

把页面逻辑拆成结果集可判定的列：

- 候选全集：按用户输入的最宽但有边界条件查出原始候选。
- 页面过滤：把每个 `WHERE`、函数判断、状态判断转成 `CASE` 原因。
- 权限/登录人：显式列出当前用户、部门、角色、负责人、创建人、组织条件。
- UI 状态：可见、不可见、禁用、已选中、可勾选、按钮可点、按钮隐藏。
- 关联状态：是否已有主表/明细/日志/关联表，是否被其他流程占用。
- 汇总计数：候选总数、页面应显示数、异常数，尽量用窗口函数放到每行。
- 排序分页：输出页面排序字段，解释“查到了但不在当前页”的可能性。

结果集必须让 Codex 能直接判断“为什么页面看到的是这个样子”，而不是只证明某张表有没有数据。

## 字段兼容

生产库、历史库或多环境 schema 可能与本地源码导出不完全一致。生成首轮只读 SQL 时，优先使用页面判断链路必需且已由源码、FRAME 配置、表结构导出或用户结果证明存在的字段；对只用于补充解释、排序、展示或统计的字段，如果存在性不确定，不要放进主 SQL 的 `SELECT`、`WHERE`、`CASE` 或子查询里，避免一个可选字段导致整段 SQL `ORA-00904` 失败。

当诊断确实依赖不确定字段时，先输出独立元数据探针，或把元数据探针作为脚本第一组结果集：

```sql
SELECT USER AS db_user,
       SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS current_schema,
       SYS_CONTEXT('USERENV','DB_NAME') AS db_name,
       owner, table_name, column_name, data_type
  FROM all_tab_columns
 WHERE owner = SYS_CONTEXT('USERENV','CURRENT_SCHEMA')
   AND table_name IN ('替换为表名1', '替换为表名2')
   AND column_name IN ('替换为字段1', '替换为字段2')
 ORDER BY table_name, column_id
```

注意：同一条 SQL 不能用 `ALL_TAB_COLUMNS` 判断字段存在后再静态引用该字段；Oracle 解析阶段仍会因为缺字段失败。因此字段不确定时，要么先让用户回传元数据结果后再给主 SQL，要么首轮主 SQL 只使用确定字段。

如果用户回传 `ORA-00904`、`ORA-00942` 或类似字段/对象不存在错误，把它视为 SQL 包需要兼容目标库的信号。先根据报错标识符定位到自己输出的表/字段，不要求用户排查；删除、替换或降级该非必要字段，必要时追加最小元数据探针，并给出一版能继续回答原诊断问题的修正 SQL。不要把某次字段缺失写成业务特例沉淀到技能里。

## Oracle/Navicat 兼容禁区

用户通常在 Navicat 里把整段 Oracle SQL 一次执行。为了避免让用户反复试错，首轮主 SQL 必须保守：

- 不在主 SQL 静态引用未由源码、既有结果或表结构证明存在的字段。例如同名业务表在不同库可能缺 `YXBZ001`、`CJSJ001`、`XGSJ001`、地址字段、扩展字段；字段不确定时先查 `ALL_TAB_COLUMNS`，或从主查询删掉该字段。
- 不在主 SQL 直接写跨 schema 表名或同义词目标，例如 `NFRCCP_OA_DA.KQ001`、`NFRCCP_OA.KQ001`、`对象@DBLINK`。除非用户已明确当前连接有权限且刚刚验证对象可查。需要跨库对比时，优先让用户分别在两个连接执行“当前 schema 本地对象版”SQL，再由 Codex 合并判断。
- 不在主 SQL 引用权限不稳定的数据字典视图：`ALL_AUDIT_TRAIL`、`DBA_*`、`ALL_SCHEDULER_JOB_RUN_DETAILS`、`ALL_SCHEDULER_JOBS`、`ALL_JOBS` 等。首轮只用 `USER_*`/`ALL_OBJECTS`/`ALL_TAB_COLUMNS`/`ALL_SYNONYMS` 这类低风险对象；调度、审计、运行历史作为“可选增量 SQL”，并说明若 ORA-00942 代表无权限或版本无该视图。
- 不把可选元数据排查和核心业务判断塞进同一个大 CTE。核心结果必须能在缺少调度/审计/DBLINK 权限时仍然跑完；可选线索单独给“如果上面结论还不够，再执行”的第二段。
- 遇到 `ORA-00904` 时，下一版必须删除或降级该字段，不要仅换别名；遇到 `ORA-00942` 时，下一版必须删除对应对象引用或改为当前 schema 本地对象版，不要继续猜授权。
- 对用户已经确认的表和字段，优先复用用户回传证据。没有证据时宁可少输出辅助列，也不要为了“完整”加入可能导致整段失败的字段。

## SQL 包格式

默认输出一个脚本。优先一个结果集；确实需要多组明细时，用 `TAG` 字段区分，或说明“同一脚本会返回多组结果”。

用户默认使用 Navicat 执行 Oracle SQL。生成 SQL 时优先采用 Navicat 兼容写法：

- 主 SQL 优先只查当前 schema 的业务表，不加 schema 前缀，不跨 DBLINK，不依赖审计/调度字典权限。跨库对比改成“同一段 SQL 分别在两个连接执行”。
- `UNION`/`UNION ALL` 后需要排序时，把并集包进外层查询或在每个分支输出 `sort_no`，最后 `ORDER BY sort_no`；不要依赖并集结果中的中文别名或未外包的别名排序。
- 聚合结果先放进独立 CTE，再与参数、目标对象或明细 CTE `CROSS JOIN` 输出；不要在同一层 `SELECT` 里混用聚合函数和无分组的标量子查询，避免 `ORA-00937`。
- 输出列统一使用简单英文别名，中文说明放在字段值里；避免需要双引号引用的别名。
- 多结果判断尽量用 `section_name`/`sort_no` 区分，减少 Navicat 结果窗手工切换。

推荐骨架：

```sql
-- 先独立执行并回传数据库身份；后续业务查询即使返回 0 行，也不能省略这一组结果
SELECT USER AS db_user,
       SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS current_schema,
       SYS_CONTEXT('USERENV','DB_NAME') AS db_name
FROM dual;

WITH p AS (
    SELECT
        '替换为关键词/编号' AS p_key,
        '替换为当前登录YHID001' AS p_user,
        CAST(NULL AS VARCHAR2(64)) AS p_optional_id
    FROM dual
),
raw_data AS (
    SELECT ...
    FROM ...
    CROSS JOIN p
    WHERE ... -- 最宽但有边界的候选条件
),
diag AS (
    SELECT
        r.*,
        CASE WHEN ... THEN 'Y' ELSE 'N' END AS will_show,
        TRIM(BOTH '；' FROM
            CASE WHEN ... THEN '原因1；' ELSE '' END ||
            CASE WHEN ... THEN '原因2；' ELSE '' END
        ) AS not_show_reason,
        CASE WHEN EXISTS (...) THEN '页面显示为已勾选且禁用' ELSE '页面显示为可勾选' END AS ui_state
    FROM raw_data r
    CROSS JOIN p
)
SELECT
    COUNT(*) OVER () AS candidate_count,
    SUM(CASE WHEN will_show = 'Y' THEN 1 ELSE 0 END) OVER () AS page_count,
    will_show,
    NVL(not_show_reason, '满足全部页面过滤条件') AS diagnosis_reason,
    ui_state,
    ...
FROM diag
ORDER BY ...
```

输出给用户时只保留必要说明：

- “只需要改这几个参数”
- “执行后把诊断所需列发我；姓名、客户、审批意见和业务正文先脱敏，无关列不要回传”
- “如果结果集太大，先发前 50 行和汇总列”

不要把源码推导过程转嫁给用户，也不要让用户分多步手工判断。

## 回传结果判定

先读库身份和汇总列，再读原因列：

- `page_count = 0`：按 `diagnosis_reason` 归因到具体过滤、权限、状态或断链条件。
- 有 `will_show='Y'` 但页面无数据：优先核对登录人参数、库/schema、代码版本、分页排序、前端二次过滤。
- 显示为禁用/已选中：不是查询不到，而是关联表或状态函数导致 UI 不可操作。
- 结果证明当前业务主键无主表/无候选：给一个最小定位 SQL，不扩散到全库扫描。
- 结果集缺关键字段：只追加一个最小增量 SQL，不让用户重跑全套。
- 用户回传字段或对象不存在错误：优先按“字段兼容”修正 SQL，保持原诊断目标不变，避免让用户在生产库反复试错。

结论必须包含：命中的过滤条件、证据字段、是否符合老/新 OA 真实逻辑、下一步只读查询或待审批修复方向。

## OALS 审批断链特别规则

遇到审批页空白、审批环节列表无数据、`OALS001` 不一致、已处理但无时间/意见、移动端和 PC 审批痕迹不一致时，读取 OALS 参考文件。

判定顺序固定为：

1. 页面/业务表当前查哪个 `OALS001`。
2. 当前流水下是否有 `OA003` 申请头、`OA001` 待办/已办、`OA010` 操作日志。
3. 同一业务主键是否存在旧流水审批痕迹。
4. 是否存在 `DBCL002='02'` 但 `DBCL003/DBCL004` 为空。
5. `F_DB_COMMON_SPLC(ywlx, oals, '')` 对 PC 页面是否返回空。

只读结果确认前，不给可执行修复 DML。确认后也只输出待审批修复草案和校验 SQL，不替用户改生产。

## 状态标签

- `readonly-sql-ready`：已给出一段可执行只读 SQL 包。
- `needs-user-result`：等待用户回传结果集。
- `diagnosed-from-result`：已根据结果集给出根因。
- `needs-one-delta-sql`：只缺一个最小增量 SQL。
- `blocked-needs-source-entry`：缺入口线索且无法从现有材料定位。
- `blocked-unsafe-write`：用户要求生产写入或副作用动作，已停止在安全边界。
