# ccx changelog（演进日志，每次改动追加一行）

| 日期 | 变更 | 为什么 |
|---|---|---|
| 2026-11-25 | 立项：A期 spec v0.1 初稿（号池 registry/state + ccx 启动器 + /modelx + 分层冷却），两期制 A/B 已拍板（先 A 后 B） | 痛点：settings.json 写死单号 + 多窗口互踩；cc-switch 故障转移静默死；用户要求"号用尽同厂商默认自动切，全用尽显示状态"；三探测定谳启动器机制（shell env 不敌 settings env → 必须走 --settings） |
| 2026-11-25 | spec v0.1 → v0.2 评审(builder check)处置：agent 补做 P4–P7 实证（`--settings` 文件路径 ✅ / env **按键合并**定谳 ✅ / `-p` 模式测不了插件→交互冒烟排入 §12-3 门）；**裁定 3 项**=①/modelx 会话内一键 mark（直接执行插件目录脚本，死窗口里没有 PowerShell）②registry 增 `models` 别名节（首日实装 bigmodel 池，schema 天然多厂商）③`ccx list` 加快照漂移提示（cc-switch 按退役处理，共存无害）；**待拍板 1 项**=启动预检 preflight（默认开 + `--no-check`，保守错误分类不误杀：401→blocked/429→r429/额度文案→daily/未知→不标照常启动） | 评审 4 问：#1 忘 mark 时 `ccx -c` 原样选回死号（需用户拍板）；#2 一键标记在哪个面 / #3 别名表 schema 位置与首日范围 / #4 cc-switch 退役与否（我裁定回填） |
| 2026-11-25 | spec v0.2 → v1.0：用户拍板 preflight **默认开**（`--no-check` 可关）→ §6 转正、§1 非目标4 修订（会话内拦截=B期，启动预检=A期）、`ccx check` 并入全量版、判据2 增假 token 号场景 | "在使用的时候号用尽默认自动切换"的 A期落地靠预检闭环；忘 mark 不再选回死号 |
| 2026-11-25 | spec v1.0 用户确认 → 出 A期实施 plan v1（plans/2026-11-25-ccx-a-v1.md：13 任务 TDD，测试零真实网络/零真实 claude/四路径缝，Task 12 人工冒烟门；完成后 commit 推 gitee+内部 GitLab 双远端） | 进入实施阶段 |
| 2026-11-25 | v1.0 执行收口：Task 1-11 全绿(11 测试文件)；T12 人工冒烟门启动(判据1/5 自动面已绿)；T13(import-ccswitch+statusline) 用户拍板砍掉，留 B期 | plan 执行台账 |
| 2026-11-25 | 整分支终审(opus)修复波 4 项：①裸 `ccx` 直接进启动路径（原误打 usage 退 1，spec §7 首行交互被吞）②`Select-AndPreflight -Group` 加 `[AllowNull()]`+菜单 0 号组护栏（全停用组原先 Mandatory 空值→真控制台交互假挂/headless 绑定异常）③`set-default` 写 settings.json 改走 `Write-CcxTextAtomic`（tmp+File.Replace 原子写，与 Save-CcxJson 同构；settings.json=裸 claude 兜底层写坏代价最高）④§6 分类顺序回填为 401→**报文关键词**→429（实码即此序：GLM 欠费=429 带欠费报文，报文优先防欠费误标 r429 死循环） | Critical×1 + Important×3 处置；11 测试文件回归全绿（test_launch 增 ⑥⑦⑧） |
