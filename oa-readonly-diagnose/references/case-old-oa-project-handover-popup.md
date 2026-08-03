# 案例：老 OA 项目交接项目编号选择弹窗

## 触发场景

用户给出老 OA “项目交接”截图，弹窗标题为“项目编号选择列表”，按项目编号关键字搜索后显示条数少于预期，需要生产只读 SQL 判断为什么某些项目不出现。

## 源码入口

- 主入口：`cpzx-oa/web/WEB-INF/jsp/application/ks/ksxt/wdsplc/wdxmjj/ksxt_wdxmjj_l.jsp`
- 编辑页：`cpzx-oa/web/WEB-INF/jsp/application/ks/ksxt/wdsplc/wdxmjj/ksxt_wdxmjj_iu.jsp`
- 项目选择弹窗：`cpzx-oa/web/WEB-INF/jsp/application/ks/ksjhsd/common/ksjhsd_common_ks009_xmjj_select.jsp`
- 页面入口配置：`cpzx-oa/sqlFiles/frame_tables/FRAME_PAGE.sql`
- 弹窗查询配置：`cpzx-oa/sqlFiles/frame_tables/FRAME_TASK_QUERY.sql`
- 弹窗列表 SQL：`cpzx-oa/sqlFiles/frame_tables/FRAME_LIST.sql`
- 弹窗过滤条件：`cpzx-oa/sqlFiles/frame_tables/FRAME_TASK_QUERY_WHERE.sql`
- 保存/关联写入配置：`cpzx-oa/sqlFiles/frame_tables/FRAME_COMMIT.sql`

弹窗 JSP 使用：

- `listData id="ksxt_wdxmjj_xm_select"`
- `taskStr="tq_ksxt_wdxmjj_xm_select#001"`
- 确认选择后把选中的 `KSID001` 逗号串写入 `done_form.KSID001`
- 保存链路：`jq_commsave -> common_ajax_save -> CommonSave -> FRAME_COMMIT`

## 老 OA 查询口径

`FRAME_LIST.ksxt_wdxmjj_xm_select`：

```sql
select KSBH001, KSID001, FZR0001, KHID001 KHID, SFXY009,
       XMSS001, YJSJ004, YJSJ005, CJR0001, CJSJ001
from ks009
```

显示列会调用：

- `f_xm041_xmjj_checkbox(KSID001, ?L_1*, ?CJR0001*)`
- `f_ht002_yhmc001`
- `frame_dict_str('BM00001', ...)`
- `frame_dict_str('JHGS001_GS', ...)`

`FRAME_TASK_QUERY_WHERE.tq_ksxt_wdxmjj_xm_select#001` 核心过滤：

```sql
{KSBH001 like '%?KSBH001*%'}
and YXBZ001='01'
and CWDZ001 is null
and TJSJ001 is null
and (
    f_ht002_yxbz001(fzr0001) = '02'
    or {fzr0001=?CJR0001*}
)
order by CJSJ001 desc
```

含义：项目有效、未财务到账、未提交，且项目负责人是当前登录人或负责人已失效/不可用。

## 写入副作用

不要执行保存。弹窗确认会通过：

- `xmjj_glxm_xm041_i`
- `p_xmjj_glxm_xm041_u_check`

写入/恢复 `XM041` 交接项目关联。取消选择或列表删除会把 `XM041.YXBZ001` 改为 `02`。

## 一次执行诊断 SQL

只让用户改顶部 3 个参数。`p_xmjj002` 是当前项目交接申请单 id；新增还没有申请单时填 `NULL`。

```sql
SELECT user AS db_user,
       sys_context('USERENV', 'CURRENT_SCHEMA') AS current_schema,
       sys_context('USERENV', 'DB_NAME') AS db_name
  FROM dual;

WITH p AS (
    SELECT
        '2065' AS p_ksbh001,
        '替换为当前登录YHID001' AS p_cjr0001,
        CAST(NULL AS VARCHAR2(64)) AS p_xmjj002
    FROM dual
),
raw_data AS (
    SELECT
        k.KSID001,
        k.KSBH001,
        k.YXBZ001,
        k.CWDZ001,
        k.TJSJ001,
        k.FZR0001,
        k.CJR0001,
        k.XMSS001,
        k.YJSJ005,
        k.YJSJ004,
        k.CJSJ001,
        f_ht002_yxbz001(k.FZR0001) AS FZR_YXBZ001
    FROM KS009 k
    CROSS JOIN p
    WHERE k.KSBH001 LIKE '%' || p.p_ksbh001 || '%'
),
diag AS (
    SELECT
        r.*,
        CASE
            WHEN r.YXBZ001 = '01'
             AND r.CWDZ001 IS NULL
             AND r.TJSJ001 IS NULL
             AND (
                    r.FZR_YXBZ001 = '02'
                    OR r.FZR0001 = p.p_cjr0001
                 )
            THEN 'Y'
            ELSE 'N'
        END AS WILL_SHOW,
        TRIM(BOTH '；' FROM
            CASE WHEN r.YXBZ001 <> '01' OR r.YXBZ001 IS NULL
                 THEN 'YXBZ001不是01；' ELSE '' END ||
            CASE WHEN r.CWDZ001 IS NOT NULL
                 THEN 'CWDZ001不为空；' ELSE '' END ||
            CASE WHEN r.TJSJ001 IS NOT NULL
                 THEN 'TJSJ001不为空；' ELSE '' END ||
            CASE WHEN NOT (
                    r.FZR_YXBZ001 = '02'
                    OR r.FZR0001 = p.p_cjr0001
                 )
                 THEN '负责人条件不满足：FZR0001不是当前登录人，且f_ht002_yxbz001(FZR0001)不是02；'
                 ELSE '' END
        ) AS NOT_SHOW_REASON,
        CASE
            WHEN EXISTS (
                SELECT 1
                FROM XM041 x
                WHERE x.KSID001 = r.KSID001
                  AND (x.XMJJ002 IS NULL OR x.XMJJ002 = p.p_xmjj002)
                  AND x.YXBZ001 = '01'
                  AND x.CJR0001 = p.p_cjr0001
            )
            THEN '页面显示为已勾选且禁用'
            ELSE '页面显示为可勾选'
        END AS CHECKBOX_STATUS
    FROM raw_data r
    CROSS JOIN p
)
SELECT
    COUNT(*) OVER () AS 匹配项目编号总数,
    SUM(CASE WHEN WILL_SHOW = 'Y' THEN 1 ELSE 0 END) OVER () AS 弹窗应显示条数,
    WILL_SHOW AS 是否会出现在弹窗,
    NVL(NOT_SHOW_REASON, '满足全部弹窗过滤条件') AS 不显示原因,
    CHECKBOX_STATUS AS 复选框状态,
    KSBH001 AS 项目编号,
    KSID001 AS 项目ID,
    FZR0001 AS 项目负责人ID,
    FZR_YXBZ001 AS 项目负责人有效标识,
    CJR0001 AS 项目创建人ID,
    XMSS001 AS 项目所属部门代码,
    YJSJ005 AS 业绩实际所属部门代码,
    YJSJ004 AS 业绩实际所属公司代码,
    YXBZ001,
    CWDZ001,
    TJSJ001,
    CJSJ001 AS 项目创建时间
FROM diag
ORDER BY
    CASE WHEN WILL_SHOW = 'Y' THEN 0 ELSE 1 END,
    CJSJ001 DESC;
```

## 判定样例

用户回传结果中：

- `匹配项目编号总数 = 7`
- `弹窗应显示条数 = 2`
- 两条 `WILL_SHOW=Y` 正好是页面截图中的 `<页面应显示项目1>`、`<页面应显示项目2>`
- 其余行原因均为负责人条件不满足

结论：页面显示 2 条是老 OA 真实过滤逻辑导致，不是生产数据缺失、分页错误或已选禁用。
