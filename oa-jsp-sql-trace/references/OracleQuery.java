/**
 * Oracle 数据库只读查询模板
 *
 * 用法：
 *   1. 复制此文件到项目根目录
 *   2. 修改 QUERIES 数组中的查询内容
 *   3. 运行时按提示输入 JDBC URL、账号、密码、schema；也可由当前用户显式设置环境变量，
 *      或用 ORACLE_QUERY_CONFIG / -Doracle.query.config 指向用户授权的 properties 文件
 *   4. 编译运行：
 *      javac -encoding UTF-8 OracleQuery.java
 *      java -Dfile.encoding=UTF-8 -cp ".;<path-to-approved-ojdbc.jar>" OracleQuery
 *   5. 若复制成临时文件，确认属于本次任务后再清理 OracleQuery.java 和 OracleQuery.class
 *
 * 注意事项：
 *   - 仅允许 SELECT，禁止 DDL/DML
 *   - 先输出 USER / CURRENT_SCHEMA / DB_NAME；不要输出账号、密码或完整连接串
 *   - 中文输出使用 UTF-8 PrintStream 避免乱码
 *   - 不内置任何默认库名、schema、账号或密码
 */
import java.awt.GraphicsEnvironment;
import java.io.Console;
import java.io.FileInputStream;
import java.io.IOException;
import java.sql.*;
import java.util.Arrays;
import java.util.Properties;
import java.util.Scanner;
import javax.swing.JPasswordField;
import javax.swing.JOptionPane;

public class OracleQuery {
    static final int QUERY_TIMEOUT_SECONDS = 20;
    static final int MAX_ROWS = 200;
    static final Properties CONFIG = loadConfig();
    static final Scanner INPUT = new Scanner(System.in, "UTF-8");
    static final String URL  = readRequired("ORACLE_QUERY_URL", "Oracle JDBC 地址", false);
    static final String USER = readRequired("ORACLE_QUERY_USER", "Oracle 数据库用户", false);
    static final String PASS = readRequired("ORACLE_QUERY_PASS", "Oracle 数据库密码", true);
    static final String OWNER = readRequired("ORACLE_QUERY_OWNER", "源码查询使用的当前 schema/owner", false).toUpperCase();
    static final String COMMENT_OWNER = readOptional("ORACLE_QUERY_COMMENT_OWNER", "备用注释 owner schema（可选）").toUpperCase();

    public static void main(String[] args) throws Exception {
        java.io.PrintStream out = new java.io.PrintStream(System.out, true, "UTF-8");
        try (Connection conn = DriverManager.getConnection(URL, USER, PASS)) {
            conn.setReadOnly(true);
            out.println("=== 已连接 ===");
            queryIdentity(conn, out);

            // ========== 按需修改以下查询 ==========

            // 1. 查表注释（先查当前 schema，再查用户输入的备用 schema）
            String[] tables = {"TABLE1", "TABLE2"};
            queryTableComments(conn, out, tables);

            // 2. 查字段注释
            queryColumnComments(conn, out, tables);

            // 3. 查函数源码
            String[] funcs = {"F_FUNC1", "F_FUNC2"};
            queryFunctionSource(conn, out, funcs);

            // 4. 自定义查询（按需添加）
            // customQuery(conn, out, "SELECT ...");

            out.println("\n=== 完成 ===");
        }
    }

    /** 查表注释：先查当前 schema，null 则查用户输入的备用 schema */
    static void queryIdentity(Connection conn, java.io.PrintStream out) throws Exception {
        out.println("\n=== 数据库身份 ===");
        String sql = "select user as current_user, sys_context('USERENV','CURRENT_SCHEMA') as current_schema, sys_context('USERENV','DB_NAME') as db_name from dual";
        try (Statement st = conn.createStatement(); ResultSet rs = st.executeQuery(sql)) {
            if (rs.next()) {
                out.println("USER=" + rs.getString("current_user"));
                out.println("CURRENT_SCHEMA=" + rs.getString("current_schema"));
                out.println("DB_NAME=" + rs.getString("db_name"));
            }
        }
    }

    static String readRequired(String name, String label, boolean secret) {
        String value = System.getenv(name);
        if (isBlank(value)) {
            value = configValue(name);
        }
        if (value == null || value.trim().isEmpty()) {
            value = prompt(label + " [" + name + "]", secret);
        }
        if (value == null || value.trim().isEmpty()) {
            throw new IllegalStateException("缺少必填输入：" + label);
        }
        return value.trim();
    }

    static String readOptional(String name, String label) {
        String value = System.getenv(name);
        if (isBlank(value)) {
            value = configValue(name);
        }
        return value == null ? "" : value.trim();
    }

    static Properties loadConfig() {
        Properties props = new Properties();
        String path = System.getenv("ORACLE_QUERY_CONFIG");
        if (isBlank(path)) {
            path = System.getProperty("oracle.query.config");
        }
        if (isBlank(path)) {
            return props;
        }
        try (FileInputStream in = new FileInputStream(path.trim())) {
            props.load(in);
            return props;
        } catch (IOException e) {
            throw new IllegalStateException("无法读取用户授权的配置文件：" + path, e);
        }
    }

    static String configValue(String envName) {
        String value = CONFIG.getProperty(envName);
        if (!isBlank(value)) return value;

        String key = "oracle.query." + envName
                .replaceFirst("^ORACLE_QUERY_", "")
                .toLowerCase()
                .replace('_', '.');
        value = CONFIG.getProperty(key);
        if (!isBlank(value)) return value;

        if ("ORACLE_QUERY_PASS".equals(envName)) {
            value = CONFIG.getProperty("oracle.query.password");
        } else if ("ORACLE_QUERY_COMMENT_OWNER".equals(envName)) {
            value = CONFIG.getProperty("oracle.query.commentOwner");
        }
        return value;
    }

    static boolean isBlank(String value) {
        return value == null || value.trim().isEmpty();
    }

    static String prompt(String label, boolean secret) {
        Console console = System.console();
        if (console != null) {
            if (secret) {
                char[] chars = console.readPassword("%s: ", label);
                if (chars == null) return "";
                String value = new String(chars);
                Arrays.fill(chars, '\0');
                return value;
            }
            String value = console.readLine("%s: ", label);
            return value == null ? "" : value;
        }

        if (!GraphicsEnvironment.isHeadless()) {
            if (secret) {
                JPasswordField field = new JPasswordField();
                int result = JOptionPane.showConfirmDialog(null, field, label, JOptionPane.OK_CANCEL_OPTION, JOptionPane.PLAIN_MESSAGE);
                if (result != JOptionPane.OK_OPTION) return "";
                char[] chars = field.getPassword();
                String value = new String(chars);
                Arrays.fill(chars, '\0');
                return value;
            }
            String value = JOptionPane.showInputDialog(null, label + ":", "Oracle 查询输入", JOptionPane.PLAIN_MESSAGE);
            return value == null ? "" : value;
        }

        System.out.print(label + (secret ? "（当前输入可能可见）: " : ": "));
        return INPUT.nextLine();
    }

    /** 查表注释：先查当前 schema，null 则查用户输入的备用 schema */
    static void queryTableComments(Connection conn, java.io.PrintStream out, String[] tables) throws Exception {
        out.println("\n=== 表注释 ===");
        String sql1 = "SELECT table_name, comments FROM user_tab_comments WHERE table_name=? AND table_type='TABLE'";
        String sql2 = "SELECT table_name, comments FROM all_tab_comments WHERE owner=? AND table_name=? AND table_type='TABLE'";
        try (PreparedStatement ps1 = conn.prepareStatement(sql1);
             PreparedStatement ps2 = conn.prepareStatement(sql2)) {
            for (String t : tables) {
                ps1.setString(1, t);
                try (ResultSet rs = ps1.executeQuery()) {
                    if (rs.next() && rs.getString(2) != null) {
                        out.println(t + " | " + rs.getString(2) + " | " + OWNER);
                        continue;
                    }
                }
                if (!COMMENT_OWNER.isEmpty()) {
                    ps2.setString(1, COMMENT_OWNER); ps2.setString(2, t);
                    try (ResultSet rs = ps2.executeQuery()) {
                        if (rs.next() && rs.getString(2) != null) {
                            out.println(t + " | " + rs.getString(2) + " | " + COMMENT_OWNER);
                        } else {
                            out.println(t + " | （无注释） | -");
                        }
                    }
                } else {
                    out.println(t + " | （无注释） | -");
                }
            }
        }
    }

    /** 查字段注释：先查当前 schema，null 则查用户输入的备用 schema */
    static void queryColumnComments(Connection conn, java.io.PrintStream out, String[] tables) throws Exception {
        out.println("\n=== 字段注释 ===");
        String sql1 = "SELECT column_name, comments FROM user_col_comments WHERE table_name=? ORDER BY column_name";
        String sql2 = "SELECT column_name, comments FROM all_col_comments WHERE owner=? AND table_name=? AND comments IS NOT NULL ORDER BY column_name";
        try (PreparedStatement ps1 = conn.prepareStatement(sql1);
             PreparedStatement ps2 = conn.prepareStatement(sql2)) {
            for (String t : tables) {
                out.println("--- " + t + " ---");
                boolean hasComments = false;
                ps1.setString(1, t);
                try (ResultSet rs = ps1.executeQuery()) {
                    while (rs.next()) {
                        String c = rs.getString(2);
                        if (c != null) { hasComments = true; out.println(t + "." + rs.getString(1) + " | " + c); }
                    }
                }
                if (!hasComments && !COMMENT_OWNER.isEmpty()) {
                    ps2.setString(1, COMMENT_OWNER); ps2.setString(2, t);
                    try (ResultSet rs = ps2.executeQuery()) {
                        while (rs.next()) {
                            out.println(t + "." + rs.getString(1) + " | " + rs.getString(2) + "（来自 " + COMMENT_OWNER + "）");
                        }
                    }
                }
            }
        }
    }

    /** 查函数源码 */
    static void queryFunctionSource(Connection conn, java.io.PrintStream out, String[] funcs) throws Exception {
        out.println("\n=== 函数源码 ===");
        String sql = "SELECT line, text FROM all_source WHERE owner=? AND name=? AND type='FUNCTION' ORDER BY line";
        try (PreparedStatement ps = conn.prepareStatement(sql)) {
            for (String f : funcs) {
                out.println("\n--- 函数：" + f + " ---");
                ps.setString(1, OWNER); ps.setString(2, f);
                try (ResultSet rs = ps.executeQuery()) {
                    boolean found = false;
                    while (rs.next()) { found = true; out.print(rs.getInt(1) + ": " + rs.getString(2)); }
                    if (!found) out.println("（未找到）");
                }
            }
        }
    }

    /** 自定义查询仅用于已完成源码副作用审查、带精确过滤条件的诊断 SQL。 */
    static void customQuery(Connection conn, java.io.PrintStream out, String sql) throws Exception {
        ensureReadOnlySelect(sql);
        out.println("\n=== 自定义查询 ===");
        out.println("SQL 已通过本地只读形态检查；为避免日志泄露，不回显原文。");
        try (Statement st = conn.createStatement()) {
            st.setQueryTimeout(QUERY_TIMEOUT_SECONDS);
            st.setMaxRows(MAX_ROWS);
            try (ResultSet rs = st.executeQuery(sql)) {
                ResultSetMetaData md = rs.getMetaData();
                int cols = md.getColumnCount();
                int rows = 0;
                while (rs.next()) {
                    rows++;
                    StringBuilder sb = new StringBuilder();
                    for (int i = 1; i <= cols; i++) {
                        if (i > 1) sb.append(" | ");
                        sb.append(rs.getString(i));
                    }
                    out.println(sb.toString());
                }
                if (rows >= MAX_ROWS) out.println("（结果已在 " + MAX_ROWS + " 行截断）");
            }
        }
    }

    static void ensureReadOnlySelect(String sql) {
        String raw = sql == null ? "" : sql.trim();
        if (raw.indexOf(';') >= 0 || raw.contains("--") || raw.contains("/*") || raw.contains("*/")) {
            throw new IllegalArgumentException("自定义查询禁止分号和 SQL 注释；复杂 SQL 请先人工审查后写成固定 PreparedStatement");
        }
        String s = raw.toLowerCase();
        if (!(s.startsWith("select ") || s.startsWith("with "))) {
            throw new IllegalArgumentException("只允许只读 SELECT/WITH 查询");
        }
        String padded = " " + s.replaceAll("\\s+", " ") + " ";
        String[] banned = {" insert ", " update ", " delete ", " merge ", " truncate ", " drop ", " alter ", " create ", " grant ", " revoke ", " commit ", " rollback ", " call "};
        for (String word : banned) {
            if (padded.contains(word)) {
                throw new IllegalArgumentException("禁止 DML/DDL 或有副作用 SQL：" + word.trim());
            }
        }
        if (!(padded.contains(" where ") || padded.contains(" rownum ") || padded.contains(" fetch first "))) {
            throw new IllegalArgumentException("自定义查询必须包含精确 WHERE、ROWNUM 或 FETCH FIRST 边界");
        }
    }
}
