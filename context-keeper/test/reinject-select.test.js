'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { selectMessages } = require('../hooks/reinject.js');
const { makeFixture } = require('./helpers/make-fixture.js');

const META = { trigger: 'manual', preTokens: 478286, postTokens: 19582 }; // budget = 130418（spec §6 预演值）

function sixEqualEntries(ch) {
  return makeFixture({ lines: Array.from({ length: 6 }, (_, i) => ({ uuid: `m${i}`, content: ch.repeat(10) })) })
    .split('\n').map((l) => JSON.parse(l));
}

test('real numbers: 6 equal entries, budget fills exactly to 130418', () => {
  const r = selectMessages(sixEqualEntries('a'), META, { hasInstructions: false });
  assert.strictEqual(r.picked.length, 2);
  assert.strictEqual(r.injectedEst, 130418); // 76451 as-is + 53967 截断 = 预算精确吃满
  assert.strictEqual(r.picked[0].truncated, true, '较老那条被截断');
  assert.strictEqual(r.picked[1].truncated, false);
  assert.strictEqual(r.picked[1].est, 76451); // 458704/6
});

test('manual with instructions → null', () => {
  assert.strictEqual(selectMessages(sixEqualEntries('a'), META, { hasInstructions: true }), null);
});

test('manual without sidecar → null（保守兜底）', () => {
  assert.strictEqual(selectMessages(sixEqualEntries('a'), META, null), null);
});

test('auto without sidecar → proceeds', () => {
  const r = selectMessages(sixEqualEntries('a'), { ...META, trigger: 'auto' }, null);
  assert.strictEqual(r.picked.length, 2);
});

test('budget below floor → null', () => {
  const r = selectMessages(sixEqualEntries('a'), { trigger: 'auto', preTokens: 160000, postTokens: 145000 }, null);
  assert.strictEqual(r, null);
});

test('degenerate boundary meta → null（兜底链：缺 preTokens/负窗口不得注入）', () => {
  assert.strictEqual(selectMessages(sixEqualEntries('a'), { trigger: 'auto', postTokens: 19582 }, null), null);
  assert.strictEqual(selectMessages(sixEqualEntries('a'), { trigger: 'auto', preTokens: 100, postTokens: 19582 }, null), null);
  assert.strictEqual(selectMessages(sixEqualEntries('a'), null, null), null);
});

test('CJK content yields identical allocation（自校准按字符占比）', () => {
  const r = selectMessages(sixEqualEntries('字'), META, { hasInstructions: false });
  assert.strictEqual(r.injectedEst, 130418);
  assert.strictEqual(r.picked[1].est, 76451);
});

test('single huge entry is capped, remaining budget flows to older entries', () => {
  const lines = [
    { uuid: 'old1', content: 'a'.repeat(10) },
    { uuid: 'old2', content: 'a'.repeat(10) },
    { uuid: 'old3', content: 'a'.repeat(10) },
    { uuid: 'old4', content: 'a'.repeat(10) },
    { uuid: 'old5', content: 'a'.repeat(10) },
    { uuid: 'big', message: { role: 'user', content: 'b'.repeat(180) } }, // 含引号 182 字符 / 总 242 = 75%
  ];
  const window = makeFixture({ lines }).split('\n').map((l) => JSON.parse(l));
  const r = selectMessages(window, { ...META, trigger: 'auto' }, null);
  // 精确推导：est_big=344976>cap(78250)→截断；old5/old4 est=22746 依序全入；
  // old3 截断填满剩余 6676 → injected=78250+22746+22746+6676=130418
  assert.deepStrictEqual(r.picked.map((p) => p.entry.uuid), ['old3', 'old4', 'old5', 'big']);
  assert.strictEqual(r.injectedEst, 130418);
  const big = r.picked.find((p) => p.entry.uuid === 'big');
  assert.strictEqual(big.truncated, true, '超 CAP_RATIO 的单条被标记截断');
  assert.strictEqual(big.est, Math.floor(130418 * 0.6), '截断后不超过 budget×60%');
  assert.strictEqual(r.picked.find((p) => p.entry.uuid === 'old3').truncated, true, '最后一条老条目截断填满预算');
});
