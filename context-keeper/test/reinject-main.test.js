'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { spawnSync, spawn } = require('node:child_process');
const { writeFileSync, appendFileSync, rmSync, mkdtempSync } = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { sidecarPath } = require('../hooks/lib.js');
const { makeFixture } = require('./helpers/make-fixture.js');

const HOOK = path.join(__dirname, '..', 'hooks', 'reinject.js');
const TMP = mkdtempSync(path.join(os.tmpdir(), 'ck-main-'));

function writeTranscript(lines) {
  const p = path.join(TMP, `tr-${Math.random().toString(36).slice(2)}.jsonl`);
  writeFileSync(p, makeFixture({ lines }) + '\n');
  return p;
}

function run(stdinObj) {
  return spawnSync(process.execPath, [HOOK], {
    input: typeof stdinObj === 'string' ? stdinObj : JSON.stringify(stdinObj),
    encoding: 'utf8',
  });
}

const B2_AUTO = { trigger: 'auto', preTokens: 478286, postTokens: 19582 };
const B2_MANUAL = { trigger: 'manual', preTokens: 478286, postTokens: 19582 };

test('(a) auto + full fixture renders hook JSON with prefixes and banner', () => {
  const tp = writeTranscript([
    { uuid: 'u1', content: 'user-visible-text' },
    { uuid: 'a1', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Monitor', input: { q: 'X'.repeat(10000) } }] } }, // 大头占比，其余条目得以留在预算内
    { uuid: 'a2', message: { role: 'assistant', content: [{ type: 'text', text: 'answer' }, { type: 'thinking', text: 'thinking-secret' }] } },
    { uuid: 'tr1', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't1', content: 'result-text' }] } },
    { uuid: 'B2', compactMetadata: B2_AUTO },
  ]);
  const sid = 'ck-auto-session';
  rmSync(sidecarPath(sid), { force: true });
  writeFileSync(sidecarPath(sid), JSON.stringify({ hasInstructions: true, ts: Date.now() })); // auto 须无视之

  const r = run({ session_id: sid, transcript_path: tp });
  assert.strictEqual(r.status, 0, `stderr: ${r.stderr}`);
  const out = JSON.parse(r.stdout);
  assert.strictEqual(out.hookSpecificOutput.hookEventName, 'SessionStart');
  const ac = out.hookSpecificOutput.additionalContext;
  assert.ok(ac.includes('context-keeper'), 'banner');
  assert.ok(ac.includes('[user] user-visible-text'));
  assert.ok(ac.includes('[tool_use Monitor]'));
  assert.ok(ac.includes('[tool_result] result-text'));
  assert.ok(!ac.includes('thinking-secret'), 'thinking 跳过');
  assert.strictEqual(existsSyncSafe(sidecarPath(sid)), false, 'sidecar 读后即删');
  rmSync(tp, { force: true });
  rmSync(sidecarPath(sid), { force: true });
});

test('(b) tool_use input is cut at 300 chars', () => {
  const tp = writeTranscript([
    { uuid: 'old', content: 'o'.repeat(100000) }, // 占 99% 字符量，保证 a1 本身不被条目级截断
    { uuid: 'a1', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'M', input: { q: 'X'.repeat(500) } }] } },
    { uuid: 'B2', compactMetadata: B2_AUTO },
  ]);
  const r = run({ session_id: 'ck-b', transcript_path: tp });
  const ac = JSON.parse(r.stdout).hookSpecificOutput.additionalContext;
  // JSON 包头 {"q":" 占 6 字符 → 300 字符内恰好 294 个连续 X
  assert.ok(ac.includes('X'.repeat(294)));
  assert.ok(!ac.includes('X'.repeat(295)));
  rmSync(tp, { force: true });
});

test('(c) truncated entries carry the marker with original token count', () => {
  const tp = writeTranscript([
    { uuid: 'e1', content: 'y'.repeat(60000) },
    { uuid: 'e2', content: 'y'.repeat(60000) },
    { uuid: 'e3', content: 'y'.repeat(60000) },
    { uuid: 'B2', compactMetadata: B2_AUTO },
  ]);
  const r = run({ session_id: 'ck-c', transcript_path: tp });
  const ac = JSON.parse(r.stdout).hookSpecificOutput.additionalContext;
  assert.ok(ac.includes('〔截断，原文共 152901 tokens〕'), `marker missing: ${ac.slice(-120)}`); // marker 印 origEst
  rmSync(tp, { force: true });
});

test('(d) bad stdin exits 0 with empty stdout', () => {
  const r = run('{bad');
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout, '');
});

test('(e) missing transcript exits 0 with empty stdout', () => {
  const r = run({ session_id: 'ck-e', transcript_path: path.join(TMP, 'nope.jsonl') });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout, '');
});

test('(f) manual without sidecar → empty stdout', () => {
  const tp = writeTranscript([
    { uuid: 'u1', content: 'hello' },
    { uuid: 'B2', compactMetadata: B2_MANUAL },
  ]);
  const sid = 'ck-f';
  rmSync(sidecarPath(sid), { force: true });
  const r = run({ session_id: sid, transcript_path: tp });
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout, '');
  rmSync(tp, { force: true });
});

test('(g) image blocks elided, unknown blocks capped', () => {
  const tp = writeTranscript([
    { uuid: 'big-old', content: 'o'.repeat(100000) },
    { uuid: 'tr-img', message: { role: 'user', content: [
      { type: 'tool_result', tool_use_id: 't9', content: [
        { type: 'image', source: { type: 'base64', data: 'QUJD'.repeat(1000) } },
        { type: 'text', text: 'caption-keep' },
      ] },
      { type: 'weird-block', payload: 'Z'.repeat(1000) },
    ] } },
    { uuid: 'B2', compactMetadata: B2_AUTO },
  ]);
  const r = run({ session_id: 'ck-g', transcript_path: tp });
  assert.strictEqual(r.status, 0, `stderr: ${r.stderr}`);
  const ac = JSON.parse(r.stdout).hookSpecificOutput.additionalContext;
  assert.ok(ac.includes('[图片，略]'));
  assert.ok(!ac.includes('QUJD'), 'base64 不得入注');
  assert.ok(ac.includes('caption-keep'), 'text 内容保留');
  assert.ok(!ac.includes('Z'.repeat(300)), '未知块回退串截断');
  rmSync(tp, { force: true });
});

test('(h) stale boundary with no fresher one → no injection（新鲜度守卫）', () => {
  const stale = new Date(Date.now() - 10 * 60 * 1000).toISOString();
  const tp = writeTranscript([
    { uuid: 'u1', content: 'stale-window-text', timestamp: stale },
    { uuid: 'B2', compactMetadata: B2_AUTO, timestamp: stale },
  ]);
  const r = spawnSync(process.execPath, [HOOK], {
    input: JSON.stringify({ session_id: 'ck-h', transcript_path: tp }),
    encoding: 'utf8',
    env: { ...process.env, CK_STALE_MS: '1000', CK_STALE_RETRY: '1', CK_STALE_RETRY_DELAY: '10' },
  });
  assert.strictEqual(r.status, 0, `stderr: ${r.stderr}`);
  assert.strictEqual(r.stdout, '', '陈旧 boundary 不得注入');
  rmSync(tp, { force: true });
});

test('(i) retry picks up boundary that lands late（竞态修复）', async () => {
  const stale = new Date(Date.now() - 60 * 1000).toISOString();
  const tp = writeTranscript([
    { uuid: 'u1', content: 'stale-window-text', timestamp: stale },
    { uuid: 'B2', compactMetadata: { trigger: 'auto', preTokens: 111, postTokens: 111 }, timestamp: stale },
  ]);
  try {
    // 异步 spawn：事件循环空闲，300ms 后的追加才能真正发生在子进程重试窗口内
    const child = spawn(process.execPath, [HOOK], {
      env: { ...process.env, CK_STALE_MS: '1000', CK_STALE_RETRY: '10', CK_STALE_RETRY_DELAY: '100' },
    });
    child.stdin.write(JSON.stringify({ session_id: 'ck-i', transcript_path: tp }));
    child.stdin.end();
    let stdout = '';
    child.stdout.on('data', (d) => { stdout += d; });
    const done = new Promise((resolve) => child.on('close', (code) => resolve(code)));
    setTimeout(() => {
      const extra = makeFixture({ lines: [
        { uuid: 'fresh-msg', content: 'fresh-msg-marker' },
        { uuid: 'B3', compactMetadata: { trigger: 'auto', preTokens: 1000, postTokens: 500 } }, // 小窗口数值，避免单条巨 est 触发截断吞掉 marker
      ]});
      appendFileSync(tp, extra + '\n');
    }, 300);
    const code = await Promise.race([
      done,
      new Promise((resolve) => setTimeout(() => { child.kill(); resolve(-1); }, 10000)),
    ]);
    assert.strictEqual(code, 0);
    const out = JSON.parse(stdout);
    assert.ok(out.hookSpecificOutput.additionalContext.includes('fresh-msg-marker'), '重读捞到迟到落盘，窗口用新 boundary');
    assert.ok(!out.hookSpecificOutput.additionalContext.includes('stale-window-text'), '不得用旧窗口内容');
  } finally {
    rmSync(tp, { force: true });
  }
});

function existsSyncSafe(p) {
  try {
    // eslint-disable-next-line global-require
    return require('node:fs').existsSync(p);
  } catch {
    return false;
  }
}
