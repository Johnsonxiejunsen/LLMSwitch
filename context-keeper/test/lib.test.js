'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const path = require('node:path');
const os = require('node:os');
const { sidecarPath, entryChars, pickLastBoundary } = require('../hooks/lib.js');
const { makeFixture } = require('./helpers/make-fixture.js');

test('sidecarPath lives under tmp context-keeper with session id', () => {
  const p = sidecarPath('abc');
  assert.ok(p.startsWith(os.tmpdir()), `should start with tmpdir: ${p}`);
  assert.ok(p.includes(path.join('context-keeper', 'sidecar-abc.json')), p);
});

test('entryChars counts JSON-stringified content', () => {
  // JSON.stringify('你好') = '"你好"' → 2 引号 + 2 字符 = 4
  assert.strictEqual(entryChars({ message: { content: '你好' } }), 4);
  assert.strictEqual(entryChars({}), 2); // '' → '""'
});

test('pickLastBoundary returns last boundary with meta', () => {
  const entries = makeFixture({ lines: [
    { content: 'hello' },
    { compactMetadata: { trigger: 'manual', preTokens: 1, postTokens: 2 } },
    { content: 'mid' },
    { compactMetadata: { trigger: 'auto', preTokens: 3, postTokens: 4 } },
  ]}).split('\n').map((l) => JSON.parse(l));
  const b = pickLastBoundary(entries);
  assert.deepStrictEqual(b, { index: 3, meta: { trigger: 'auto', preTokens: 3, postTokens: 4 } });
});

test('pickLastBoundary returns null without boundary', () => {
  const entries = makeFixture({ lines: [{ content: 'x' }] }).split('\n').map((l) => JSON.parse(l));
  assert.strictEqual(pickLastBoundary(entries), null);
});

test('makeFixture emits parseable JSONL with defaults and overrides', () => {
  const lines = makeFixture({ lines: [{ content: 'a' }, { uuid: 'fixed', content: 'b' }] }).split('\n');
  assert.strictEqual(lines.length, 2);
  const first = JSON.parse(lines[0]);
  const second = JSON.parse(lines[1]);
  assert.strictEqual(first.uuid, 'u1');
  assert.strictEqual(first.sessionId, 's1');
  assert.strictEqual(second.uuid, 'fixed');
});
