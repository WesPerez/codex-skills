# 案例：老 OA 审批流水/OALS 断链

## 触发场景

老 OA 审批页空白、审批环节列表无数据、业务表 `OALS001` 指向新流水但 `OA001/OA003/OA010` 缺失、已处理记录 `DBCL002='02'` 但 `DBCL003/DBCL004` 为空、移动端显示已处理但 PC 不显示。

本案例是 `oa-readonly-diagnose` 的参考文件，不是独立技能入口。遇到相关线索时，先按主技能要求输出最少步骤的生产只读 SQL 包，再用本文件规则判断结果集。

## 必读源码

优先读取这些老 OA 对象，按本地实际路径：

- `cpzx-oa/sqlFiles/procedures/P_XTGL_COMM_SH_INIT.sql`
- `cpzx-oa/sqlFiles/procedures/P_KSXT_XYYSSP_TJ.sql`
- `cpzx-oa/sqlFiles/procedures/P_OA_DB_SHOW_SPLCTJ.sql`
- `cpzx-oa/sqlFiles/procedures/P_XTGL_COMM_SH_TJ.sql`
- `cpzx-oa/sqlFiles/procedures/P_OA_DB_SET.sql`
- `cpzx-oa/sqlFiles/procedures/P_OA_DB_FQ_SET.sql`
- `cpzx-oa/sqlFiles/procedures/P_XTGL_COMM_SH_PASS.sql`
- `cpzx-oa/sqlFiles/procedures/P_OA_DB_SET_D.sql`
- `cpzx-oa/sqlFiles/procedures/P_OA_DB_SHOW_PASS.sql`
- `cpzx-oa/sqlFiles/procedures/P_SH_MOBILE_YSXY_SH_PASS.sql`
- `cpzx-oa/sqlFiles/functions/F_DB_COMMON_SPLC.sql`

`YWLX001='140'` 预算协议/合同预算审批还必须读取：

- `cpzx-oa/sqlFiles/procedures/P_KSXT_XYYSSP_TJ.sql`
- `cpzx-oa/sqlFiles/procedures/P_OA_DB_SHOW_SPLCTJ.sql`

## 关键机制

`OALS001` 新流水由 `P_XTGL_COMM_SH_INIT` 生成：

```sql
substr(f_sysdate_l, 0, 2) || '-' || in_curr_ywlx001 || '-' ||
lpad(seq_oa001_oals001.nextval, 10, 0)
```

业务提交通常是：

1. 业务提交过程调用 `P_XTGL_COMM_SH_INIT`，生成新 `OALS001`、流程串 `SHLC001`、下一状态。
2. 业务表更新为新 `OALS001`、新 `PHZT001`、新 `SHLC001`。
3. `P_XTGL_COMM_SH_TJ` 调 `P_OA_DB_SET` 插入当前/下一环节 `OA001`。
4. `P_OA_DB_FQ_SET` 基于第一条待办补 `OA003` 申请头。
5. 页面审批环节函数 `F_DB_COMMON_SPLC` 按传入 `OALS001` 查 `OA001`，且已办显示要求 `DBCL003 IS NOT NULL`。

因此，业务表有 `OALS001` 不代表审批链完整。至少要同时核对：

- 业务表当前 `OALS001`
- `OA003` 申请头
- `OA001` 待办/已办
- `OA010` 操作日志
- PC 展示函数返回值

## 140 预算协议高风险点

`P_OA_DB_SHOW_SPLCTJ` 的 `YWLX001='140'` 分支在重新提交时会：

1. 按当前 `OALS001` 找 `KS069`。
2. 调 `P_XTGL_COMM_SH_RESET('140', fjid001, old_oals001, ...)`。
3. 重置 `KS069` 的打印状态、审批流程和审批流水字段。此处只描述已取证的过程行为，不提供可直接执行的 DML；生产诊断仍只允许只读 SQL。
4. 再调 `P_KSXT_XYYSSP_TJ`，生成并绑定新 `OALS001`。

如果 reset/重提后 `OA001/OA003/OA010` 未完整落库，就会出现“业务表指向新流水，旧流水保留审批痕迹，新流水页面空白”。

## 只读 SQL 参考

读取 `approval-oals-diagnostic-sql.md`。输出给用户时不要机械照搬全部段落，优先压缩成一次执行脚本；只有业务表、主键或流水无法定位时，才拆成“定位 SQL + 明细 SQL”两步。

结果集必须能回答：

- 业务表当前指向哪个 `OALS001`。
- 当前 `OALS001` 是否有 `OA003` 申请头。
- 当前 `OALS001` 是否有 `OA001` 待办/已办。
- 当前 `OALS001` 是否有 `OA010` 操作日志。
- 同一业务主键是否还有其他历史 `OALS001`。
- 是否存在 `DBCL002='02'` 但 `DBCL003/DBCL004` 为空。
- `F_DB_COMMON_SPLC(ywlx, oals, '')` 对当前流水是否返回空。

## 判定标签

- `业务表空壳流水`：业务表当前 `OALS001` 有值，但当前流水下 `OA001/OA003/OA010` 全部或关键记录缺失。
- `旧流水残留审批`：同一 `ZJID003/FJID001` 在旧 `OALS001` 下存在 `OA001/OA003/OA010`。
- `半成品已办`：`OA001.DBCL002='02'`，但 `DBCL003` 或 `DBCL004` 为空。
- `PC 不显示原因明确`：`F_DB_COMMON_SPLC` 查当前流水为空，或对应环节 `DBCL003 IS NULL`。
- `移动端/PC 落库不一致`：移动端显示已处理，但缺 `OA010` 通过日志或缺 `DBCL003/DBCL004`。

## 固定判定顺序

1. 定位业务类型：查 `SP001`，确认业务表、主键字段、业务类型。
2. 查目标业务表当前状态：当前 `OALS001`、`PHZT001`、`SHLC001`、创建人、更新时间。
3. 用当前 `OALS001` 查 `OA001/OA003/OA010` 行数和明细。
4. 用业务主键 `ZJID003/FJID001` 反查所有历史 `OALS001`。
5. 对比当前流水与历史流水：哪个有申请头，哪个有审批行，哪个有日志。
6. 查异常已办：`DBCL002='02' AND (DBCL003 IS NULL OR DBCL004 IS NULL)`。
7. 查 PC 展示函数：`F_DB_COMMON_SPLC(ywlx, oals, '')` 只返回长度和存在性状态，不回传 HTML 正文。
8. 按标签输出原因，不把缓存、浏览器或页面刷新作为首因。

## 本案证据摘要

历史案例 `YWLX001=<业务类型>`、`FJID001=<业务主键>`：

- `KS069.OALS001=<当前流水>`
- `OA001/OA003/OA010` 有效审批数据主要在旧流水 `<旧流水>`
- 当前 `<当前流水>` 下审批关联为空，PC 函数返回空
- `<处理人>` 记录在旧流水下 `DBCL002=02`，但 `DBCL003/DBCL004` 为空，且缺 `OA010` 通过日志
- 根因形态：重新提交/重置后业务表指向新流水，但审批流未完整落库；旧流水残留半成品审批痕迹
