# 老 OA 审批 OALS 只读诊断 SQL 参考

以下 SQL 面向 Oracle 老 OA。它是 `oa-readonly-diagnose` 生成最终 SQL 包时的素材，不要求每次全部输出；优先按用户给出的业务类型、主键、流水压缩成一次执行脚本。

执行前替换：

- `:YWLX`：业务类型，如 `140`
- `:PK`：业务主键的具体绑定值，如某条记录的 `FJID001` 值；不要填写字段表达式
- `:CURR_OALS`：业务表当前流水；未知时显式绑定 `NULL`，查出后再替换为具体值

## 0. 库身份

任何发给用户执行的 OALS 诊断 SQL 包，都必须把库身份放在第一组结果，便于确认结果来自目标库和目标 schema。

```sql
SELECT '00_DB_ID' tag,
       USER AS db_user,
       SYS_CONTEXT('USERENV','CURRENT_SCHEMA') AS current_schema,
       SYS_CONTEXT('USERENV','DB_NAME') AS db_name
  FROM dual;
```

## 1. 对象和配置

```sql
SELECT '00_OBJECTS' tag, object_type, object_name, status
  FROM user_objects
 WHERE object_name IN (
       'SP001','SP002','OA001','OA003','OA010','KS069','KS012','FRAME_DICT',
       'F_DB_COMMON_SPLC','P_XTGL_COMM_SH_INIT','P_KSXT_XYYSSP_TJ',
       'P_OA_DB_SHOW_SPLCTJ','P_XTGL_COMM_SH_TJ','P_OA_DB_SET',
       'P_OA_DB_FQ_SET','P_XTGL_COMM_SH_PASS','P_OA_DB_SET_D',
       'P_OA_DB_SHOW_PASS','P_SH_MOBILE_YSXY_SH_PASS')
 ORDER BY object_type, object_name;

SELECT '01_SP001' tag, ywlx001, splc001, bm00002, zdm0001, spzt002
  FROM sp001
 WHERE ywlx001 = :YWLX;

SELECT '02_DICT' tag, dmlb001, dm00001, dmmc001, sxh0001
  FROM frame_dict
 WHERE dmlb001 = (SELECT spzt002 FROM sp001 WHERE ywlx001 = :YWLX)
 ORDER BY sxh0001, dm00001;
```

## 2. 140 预算协议/合同预算审批目标业务表

适用于 `YWLX='140'`、主表 `KS069`。

```sql
SELECT '10_TARGET_KS069' tag,
       k.fjid001, k.oals001, k.ywlx001, k.phzt001,
       frame_dict_str((SELECT spzt002 FROM sp001 WHERE ywlx001 = k.ywlx001), k.phzt001) phzt_name,
       k.shlc001, k.cjr0001, k.cjsj001, k.xgsj001,
       x.ksid001, x.xyqd002
  FROM ks069 k
  LEFT JOIN ks012 x ON x.fjid001 = k.fjid001
 WHERE k.fjid001 = :PK;
```

## 3. 当前流水完整性

```sql
SELECT '20_LINK_COUNTS_BY_OALS' tag,
       o.oals001,
       SUM(CASE WHEN src = 'OA003' THEN cnt ELSE 0 END) oa003_cnt,
       SUM(CASE WHEN src = 'OA001' THEN cnt ELSE 0 END) oa001_cnt,
       SUM(CASE WHEN src = 'OA001_PENDING' THEN cnt ELSE 0 END) oa001_pending_cnt,
       SUM(CASE WHEN src = 'OA001_DONE' THEN cnt ELSE 0 END) oa001_done_cnt,
       SUM(CASE WHEN src = 'OA010' THEN cnt ELSE 0 END) oa010_cnt
  FROM (
        SELECT :CURR_OALS oals001 FROM dual
        UNION
        SELECT oals001 FROM oa001 WHERE zjid003 = :PK AND ywlx001 = :YWLX
        UNION
        SELECT oals001 FROM oa003 WHERE zjid003 = :PK AND ywlx001 = :YWLX
        UNION
        SELECT oals001 FROM oa010 WHERE zjid003 = :PK AND ywlx001 = :YWLX
       ) o
  LEFT JOIN (
        SELECT 'OA003' src, oals001, COUNT(*) cnt FROM oa003 WHERE zjid003 = :PK AND ywlx001 = :YWLX GROUP BY oals001
        UNION ALL
        SELECT 'OA001' src, oals001, COUNT(*) cnt FROM oa001 WHERE zjid003 = :PK AND ywlx001 = :YWLX GROUP BY oals001
        UNION ALL
        SELECT 'OA001_PENDING' src, oals001, COUNT(*) cnt FROM oa001 WHERE zjid003 = :PK AND ywlx001 = :YWLX AND dbcl002 = '01' GROUP BY oals001
        UNION ALL
        SELECT 'OA001_DONE' src, oals001, COUNT(*) cnt FROM oa001 WHERE zjid003 = :PK AND ywlx001 = :YWLX AND dbcl002 = '02' GROUP BY oals001
        UNION ALL
        SELECT 'OA010' src, oals001, COUNT(*) cnt FROM oa010 WHERE zjid003 = :PK AND ywlx001 = :YWLX GROUP BY oals001
       ) c ON c.oals001 = o.oals001
 GROUP BY o.oals001
 ORDER BY o.oals001;
```

## 4. 申请头、审批行、操作日志明细

```sql
SELECT '30_OA003' tag,
       oals001, ywlx001, zjid003, ksid001,
       sqr0001, sqsj001, cjr0001, cjsj001, shlc002
  FROM oa003
 WHERE zjid003 = :PK
   AND ywlx001 = :YWLX
 ORDER BY cjsj001, oals001;

SELECT '31_OA001' tag,
       oadb001, oals001, ywlx001, zjid003, dbzt001,
       frame_dict_str((SELECT spzt002 FROM sp001 WHERE ywlx001 = :YWLX), dbzt001) dbzt_name,
       dbcl001,
       dbcl002, frame_dict_str('DBCL002', dbcl002) dbcl002_name,
       CASE WHEN dbcl003 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl003_state,
       CASE WHEN dbcl004 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl004_state,
       gxsj001, cjr0001, cjsj001
  FROM oa001
 WHERE zjid003 = :PK
   AND ywlx001 = :YWLX
 ORDER BY oals001, cjsj001, dbzt001, oadb001;

SELECT '32_OA010' tag,
       oacz001, oals001, ywlx001, zjid003, czlx003,
       frame_dict_str('CZLX003', czlx003) czlx_name,
       dbzt001,
       frame_dict_str((SELECT spzt002 FROM sp001 WHERE ywlx001 = :YWLX), dbzt001) dbzt_name,
       czy0001, czsj001,
       CASE WHEN dbcl004 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl004_state,
       cjr0001, cjsj001, sqr0001
  FROM oa010
 WHERE zjid003 = :PK
   AND ywlx001 = :YWLX
 ORDER BY czsj001, oacz001;
```

## 5. 半成品已办和孤儿审批

```sql
SELECT '40_HALF_DONE' tag,
       oals001, zjid003, dbzt001,
       dbcl001, dbcl002,
       CASE WHEN dbcl003 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl003_state,
       CASE WHEN dbcl004 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl004_state,
       cjsj001
  FROM oa001
 WHERE zjid003 = :PK
   AND ywlx001 = :YWLX
   AND dbcl002 = '02'
   AND (dbcl003 IS NULL OR dbcl004 IS NULL)
 ORDER BY oals001, cjsj001;

SELECT '41_ORPHAN_OA001' tag,
       a.oals001, a.zjid003, a.dbzt001, a.dbcl001,
       a.dbcl002,
       CASE WHEN a.dbcl003 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl003_state,
       CASE WHEN a.dbcl004 IS NULL THEN 'EMPTY' ELSE 'PRESENT' END dbcl004_state,
       CASE WHEN EXISTS (SELECT 1 FROM oa003 h WHERE h.oals001 = a.oals001 AND h.zjid003 = a.zjid003 AND h.ywlx001 = a.ywlx001)
            THEN 'HAS_OA003' ELSE 'NO_OA003' END oa003_state,
       CASE WHEN EXISTS (SELECT 1 FROM ks069 k WHERE k.oals001 = a.oals001 AND k.fjid001 = a.zjid003)
            THEN 'CURRENT_BIZ_OALS' ELSE 'NOT_CURRENT_BIZ_OALS' END biz_oals_state
  FROM oa001 a
 WHERE a.zjid003 = :PK
   AND a.ywlx001 = :YWLX
 ORDER BY a.oals001, a.cjsj001;
```

## 6. PC 审批环节函数验证

```sql
SELECT '50_PC_HTML' tag,
       oals001,
       LENGTH(pc_html) html_len,
       CASE WHEN pc_html IS NULL THEN 'EMPTY' ELSE 'PRESENT' END html_state
  FROM (
        SELECT :CURR_OALS oals001,
               f_db_common_splc(:YWLX, :CURR_OALS, '') pc_html
          FROM dual
       );

SELECT '51_PC_HTML_ALL_OALS' tag,
       oals001,
       LENGTH(pc_html) html_len,
       CASE WHEN pc_html IS NULL THEN 'EMPTY' ELSE 'PRESENT' END html_state
  FROM (
        SELECT ids.oals001,
               f_db_common_splc(:YWLX, ids.oals001, '') pc_html
          FROM (
                SELECT :CURR_OALS oals001 FROM dual
                UNION
                SELECT oals001 FROM oa001 WHERE zjid003 = :PK AND ywlx001 = :YWLX
                UNION
                SELECT oals001 FROM oa003 WHERE zjid003 = :PK AND ywlx001 = :YWLX
                UNION
                SELECT oals001 FROM oa010 WHERE zjid003 = :PK AND ywlx001 = :YWLX
               ) ids
       )
 ORDER BY oals001;
```

## 7. 状态对比汇总

```sql
SELECT '60_STATUS_COMPARE' tag,
       k.fjid001, k.oals001 curr_oals001, k.ywlx001, k.phzt001,
       frame_dict_str((SELECT spzt002 FROM sp001 WHERE ywlx001 = k.ywlx001), k.phzt001) phzt_name,
       k.shlc001,
       CASE
         WHEN k.oals001 IS NULL THEN 'BAD:业务表OALS为空'
         WHEN NOT EXISTS (SELECT 1 FROM oa003 h WHERE h.oals001 = k.oals001 AND h.zjid003 = k.fjid001 AND h.ywlx001 = k.ywlx001)
          AND NOT EXISTS (SELECT 1 FROM oa001 a WHERE a.oals001 = k.oals001 AND a.zjid003 = k.fjid001 AND a.ywlx001 = k.ywlx001)
          THEN 'BAD:当前OALS无OA003/OA001'
         WHEN EXISTS (SELECT 1 FROM oa001 a WHERE a.oals001 = k.oals001 AND a.zjid003 = k.fjid001 AND a.ywlx001 = k.ywlx001 AND a.dbcl002='02' AND a.dbcl003 IS NULL)
          THEN 'BAD:当前OALS存在已处理但无处理时间'
         ELSE 'OK:当前OALS有关联审批数据'
       END diagnose,
       (SELECT COUNT(*) FROM oa003 h WHERE h.oals001 = k.oals001 AND h.zjid003 = k.fjid001 AND h.ywlx001 = k.ywlx001) curr_oa003_cnt,
       (SELECT COUNT(*) FROM oa001 a WHERE a.oals001 = k.oals001 AND a.zjid003 = k.fjid001 AND a.ywlx001 = k.ywlx001) curr_oa001_cnt,
       (SELECT COUNT(*) FROM oa010 l WHERE l.oals001 = k.oals001 AND l.zjid003 = k.fjid001 AND l.ywlx001 = k.ywlx001) curr_oa010_cnt,
       (SELECT COUNT(DISTINCT oals001) FROM oa001 a WHERE a.zjid003 = k.fjid001 AND a.ywlx001 = k.ywlx001 AND a.oals001 <> k.oals001) other_oa001_oals_cnt
  FROM ks069 k
 WHERE k.fjid001 = :PK
   AND k.ywlx001 = :YWLX;
```

## 本案证据摘要

脱敏案例 `YWLX001=<业务类型>`、`FJID001=<业务主键>`：

- `KS069.OALS001=<当前流水>`
- `OA001/OA003/OA010` 有效审批数据主要在旧流水 `<旧流水>`
- 当前 `<当前流水>` 下审批关联为空，PC 函数返回空
- `<处理人>` 记录在旧流水下 `DBCL002=02`，但 `DBCL003/DBCL004` 为空，且缺 `OA010` 通过日志
- `<当前流水>` 的生成规则来自 `P_XTGL_COMM_SH_INIT`：`substr(f_sysdate_l,0,2) || '-' || ywlx || '-' || lpad(seq_oa001_oals001.nextval,10,0)`
- 根因形态：重新提交/重置后业务表指向新流水，但审批流未完整落库；旧流水残留半成品审批痕迹
