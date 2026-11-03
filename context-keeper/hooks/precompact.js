'use strict';

// PreCompact hook：把「本次压缩是否带自定义指令」写进临时侧标文件，
// 供 SessionStart 的 reinject.js 执行 Q3 策略（manual+指令 → 不回注）。
// 任何分支都 exit 0、无 stdout —— 失败 = 没装插件。
const { readFileSync, mkdirSync, writeFileSync } = require('node:fs');
const path = require('node:path');
const { sidecarPath } = require('./lib.js');

function main() {
  try {
    const raw = readFileSync(0, 'utf8');
    try {
      const input = JSON.parse(raw);
      const ci = input?.custom_instructions;
      const hasInstructions = typeof ci === 'string' && ci.trim().length > 0;
      const target = sidecarPath(String(input?.session_id ?? 'unknown'));
      mkdirSync(path.dirname(target), { recursive: true });
      writeFileSync(target, JSON.stringify({ hasInstructions, ts: Date.now() }));
    } catch {
      // stdin 不可解析 → 不写侧标；SessionStart 侧对 manual 无侧标按保守（不回注）处理
    }
  } catch {
    // stdin 读不出来 → 同上
  }
  process.exit(0);
}

main();
