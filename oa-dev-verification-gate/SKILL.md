---
name: oa-dev-verification-gate
description: 受控 OA 开发验证门禁。用于后端改动、IDEA Spring Boot 重启、Spring DevTools trigger-file 重载、Logback/IDEA/Tomcat 控制台日志检查，以及真实 Edge 浏览器 Network/console 动作窗口证据。适用于 Java、Mapper XML、模板、配置或后端面对行为变化；页面报错、请求报错、接口信息核对、真实点击/下载/保存/搜索失败；需要判断是否重启 IDEA 启动的后端；或其他 OA 技能在验收前需要对应后端运行时日志和浏览器请求/响应证据时。
---

# OA 开发验证门禁

## 目的

本技能让 OA 开发验证保持可复现：

- 后端重启是代码/SQL 预检之后的受控门禁，不是“保存文件就自动算生效”。
- 通过官方 Edge/浏览器插件捕获真实动作证据：Network、console、toast/modal、截图、下载、后端日志和必要的数据库读回。
- 页面报错、请求报错或接口信息核对时，先读取对应后端 IDEA/Tomcat/Spring 控制台或文件日志，再做数据库探针、源码推断或配置修复。
- 证明重启后的后端健康，并且确实服务于当前要验收的代码路径。

真实点击、延迟错误、生成下载、副作用分类或共享页面上下文保护，交给 `oa-real-action-evidence` 做详细动作窗口循环。

## 代码与产物边界

本门禁可能编译代码、更新 `target/classes`、触碰 `.reloadtrigger` 或读取日志，但这些运行时产物不等于可提交源码。涉及源码修复、暂存、提交、还原或清理时，遵守 `oa-business-logic-compare` 的“任务边界、提交边界与还原边界”；本门禁不得为了证明运行时新鲜而 stage `.idea`、`target`、日志、下载文件或证据报告，也不得还原归属不明的源码差异。

## 可执行闭环原则

本门禁优先寻找可运行路径，而不是直接报告阻断。凡是页面动作会发送到后端，且任务是在排查、验证或核对该请求/接口，第一优先级都是对应后端运行时日志；只有命令侧日志链路已尝试或有证据证明不适用后，才使用 `runtime-stale`、`restart-unproven` 或 Computer Use 兜底。

本工作区已验证的命令侧链路：

1. 编译或更新真实变更 class/resource 到 `target/classes`。
2. 验证当前 8090 Java 进程由 IDEA 启动，并带有 DevTools 参数。
3. 必要时更新真实 classpath 产物时间戳，再写入 `back/office-web/target/classes/.reloadtrigger`。
4. 读取 Logback 文件，确认新鲜的 `thread="restartedMain"` 和 `NfrcApplication startup`。
5. 探测 `http://localhost:8090/portal/common/captchaImage`，要求 JSON `code:"0"` / `message:"操作成功"`。
6. 重跑需要后端刷新的真实 Edge 动作。

不要停在“IDEA console file 未配置”。可运行日志路径是 IDEA 启动 JVM 产生的 Logback 文件。只有确实配置了保存 console 输出时才读 IDEA console 文件；只有文件/进程证据缺失或矛盾且需要可见 IDEA console 时，才用 Computer Use。

## 跨技能交接契约

本门禁负责后端/运行时新鲜度和后端请求日志取证，不代替 SQL gate 或浏览器动作证明：

- 输入：后端面对文件或重载原因、适用时的编译/SQL gate 结果、要复测的 endpoint/action、请求 URL/method/status/timestamp、后端端口或系统线索、已知进程事实、调用方最后失败的 Network/log 症状。
- 输出：运行时证据行，包含时间戳、编译/预检结果、后端 PID、父 IDEA/Tomcat/Spring 进程、DevTools/运行配置状态、trigger 文件路径/时间、classpath 产物或编译输出、Logback/Tomcat/IDEA console 启动/失败/请求日志行、探活 URL/body 判定和最终运行时状态。
- 返回状态：`runtime-fresh`、`runtime-verified-api-only`、`runtime-stale`、`restart-unproven`、`compile-failed`、`sql-gate-required`、`probe-failed`、`computer-use-fallback-required`。
- Mapper/SQL 改动且没有 SQL gate 报告时，返回 `sql-gate-required`，先调用或交给 `oa-real-sql-gate`，再重启。
- 运行时为 `runtime-fresh` 时，把精确 action/API 交回 `oa-real-action-evidence` 或 `oa-real-browser-driver` 重跑。运行时新鲜不等于功能验收。
- 只有轻量未认证 API 探活成功时，除非用户请求的正是该 API，否则返回 `runtime-verified-api-only`，并写清仍需真实浏览器/动作复跑的 endpoint。
- 运行时仍陈旧或无法证明时，停止业务点击，返回缺失证据或兜底路径。
- 需要可见 IDEA console 证据时，Computer Use 只是兜底证据通道，要与 Logback/进程证据分开。

## 门禁流程

### 0. 后端请求日志优先门禁

当真实页面动作、弹窗、下载、保存、搜索、列表加载或接口核对会发送后端请求时，先完成本门禁，再做数据库探针或源码结论：

1. 从浏览器 Network 取请求 URL、method、status、payload 摘要和点击时间窗口；没有 Network 时先说明是前端 handler/禁用/校验问题。
2. 识别对应后端，不凭记忆猜：新 OA 通常是 8090 Spring Boot；老 OA 通常是 9099 Tomcat/JSP；其他端口按 Network URL 和监听进程确认。
3. 读取对应后端运行日志：
   - 新 OA：IDEA 启动的 Spring Boot Logback 文件；确有保存 console 输出时可读 IDEA console 文件。
   - 老 OA：IDEA/Tomcat console 保存文件、Tomcat `catalina.base` 下日志；无文件时用 Computer Use 只读查看可见 IDEA/Tomcat 控制台。
   - 其他后端：先用监听端口、进程命令行、父进程和 run configuration 确认日志来源。
4. 日志窗口必须覆盖本次请求时间；至少搜索请求路径、业务主键、异常关键词、SQL/ORA、JSP/Servlet、Controller/Mapper/方法名。
5. 只有拿到后端日志证据，或证明当前日志通道不可达并记录兜底尝试后，才进入 DB 元数据/FRAME_PAGE/Mapper/配置探针。
6. `codex_app.read_thread_terminal` 不是 IDEA/Tomcat/Spring 控制台，除非本线程明确运行了对应后端进程；不能用它替代后端日志。

### 1. 分类动作

- `frontend-only`：Vue/CSS/下载处理，不需要后端重启。
- `backend-code`：Java、Service、Controller、模板或配置改动，需要编译和后端重载。
- `mapper-sql`：MyBatis XML、DAO、SQL 或数据库面对代码。任何重启结论前先读并执行 `oa-real-sql-gate`。
- `backend-request-check`：任何页面请求、接口信息核对、列表加载、搜索、下载、保存、弹窗打开后需要验证或排查后端行为。第一步执行“后端请求日志优先门禁”。
- `browser-failure`：点击后出现用户可见失败。猜测前先捕获 Network/console 证据，并读取对应后端 IDEA/Tomcat/Spring 控制台或文件日志。
- `old-oa-jsp-failure`：老 OA 9099/JSP/FRAME 点击后出现“服务器程序出现错误”、空白 iframe、JSP 编译错误或 Struts forward 错误。第一动作是读取老 OA 运行控制台/日志和浏览器 Network/console，然后才查 FRAME_PAGE、JSP 同步、Oracle SQL/函数。
- `unknown-side-effect`：副作用和恢复计划未知前不要执行。

用户明确要求先解决 IDEA 重启或日志读取时，暂停无关业务验证，先完成本门禁。运行时重载路径未证明前，不要漂移到页面修复。

### 1.1 老 OA 9099/JSP 错误页快速路径

老 OA 与新 OA Spring Boot 门禁分开处理。遇到老 OA `localhost:9099`、`cpzx-oa`、JSP/FRAME、Struts `forwardName` 或 Phr 弹窗错误页时：

1. 不调用 `oa-real-sql-gate`；它只验证新 OA MyBatis。
2. 不把 `codex_app.read_thread_terminal` 当作 IDEA/Tomcat 老 OA 控制台。该工具只读当前 Codex 线程 terminal；除非本线程明确挂接了老 OA 运行控制台，否则结果为“不适用”。
3. 先找真实运行通道：
   - 若 IDEA/Tomcat console 保存到了文件，读取保存文件并验证 `LastWriteTime` 晚于本次点击。
   - 若没有保存文件，用 Computer Use 兜底读取可见 IDEA/Tomcat 控制台，只读观察，不点击 Stop/Rerun/Debug/Run。
   - 同时用官方 Edge 插件读取弹窗/iframe 的 Network、console、URL、状态码和页面文本。
4. 控制台/日志要优先搜索：`Exception`、`JasperException`、`ServletException`、`SQLException`、`ORA-`、`NoSuchMethodError`、`ClassNotFoundException`、`NullPointerException`、`forwardName`、`FRAME_PAGE`、目标 JSP 文件名和业务主键。
5. 只有拿到运行时错误线索，或证明控制台/日志当前不可达后，才转到数据库只读探针检查 `FRAME_PAGE`、表字段、函数状态和 SQL 解析。
6. 如果数据库探针先发现明确缺口，也必须回到浏览器/控制台复验错误页是否消失；不能把 `FRAME_PAGE` 补齐读回当作页面验收。

### 2. 重启前预检

- 后端代码改动时，从 `E:/IdeaProjects/oa/hrtac-oa/back` 运行能证明变更模块可编译的最窄命令，通常是：

```powershell
mvn -pl office-web -am -DskipTests compile
```

- Mapper XML 或 SQL 改动时，按真实开发/测试数据源和回滚规则运行 `oa-real-sql-gate`。
- 生成文档/模板变化时，确认目标资源在运行时 classpath 或打包模块路径中存在。
- 预检失败时不要重启 IDEA 后端；先修预检失败。

### 3. 进入重载门禁

- 简单 Java 方法体变更且 IDEA 确认 HotSwap 时，可以接受方法体热替换。但 bean 定义、方法签名、Mapper XML、资源/模板、配置、依赖或注解变更不能只靠 HotSwap。
- 首选路径：使用 Codex 命令侧进程检查、编译输出、Spring DevTools trigger-file、Logback 证据和 HTTP 探活，在不手动点击 UI 的情况下重载并验证 IDEA 启动的后端。仅当运行中 JVM command line 证明 `spring.devtools.restart.enabled=true` 和 `spring.devtools.restart.trigger-file=.reloadtrigger` 都启用时，该路径才有效。缺任一参数时，先走 run configuration 启用路径；完成前只能记录 `runtime-stale`。
- 后端改动不能仅凭编译或触碰 `.reloadtrigger` 视为通过。证明必须包含：IDEA-owned Java PID、DevTools 参数、trigger 时间戳、该时间之后的新鲜 Logback startup/restartedMain 证据和轻量 8090 探活。
- DevTools reload 需要但未配置时，说明缺少的 VM options；用户授权修改本地 IDEA 配置时，只改本地 ignored 的 IDEA run configuration，加入：

```text
-Dspring.devtools.restart.enabled=true -Dspring.devtools.restart.trigger-file=.reloadtrigger
```

然后通过 IDEA 重启一次，让后续可由命令触发 reload。

- 修改 IDEA Run/Debug Configuration 后，不要用当前 Debug 工具窗口底部的 `Rerun` 按钮证明配置生效。本工作区观察到该路径可能复用旧 debug session 快照，不会重新读取新 VM options。应停止当前 `NfrcApplication` session，再从顶部工具栏启动当前 `NfrcApplication` Debug configuration，然后用 `jcmd` 验证。
- 命令侧 reload 不可用、未配置或证据矛盾时，记录命令侧事实后才使用 Computer Use。检查 IntelliJ IDEA 中 `E:/IdeaProjects/oa/hrtac-oa` 窗口，选择精确的 `NfrcApplication` run/debug console，读取可见错误/启动状态。确需重启时，只点击该 configuration 的 IDEA 自身 rerun/start 控件。控件不清楚时先查官方 JetBrains IDEA 文档，不要猜图标。
- 除非当前会话启动了精确进程，并有 PID/命令/工作目录直接证据，否则不要杀 Java 进程或释放端口。归属不明时询问。

### 4. 证明后端就绪

不要把 Computer Use 当作常规日志读取方式。常规路径是命令侧文件/进程证据。

先识别当前活动后端，而不是依赖记忆路径：

1. 找到监听 `8090` 的进程。
2. 读取 owning Java 进程 command line 和父进程。
3. 确认父进程是 `idea64.exe`，main class 是 `com.nfrc.apps.NfrcApplication`，classpath 指向 `E:/IdeaProjects/oa/hrtac-oa/back/.../target/classes`。
4. 用 `jcmd <pid> VM.command_line` 或 `jcmd <pid> VM.system_properties` 检查 `spring.devtools.restart.enabled` 和 `spring.devtools.restart.trigger-file`。

再读取 IDEA 启动后端写出的活动 Logback 文件。正常路径是 JVM 产生的运行时文件日志，不是 Computer Use，也不是 Codex terminal。

活动 Logback 文件推导步骤：

- `Get-NetTCPConnection -LocalPort 8090 -State Listen` 得到 Java PID。
- `Get-CimInstance Win32_Process -Filter "ProcessId=<pid>"` 得到父 IDEA PID 和 command line。
- `jcmd <pid> VM.command_line` / `jcmd <pid> VM.system_properties` 得到 `user.dir`、classpath、DevTools 参数、active profile/config 线索。
- 读取 `back/office-web/src/main/resources/logback-spring.xml` 中 `${hrtac.log.path}/${hrtac.log.name}.${HOSTNAME}.log`。
- 读取 active profile config，通常是 `back/office-web/src/main/resources/application-dev.yml` 中的 `hrtac.file.root_path`、`hrtac.log.path`、`hrtac.log.name`。
- 用 `Test-Path` / `Get-Item` 验证路径，并要求 `LastWriteTime` 与活动进程/重启窗口匹配。再用 `Get-Content -Encoding UTF8 -Tail ...` 或 `Select-String -Encoding UTF8 -Path ...` 读取。

历史验证过的命令模式：

```powershell
Select-String -Encoding UTF8 -Path '<active-logback-file>' `
  -Pattern 'restartedMain|NfrcApplication startup|APPLICATION FAILED TO START|BeanCreationException|BindingException|UnsatisfiedDependencyException|NoSuchMethodError|ORA-|port|端口' |
  Select-Object -Last 80 | ForEach-Object { $_.Line }
```

该文件可用于证明 DevTools reload（`restartedMain` + 新鲜 `NfrcApplication startup`），检查真实 `/portal/...` 请求、SQL interceptor 输出、响应体和后端错误。

IDEA 保存的 console 输出文件只在 run configuration 确实配置时使用。检查 `.idea/runConfigurations/NfrcApplication.xml` 和 `.idea/workspace.xml` 是否有 `SAVE_OUTPUT_TO_FILE`、`OUTPUT_FILE`、`fileOutputPath`、`saveOutput`、`LogFileOptions` 或等价设置。有路径时验证 `Test-Path`、`LastWriteTime` 和当前进程时间，再读取。没有配置时，不要声称存在 IDEA console 输出文件。

`idea.log` 只用于 IDEA runner/configuration 错误、profiler 参数、action 失败和插件错误。不要把 `idea.log` 当 Spring Boot 应用 console，除非它确实包含所需应用输出。

文件日志搜索应覆盖启动和失败标记：`Picked up JDK_JAVA_OPTIONS`、`Picked up JAVA_TOOL_OPTIONS`、`spring.devtools.restart.enabled`、`restartedMain`、`NfrcApplication startup`、`APPLICATION FAILED TO START`、`BeanCreationException`、`BindingException`、`UnsatisfiedDependencyException`、`NoSuchMethodError`、`ORA-` 和端口绑定错误。

报告中要分清证据通道：

- Logback 文件：IDEA 启动后端的应用运行时日志，是这里常规后端诊断来源。
- IDEA 保存 console 输出文件：只有 run configuration 真的保存时才是磁盘上的 IDEA console 文本。
- `idea.log`：IDEA 进程/runner 日志。
- `codex_app.read_thread_terminal`：仅 Codex 线程 terminal，不是 IDEA Debug console。

如果没有 IDEA 保存 console 输出配置，而用户希望未来能用文件读取字面 IDEA console 文本，先说明并征求授权，再修改本地 IDEA run configuration 启用“Save console output to file”。本地 `.idea` 配置不是产品代码，除非用户明确要求，不要 stage。

Computer Use 仅为最后兜底：当文件/进程证据缺失或矛盾，或用户明确说可见 IDEA console 中有文件没有的信息时使用。先读 `computer-use` 技能，目标锁定精确 `hrtac-oa` IDEA 窗口，被动检查截图/文本；只是读日志时不要点击 Stop/Rerun/Debug/Run。

成功必须同时满足：

- 有晚于 restart trigger 的 startup 行，例如 `NfrcApplication startup`。
- 8090 探活成功。
- 没有同一窗口内的致命启动失败。
- 运行时 classpath/资源与变更文件对应。

### 5. 重跑真实动作

后端新鲜后，回到原失败动作：

1. 用同一个或健康兜底 Edge tab。
2. 重跑原按钮/下载/保存/搜索。
3. 捕获 Network、console、可见消息、后端日志和文件/DB 证据。
4. 若仍失败，把失败交回 `oa-real-action-evidence` 或业务技能继续分析，不要把后端新鲜误当成功能验收。

## 数据库与副作用边界

- Mapper XML 或 SQL 变更必须先过 `oa-real-sql-gate`。
- 生产库或身份不明库只读。
- 开发/测试库写入也必须有样例、备份、预期影响、读回、恢复和恢复验证。
- 不要在本门禁里自行发明 DML 恢复方案；交给 SQL gate。

## 报告模板

报告至少包含：

| 项 | 内容 |
|---|---|
| 分类 | `frontend-only` / `backend-code` / `mapper-sql` / `backend-request-check` / `browser-failure` / `old-oa-jsp-failure` / `unknown-side-effect` |
| 编译/预检 | 命令、结果、失败摘要 |
| SQL gate | 报告路径和状态，如适用 |
| 进程 | 实际后端端口 PID（新 OA 通常 8090、老 OA 通常 9099）、父 IDEA/Tomcat/Spring PID、main class、classpath 或 catalina.base |
| DevTools | `spring.devtools.restart.enabled`、`.reloadtrigger` |
| Trigger | 文件路径和时间戳 |
| Logback | 日志路径、新鲜 startup/failure 行 |
| 对应后端请求日志 | URL/method/status/timestamp、日志通道、命中日志行或不可达证明 |
| 探活 | URL、状态、body 判定 |
| 重跑动作 | Edge tab、请求、可见消息、文件/DB 证据 |
| 最终状态 | `runtime-fresh` 等精确标签 |

## 禁止事项

- 禁止在 SQL gate 失败或缺失时重启后端并声称 SQL 已安全。
- 禁止把旧后端上的浏览器成功当成新代码验收。
- 禁止只凭 IDEA 可见运行中图标断言后端新鲜。
- 禁止杀归属不明的 Java、IDEA、浏览器或系统进程。
- 禁止关闭用户原有标签页或归属不明标签页。
- 禁止在报告中输出数据库凭据、token、cookies、Authorization、Set-Cookie 或敏感 payload。
- 禁止把 unauthenticated probe 升级成完整业务流程验收。
- 禁止提交本地 `.idea` 配置、生成日志、target、下载文件或证据报告，除非用户明确要求。

## 完成标准

- 后端面对变更已编译或明确不需要编译。
- Mapper/SQL 变更已有 SQL gate 结论。
- 需要重载时，DevTools/重启证据新鲜且可审计。
- 页面/接口动作涉及后端请求时，已读取对应后端 IDEA/Tomcat/Spring 控制台或文件日志，或明确证明日志通道不可达并说明兜底尝试。
- 8090 探活成功，且无启动失败。
- 原真实 Edge 动作已重跑，或明确交回下一步动作证据技能。
- 所有未完成项都有精确阻断原因和下一步。
