'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { PassThrough } = require('node:stream');
const { extractWindow } = require('../hooks/reinject.js');
const { makeFixture } = require('./helpers/make-fixture.js');

test('extractWindow picks main-chain entries between last two boundaries', async () => {
  const text = makeFixture({ lines: [
    { uuid: 'u1', content: 'u1' },
    { uuid: 'side', isSidechain: true, content: 'sidechain' },
    { uuid: 'meta', isMeta: true, content: 'meta' },
    { uuid: 'B1', compactMetadata: { trigger: 'manual', preTokens: 10, postTokens: 5 } },
    { uuid: 'sum1', isCompactSummary: true, content: 'summary-1' }, // 真实位置：紧跟上一条 boundary 之后（窗口内）
    { uuid: 'u3', content: 'u3' },
    { uuid: 'a2', message: { role: 'assistant', content: [{ type: 'tool_use', name: 'Monitor', input: { x: 1 } }] } },
    { uuid: 'preserved-1', content: 'kept-by-harness' },
    { uuid: 'u5', content: 'u5' },
    { uuid: 'B2', compactMetadata: { trigger: 'manual', preTokens: 478286, postTokens: 19582, preservedMessages: { uuids: ['preserved-1'] } } },
    { uuid: 'u6', content: 'u6-after-boundary' },
  ]}) + '\n{"broken json"\n';

  const pt = new PassThrough();
  const p = extractWindow(pt);
  pt.end(text);
  const { boundary, window } = await p;

  assert.strictEqual(boundary.meta.preTokens, 478286, 'boundary = B2');
  assert.deepStrictEqual(window.map((e) => e.uuid), ['u3', 'a2', 'u5'],
    'sidechain/isMeta/sum1/preserved/post-boundary/malformed 全部不在窗口');
});

test('extractWindow returns null boundary and empty window without boundary', async () => {
  const pt = new PassThrough();
  const p = extractWindow(pt);
  pt.end(makeFixture({ lines: [{ uuid: 'only', content: 'x' }] }));
  const { boundary, window } = await p;
  assert.strictEqual(boundary, null);
  assert.deepStrictEqual(window, []);
});
