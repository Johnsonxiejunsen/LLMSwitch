'use strict';

const { test } = require('node:test');
const assert = require('node:assert');
const { spawnSync } = require('node:child_process');
const { readFileSync, rmSync } = require('node:fs');
const path = require('node:path');
const { sidecarPath } = require('../hooks/lib.js');

const HOOK = path.join(__dirname, '..', 'hooks', 'precompact.js');

function run(stdin) {
  return spawnSync(process.execPath, [HOOK], { input: stdin, encoding: 'utf8' });
}

test('manual with instructions writes hasInstructions true', () => {
  const r = run(JSON.stringify({ session_id: 's9', trigger: 'manual', custom_instructions: 'focus on API' }));
  assert.strictEqual(r.status, 0, `stderr: ${r.stderr}`);
  assert.strictEqual(r.stdout, '');
  const sidecar = JSON.parse(readFileSync(sidecarPath('s9'), 'utf8'));
  assert.strictEqual(sidecar.hasInstructions, true);
  assert.strictEqual(typeof sidecar.ts, 'number');
  rmSync(sidecarPath('s9'), { force: true });
});

test('manual without instructions writes hasInstructions false', () => {
  const r = run(JSON.stringify({ session_id: 's9', trigger: 'manual', custom_instructions: null }));
  assert.strictEqual(r.status, 0, `stderr: ${r.stderr}`);
  const sidecar = JSON.parse(readFileSync(sidecarPath('s9'), 'utf8'));
  assert.strictEqual(sidecar.hasInstructions, false);
  rmSync(sidecarPath('s9'), { force: true });
});

test('invalid stdin still exits 0 and writes no file', () => {
  rmSync(sidecarPath('s10'), { force: true });
  const r = run('not json');
  assert.strictEqual(r.status, 0);
  assert.strictEqual(r.stdout, '');
  assert.throws(() => readFileSync(sidecarPath('s10'), 'utf8'), /ENOENT/);
});
