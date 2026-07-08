#!/usr/bin/env node
import fs from "node:fs";
import crypto from "node:crypto";

function parseArgs(argv) {
  const args = { json: false };
  for (let i = 2; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--json") {
      args.json = true;
    } else if (arg === "--bookmarks") {
      args.bookmarks = argv[++i];
    } else if (arg === "--baseline") {
      args.baseline = argv[++i];
    } else if (arg === "--help" || arg === "-h") {
      args.help = true;
    } else {
      throw new Error(`Unknown argument: ${arg}`);
    }
  }
  return args;
}

function usage() {
  return [
    "Usage:",
    "  node chromium_bookmarks_audit.mjs --bookmarks <Bookmarks> [--baseline <Bookmarks>] [--json]",
  ].join("\n");
}

function readBookmarks(file) {
  const text = fs.readFileSync(file, "utf8");
  return JSON.parse(text);
}

function sha256(value) {
  return crypto.createHash("sha256").update(String(value), "utf8").digest("hex");
}

function displayUrl(url) {
  const text = String(url || "");
  if (text.length <= 180) return text;
  return `${text.slice(0, 120)}...<len=${text.length} sha256=${sha256(text).slice(0, 16)}>`;
}

function walkNode(node, root, folders, out) {
  if (!node) return;
  if (node.type === "url" && node.url) {
    out.urls.push({
      root,
      path: folders.join("/"),
      name: String(node.name || ""),
      url: String(node.url),
    });
  }
  if (node.type === "folder") out.folderCount += 1;
  const nextFolders = node.type === "folder" && node.name ? [...folders, String(node.name)] : folders;
  for (const child of node.children || []) walkNode(child, root, nextFolders, out);
}

function collect(rootObj) {
  const out = { urls: [], folderCount: 0 };
  const rootNames = Object.keys(rootObj.roots || {});
  for (const root of rootNames) {
    for (const child of rootObj.roots?.[root]?.children || []) walkNode(child, root, [], out);
  }
  return { rootNames, urls: out.urls, folderCount: out.folderCount };
}

function countUnder(node) {
  let urls = 0;
  let folders = 0;
  (function rec(item) {
    if (!item) return;
    if (item.type === "url") urls += 1;
    if (item.type === "folder") folders += 1;
    for (const child of item.children || []) rec(child);
  })(node);
  return { urls, folders: Math.max(0, folders - 1) };
}

function rootSummary(rootObj) {
  const result = {};
  for (const [name, node] of Object.entries(rootObj.roots || {})) result[name] = countUnder(node);
  return result;
}

function topLevel(rootObj, rootName) {
  const root = rootObj.roots?.[rootName];
  return (root?.children || []).map((child) => {
    const base = { type: child.type, name: String(child.name || "") };
    if (child.type === "url") {
      const url = String(child.url || "");
      return { ...base, url: displayUrl(url), urlLength: url.length, urlSha256: sha256(url) };
    }
    return { ...base, ...countUnder(child) };
  });
}

function duplicateGroups(urls) {
  const groups = new Map();
  for (const item of urls) {
    const key = item.url.toLowerCase();
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  return [...groups.entries()]
    .filter(([, items]) => items.length > 1)
    .map(([url, items]) => ({
      url: displayUrl(url),
      urlSha256: sha256(url),
      count: items.length,
      paths: items.map((x) => `${x.root}/${x.path}/${x.name}`),
    }));
}

function checksum(rootObj) {
  if (!rootObj.checksum) return null;
  const md5 = crypto.createHash("md5");
  const addUtf8 = (value) => md5.update(Buffer.from(String(value ?? ""), "utf8"));
  const addUtf16 = (value) => md5.update(Buffer.from(String(value ?? ""), "utf16le"));
  const visit = (node) => {
    if (!node) return;
    addUtf8(node.id);
    addUtf16(node.name);
    addUtf8(node.type);
    if (node.type === "url") addUtf8(node.url);
    for (const child of node.children || []) visit(child);
  };
  for (const rootName of Object.keys(rootObj.roots || {})) visit(rootObj.roots[rootName]);
  const computed = md5.digest("hex");
  return { stored: rootObj.checksum, computed, ok: computed === rootObj.checksum, rootNames: Object.keys(rootObj.roots || {}) };
}

function directBookmarkBarUrls(rootObj) {
  return (rootObj.roots?.bookmark_bar?.children || [])
    .filter((child) => child.type === "url")
    .map((child) => {
      const url = String(child.url || "");
      return { name: String(child.name || ""), url: displayUrl(url), urlLength: url.length, urlSha256: sha256(url) };
    });
}

function directBookmarkBarUrlValues(rootObj) {
  return (rootObj.roots?.bookmark_bar?.children || [])
    .filter((child) => child.type === "url")
    .map((child) => String(child.url || ""));
}

function treeNodeSignature(node) {
  if (!node) return null;
  const base = {
    type: String(node.type || ""),
    name: String(node.name || ""),
  };
  if (node.type === "url") return { ...base, url: String(node.url || "") };
  return {
    ...base,
    children: (node.children || []).map((child) => treeNodeSignature(child)),
  };
}

function treeSignature(rootObj) {
  const roots = {};
  for (const rootName of Object.keys(rootObj.roots || {})) {
    roots[rootName] = treeNodeSignature(rootObj.roots[rootName]);
  }
  return JSON.stringify(roots);
}

function summarize(file) {
  const rootObj = readBookmarks(file);
  const inventory = collect(rootObj);
  const dupes = duplicateGroups(inventory.urls);
  return {
    file,
    version: rootObj.version ?? null,
    roots: inventory.rootNames,
    counts: {
      urls: inventory.urls.length,
      folders: inventory.folderCount,
      duplicateUrlGroups: dupes.length,
    },
    rootSummary: rootSummary(rootObj),
    topLevelBookmarkBar: topLevel(rootObj, "bookmark_bar"),
    directBookmarkBarUrls: directBookmarkBarUrls(rootObj),
    directBookmarkBarUrlValues: directBookmarkBarUrlValues(rootObj),
    treeSignature: treeSignature(rootObj),
    checksum: checksum(rootObj),
    duplicateSamples: dupes.slice(0, 20),
    urlSet: new Set(inventory.urls.map((x) => x.url.toLowerCase())),
  };
}

function compare(current, baseline) {
  const missingFromCurrent = [...baseline.urlSet].filter((url) => !current.urlSet.has(url));
  const addedInCurrent = [...current.urlSet].filter((url) => !baseline.urlSet.has(url));
  const currentDirect = current.directBookmarkBarUrlValues;
  const baselineDirect = baseline.directBookmarkBarUrlValues;
  return {
    missingFromCurrentCount: missingFromCurrent.length,
    addedInCurrentCount: addedInCurrent.length,
    missingFromCurrentSamples: missingFromCurrent.slice(0, 20).map(displayUrl),
    addedInCurrentSamples: addedInCurrent.slice(0, 20).map(displayUrl),
    directBookmarkBarUrlSequenceSame: JSON.stringify(currentDirect) === JSON.stringify(baselineDirect),
    exactTreeAndOrderMatch: current.treeSignature === baseline.treeSignature,
  };
}

function stripInternal(summary) {
  const { urlSet, directBookmarkBarUrlValues: _directBookmarkBarUrlValues, treeSignature: _treeSignature, ...rest } = summary;
  return rest;
}

function printText(report) {
  const current = report.current;
  console.log(`Bookmarks: ${current.file}`);
  console.log(`URLs: ${current.counts.urls}`);
  console.log(`Folders: ${current.counts.folders}`);
  console.log(`Duplicate URL groups: ${current.counts.duplicateUrlGroups}`);
  if (current.checksum) console.log(`Checksum: ${current.checksum.ok ? "ok" : "mismatch"} (${current.checksum.computed})`);
  console.log(`Roots: ${current.roots.join(", ")}`);
  if (report.compare) {
    console.log(`Missing vs baseline: ${report.compare.missingFromCurrentCount}`);
    console.log(`Added vs baseline: ${report.compare.addedInCurrentCount}`);
    console.log(`Direct bookmark bar URL sequence same: ${report.compare.directBookmarkBarUrlSequenceSame}`);
    console.log(`Exact tree and order match: ${report.compare.exactTreeAndOrderMatch}`);
  }
}

try {
  const args = parseArgs(process.argv);
  if (args.help || !args.bookmarks) {
    console.log(usage());
    process.exit(args.help ? 0 : 1);
  }
  const current = summarize(args.bookmarks);
  const report = { current: stripInternal(current) };
  if (args.baseline) {
    const baseline = summarize(args.baseline);
    report.baseline = stripInternal(baseline);
    report.compare = compare(current, baseline);
  }
  if (args.json) console.log(JSON.stringify(report, null, 2));
  else printText(report);
} catch (error) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
