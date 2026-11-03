# context-keeper · changelog

- 2026-10-27 创建主 spec v0.1（草案，待确认）：A 方案（忠实回注 150k 原文）定案；触发走原生 `autoCompactWindow: 200000`；实测取证 v2.1.311 compact_boundary 结构（7562e3c6，478286→19582）
- 2026-10-27 v0.2（builder 审查修订）：遗留风险重组为 5 项 spike（新增 #0 auto 触发 SessionStart 实证 + Plan B）；新增 5.6 isMeta 剔除（AI 裁决）；新增 §12 待拍板 Q3（manual 压缩回注策略）/ Q4（单条巨块截断）
- 2026-10-28 v1.0 定稿：Q3 拍板（manual+指令不回注/裸 manual 回注/auto 回注；新增 PreCompact 临时侧标检测机制，§5.7/§8 同步修订）；Q4 拍板（单条上限 budget×60% 截尾标注，§6/§7 修订）；下一步 plan
- 2026-11-02 v0.1.1：部署后 E2E 实证回填（触发点=window−32k 输出预留，窗口调 235000 后实测触发 202-205k；spike #2/#3 实测定谳）；§5.9 新增新鲜度守卫修 10-30 读盘竞态（1/105，重读 5×1s，穷尽则 skipped-stale）；单轮巨涨（805k）定性为 harness 轮粒度，插件侧已有预算守卫兜底不另修
