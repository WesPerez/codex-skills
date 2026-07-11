#!/usr/bin/env node

import fs from "node:fs";

const UUID_RE = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/gi;

function usage() {
  return `Usage:
  node check_k12_workspaces.mjs --ids-file ids.txt --cdp http://127.0.0.1:9223
  node check_k12_workspaces.mjs --ids "uuid | S2" --json

Options:
  --ids <text>             Candidate IDs; can be repeated and can contain newlines.
  --ids-file <path>        File containing candidate IDs.
  --cdp <url>              CDP base URL, default http://127.0.0.1:9223.
  --delay-ms <number>      Delay between workspace checks, default 500.
  --timeout-ms <number>    Per-request/page evaluation timeout, default 20000.
  --json                   Print sanitized JSON instead of a table.
  --no-restore-current     Do not restore the starting ChatGPT account context.
  --self-test              Run parser self-test only.
  --help                   Show this help.
`;
}

function parseArgs(argv) {
  const opts = {
    idsText: [],
    idsFiles: [],
    cdp: "http://127.0.0.1:9223",
    delayMs: 500,
    timeoutMs: 20000,
    json: false,
    restoreCurrent: true,
    selfTest: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    const next = () => {
      i += 1;
      if (i >= argv.length) throw new Error(`Missing value for ${arg}`);
      return argv[i];
    };

    if (arg === "--ids") opts.idsText.push(next());
    else if (arg === "--ids-file") opts.idsFiles.push(next());
    else if (arg === "--cdp") opts.cdp = next();
    else if (arg === "--delay-ms") opts.delayMs = Number(next());
    else if (arg === "--timeout-ms") opts.timeoutMs = Number(next());
    else if (arg === "--json") opts.json = true;
    else if (arg === "--no-restore-current") opts.restoreCurrent = false;
    else if (arg === "--self-test") opts.selfTest = true;
    else if (arg === "--help" || arg === "-h") {
      process.stdout.write(usage());
      process.exit(0);
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }

  if (!Number.isFinite(opts.delayMs) || opts.delayMs < 0) throw new Error("--delay-ms must be >= 0");
  if (!Number.isFinite(opts.timeoutMs) || opts.timeoutMs < 1000) {
    throw new Error("--timeout-ms must be >= 1000");
  }
  return opts;
}

function normalizeInput(text) {
  return String(text || "")
    .normalize("NFKC")
    .replace(/[‐‑‒–—﹣－]/g, "-");
}

export function parseWorkspaceIds(text) {
  const seen = new Set();
  const rows = [];

  for (const rawLine of normalizeInput(text).split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line) continue;

    const source = line.includes("|") ? line.split("|").slice(1).join("|").trim() : "";
    const matches = line.match(UUID_RE) || [];
    for (const match of matches) {
      const id = match.toLowerCase();
      if (seen.has(id)) continue;
      seen.add(id);
      rows.push({ id, source });
    }
  }

  return rows;
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function runSelfTest() {
  const parsed = parseWorkspaceIds(`
    FF598C4D-CCAF-40C1-BFAA-CB94565764B1 | S1, S2
    text 521ffc8f－9612－4950－84ed－95773138eca6 | S2
    ff598c4d-ccaf-40c1-bfaa-cb94565764b1 | duplicate
  `);
  assert(parsed.length === 2, `expected 2 parsed rows, got ${parsed.length}`);
  assert(parsed[0].id === "ff598c4d-ccaf-40c1-bfaa-cb94565764b1", "first ID normalization failed");
  assert(parsed[0].source === "S1, S2", "source preservation failed");
  assert(parsed[1].id === "521ffc8f-9612-4950-84ed-95773138eca6", "dash normalization failed");
  process.stdout.write("self-test ok\n");
}

async function readIds(opts) {
  const chunks = [...opts.idsText];
  for (const file of opts.idsFiles) {
    chunks.push(fs.readFileSync(file, "utf8"));
  }

  if (!process.stdin.isTTY) {
    const stdin = fs.readFileSync(0, "utf8");
    if (stdin.trim()) chunks.push(stdin);
  }

  const rows = parseWorkspaceIds(chunks.join("\n"));
  if (!rows.length) throw new Error("No workspace UUIDs found. Pass --ids or --ids-file.");
  return rows;
}

function trimSlash(url) {
  return String(url).replace(/\/+$/, "");
}

async function fetchJson(url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    let res;
    try {
      res = await fetch(url, { signal: controller.signal });
    } catch (error) {
      throw new Error(`Cannot reach CDP endpoint ${url}: ${error.message}`);
    }
    if (!res.ok) throw new Error(`HTTP ${res.status} from ${url}`);
    return await res.json();
  } finally {
    clearTimeout(timer);
  }
}

async function findChatGptPage(cdpBase, timeoutMs) {
  const pages = await fetchJson(`${trimSlash(cdpBase)}/json/list`, timeoutMs);
  const candidates = pages.filter((page) => page.type === "page");
  const chat = candidates.find((page) => /^https:\/\/chatgpt\.com\//.test(page.url || ""));
  const page = chat;
  if (!page) throw new Error("No explicit https://chatgpt.com/ CDP page target found; refusing to evaluate another page.");
  if (!page.webSocketDebuggerUrl) throw new Error("Selected CDP page has no webSocketDebuggerUrl.");
  return page;
}

async function createCdpClient(wsUrl, timeoutMs) {
  if (typeof WebSocket === "undefined") {
    throw new Error("This script needs a Node.js runtime with global WebSocket support.");
  }

  const ws = new WebSocket(wsUrl);
  const pending = new Map();
  let nextId = 1;

  await new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("Timed out opening CDP websocket")), timeoutMs);
    ws.addEventListener("open", () => {
      clearTimeout(timer);
      resolve();
    }, { once: true });
    ws.addEventListener("error", () => {
      clearTimeout(timer);
      reject(new Error("Failed to open CDP websocket"));
    }, { once: true });
  });

  ws.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id || !pending.has(message.id)) return;
    const item = pending.get(message.id);
    pending.delete(message.id);
    clearTimeout(item.timer);
    if (message.error) item.reject(new Error(JSON.stringify(message.error)));
    else item.resolve(message.result);
  });

  function send(method, params = {}, commandTimeoutMs = timeoutMs) {
    const id = nextId;
    nextId += 1;
    ws.send(JSON.stringify({ id, method, params }));
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, commandTimeoutMs);
      pending.set(id, { resolve, reject, timer });
    });
  }

  return {
    send,
    close() {
      ws.close();
    },
  };
}

function buildBrowserExpression(rows, opts) {
  return `
(async (inputRows, options) => {
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
  const pick = (...values) => {
    for (const value of values) {
      if (value !== undefined && value !== null && String(value) !== "") return String(value);
    }
    return "";
  };
  const isUuid = (value) => /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(String(value || ""));
  function jwtPayload(token) {
    try {
      const payload = String(token || "").split(".")[1];
      if (!payload) return {};
      const base64 = payload.replace(/-/g, "+").replace(/_/g, "/").padEnd(Math.ceil(payload.length / 4) * 4, "=");
      const raw = atob(base64);
      let encoded = "";
      for (let i = 0; i < raw.length; i += 1) {
        encoded += "%" + ("00" + raw.charCodeAt(i).toString(16)).slice(-2);
      }
      return JSON.parse(decodeURIComponent(encoded));
    } catch {
      return {};
    }
  }
  async function fetchText(url, requestOptions) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), options.timeoutMs);
    try {
      const res = await fetch(url, { ...requestOptions, signal: controller.signal });
      const text = await res.text();
      return { res, text };
    } finally {
      clearTimeout(timer);
    }
  }
  function claimsFromSession(json) {
    const token = pick(json.accessToken, json.access_token, json.tokens && json.tokens.access_token);
    const claims = jwtPayload(token);
    const auth = claims["https://api.openai.com/auth"] || {};
    const accountId = pick(auth.chatgpt_account_id, json.account && json.account.id, json.account_id);
    const plan = pick(auth.chatgpt_plan_type, auth.plan_type, json.account && json.account.planType, json.account && json.account.plan_type, json.plan_type);
    return { tokenPresent: Boolean(token), accountId, plan };
  }
  async function exchange(accountId) {
    const url = "/api/auth/session?exchange_workspace_token=true&workspace_id=" + encodeURIComponent(accountId) + "&reason=setCurrentAccount";
    const response = await fetchText(url, { credentials: "include", headers: { accept: "*/*" } });
    let json = {};
    try { json = JSON.parse(response.text); } catch {}
    return { response, json, claims: claimsFromSession(json) };
  }

  const startedAt = new Date().toISOString();
  const sessionResponse = await fetchText("/api/auth/session", { credentials: "include", headers: { accept: "*/*" } });
  let sessionJson = {};
  try { sessionJson = JSON.parse(sessionResponse.text); } catch {}
  const initial = claimsFromSession(sessionJson);
  if (!initial.tokenPresent) {
    return {
      method: "exchange-only",
      startedAt,
      loggedIn: false,
      sessionHttp: sessionResponse.res.status,
      currentAccount: "",
      rows: [],
      restore: { attempted: false, ok: false, note: "not logged in" },
    };
  }

  const rows = [];
  for (const row of inputRows) {
    const item = {
      id: row.id,
      source: row.source || "",
      status: "exchange-only-no-access",
      http: "",
      returned: "",
      returnedAccountId: "",
      plan: "",
      note: "",
    };
    try {
      const exchanged = await exchange(row.id);
      item.http = String(exchanged.response.res.status);
      item.returnedAccountId = exchanged.claims.accountId || "";
      item.returned = item.returnedAccountId ? item.returnedAccountId.slice(0, 8) : "";
      item.plan = exchanged.claims.plan || "";
      if (exchanged.response.res.ok && exchanged.claims.accountId.toLowerCase() === row.id.toLowerCase()) {
        item.status = item.plan.toLowerCase() === "k12" ? "exchange-only-available" : "accessible-not-k12";
      } else if (exchanged.response.res.ok && exchanged.claims.accountId) {
        item.note = "returned-other-account";
      } else {
        item.note = "no-target-session";
      }
    } catch (error) {
      item.http = "ERR";
      item.note = String(error && error.message || error).slice(0, 120);
    }
    rows.push(item);
    if (options.delayMs > 0) await sleep(options.delayMs);
  }

  const restore = { attempted: false, ok: false, note: "" };
  if (options.restoreCurrent && isUuid(initial.accountId)) {
    const lastReturnedAccountId = rows.length ? rows[rows.length - 1].returnedAccountId : "";
    if (!lastReturnedAccountId || initial.accountId.toLowerCase() !== lastReturnedAccountId.toLowerCase()) {
      restore.attempted = true;
      try {
        const restored = await exchange(initial.accountId);
        restore.ok = restored.response.res.ok && restored.claims.accountId.toLowerCase() === initial.accountId.toLowerCase();
        restore.note = restore.ok ? "restored" : "restore-returned-other-account";
      } catch (error) {
        restore.note = String(error && error.message || error).slice(0, 120);
      }
    } else {
      restore.note = "already-current";
    }
  } else {
    restore.note = options.restoreCurrent ? "initial-account-not-restorable" : "disabled";
  }

  return {
    method: "exchange-only",
    startedAt,
    loggedIn: true,
    sessionHttp: sessionResponse.res.status,
    currentAccount: initial.accountId ? initial.accountId.slice(0, 8) : "",
    rows: rows.map(({ returnedAccountId, ...row }) => row),
    restore,
  };
})(${JSON.stringify(rows)}, ${JSON.stringify({
    delayMs: opts.delayMs,
    timeoutMs: opts.timeoutMs,
    restoreCurrent: opts.restoreCurrent,
  })})`;
}

async function runCheck(rows, opts) {
  const page = await findChatGptPage(opts.cdp, opts.timeoutMs);
  const cdp = await createCdpClient(page.webSocketDebuggerUrl, opts.timeoutMs);
  try {
    await cdp.send("Runtime.enable");
    const expression = buildBrowserExpression(rows, opts);
    const result = await cdp.send(
      "Runtime.evaluate",
      { expression, awaitPromise: true, returnByValue: true },
      Math.max(opts.timeoutMs * (rows.length + 3), 30000),
    );
    if (result.exceptionDetails) {
      throw new Error(`Browser evaluation failed: ${JSON.stringify(result.exceptionDetails)}`);
    }
    return result.result.value;
  } finally {
    cdp.close();
  }
}

function pad(value, width) {
  const text = String(value ?? "");
  return text + " ".repeat(Math.max(0, width - text.length));
}

function printTable(result) {
  process.stdout.write(`method: ${result.method}\n`);
  process.stdout.write(`loggedIn: ${result.loggedIn} sessionHttp: ${result.sessionHttp} currentAccount: ${result.currentAccount || "-"}\n`);
  process.stdout.write(`restore: attempted=${result.restore?.attempted ?? false} ok=${result.restore?.ok ?? false} note=${result.restore?.note || ""}\n\n`);

  if (!result.rows?.length) return;
  const headers = ["status", "id", "source", "plan", "http", "returned", "note"];
  const widths = Object.fromEntries(headers.map((header) => [header, header.length]));
  for (const row of result.rows) {
    for (const header of headers) {
      widths[header] = Math.max(widths[header], String(row[header] ?? "").length);
    }
  }
  process.stdout.write(headers.map((header) => pad(header, widths[header])).join(" | ") + "\n");
  process.stdout.write(headers.map((header) => "-".repeat(widths[header])).join("-+-") + "\n");
  for (const row of result.rows) {
    process.stdout.write(headers.map((header) => pad(row[header], widths[header])).join(" | ") + "\n");
  }
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.selfTest) {
    runSelfTest();
    return;
  }

  const rows = await readIds(opts);
  const result = await runCheck(rows, opts);
  if (opts.json) process.stdout.write(JSON.stringify(result, null, 2) + "\n");
  else printTable(result);
}

main().catch((error) => {
  process.stderr.write(`ERROR: ${error.message}\n`);
  process.exit(1);
});
