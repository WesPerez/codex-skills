# 老 OA JSP / FRAME / Oracle SQL 追踪检查清单

## 执行前

- [ ] 已确认调用方/用户目标：业务对比、老 OA 独立取证、生产只读诊断、页面报错、真实浏览器验收或写入副作用评估。
- [ ] 已确认入口类型：Struts forward / JSP URL / JSP 文件 / FRAME 配置 id。
- [ ] 已确认真实路径存在，未假设不存在的目录。
- [ ] 已确认是否需要真实数据库；需要时先定位老 OA Proxool / `OracleQuery.java` / 只读工具入口，不使用新 OA SQL gate。
- [ ] 已确认数据库身份、当前 `USER`、`CURRENT_SCHEMA`；身份不清按生产库只读处理；无法连接时输出待执行只读 SQL。
- [ ] 已确认不会执行 DDL/DML、保存、下载完成、打印完成、审批流转、状态变更。
- [ ] 如需使用 `OracleQuery.java`，只用本技能目录内的 `references/OracleQuery.java` 作为只读查询模板，不输出账号、密码、token、完整连接串。
- [ ] 若页面错误、按钮点击、下载文件、9099/Tomcat 日志或 Network/console 是验收目标，已准备交给 `oa-dev-verification-gate` / `oa-real-action-evidence`，不把静态追踪当动作闭环。

## JSP / FRAME

- [ ] 已定位 Struts forward、JSP 入口、include 链路。
- [ ] 已逐行解析 JSP：include、taglib、隐藏域、表单、按钮、弹窗、JS、提交函数。
- [ ] 已提取 `nf:dst`、`nf:dstData`、`nf:listDst`、`nf:listData`、`nf:list`、`nf:form`、`nf:input`。
- [ ] 已提取 `commitIDArrStr`、`commitIDArrStr_i`、`commitIDArrStr_u`、`GlobalUtil.encrypt(...)`、`a_save(this)`、`jq_commsave(...)`、`l_para`、`frame_list_curr_page`。
- [ ] 已追 `common_save.jsp`、`common_ajax_save.jsp`、`frame_list.jsp`、`frame_ajax_save.js`。
- [ ] 已读 `ConnectUtil.java`、`FrameList.java`、`FrameQuery.java`、`FrameCommit.java`、`CommonSave.java`、`DatabaseTool.java`。
- [ ] 已记录 `frame_alias` / `frame_cfalias` / Proxool alias 数据源分支；未输出凭据。

## SQL / 函数

- [ ] 已展开 `FRAME_QUERY`。
- [ ] 已展开 `FRAME_LIST`。
- [ ] 已展开 `FRAME_TASK_QUERY`。
- [ ] 已展开 `FRAME_TASK_QUERY_WHERE`。
- [ ] 已展开 `FRAME_COMMIT`。
- [ ] 已对 `#001/#002/#003` 等版本逐项展开，未写“同上”。
- [ ] 已记录 `SQL_STR`、`SQL_NAME`、`OUT_STR`、`ALIAS`、`SEQ_ID`、入参、where、排序、分页、返回列、保存副作用。
- [ ] 已递归追踪 `F_*`、`P_*`、包调用、`call`。
- [ ] 已记录函数/过程入参来源、变量含义、查询表、更新表、条件分支、返回值、异常分支、副作用风险。
- [ ] 对写入、副作用、下载带记录、审批/流程/状态流转，已列影响表、条件、读回/恢复要素，未执行。

## 状态与交接

- [ ] 已给出精确状态：`old-oa-source-traced`、`old-oa-db-readonly-pass`、`needs-old-oa-db-connection`、`needs-readonly-db-result`、`needs-browser-action-evidence`、`runtime-log-required`、`side-effect-not-executed`、`blocked-production-or-unknown-db-write` 或 `blocked-old-oa-write-gate-missing`。
- [ ] 已写清下一跳 owner：`oa-business-logic-compare`、`oa-readonly-diagnose`、`oa-dev-verification-gate`、`oa-real-browser-driver` / `oa-real-action-evidence`，或无下一跳。
- [ ] 若交给调用方，已附入口、已读文件、FRAME id、展开 SQL、数据库身份/缺口、样例条件、副作用清单和未验证项。

## 输出

- [ ] 已按报告模板输出：调用与状态、入口与假设、JSP/Struts、标签与按钮、公共入口、数据源与工具、FRAME 映射、SQL 展开、函数/过程、数据库只读校验、表字段注释、副作用、未验证项、风险提示。
- [ ] 未泄露凭据。
- [ ] 若本次创建临时 `OracleQuery.java` / `.class`，已确认它们属于本次任务后再清理；无法证明归属则保留并询问。
