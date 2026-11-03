'use strict';

const os = require('node:os');
const path = require('node:path');

// spec §6 原值；CK_TARGET_TOTAL env 可覆盖 TARGET_TOTAL
const TARGET_TOTAL = Number(process.env.CK_TARGET_TOTAL) || 150000;
const BUDGET_FLOOR = 10000;
const CAP_RATIO = 0.6;
const MIN_TAIL = 2000;
// §5.9 新鲜度守卫：boundary 时间戳早于 hook 启动超过 STALE_MS = 疑似落盘竞态旧态
const STALE_MS = Number(process.env.CK_STALE_MS) || 120000;
const STALE_RETRY = Number(process.env.CK_STALE_RETRY) || 5;
const STALE_RETRY_DELAY = Number(process.env.CK_STALE_RETRY_DELAY) || 1000;

function sidecarPath(sessionId) {
  return path.join(os.tmpdir(), 'context-keeper', `sidecar-${sessionId}.json`);
}

function entryChars(entry) {
  try {
    return JSON.stringify(entry?.message?.content ?? '').length;
  } catch {
    return 0;
  }
}

function isBoundary(entry) {
  return entry?.subtype === 'compact_boundary';
}

// 返回 {index, meta}（meta = compactMetadata）或 null
function pickLastBoundary(entries) {
  for (let i = entries.length - 1; i >= 0; i--) {
    if (isBoundary(entries[i])) {
      return { index: i, meta: entries[i].compactMetadata || {} };
    }
  }
  return null;
}

module.exports = { TARGET_TOTAL, BUDGET_FLOOR, CAP_RATIO, MIN_TAIL, STALE_MS, STALE_RETRY, STALE_RETRY_DELAY, sidecarPath, entryChars, isBoundary, pickLastBoundary };
