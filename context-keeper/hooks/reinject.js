'use strict';

// SessionStart(compact) hook：压缩完成后回注近期原文，使落点 ≈ TARGET_TOTAL。
// 只读 transcript + 写 stdout；任何异常 exit 0 空输出（= 没装插件）。
const readline = require('node:readline');
const { createReadStream, readFileSync, rmSync, writeFileSync, mkdirSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { TARGET_TOTAL, BUDGET_FLOOR, CAP_RATIO, MIN_TAIL, STALE_MS, STALE_RETRY, STALE_RETRY_DELAY, sidecarPath, isBoundary, pickLastBoundary, entryChars } = require('./lib.js');

// spec §5：流式解析 JSONL，取最后一条 boundary 之前、上一条 boundary 之后的主链行，
// 剔除 preserved/isCompactSummary/isMeta；畸形行跳过；boundary 之后的内容不进窗口。
async function extractWindow(stream) {
  const entries = [];
  const rl = readline.createInterface({ input: stream, crlfDelay: Infinity });
  for await (const line of rl) {
    let e = null;
    try {
      e = JSON.parse(line);
    } catch {
      continue; // 畸形行跳过
    }
    if (e && typeof e === 'object') entries.push(e);
  }

  const boundary = pickLastBoundary(entries);
  if (!boundary) return { boundary: null, window: [] };
  boundary.ts = entries[boundary.index].timestamp;

  let prev = -1;
  for (let i = boundary.index - 1; i >= 0; i--) {
    if (isBoundary(entries[i])) {
      prev = i;
      break;
    }
  }

  const preserved = new Set(boundary.meta?.preservedMessages?.uuids ?? []);
  const window = [];
  for (let i = prev + 1; i < boundary.index; i++) {
    const e = entries[i];
    if (e.isSidechain === true) continue;
    if (e.isCompactSummary === true) continue;
    if (e.isMeta === true) continue;
    if (preserved.has(e.uuid)) continue;
    window.push(e);
  }
  return { boundary, window };
}

// spec §5.7 + §6：trigger 策略 → 预算 → 从新往旧累加（单条上限 budget×CAP_RATIO，
// 超限截尾；剩余 < MIN_TAIL 停止）。返回 null = 不回注。
// picked 沿用 window 顺序（旧→新），供渲染按时间序输出。
function selectMessages(window, meta, sidecar) {
  if (meta?.trigger === 'manual' && (!sidecar || sidecar.hasInstructions)) return null;
  const budget = TARGET_TOTAL - (meta?.postTokens ?? 0);
  if (budget < BUDGET_FLOOR) return null;

  // 兜底链：退化 meta（缺 preTokens / 窗口 ≤0）→ 不回注，绝不整窗注入
  const windowTokens = (meta?.preTokens ?? 0) - (meta?.postTokens ?? 0);
  if (!Number.isFinite(windowTokens) || windowTokens <= 0) return null;

  const chars = window.map(entryChars);
  const total = chars.reduce((a, b) => a + b, 0);
  if (total === 0) return { picked: [], injectedEst: 0 };
  const cap = Math.floor(budget * CAP_RATIO);
  const picked = [];
  let injected = 0;
  for (let i = window.length - 1; i >= 0; i--) {
    const remaining = budget - injected;
    if (remaining < MIN_TAIL) break;
    const est = Math.round((chars[i] / total) * windowTokens);
    const allowance = Math.min(remaining, cap);
    if (est <= allowance) {
      picked.push({ entry: window[i], est, origEst: est, truncated: false });
      injected += est;
    } else {
      picked.push({ entry: window[i], est: allowance, origEst: est, truncated: true });
      injected += allowance;
    }
  }
  picked.reverse();
  return { picked, injectedEst: injected };
}

// spec §7：忠实渲染；thinking 跳过；tool_use input 截 300 字符；truncated 条目截尾并标注原文 token 数
function blockText(block) {
  if (typeof block === 'string') return block;
  if (Array.isArray(block)) return block.map(blockText).join('\n');
  if (block?.type === 'text') return block.text ?? '';
  if (block?.type === 'image') return '[图片，略]'; // base64 不得入注
  const s = JSON.stringify(block ?? '');
  return s.length > 300 ? `${s.slice(0, 300)}…` : s; // 未知块回退串截断
}

function renderEntryText(item) {
  const role = item.entry?.message?.role === 'assistant' ? 'assistant' : 'user';
  const content = item.entry?.message?.content;
  const lines = [];
  if (typeof content === 'string') {
    lines.push(`[${role}] ${content}`);
  } else if (Array.isArray(content)) {
    for (const b of content) {
      if (b?.type === 'thinking') continue;
      if (b?.type === 'tool_use') lines.push(`[tool_use ${b.name}] ${JSON.stringify(b.input ?? {}).slice(0, 300)}`);
      else if (b?.type === 'tool_result') lines.push(`[tool_result] ${blockText(b.content)}`);
      else lines.push(`[${role}] ${blockText(b)}`);
    }
  }
  return lines.join('\n');
}

function renderPicked(picked) {
  const banner = '以下为 context-keeper 回注的近期对话原文（已被压缩摘除，回注保留细节）：';
  const body = picked.map((item) => {
    let text = renderEntryText(item);
    if (item.truncated) {
      const cut = Math.max(1, Math.floor(text.length * (item.est / item.origEst)));
      text = `${text.slice(0, cut)}〔截断，原文共 ${item.origEst} tokens〕`;
    }
    return text;
  });
  return [banner, ...body].join('\n\n');
}

function writeLog(sessionId, extra) {
  try {
    const dir = path.join(os.tmpdir(), 'context-keeper');
    mkdirSync(dir, { recursive: true });
    writeFileSync(path.join(dir, `last-run-${sessionId}.json`), JSON.stringify({ ts: Date.now(), sessionId, ...extra }));
  } catch {
    // 日志失败不影响主流程
  }
}

// §5.9：boundary 时间戳早于 hookStart 超过 STALE_MS = 疑似落盘竞态旧态
function isStaleBoundary(boundary, hookStart) {
  const ts = Date.parse(boundary?.ts || '');
  if (!Number.isFinite(ts)) return false; // 不可解析 → 视为新鲜（不破坏既有行为）
  return hookStart - ts > STALE_MS;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function main() {
  const hookStart = Date.now();
  let sessionId = 'unknown';
  let outcome = 'error';
  try {
    const input = JSON.parse(readFileSync(0, 'utf8'));
    sessionId = String(input?.session_id ?? 'unknown');
    const tp = input?.transcript_path;
    if (!tp) throw new Error('no transcript_path');

    const sp = sidecarPath(sessionId);
    let sidecar = null;
    try {
      sidecar = JSON.parse(readFileSync(sp, 'utf8'));
    } catch {
      sidecar = null;
    }
    rmSync(sp, { force: true }); // 读后即删（spec §8）

    let { boundary, window } = await extractWindow(createReadStream(tp));

    // §5.9 新鲜度守卫：陈旧则重读，等迟到落盘的 boundary；穷尽则保守不注入
    if (boundary && isStaleBoundary(boundary, hookStart)) {
      let rescued = null;
      for (let i = 0; i < STALE_RETRY && !rescued; i++) {
        await sleep(STALE_RETRY_DELAY);
        const r2 = await extractWindow(createReadStream(tp));
        if (r2.boundary && !isStaleBoundary(r2.boundary, hookStart)) rescued = r2;
      }
      if (rescued) {
        boundary = rescued.boundary;
        window = rescued.window;
      } else {
        boundary = null; // 穷尽 → 保守不注入
        outcome = 'skipped-stale';
      }
    }

    const result = boundary ? selectMessages(window, boundary.meta, sidecar) : null;
    if (result && result.picked.length > 0) {
      const additionalContext = renderPicked(result.picked);
      process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: 'SessionStart', additionalContext } }));
      outcome = 'injected';
    } else if (outcome !== 'skipped-stale') {
      outcome = 'skipped';
    }
  } catch {
    outcome = 'error'; // 兜底：任何异常 exit 0 空输出 = 原生行为
  }
  writeLog(sessionId, { outcome });
  process.exit(0);
}

if (require.main === module) main();

module.exports = { extractWindow, selectMessages, renderPicked };
