'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const { writeFileSync, rmSync, readFileSync, createReadStream, existsSync } = require('node:fs');
const path = require('node:path');
const { TARGET_TOTAL, sidecarPath } = require('../hooks/lib.js');
const { extractWindow, selectMessages } = require('../hooks/reinject.js');

const HOOK = path.join(__dirname, '..', 'hooks', 'reinject.js');
const SRC = process.env.CK_SMOKE_FILE;

test('real transcript smoke: pipeline lands budget, spawn contract holds', async (t) => {
  if (!SRC) return t.skip('CK_SMOKE_FILE not set');

  // 管线级：直接驱动导出函数，预算从真实 boundary meta 推导，断言 spec §10 判据
  const { boundary, window } = await extractWindow(createReadStream(SRC));
  assert.ok(boundary, 'real file has a compact boundary');
  const budget = TARGET_TOTAL - boundary.meta.postTokens;
  const r = selectMessages(window, boundary.meta, { hasInstructions: false });
  assert.ok(
    r.injectedEst >= budget * 0.9 && r.injectedEst <= budget * 1.1,
    `injectedEst=${r.injectedEst} vs budget=${budget}（落点=${boundary.meta.postTokens + r.injectedEst}，目标 ${TARGET_TOTAL}）`
  );

  // 进程级：完整 main 合同（sidecar 读后即删、stdout JSON、耗时 <5s）
  const sid = 'smoke';
  rmSync(sidecarPath(sid), { force: true });
  writeFileSync(sidecarPath(sid), JSON.stringify({ hasInstructions: false, ts: Date.now() }));
  const t0 = Date.now();
  const proc = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ session_id: sid, transcript_path: SRC }),
    encoding: 'utf8',
    maxBuffer: 256 * 1024 * 1024,
    env: { ...process.env, CK_STALE_MS: '99999999999' }, // 历史固定样本 boundary 必然"陈旧"，冒烟测的是管线机制
  });
  const durationMs = Date.now() - t0;
  assert.strictEqual(proc.status, 0, `stderr: ${String(proc.stderr).slice(0, 200)}`);
  assert.ok(durationMs < 5000, `duration ${durationMs}ms`);
  const out = JSON.parse(proc.stdout);
  assert.ok(out.hookSpecificOutput.additionalContext.length > 1000, 'ac non-empty');
  assert.strictEqual(existsSync(sidecarPath(sid)), false, 'sidecar 读后即删');
  rmSync(sidecarPath(sid), { force: true });
});
