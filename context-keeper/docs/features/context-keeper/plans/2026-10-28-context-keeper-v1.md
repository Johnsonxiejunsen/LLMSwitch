# context-keeper v1 实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Claude Code 插件：auto/manual 压缩后回注近期原文，使 context 落点稳定 ≈150k。

**Architecture:** 两个钩子。`PreCompact` 写临时侧标文件（记录是否带自定义指令，供 Q3 策略用）；`SessionStart(matcher: compact)` 流式解析会话 JSONL，按 spec §5 规则选窗口、按 §6 预算从新往旧累加、按 §7 渲染，以 `additionalContext` 回注。核心零 npm 依赖，全部失败路径 exit 0 静默（= 没装插件）。

**Tech Stack:** Node.js ≥18（`node:test` 内置测试框架，零第三方依赖），Claude Code 插件（hooks.json + plugin.json）。

**Spec:** `docs/features/context-keeper/specs/context-keeper.md`（v1.0 定稿）——本计划从 spec 论证，两者须同读。

## Global Constraints

- Node ≥18，**零 npm 依赖**（只用 node: 内置模块）
- 两个钩子脚本**任何异常 exit 0 + 空输出**，禁止 exit 2（铁律：不破坏既有行为，兜底=原生）
- stdout 只允许：合法 hook JSON（reinject 成功时）或空（其余一切情况）；诊断信息只进日志文件
- 常量（spec §6 原值）：`TARGET_TOTAL=150000`、`BUDGET_FLOOR=10000`、`CAP_RATIO=0.6`、`MIN_TAIL=2000`；`CK_TARGET_TOTAL` env 可覆盖 TARGET_TOTAL
- 日志：写 `os.tmpdir()/context-keeper/last-run-<session_id>.json`（E2E 取证用），`CK_DEBUG=1` 时也写 stderr
- Git：每任务一 commit，**禁止 push**；仓库尚未 init，Task 1 中 init
- Windows 优先：路径一律 `path.join`/`os.tmpdir()`，不硬编码分隔符

## Review Focus

1. **boundary 之后已有新消息**（hook 运行时用户已开新 turn）——窗口必须严格小于 boundary 行号，新消息绝不回注。测试：Task 3 `post-boundary message excluded`
2. **畸形 JSONL 行 / 超长单行**——单行 parse 失败跳过该行，不炸整个流。测试：Task 3 `malformed line skipped`
3. **CJK 密集内容 token 估算失真**——自校准按字符占比分摊精确总量，比例失真被吸收。测试：Task 4 全 CJK fixture 落预算内
4. **sidecar 陈旧残留**（上次会话崩溃未删）——SessionStart 读后必删；manual 且无 sidecar → 不回注（保守）。测试：Task 4/5
5. **stdin 非法 / transcript 缺失 / 空会话**——兜底链入口，exit 0 空输出。测试：Task 5 `bad stdin exits 0 empty`

---

### Task 1: 仓库骨架 + lib.js（共享常量与工具）

**Files:**
- Create: `.claude-plugin/plugin.json`, `hooks/hooks.json`, `hooks/lib.js`
- Test: `test/lib.test.js`, `test/helpers/make-fixture.js`

**Interfaces:**
- Produces（后续任务依赖，签名固定）:
  - `TARGET_TOTAL, BUDGET_FLOOR, CAP_RATIO, MIN_TAIL: number`
  - `sidecarPath(sessionId: string) -> string`（`os.tmpdir()/context-keeper/sidecar-<sessionId>.json`）
  - `entryChars(entry) -> number`：`JSON.stringify(entry.message?.content ?? '').length`
  - `pickLastBoundary(entries) -> {index, meta} | null`：meta = `entry.compactMetadata`
  - `makeFixture(spec) -> string`（helpers，仅测试用）：按对象生成 JSONL 文本

- [ ] **Step 1: `git init` + 写 plugin.json / hooks.json**

plugin.json：`{"name": "context-keeper", "version": "0.1.0", "description": "Post-compaction context re-injection to ~150k"}`。
hooks.json（`${CLAUDE_PLUGIN_ROOT}` 原样保留，由 harness 展开）：

```json
{
  "hooks": {
    "PreCompact": [
      {"hooks": [{"type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/precompact.js\""}]}
    ],
    "SessionStart": [
      {"matcher": "compact", "hooks": [{"type": "command", "command": "node \"${CLAUDE_PLUGIN_ROOT}/hooks/reinject.js\""}]}
    ]
  }
}
```

- [ ] **Step 2: 写失败测试 `test/lib.test.js`**

用 `node:test`+`assert`：(a) `sidecarPath('abc')` 结果含 `context-keeper` 与 `sidecar-abc.json` 且经 `path.join`；(b) `entryChars` 对 `{message:{content:'你好'}}` 返回 4（JSON 引号计入）；(c) `pickLastBoundary` 对 3 行文本（含 2 个 boundary）返回最后那个的 index 与 meta.preTokens；(d) makeFixture 生成的每行 `JSON.parse` 通过。

- [ ] **Step 3: 运行确认 FAIL**：`node --test test/lib.test.js` → FAIL（模块不存在）
- [ ] **Step 4: 实现 lib.js**（上述 4 个导出；makeFixture 签名：`{lines: Array<{type,subtype,message,uuid,isSidechain?,isMeta?,isCompactSummary?,compactMetadata?}>}`，每行补 `uuid`（缺省自增）、`timestamp`、`sessionId:'s1'`）
- [ ] **Step 5: 运行确认 PASS**：`node --test test/lib.test.js`
- [ ] **Step 6: Commit** `git add -A && git commit -m "feat: scaffold plugin + shared lib"`

### Task 2: precompact.js（侧标写入）

**Files:**
- Create: `hooks/precompact.js`
- Test: `test/precompact.test.js`

**Interfaces:**
- Consumes: `sidecarPath`（Task 1）
- Produces: 侧标文件 `{"hasInstructions": boolean, "ts": number}`；进程行为：stdin 任意 → 写文件 → **总是 exit 0**，无 stdout

- [ ] **Step 1: 写失败测试**：`spawnSync('node', ['hooks/precompact.js'], {input: JSON.stringify({session_id:'s9', trigger:'manual', custom_instructions:'focus on API'})})` → 退出码 0、stdout 空、`JSON.parse(readFileSync(sidecarPath('s9')))` 得 `{hasInstructions:true}`；用例二 `custom_instructions:null` → `hasInstructions:false`；用例三 stdin=`'not json'` → 仍退出 0 且**不写文件**。测试尾部 `rmSync(sidecarPath(...), {force:true})` 清理。
- [ ] **Step 2: 运行确认 FAIL**
- [ ] **Step 3: 实现**：读 stdin（4096 截断足够）→ try parse → `hasInstructions = typeof custom_instructions==='string' && custom_instructions.trim().length>0` → `mkdirSync(dirname, {recursive:true})` + `writeFileSync` → 全体包 try/catch，任何分支 `process.exit(0)`
- [ ] **Step 4: 运行确认 PASS**
- [ ] **Step 5: Commit** `feat: precompact sidecar hook`

### Task 3: reinject.js 解析层（流式窗口提取）

**Files:**
- Modify: `hooks/reinject.js`（新建文件，本任务先写解析层）
- Test: `test/reinject-parse.test.js`

**Interfaces:**
- Consumes: `makeFixture`、`pickLastBoundary`（Task 1）
- Produces: `extractWindow(stream: Readable) -> Promise<{boundary: {index, meta} | null, window: Array<entry>}>`——规则（spec §5）：取**最后一条** boundary 之前、**上一条** boundary 之后的主链（`isSidechain!==true`）行；剔除 `preservedMessages.uuids`、`isCompactSummary===true`、`isMeta===true`；畸形行跳过；boundary 之后的内容（含新消息）不进 window

- [ ] **Step 1: 写失败测试**（fixture 经 `PassThrough` 喂入）：构造 spec：`[u1, a1(sidechain:true), u2(isMeta:true), sum1(isCompactSummary:true), B1, u3, a2(tool_use), u4(tool_result, preserved uuid), u5, B2, u6(post-boundary), malformed-line]` → 断言 `boundary.meta.preTokens` 取 B2；window 恰为 `[u3, a2, u5]`（u6/malformed/isMeta/sidechain/sum1/preserved-u4 全部不在）
- [ ] **Step 2: 运行确认 FAIL**
- [ ] **Step 3: 实现**：`readline.createInterface({input: stream})` 逐行 try/parse 收集 `entries`（带行号），结束后按上述规则切片过滤
- [ ] **Step 4: 运行确认 PASS**
- [ ] **Step 5: Commit** `feat: transcript window extraction`

### Task 4: reinject.js 决策层（trigger 策略 + 预算累加）

**Files:**
- Modify: `hooks/reinject.js`
- Test: `test/reinject-select.test.js`

**Interfaces:**
- Consumes: Task 3 的 `extractWindow`；Task 1 常量
- Produces: `selectMessages(window, meta, sidecar) -> {picked: Array<{entry, est, truncated}>, injectedEst: number} | null`（null = 不回注）——策略：`meta.trigger==='manual' && (!sidecar || sidecar.hasInstructions)` → null（spec §5.7，sidecar 缺失保守不回注）；`budget = TARGET_TOTAL − meta.postTokens`，`budget < BUDGET_FLOOR` → null；est 按 `chars_i/Σchars × (preTokens−postTokens)`；单条 `est > budget×CAP_RATIO` → 标记 truncated（渲染层负责截断）；从新往旧累加，`est > remaining` 时：`remaining ≥ MIN_TAIL` 则收入并 truncated 后停止，否则直接停止

- [ ] **Step 1: 写失败测试**（数值代入 spec §6 预演）：meta 用真实值 `{trigger:'manual', preTokens:478286, postTokens:19582}`（budget=130418）+ sidecar `{hasInstructions:false}`；6 条消息字符均等 → 每条 est=76451（=458704/6），新→旧收入第 1 条（76451≤130418）、第 2 条 remaining=53967≥MIN_TAIL → truncated 收入后停 → `picked.length===2` 且 `injectedEst===130418` 精确值；用例二 trigger=manual+sidecar `{hasInstructions:true}` → null；用例三 manual+sidecar=null → null；用例四 trigger=auto+sidecar=null → 正常；用例五 `postTokens:145000`（budget=5000<FLOOR）→ null；用例六全 CJK 等分字符 → 同用例一断言（Review Focus 3）；用例七单条字符占 90% → 该条 `truncated===true` 但被收入且 est 不超 budget
- [ ] **Step 2: 运行确认 FAIL**
- [ ] **Step 3: 实现**（纯函数，无 IO）
- [ ] **Step 4: 运行确认 PASS**
- [ ] **Step 5: Commit** `feat: budget selection + trigger policy`

### Task 5: reinject.js 渲染层 + main（stdin/stdout 合同与兜底）

**Files:**
- Modify: `hooks/reinject.js`
- Test: `test/reinject-main.test.js`

**Interfaces:**
- Consumes: Task 3/4 全部；Task 1 `sidecarPath`
- Produces: `renderPicked(picked) -> string`（banner + 前缀渲染）；可执行入口 `main()`。渲染规则（spec §7）：`[user]`/`[assistant]` 文本全文；`[tool_use 名]` input JSON 前 300 字符；`[tool_result]` 全文；thinking 跳过；truncated 条目尾部接 `〔截断，原文共 X tokens〕`，内容截到其 est 对应字符比例处。main 流程：读 stdin → parse 取 `session_id, transcript_path` → 读 sidecar（读后即删 `rmSync force`）→ `createReadStream(transcript_path)` → extractWindow → selectMessages → render → stdout `{"hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext": <text>}}` → 写日志文件 → exit 0。任何一步异常：exit 0 空 stdout

- [ ] **Step 1: 写失败测试**（全部走 `spawnSync('node', ['hooks/reinject.js'], {input})`，fixture 先写成临时文件）：(a) auto+完整 fixture → stdout 合法 JSON 且 `additionalContext` 含 `[user]`、`[tool_use Monitor]`、不含 thinking 文本、含 banner；(b) tool_use input 500 字符 → 渲染后 ≤300+前缀；(c) truncated 条目含 `〔截断，原文共`；(d) stdin=`'{bad'` → 退出 0、stdout 空；(e) `transcript_path` 指向不存在文件 → 退出 0、stdout 空；(f) manual+无 sidecar → stdout 空（Review Focus 4/5）
- [ ] **Step 2: 运行确认 FAIL**
- [ ] **Step 3: 实现**（renderPicked 纯函数 + main 带 `fs.rmSync(sidecarPath(sessionId), {force:true})`）
- [ ] **Step 4: 运行确认 PASS**：`node --test test/` 全绿
- [ ] **Step 5: Commit** `feat: rendering + main contract`

### Task 6: 真实 JSONL 冒烟

**Files:**
- Test: `test/smoke-real.test.js`

**Interfaces:**
- Consumes: Task 5 完整 main

- [ ] **Step 1: 写冒烟测试**：`const SRC = process.env.CK_SMOKE_FILE`；falsy → `t.skip()`。否则 `spawnSync` 喂 `{"session_id":"smoke","transcript_path":SRC}` + 预置 auto sidecar → 断言：退出 0；stdout JSON 合法；`additionalContext` 字符数换算 est（按 fixture 同一 chars 比例法）落在 130418±10%；`durationMs < 5000`（真实文件 7562e3c6，12k+ 行）
- [ ] **Step 2: 运行**：`CK_SMOKE_FILE=C:/Users/User/.claude/projects/C--Users-User/7562e3c6-38c9-40b5-8f64-2909b21d1c5e.jsonl node --test test/smoke-real.test.js` → PASS
- [ ] **Step 3: Commit** `test: real-transcript smoke`

### Task 7: README + 安装/验收清单（含 4 个运行时 spike 的判定）

**Files:**
- Create: `README.md`

- [ ] **Step 1: 写 README**，必含：① 前置 settings 两配置（`autoCompactEnabled: true`、`autoCompactWindow: 200000`，缺一不可，理由引 spec §2）；② 安装：`claude plugin marketplace add D:\program\context-keeper` + 启用；③ 验收清单（下面 Step 2）；④ spike 判定表：每项写「操作 → 期望 → 若证伪执行 Plan B」（#0 auto 触发无 hook 日志 → 停用，等 UserPromptSubmit 方案；#1 /context 落点 <145k 且日志显示截断 → 降 TARGET_TOTAL；#2 二轮 compact 的 preTokens 未计入上轮回注 → 停用上报；#3/#4 日志观察项）
- [ ] **Step 2: `claude plugin validate D:\program\context-keeper`** → 通过（不通过则修 plugin.json/hooks.json）
- [ ] **Step 3: 手动 E2E（需用户在场）**：临时会话读大文件灌到 >200k → auto-compact 触发 → 查 `last-run-*.json` 存在（spike #0 过）→ `/context` 读数落 145k–160k → 记录四个 spike 实测结果回填 spec §11
- [ ] **Step 4: Commit** `docs: readme + acceptance checklist`

---

## Self-Review 记录

- **Spec 覆盖**：§2→Task 7 README①；§3 机制→Task 5 main；§4 数据源→Task 3；§5 规则 1-8→Task 3（1/2/3/4/5/6）+Task 4（7/8）；§6→Task 4；§7→Task 5；§8 兜底→Task 5(d)(e)+全局约束；§10 判据→Task 4 数值代入/Task 6 冒烟/Task 7 E2E+回归；§11 spike→Task 7③④。无缺口。
- **Step 扫描**：每步一个动作；代码步只给签名/数值/算法骨架，无成文实现体。
- **类型一致**：`picked`/`sidecar`/`boundary`/常量名在 Task 1/3/4/5 间逐一核对一致。
- **Review Focus**：5 项均有归属测试（Task 3×2、Task 4×1、Task 4/5×1、Task 5×2）。
- **比例**：计划以签名+断言为主，仅 hooks.json/侧标 schema 给了成文块（spec 未钉死的合同）。长度≈spec 的 2 倍，可接受。
