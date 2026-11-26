# ccx 版本选择（§13 C⊕B）Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:executing-plans（inline）+ superpowers:test-driven-development。步骤用 `- [ ]` 跟踪。

**Goal:** 交互启动时出"组→版本"二级菜单（C 手配真相源 ⊕ B `/v1/models` 在线发现），选中版本覆盖临时 settings 的模型键；别名/强指/`-p` 走 `default_version` 快路径。

**Architecture:** 纯函数层（归一化/合并/解析）+ 一次增强 fetch（失败静默空）+ `Merge-CcxEnv -Version` 覆盖 + `Invoke-CcxLaunch` 接线。无新文件（全部进 ccx-core.psm1），新测试文件 test_version_menu.ps1。

**Spec:** `docs/features/ccx/specs/ccx.md` §13（本 plan 的依据，验收数值在 §13 尾部）

## Global Constraints

- 兜底铁律：无 versions 且拉取空 → 无二级菜单 = A期行为；无 default_version → 快路径不覆盖 env；B 失败静默只显 C
- B 结果永不写回 registry；版本选择不进 state.json（仅当前窗口）
- 测试零真实网络（fetch 用 -Fetcher 缝 + 127.0.0.1:1 秒拒）、零真实 claude（fake_claude）
- 中文 .ps1 UTF-8 BOM；JSON 无 BOM；PS 5.1 逗号包数组
- `ccx add` 交互提示版本列表但**保留自由输入**（-Answers 注入路径零变化）

## Review Focus（§13 隐含但下列测试未全覆盖时的候补）

1. `ccx -c` 多组时既有组菜单又加版本菜单 → 回车链可用（两条菜单回车均落默认）
2. 在线返回非 JSON/畸形 data → 不得炸启动（空数组降级）
3. versions 含对象形式 `@{id=..}` → 与字符串混排可用
4. 选中版本含正则元字符（如 `[1M]`）→ 去尾变体用字符串操作不用正则替换语义歧义
5. 唯一在线选项、零本地配置 → 静默直用该选项（无菜单无默认标注）

---

### Task 0: 预检硬化（探针剥 `[..]` 标签 + 模型不存在明错不启动）

**Files:** Modify `ccx/bin/ccx-core.psm1`；Test `ccx/test/test_preflight.ps1`（追加）

**Interfaces:**
- `Get-CcxProbeModel [hashtable]$Account → [string]`（env.ANTHROPIC_MODEL 剥尾 `[..]`，空 → `claude-3-5-haiku-20241022`；Invoke-CcxProbe 改用之）
- `Invoke-CcxPreflight` 分类增 `Fatal=$true`（模型不存在报文：不标；策略归调用方）
- `Select-AndPreflight` 两路径（轮转/强指）遇 Fatal → throw 明错不启动；`Invoke-CcxCheck` 渲染「模型不存在(配置错)」行不中断

- [x] **Step 1** 失败测试：剥标签三例 / 400[1211]→Fatal 不落盘 / 英文报文同判 / 无关键词 400 仍未知（兜底回归）/ 轮转与强指 throw / check 面板两行不中断
- [x] **Step 2** RED → 实现 → GREEN
- [x] **Step 3** spec §6 回填 + changelog；commit `fix(ccx): 预检硬化(探针剥[..]标签+模型不存在明错不启动)`

### Task 1: 纯函数层（归一化 + 选项合并 + 输入解析）

**Files:** Modify `ccx/bin/ccx-core.psm1`；Test `ccx/test/test_version_menu.ps1`（新建）

**Interfaces:**
- `ConvertTo-CcxVersionBase [string]$Id → [string]`（小写+去尾 `[..]`+去非字母数字）
- `Get-CcxVersionOptions $ModelNode, [string[]]$Fetched → @( @{Id; IsDefault; Source='local'|'remote'} )`（本地配置序在前，默认版标 IsDefault；在线按 include 过滤+归一化去重追加 Source='remote'；$ModelNode 可 $null）
- `Resolve-CcxVersionInput [string]$Input, $Options → [string]`（空→默认；数字→编号映射；串→须在 options；否则 throw '无效版本选择'）

- [x] **Step 1** 写失败测试：§13 验收场景①（4 项菜单与去重）、include 过滤、无 ModelNode、空输入→默认、数字/无效输入
- [x] **Step 2** 跑 `powershell -File test_version_menu.ps1` 见 RED（函数不存在）
- [x] **Step 3** 实现三函数（插入 Format-CcxUntil 之前）
- [x] **Step 4** GREEN；commit `feat(ccx): 版本选择纯函数层(归一化/合并/输入解析)`

### Task 2: 在线发现 fetch（含缝与静默降级）

**Files:** Modify `ccx/bin/ccx-core.psm1`

**Interfaces:** `Get-CcxRemoteVersions [hashtable]$Account, [int]$TimeoutSec=4, [scriptblock]$Fetcher → [string[]]`（GET base_url+/v1/models Bearer；任何异常/畸形 → @()；-Fetcher 缝默认真 IWR）

- [x] **Step 1** 失败测试：缝返回 OpenAI 风样例 JSON → 解析 data[].id；缝抛异常 → @()；真请求 127.0.0.1:1 → @()（秒拒确定性）
- [x] **Step 2** RED → 实现（Invoke-WebRequest -TimeoutSec，JSON 解析 try/catch 全吞为空）→ GREEN
- [x] **Step 3** commit `feat(ccx): /v1/models 在线发现(4s超时·失败静默空)`

### Task 3: Merge-CcxEnv 版本覆盖

**Files:** Modify `ccx/bin/ccx-core.psm1`；Test 同文件追加

**Interfaces:** `Merge-CcxEnv -Account <hashtable> [-Version <string>]`——有 Version 时：merged 中 `ANTHROPIC_*` 且含 `MODEL` 的键，`*_NAME` ← 基名、其余 ← 版本串；并确保 `ANTHROPIC_MODEL` 写入；其余键不动。无 -Version 行为与现状逐字节一致。

- [x] **Step 1** 失败测试：全家族覆盖（[1M] 主键/裸名 _NAME）、BASE_URL/TOKEN/EFFORT_LEVEL 不动、最小 env 号、无 -Version 回归不变
- [x] **Step 2** RED → 实现（基名=ConvertTo-CcxVersionBase 之外的字符串版去尾 `[..]`，用 `'[' + idx` 截取）→ GREEN
- [x] **Step 3** commit `feat(ccx): Merge-CcxEnv -Version 模型键覆盖(§13 规则)`

### Task 4: 启动接线（菜单/快路径/唯一选项跳过）

**Files:** Modify `ccx/bin/ccx-core.psm1`（Invoke-CcxLaunch + Get-CcxModelNode 新函数）；Test 同文件追加子进程用例

**Interfaces:** `Get-CcxModelNode $Registry, [string]$Vendor → hashtable|$null`；launch 在组解析后：交互（无 ModelSpec 无 -p）→ options 非空出菜单（唯一选项静默直用）；否则 default_version 直用；选中的 Version 传 `Select-AndPreflight` 之后的 `Merge-CcxEnv`。

- [x] **Step 1** 失败测试：单 vendor+versions 多项，子进程 -NonInteractive 裸 ccx → 输出含 `选择版本`、含默认标注、exit 1；唯一选项 → fake log 存在+快照 `ANTHROPIC_MODEL`=该版本；`ccx glm` 别名 → 快照=default_version；无 versions 组 → 无版本菜单照启（回归⑥口径）
- [x] **Step 2** RED → 实现 → GREEN；**全量回归** `test/run-tests.ps1`（12 文件）
- [x] **Step 3** commit `feat(ccx): 启动路径组→版本二级菜单接线(C⊕B)`

### Task 5: ccx add 版本提示 + usage 更新

**Files:** Modify `ccx/bin/ccx.ps1`（usage 行）、`ccx/bin/ccx-core.psm1`（Invoke-CcxAdd Read-Host 分支）；Test 追加

- [x] **Step 1** 测试：-Answers 路径产物与现状一致（回归）；Resolve-CcxVersionInput 数字映射已被 Task 1 覆盖，add 仅提示不强制
- [x] **Step 2** 实现：模型提示行前打印该 vendor 组 versions 编号列表（存在时），输入接受编号或全名（编号经 Resolve 解析）
- [x] **Step 3** usage 首行改 `交互选模型+版本并启动`；GREEN；commit `feat(ccx): add 向导版本提示+usage 更新`

### Task 6: 收口

- [x] **Step 1** 全量 `test/run-tests.ps1` 绿；卫生门照跑（test_hygiene 在套件内）
- [x] **Step 2** spec §13 状态无需改（反映当前真相）；changelog 已在立项行；plan workspace 无（inline 执行）
- [x] **Step 3** 向用户交付：全命令清单（含本增量）
