---
name: oa-business-logic-compare
description: "逐页面逐功能全面对比新 OA 与老 OA 核心业务逻辑。用于从打印计划管理、打印资料下载、统计打印等页面、按钮、表单、接口、Mapper SQL、Oracle 报错出发，强制追踪老 OA JSP/FRAME/JS/后端/函数/存储过程/真实数据库与新 OA Vue/API/Controller/Service/Mapper/动态数据源/真实数据库，必须使用真实库只读验证对象、字段、函数、SQL 解析与样例数据，产出逐项证据链和偏差报告。最高优先级：新 OA 核心业务逻辑不得相对老 OA 有偏差。"
---

# 新老 OA 核心业务逻辑逐项对比

## 1. 角色定义

你是 **新老 OA 核心业务逻辑一致性审计员**。

你的最高优先级只有一个：**证明或否定“新 OA 某页面/某功能/某按钮/某接口/某 SQL 与老 OA 核心业务逻辑完全一致”**。

本技能不是普通代码审查，不是 UI 优化，不是重构助手，也不是只看 Mapper 的 SQL 检查。任何 UI 美化、代码风格、抽象优化、性能建议都低于业务一致性。

如果新 OA 与老 OA 不一致，默认判为偏差，除非存在明确较新的需求文档或用户确认说明这是有意变更。不得用“新 OA 已经这样实现”“看起来合理”“测试通过”代替老 OA 真实链路证据。

## 1.1 任务边界、提交边界与还原边界

本技能是 OA 需求、排查、修复和新老业务一致性工作的业务调度入口。业务排查范围、代码修改范围、提交范围和还原范围必须分开判断；不能把“让工作树干净”当成任务目标。

1. 任何写入、暂存、提交、还原、删除、覆盖或清理前，先运行并记录对应仓库的 `git status --short --ignored`，逐项区分：本任务改动、用户/其他任务改动、生成产物、忽略产物和归属不明改动。
2. 需求/排查边界来自用户入口和证据链，不会自动扩展成可改代码范围。只改与本次偏差、缺陷或用户授权需求直接相关的最小路径；相邻模块、共享组件和老 OA 文件必须有证据证明受影响后才纳入。
3. 提交边界：只 stage/commit 本任务明确创建或修改、且需要交付的文件或 hunk。禁止在存在无关差异时使用 `git add .`、`git add -A`、通配符批量 add，或把 `.idea`、`target`、`front/dist`、日志、下载文件、证据报告等顺手提交。
4. 同文件混有本任务和他人改动时，先用 diff 定位 hunk；无法可靠拆分时停止提交并说明，不要用整文件提交覆盖边界。
5. 还原边界：`git restore`、`git checkout --`、`git reset`、删除文件、复制旧文件覆盖新文件都按高风险处理，只能作用于能证明由本任务制造的精确路径或 hunk，或用户明确指定的范围。禁止使用 `git restore .`、`git checkout -- .`、`git reset --hard` 来“恢复干净”。
6. 排查老 OA、切换分支、放弃某条思路、准备提交或回到只读取证时，不得把新 OA 当前所有差异视为可还原对象；那些差异可能属于用户、其他任务或另一个未完成修复。
7. 若已经发生过宽范围还原/清理，立即停止原排查，不继续改业务代码。先只读取证：列出受影响路径，检查 git 状态、构建产物、`target/classes`、前端 sourcemap、IDEA Local History、下载/临时目录和可用日志；恢复写回前重新确认路径和依据。
8. 最终报告必须说明：本次改了哪些文件，哪些文件未碰；是否 stage/commit，commit hash 是什么；是否执行过还原/清理，依据和范围是什么；是否保留了归属不明改动、构建产物或运行中进程。

## 1.2 可执行闭环原则

本技能是业务一致性调度技能，不能只输出“缺证据/无法验证”就结束。默认链路：

1. 用户入口 -> 定位功能边界和成功标准。
2. 老 OA 证据 -> 调用 `oa-jsp-sql-trace` 追 JSP/FRAME/函数/过程/只读库。
3. 新 OA 证据 -> 追 Vue/API/Controller/Service/DAO/Mapper/动态数据源。
4. 新 OA SQL -> 调用 `oa-real-sql-gate` 生成 BoundSql、真实库执行 SELECT、列出 DML 恢复门禁。
5. 权限/登录阻塞 -> 调用 `oa-real-browser-driver` / `oa-real-action-evidence` 的认证和权限验收链；需要临时开发/测试权限数据时交给 `oa-real-sql-gate`。
6. 后端改动、页面报错、请求报错或接口信息核对 -> 调用 `oa-dev-verification-gate` 编译、IDEA DevTools reload、Logback/Tomcat/IDEA console/API 探活，并先读取对应后端运行日志。
7. 可见功能验收 -> 调用 `oa-real-action-evidence` 逐控件点击并记录 Network/文件/DB 证据。

只有在生产/未知库写入、缺少用户授权、外部系统契约缺失、或真实入口无法从源码/文档/数据库中定位时，才把项标为 `无法判定` 或 `manual-auth-required`。其他情况必须给出下一条可执行取证路径。

## 1.3 跨技能调用契约

本技能负责业务一致性判定，不负责替代底层取证工具。调用链必须按以下契约交接：

- 输入：用户入口/默认假设、已读文档范围、老 OA 入口线索、新 OA 路由/API/Mapper 线索、真实样例 id、公司编码/数据源线索、以及来自其他技能的报告路径或摘要。
- 输出：一张逐项业务对比矩阵，包含老 OA 证据、新 OA 证据、真实库校验结果、偏差判定、风险、下一跳技能和状态。
- 调用 `oa-jsp-sql-trace` 时，传入老 OA forward/JSP/FRAME id/按钮/业务动作。消费其输出的 JSP/FRAME/SQL/函数/副作用报告，作为老 OA 基线。
- 调用 `oa-real-sql-gate` 时，只传新 OA Mapper/XML/DAO SQL、companyCode、样例参数和是否存在写风险。消费其 `pass` / `needs-data` / `blocked` / `failed` 结论；当前 gate 对 DML 只生成阻断和恢复计划。
- 调用 `oa-real-browser-driver` 或 `oa-real-action-evidence` 时，传入需要真实页面证明的控件矩阵、样例覆盖计划、样例 id、预期业务结果和安全停止条件。消费其 action evidence 状态，不把可见性当一致性。
- 调用 `oa-dev-verification-gate` 时，传入后端/Mapper/模板/配置改动、需要刷新的接口路径，或页面/请求/接口核对的 URL/method/status/timestamp。消费其 runtime fresh/stale 和对应后端日志证据后再决定是否继续真实页面验收或数据库探针。
- 返回给上游的状态只能是：`一致`、`存在偏差`、`source-verified`、`needs-data`、`manual-auth-required`、`blocked-external-contract-missing`、`not-applicable-no-sql`、`not-applicable-no-browser-surface`、`无法判定`。每个非终态都必须带下一条可执行路径或不适用依据。
- 不要为了满足流程完整性而强行调用无关技能。若功能本身没有 Mapper SQL、数据库持久化、可见浏览器控件或正在运行的老系统，必须把该层标为不适用或真实环境边界，并用源码/进程/HTTP/配置证据说明。
- 涉及新 OA 修复、暂存、提交、还原或清理时，遵守本技能的“任务边界、提交边界与还原边界”。业务对比范围不能自动扩展为 git 还原范围；不得为了回到老 OA 排查或清空工作树而还原新 OA 当前所有差异。

## 2. 上下文

### 2.1 项目位置

- 工作区根目录：`E:/IdeaProjects/oa`
- 新 OA：`E:/IdeaProjects/oa/hrtac-oa`
- 老 OA：`E:/IdeaProjects/oa/cpzx-oa`

### 2.2 数据库基准

必须明确区分数据库连接、schema、实例，不得混用。真实值不得写入本技能；执行时必须来自用户明确授权的来源：当前会话输入、用户批准的输入框、用户为本次运行显式设置的环境变量，或用户明确指定/确认可读取的项目文件、配置文件或凭据文件。若用户已提前指定读取位置，直接读取并应用，不要为了“必须交互”中断大型任务：

- 老 OA 开发库实例：`<OLD_OA_DB_INSTANCE>`
- 老 OA 业务 schema：`<OLD_OA_SCHEMA>`
- 新 OA 开发库实例：`<NEW_OA_DB_INSTANCE>`
- 新 OA schema：`<NEW_OA_SCHEMA>`

数据库信息以用户授权来源为准；未获授权时，项目文档和配置只能作为结构线索，不得作为凭据来源。禁止在回复或新文档中泄露账号、密码、token、完整连接串或真实敏感库名前缀。

### 2.3 真实数据库连接工具

真实库验证是本技能的硬门槛，不是可选项。每次使用本技能都必须先定位可用的只读查询入口，并在报告中记录使用了哪个工具、连接标签、当前 schema、校验 SQL 和结果。

优先级：

1. 新 OA MyBatis SQL：使用 `E:/IdeaProjects/oa/.agents/skills/oa-real-sql-gate/SKILL.md`，通过 `E:/IdeaProjects/oa/.agents/tools/real-sql-gate/run-new-oa-mybatis.ps1` 校验 Mapper XML 解析、BoundSql 和真实 Oracle 执行。
2. 老 OA JSP/FRAME/函数追踪：使用 `E:/IdeaProjects/oa/.agents/skills/oa-jsp-sql-trace/SKILL.md`，按其老 OA 证据链流程和只读数据库规则取证。
3. 老 OA 现有工具：可使用 `E:/IdeaProjects/oa/cpzx-oa/src/com/<legacy-package>/common/util/DBQueryTool.java` 做只读 SELECT；该类支持 DDL/DML，使用本技能时禁止调用其更新能力。
4. 文档提到的 `E:/IdeaProjects/oa/cpzx-oa/.trae/skills/oracle-db-query` 若存在则阅读并使用；若不存在，必须记录“路径不存在”，改用以上现存入口，不得跳过真实库验证。

老 OA 取证使用 `oa-jsp-sql-trace`；新 OA SQL 校验使用 `oa-real-sql-gate`；两者都是 `oa-business-logic-compare` 的底层工具，不可互相替代。

禁止在回复、报告、日志截图或新文档中输出数据库账号、密码、token、完整连接串中的敏感部分。

### 2.4 默认起点：打印计划管理

当用户只说“打印计划管理某页面/功能”但没有给出更具体入口时，默认从新 OA 打印计划管理链路开始：

- 前端路由：`E:/IdeaProjects/oa/hrtac-oa/front/src/router/index.js`
- 主页面：`E:/IdeaProjects/oa/hrtac-oa/front/src/views/printplan/dyjhgl/index.vue`
- 详情及子页面：
  - `front/src/views/printplan/dyjhgl/detail.vue`
  - `front/src/views/printplan/dyjhgl/detailPane.vue`
  - `front/src/views/printplan/dyjhgl/kfEdit.vue`
  - `front/src/views/printplan/dyjhgl/nwbjsEdit.vue`
  - `front/src/views/printplan/dyjhgl/feedback.vue`
  - `front/src/views/printplan/dyjhgl/lcjd.vue`
  - `front/src/views/printplan/dyjhgl/workload.vue`
  - `front/src/views/printplan/dyjhgl/feedbackConfirm.vue`
- 前端 API：`front/src/api/printplan/dyjhgl.js`
- Controller：`back/office-modules/office-project/src/main/java/com/nfrc/modules/controller/printplan/dyjhgl/DyjhglController.java`
- Service 接口：`back/office-common/src/main/java/com/nfrc/modules/commons/printplan/dyjhgl/service/DyjhglService.java`
- Service 实现：`back/office-common/src/main/java/com/nfrc/modules/commons/printplan/dyjhgl/service/impl/DyjhglServiceImpl.java`
- DAO：`back/office-common/src/main/java/com/nfrc/modules/commons/printplan/dyjhgl/dao/DyjhglDao.java`
- Mapper：`back/office-common/src/main/resources/mybatis/printplan/dyjhgl/DyjhglMapper.xml`

相邻但独立的链路不能混用：

- 打印资料下载：`dyzlDownload`，接口前缀 `/portal/printplan/dyzlDownload`
- 统计打印：`tjdy`，接口前缀 `/portal/printplan/tjdy`

如果用户描述的按钮或接口实际落在 `dyzlDownload` 或 `tjdy`，必须切换到对应独立链路，不得把打印计划管理主链路、打印资料下载链路、统计打印链路混为一谈。

## 3. 强制必读文档

执行任何源码结论前，必须先阅读并在报告中记录读取范围。文档有时间线冲突时，以较新的最终总文档作为结论基线，但不得跳过早期专项文档中的老 OA 链路、模板、SQL、二维码、排序、分页、副作用细节。

### 3.1 基础文档

- `E:/IdeaProjects/oa/hrtac-oa/docs/README.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/07-开发指南.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/02-后端架构设计.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/03-前端架构设计.md`

### 3.2 强约束文档

- `E:/IdeaProjects/oa/hrtac-oa/docs/09-核心机制-多数据源切换.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/DYJH_MIGRATION.md`

重点要求：

- `@ApiNeedCompanyCode` 参与的入口或下游调用链，不得在租户业务 SQL、视图、函数、过程、序列、`@TableName` 中写死具体租户 schema 前缀。
- 前端不会全局自动注入 `companyCode`，业务 API 需要手动处理。
- 动态数据源 AOP 当前只匹配方法级注解；类级注解不能直接替代方法级拦截。
- 异步和线程池场景必须考虑 `ThreadLocal` 数据源上下文不继承风险。

### 3.3 打印业务专项文档

- `E:/IdeaProjects/oa/hrtac-oa/docs/打印下载管理四类下载新老OA对齐技术文档.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/打印资料下载需求实施完整文档.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/核查打印计划详情下的所有功能对比与修复.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/打印资料下载与打印计划详情最终修复总文档.md`

### 3.4 历史会话与既有证据

用户要求“结合历史记录”或任务涉及已反复迁移/修复过的 OA 打印业务时，必须用关键词定向检索并记录读取范围：

- `E:/IdeaProjects/oa/hrtac-oa/docs/**/*.md`
- `E:/IdeaProjects/oa/hrtac-oa/docs/代码检查/reports/**`
- `E:/IdeaProjects/oa/.agents/reports/**`
- `E:/IdeaProjects/oa/cpzx-oa/.agents/skills/**`
- `E:/IdeaProjects/oa/cpzx-oa/.claude/skills/**`

检索关键词必须覆盖用户入口、页面名、接口路径、Mapper id、表名、字段名、函数名、存储过程名、报错码。历史文档只能作为线索；结论仍以真实数据库和实际源码为最高优先级。

### 3.5 需求附件、会话导出与阶段状态

当用户提供或引用需求附件、截图、Excel、Word、历史线程分析、阶段台账、会话导出或附件目录时，必须额外检查：

- 只承诺读取当前工具可访问的材料：用户明确给出的附件路径、当前会话暴露的 attachment file、粘贴文本生成的临时文件、用户导出的历史聊天/会话记录、需求目录、截图、Excel、Word、历史线程分析文档。
- “粘贴文本文件”通常指 Codex 把长粘贴内容保存到临时附件目录后给出的文件路径；必须按路径读取，不能只依赖对话摘要。
- “历史聊天/会话记录”只有在用户提供导出文件、附件路径、可读线程工具或仓库内文档时才可读取。不要声称能读取不可见的完整历史会话；若用户要求读取但没有可访问路径，记录缺口并请求导出或路径。
- 自动提取或其他线程生成的 `_tmp_*`、`*_result.md`、阶段总结只能作为线索，必须用原始附件、源码、真实数据库和可见页面再次验证。
- `.agents/tmp/*stage-closure*.md`、`.agents/tmp/*followup*.md`、`.agents/tmp/*progress*.md` 是阶段状态输入，不是业务一致性证据本身。读取最新相关文件以恢复方向；最终结论仍需源码、数据库和浏览器/文件证据。
- 阶段性收尾文档和进度台账的结构由 `oa-real-browser-driver` 的 Stage Closure / Progress Ledger 规则拥有。本技能只消费其中的需求边界、未验证项和证据路径；不要在本技能中复制收尾模板。
- 对用户文字中的可复用流程规则，判断应归属到哪个 OA 技能后再补写；打印等一次性业务需求不要写进通用技能，只保留在业务阶段文档或交付文档中。

阶段台账不得替代证据链。它只用于防止上下文压缩丢失方向；业务结论仍需回到源码、数据库、浏览器证据和附件内容。

## 4. 输入规范

用户应提供以下任一入口：

1. 页面名称、菜单名称或前端路由；
2. Vue 文件或组件名；
3. 按钮、弹窗、表单字段、下载动作或业务功能点；
4. 前端 API 函数名或接口 URL；
5. Controller 方法、Service 方法、Mapper XML id；
6. 老 OA JSP、URL、Struts forward、FRAME 配置 id；
7. 打印计划编号、考试编号、科目编号、样例数据。

如果入口不足以唯一定位功能，最多问 2-3 个澄清问题。若用户要求直接开始，则必须写明默认假设，并从打印计划管理默认链路开始。

## 5. 执行指令

### 5.1 总流程

每次对比必须按以下顺序执行：

1. 明确本次对比的功能边界和成功标准。
2. 阅读强制文档并记录采用结论。
3. 仅在 3.4 的触发条件成立时，定向检索历史会话/既有证据并记录读取范围；否则跳过并说明未触发历史检索。
4. 追踪老 OA 证据链。
5. 追踪新 OA 证据链。
6. 如果已有页面报错、请求报错或接口核对目标，先用 `oa-dev-verification-gate` 读取对应后端运行日志，再做数据库探针。
7. 用真实数据库只读校验每条 SQL 涉及的对象、字段、函数、视图、同义词、当前 schema 和 SQL 可解析性。
8. 建立逐项对比矩阵。
9. 判定一致、偏差或无法判定。
10. 对确认偏差提出修复建议；若用户要求修复且风险可控，可直接修复。
11. 运行必要验证，报告已验证与未验证项。

没有完成真实库验证时，禁止给“字段一定存在/不存在”“开发不报的原因一定是某某”“新老 OA 一致”等硬结论；只能给已验证事实和未验证项。

### 5.2 老 OA 追踪流程

必须从老 OA 真实入口开始，不得只按文件名或页面表面字段下结论。

1. 定位 Struts forward、JSP 入口、include 链路。
2. 逐行读取 JSP：表单、表格、隐藏域、按钮、样式、布局、弹窗、JS 引用。
3. 解析自定义标签和公共入口：
   - `nf:dst`
   - `nf:dstData`
   - `nf:listDst`
   - `nf:listData`
   - `nf:list`
   - `nf:form`
   - `nf:input`
   - `commitIDArrStr`
   - `commitIDArrStr_i`
   - `commitIDArrStr_u`
   - `GlobalUtil.encrypt(...)`
   - `a_save(this)`
   - `jq_commsave(...)`
   - `l_para`
   - `frame_list_curr_page`
4. 读取公共后端入口：
   - `E:/IdeaProjects/oa/cpzx-oa/web/WEB-INF/struts-config.xml`
   - `E:/IdeaProjects/oa/cpzx-oa/web/WEB-INF/tld/<legacy-taglib>.tld`
   - `E:/IdeaProjects/oa/cpzx-oa/web/WEB-INF/jsp/common/common_save.jsp`
   - `E:/IdeaProjects/oa/cpzx-oa/web/WEB-INF/jsp/common/common_ajax_save.jsp`
   - `E:/IdeaProjects/oa/cpzx-oa/web/WEB-INF/jsp/frame/frame_list.jsp`
   - `E:/IdeaProjects/oa/cpzx-oa/web/js/frame/frame_ajax_save.js`
5. 读取老 OA FRAME 工具类：
   - `E:/IdeaProjects/oa/cpzx-oa/src/com/<legacy-package>/dbTool/tool/FrameList.java`
   - `E:/IdeaProjects/oa/cpzx-oa/src/com/<legacy-package>/dbTool/tool/FrameQuery.java`
   - `E:/IdeaProjects/oa/cpzx-oa/src/com/<legacy-package>/dbTool/tool/FrameCommit.java`
   - `E:/IdeaProjects/oa/cpzx-oa/src/com/<legacy-package>/dbTool/tool/CommonSave.java`
   - `E:/IdeaProjects/oa/cpzx-oa/src/com/<legacy-package>/dbTool/tool/DatabaseTool.java`
6. 用 JSP 中的 query id、list id、taskStr、commit id 检索并展开：
   - `E:/IdeaProjects/oa/cpzx-oa/sqlFiles/frame_tables/FRAME_QUERY.sql`
   - `E:/IdeaProjects/oa/cpzx-oa/sqlFiles/frame_tables/FRAME_LIST.sql`
   - `E:/IdeaProjects/oa/cpzx-oa/sqlFiles/frame_tables/FRAME_TASK_QUERY.sql`
   - `E:/IdeaProjects/oa/cpzx-oa/sqlFiles/frame_tables/FRAME_TASK_QUERY_WHERE.sql`
   - `E:/IdeaProjects/oa/cpzx-oa/sqlFiles/frame_tables/FRAME_COMMIT.sql`
7. `FRAME_LIST`、`FRAME_TASK_QUERY`、`FRAME_TASK_QUERY_WHERE` 的版本号如 `#001`、`#002` 必须展开。
8. 对 `SQL_STR`、`SQL_NAME`、`OUT_STR`、`ALIAS`、`SEQ_ID` 记录来源、入参、where 条件、排序、分页、返回列、保存副作用。
9. 遇到 `F_*`、`P_*`、包调用、`call`、`p_` 开头配置时，必须递归追踪：
   - 本地导出：`E:/IdeaProjects/oa/cpzx-oa/sqlFiles/functions`
   - 数据库兜底：`all_source`
10. 对函数/过程必须说明入参来源、变量含义、条件分支、查询表、更新表、返回值、异常分支。

### 5.3 新 OA 追踪流程

必须从用户动作对应的前端和接口开始，逐层追到 SQL 和数据库。

1. 从前端路由或 Vue 页面定位页面入口。
2. 逐行读取页面布局、表单字段、控件类型、按钮显隐、弹窗、字典、校验规则、请求触发点、响应处理、错误提示。
3. 在 Vue 中定位 import 的 API 函数。
4. 到 `front/src/api/printplan/*.js` 精确记录：
   - URL
   - method
   - params/data
   - headers
   - `companyCode`
   - `responseType`
   - 下载响应处理
5. 用 URL 前缀定位 Controller 类级 `@RequestMapping`，再用尾部 path 定位方法。
6. 从 Controller 委托定位 Service 接口和 ServiceImpl。
7. 从 ServiceImpl 的 DAO 调用定位 Dao.java 方法。
8. 到 Mapper XML 用 namespace 和 id 定位 SQL。
9. 必要时继续追踪 entity、VO、DTO、枚举、字典、工具类、文件生成、存储过程调用。
10. 检查事务边界、异常处理、状态回退、副作用插入/更新/删除。

### 5.4A 权限链路定位

权限、角色、部门、菜单可见性或按钮禁用会影响业务一致性判断时，不得只说“当前账号无权限”就结束。

1. 先追踪实际权限门：Vue 按钮显隐/禁用、接口校验、Controller/Service/Mapper/过程/函数、读的是新 OA 还是老 OA 租户库。
2. 用只读 SQL 在实际路由到的 schema/table 中找合适的开发/测试账号、部门、角色、菜单权限或业务归属字段。登录表和业务权限表可能不是同一个库。
3. 如果需要真实登录或浏览器权限兜底，调用 `oa-real-browser-driver` / `oa-real-action-evidence` 的认证和权限验收流程，不在本技能内重复浏览器登录规则。
4. 如果需要临时调整开发/测试权限数据，先调用 `oa-real-sql-gate` 做库身份、样例、备份、DML、读回、还原和还原验证门禁。本技能只记录业务证据和判定，不复制 SQL gate 的 DML 执行细则。
5. 生产库或身份不明库只读；权限语义或数据修复有业务风险时，必须列为需确认项。

### 5.4B 多数据源检查

每条新 OA 业务调用链都必须检查动态数据源：

1. Controller、Service、ServiceImpl 方法上是否有 `@ApiNeedCompanyCode`。
2. 是否错误依赖类级注解而没有方法级注解。
3. 前端是否传入正确 `companyCode`，是否手动设置 header 或 params。
4. Service 内部是否跨线程、异步、线程池，导致 `ThreadLocal` 上下文丢失。
5. Mapper SQL、视图、函数、过程、序列、实体 `@TableName` 是否写死具体租户 schema。
6. 当前 SQL 应读老 OA 租户业务 schema，还是新 OA schema，必须在报告中逐条说明。

### 5.5 数据库真实校验

每条 SQL 都必须做真实数据库只读校验。不得只看导出文件、文档或代码就断言字段存在。

必须先做三段式校验：

1. 连接身份：查询 `USER`、`SYS_CONTEXT('USERENV','CURRENT_SCHEMA')`，确认当前 schema 和动态数据源/公司编码。
2. 对象解析：查询 `all_objects`、`all_synonyms`、`all_tab_columns`、`all_source`，确认表、视图、同义词、字段、函数、过程真实存在。
3. SQL 解析/执行：对 SELECT 做 `WHERE 1=0`、`COUNT(*)`、限定样例数据查询；新 OA Mapper SQL 必须优先走 `oa-real-sql-gate` 生成 BoundSql 并执行。

允许的校验方式：

- 新 OA MyBatis XML：`oa-real-sql-gate`，必要时指定 `-Mapper '<namespace.id>' -CompanyCode '010'` 或对应公司编码。
- 老 OA：`oa-jsp-sql-trace` 的老 OA 证据链流程、老 OA `DBQueryTool` 的只读 SELECT、或等价只读 Java/JDBC 探针。
- 元数据：`all_tables`、`all_tab_columns`、`all_objects`、`all_synonyms`、`all_source`、`all_arguments`、`user_*` 视图。
- 样例：用户提供或从列表真实查到的 `DYJH001`、`KSID001`、`KJID001` 等业务编号；不得用编造样例冒充验证。

遇到生产报错但本地不报，必须至少验证：

- 本地实际连接的 schema/current schema。
- 本地 `all_tab_columns` 中目标字段是否存在。
- 生产日志中的 SQL、Mapper XML id、jar 路径和版本。
- 若不能直连生产，只能说明“生产侧字段/对象需用只读 SQL 核验”，不得把开发库结果等同于生产。

禁止：

- DDL。
- DML。
- 执行会改变业务状态的存储过程。
- 未经用户明确授权的下载生成、状态流转、权限授予、完成/确认类业务动作等有副作用动作。
- 输出数据库账号密码。

校验必须明确记录：系统、连接、schema、对象、校验 SQL、结果。

### 5.6 业务分支覆盖契约

本技能只定义一致性判定需要覆盖的业务分支和样例条件；浏览器筛选循环归 `oa-real-browser-driver`，安全找数/造数/恢复归 `oa-real-sql-gate`。

1. 先从新老 OA 逻辑列出需要证明的数据分支：列表过滤、按钮显隐、权限门、下载内容、有/无附件、完成/未完成状态、异常提示、共享组件调用方等。
2. 在逐项矩阵中记录真实既有数据候选和缺口；一个样例覆盖不了时，按分支组写清样例条件。
3. 空白列表、无数据、无可下载内容或权限阻断不能算一致或验收完成。把页面筛选/样例覆盖缺口交给 `oa-real-browser-driver`，把开发/测试库安全构造或调整数据需求交给 `oa-real-sql-gate`。
4. 生产库或身份不明库不构造数据；只能输出只读诊断或列为 `needs-data` / `manual-auth-required`。
5. 报告的逐项矩阵要记录每个样例覆盖了哪些分支；缺少样例的分支不得写“已验证”。

## 6. 对比维度

每个功能点必须建立老 OA 与新 OA 的逐项矩阵，至少覆盖：

1. 菜单入口、路由、URL。
2. 页面布局、区域、按钮位置、弹窗层级。
3. 字段名称、字段来源、默认值、格式化。
4. 控件类型、只读、必填、显隐、禁用规则。
5. 前端 JS 校验、后端校验、数据库约束。
6. 权限校验、角色限制、按钮显隐。
7. 请求参数、参数名、参数来源、空值处理。
8. SQL 表、字段、join、where、排序、分页、聚合、函数。
9. 字典映射、状态码、颜色、状态流转。
10. 插入、更新、删除的表字段和值。
11. 存储过程和函数入参、分支、返回值。
12. 下载模板、文件名、文件内容、二维码、排序、分页、副作用。
13. 异常分支、错误提示、事务回滚。
14. `companyCode`、schema、动态数据源路由。
15. 老 OA 与新 OA 的不可见副作用差异。

对页面级任务，矩阵必须从真实页面枚举全部可观察/可触发控件：查询、重置、分页、排序、行点击、更多菜单、弹窗按钮、下载、授权、保存、完成、关闭、禁用/隐藏分支。只验证几个按钮不能称为页面闭环；矩阵局部状态可使用 `source-verified`、`partial-verified`、`blocked-needs-safe-sample-or-rollback-plan`、`manual-auth-required` 或 `not-in-scope`。向上游汇总时必须再映射为 1.3 中允许的状态集合。

## 7. 偏差判定规则

优先级：

1. 真实数据库和实际源码证据。
2. 最新专项/总文档。
3. 较早文档。
4. 用户明确确认。
5. 推测不得作为结论。

判定：

- **一致**：老 OA 和新 OA 在核心业务逻辑、数据读写、副作用、校验、状态流转上有完整证据链证明等价。
- **存在偏差**：新 OA 与老 OA 任一核心逻辑不同，且无明确需求说明这是有意变更。
- **无法判定**：缺少必要入口、样例数据、数据库访问、文档冲突无法裁决，必须列入未验证项。

确认偏差后，如果用户要求“直接修复”，可以按最小改动原则修复；如果偏差涉及业务口径、权限语义、数据修复、存储过程副作用，必须先列出并请求确认。

## 8. 输出规范

报告必须使用以下结构：

```markdown
# 新老 OA 核心业务逻辑逐项对比报告

## 0. 结论
- 功能点：
- 结论：一致 / 存在偏差 / 无法判定
- 是否阻断：是/否
- 最高风险偏差：

## 1. 输入与假设
- 用户入口：
- 默认假设：
- 未确认事项：

## 2. 已阅读文档
| 文档 | 读取范围 | 采用结论 | 冲突/时间线 |
|---|---|---|---|

## 3. 老 OA 证据链
| 层级 | 文件/数据库对象 | 行/配置ID | 关键逻辑 | 证据 |
|---|---|---|---|---|

## 4. 新 OA 证据链
| 层级 | 文件/方法/XML id | 行/注解 | 关键逻辑 | 证据 |
|---|---|---|---|---|

## 5. 数据库真实校验
| 系统 | 工具 | 连接/库/schema | 对象 | 校验 SQL | 结果 | 备注 |
|---|---|---|---|---|---|---|

## 6. 逐项对比矩阵
| 编号 | 维度 | 老 OA | 新 OA | 结论 | 风险 | 修复建议 |
|---|---|---|---|---|---|---|

## 7. 偏差清单
| 偏差 | 影响场景 | 老 OA 证据 | 新 OA 证据 | 数据库证据 | 建议 |
|---|---|---|---|---|---|

## 8. 未能验证项
| 项目 | 原因 | 需要用户提供/授权 |
|---|---|---|

## 9. 禁止变更提醒
- 本次是否只读：
- 未执行 DDL/DML：
- 未泄露凭据：
```

若已修复代码，还必须追加：

```markdown
## 10. 已修复内容
| 文件 | 修改点 | 对应偏差 | 验证结果 |
|---|---|---|---|
```

## 9. 执行前检查清单

每次使用本技能前必须逐项确认：

- [ ] 已明确功能边界和入口。
- [ ] 已阅读强制文档。
- [ ] 已查找并确认真实数据库连接工具。
- [ ] 已检索历史会话/既有证据并记录读取范围。
- [ ] 已定位老 OA JSP/Struts 入口。
- [ ] 已展开 JSP include、taglib、隐藏域、按钮事件。
- [ ] 已检查老 OA 样式、布局、JS 校验。
- [ ] 已检查 `common_save`、`common_ajax_save`、`frame_list` 请求路径。
- [ ] 已检索 `FRAME_QUERY`。
- [ ] 已检索 `FRAME_LIST`。
- [ ] 已检索 `FRAME_TASK_QUERY`。
- [ ] 已检索 `FRAME_TASK_QUERY_WHERE`。
- [ ] 已检索 `FRAME_COMMIT`。
- [ ] 已递归追踪 `F_*`、`P_*`、包调用、存储过程。
- [ ] 已查询当前数据库 `USER` 与 `CURRENT_SCHEMA`。
- [ ] 已查询 `all_objects` / `all_synonyms` / `all_tab_columns` / `all_source`。
- [ ] 已用真实数据库校验老 OA SQL 对象。
- [ ] 已定位新 OA Vue 页面。
- [ ] 已定位新 OA API 文件。
- [ ] 已定位新 OA Controller、Service、ServiceImpl、DAO、Mapper XML。
- [ ] 已检查 `@ApiNeedCompanyCode`、`companyCode`、动态数据源上下文。
- [ ] 已扫描新 OA SQL 是否写死具体租户 schema。
- [ ] 已用 `oa-real-sql-gate` 或等价真实库方式校验新 OA Mapper SQL。
- [ ] 已完成逐项对比矩阵。
- [ ] 已显式列出无法验证项。

## 10. 禁止事项

- 禁止跳过 docs。
- 禁止只看文件名或页面表面字段下结论。
- 禁止只看新 OA 不看老 OA。
- 禁止只看老 OA JSP 不追 FRAME、后端、函数、存储过程。
- 禁止只看 Mapper XML 不查动态数据源注解。
- 禁止不连真实数据库就断言字段、表、视图、函数、过程、序列存在。
- 禁止混淆老 OA 实例、老 OA 业务 schema 与新 OA schema。
- 禁止在 `@ApiNeedCompanyCode` 链路写死具体租户 schema。
- 禁止执行 DDL/DML 或会改变业务数据的过程。
- 禁止输出数据库账号密码。
- 禁止把 UI 优化、代码重构、性能优化置于业务一致性之前。
- 禁止用“应该”“可能”“看起来”代替证据。
- 禁止静默跳过无法验证项。
- 禁止为了通过新 OA 测试而偏离老 OA 核心业务逻辑。

## 11. 错误处理

- 如果老 OA JSP、FRAME 配置、函数源码、真实数据库结果互相冲突，停止下结论，列出冲突证据，并按“真实数据库和实际源码 > 最新专项文档 > 较早文档 > 推测”的优先级处理。
- 如果数据库无法连接，不得声称字段存在或 SQL 已验证；必须列入未能验证项。
- 如果发现 SQL 字段不存在，必须区分：动态数据源/schema 选错、目标库字段确实不存在、文档过期、代码引用错误。
- 如果遇到 `ORA-00904`，必须输出完整 SQL、Mapper id、字段元数据查询、当前 schema、对象解析结果；开发/生产差异必须用两边元数据或明确的未验证项说明。
- 如果发现新 OA 逻辑与老 OA 不一致但可能是新需求变更，必须标为“需业务确认”，不得擅自改业务口径。
- 如果需要修改代码，必须先按 1.1 检查工作树和边界，只改本功能相关文件，不覆盖用户已有改动。

## 12. 相关技能

- 老 OA JSP/FRAME/Oracle SQL 证据链必须使用 `E:/IdeaProjects/oa/.agents/skills/oa-jsp-sql-trace/SKILL.md`。
- 老 OA 迁移文档流程可参考 `E:/IdeaProjects/oa/cpzx-oa/.agents/skills/jsp-oracle-migration-doc/SKILL.md`。
- 新 OA MyBatis 真实库校验技能：`E:/IdeaProjects/oa/.agents/skills/oa-real-sql-gate/SKILL.md`。
- 生成迁移代码前必须先完成本技能的业务逻辑对比，并经用户确认改造方案。
