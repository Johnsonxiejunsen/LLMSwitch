'use strict';

// 按对象 spec 生成 JSONL 文本（仅测试用）。
// spec: { lines: Array<{type?, subtype?, message?, uuid?, isSidechain?, isMeta?,
//   isCompactSummary?, compactMetadata?, content?}> }
// 每行补 uuid（缺省自增 uN）、timestamp、sessionId:'s1'。
function makeFixture({ lines }) {
  let auto = 0;
  return lines
    .map((l) => {
      const e = {
        parentUuid: null,
        isSidechain: l.isSidechain ?? false,
        type: l.type || 'user',
        message: l.message || { role: 'user', content: l.content ?? '' },
        uuid: l.uuid || `u${++auto}`,
        timestamp: l.timestamp || new Date().toISOString(),
        sessionId: 's1',
      };
      if (l.isMeta) e.isMeta = true;
      if (l.isCompactSummary) e.isCompactSummary = true;
      if (l.compactMetadata) {
        e.type = 'system';
        e.subtype = 'compact_boundary';
        e.compactMetadata = l.compactMetadata;
      }
      return JSON.stringify(e);
    })
    .join('\n');
}

module.exports = { makeFixture };
