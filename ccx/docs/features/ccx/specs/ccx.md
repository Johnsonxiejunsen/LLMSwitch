# ccx — Claude Code 号池启动器（A期：开窗/续会话切换）

> 状态: **v1.0 待用户确认（七探测定谳；评审 3 裁定 + preflight 拍板默认开，均已回填）** · 2026-11-25 · 域: ccx
> 变更历史: 见 `specs/archive/ccx-changelog.md`（立项起逐次追加）

---

## 0. 触发场景 / 背景（为什么做）

**用户原话**：进入窗口可切换大模型；同一模型（如 GLM）有多个号，一个用到受限就切**同模型的另一个号**，没有就不切（宁可不切也不换模型）；本地多窗口并行；**"在使用的时候当一个号用尽同厂商默认自动切换到有 token 的账号，都没有则显示已经切换账号的状态"**。

**现状**：
- `~/.claude/settings.json` env 写死单号（智谱 `glm-5.3[1M]`），多窗口共享全局文件，手改即互相踩
- cc-switch 的代理接管/故障转移 **2026-10-31 起静默失效**，已回落直连模式一个月无人察觉（反面教材：常驻件静默死）
- 两期制已拍板：**A期**（纯插件+启动器，开窗/续会话时切换）先行，**B期**（会话内无感热切换）后做

---

## 1. 目标 / 非目标 / 反目标

**目标**
1. 开窗时选模型 → **默认自动选同厂商号池中第一个可用号**（也可手动指定号）
2. 受限分层冷却：429 限流 → 60s 自动恢复；当日额度用尽 → 该号重置点自动恢复；欠费/封号/key 失效 → 仅手动解锁
3. 号用尽后 `ccx -c` 续会话 → 自动落到下一个有额度的号（= 用户要求的"默认自动切换"在 A期的落地形态）
4. **全池不可用 → 明确状态面板**（每号状态 + 受限类型 + 最早恢复时间），绝不静默
5. 多窗口各自独立选号互不影响；裸 `claude` 行为**分毫不动**（兜底）
6. 会话内 `/modelx`：池状态 + 当前窗口用哪个号 + 受限后下一步指引

**非目标（A期明确不做）**
- 会话运行中热切换（当前窗口不断线换号）→ **B期**（本地代理 / apiKeyHelper 预研后定）
- 跨厂商切换：号池 = **同厂商多 key**（base_url 相同）；不同厂商之间是"选模型"，不属自动切换
- 常驻进程 / 守护 → B期
- 受限自动检测（**会话内**拦截 API 错误）→ B期；A期 = **启动时预检 preflight**（已拍板默认开，见 §6）+ 会话内一键标记

**反目标（做到 = 失败）**
- 任一路径静默失败：选不出号 / 池文件损坏 → 必须明示错误 + 提示裸 `claude` 仍可用
- settings.json 被后台静默改写（唯一写入口 = `ccx set-default` 显式命令）
- token / 凭据出现在 claude-tools 仓内任何文件（registry 在 `~/.claude/model-accounts/`，永不入仓）

---

## 2. 硬边界实证（2026-11-25 本机 P1–P7 七探测）

| # | 实验 | 结果 | 结论 |
|---|---|---|---|
| P1 | shell 注入 `ANTHROPIC_BASE_URL=http://127.0.0.1:9` 后 `claude -p` | 正常回答 "ok"（请求打到了 bigmodel） | **settings.json 的 env 块压过进程 env** → 启动器不能靠 `$env:` 注入模型变量 |
| P2 | `claude --settings '{"env":{"ANTHROPIC_BASE_URL":"http://127.0.0.1:9"}}' -p` | `Connection refused (ECONNREFUSED)` | **`--settings` env 压过 settings.json env** ✅ 启动器机制成立 |
| P3 | `claude --settings '{"env":{"ANTHROPIC_AUTH_TOKEN":"bogus"}}' -p` | `401 令牌已过期或验证不正确` | **`--settings` env 同样压过 AUTH_TOKEN** ✅ 换号核心成立 |
| P4 | `claude --settings <临时文件路径>`（文件内假 token） | 快速 `401` | **`--settings` 接受文件路径** ✅ §8 临时文件路线成立（P2/P3 只证了内联 JSON） |
| P5 | `--settings` 临时文件只含 `{"env":{"CCX_PROBE_MARKER":"1"}}`（无 token/base_url） | 请求照常打到大模型并正常回答 | **env 为按键合并，非整块替换** → settings.json 未覆盖键全部存活 |
| P6/P7 | `-p` 模式下带/不带 `--settings` 验证插件加载 | 两种都不可见（`-p` 不暴露插件，模式伪影） | 插件/hooks 在 `--settings` 窗口下是否存活 → **交互式冒烟**排入 plan（§12-3 门）；env 已证合并语义，兜底=临时文件补 `enabledPlugins`，极便宜 |

P1 附带结论：settings.json **未定义**的键（如将设的 `CCX_ACCOUNT_ID`）走进程 env 畅通 → SessionStart hook / statusline 取当前号走此路。
P5 定谳后仍维持"写完整合并 env 块"（§8）：临时文件自洽、对未来语义变化免疫，成本为零。
（P4–P7 为 2026-11-25 builder 评审 agent 补做实证；探针文件已清理，未动 settings.json，token 未出现在任何输出）

---

## 3. 架构全景（A期，无常驻件）

```
 开新窗口 / ccx -c 续会话
        │
        ▼
 ┌─ bin/ccx.ps1 启动器 ────────────────────────────────┐
 │ 1. 读 registry.json(号池) + state.json(受限态)      │
 │ 2. 选号: 该模型组内 priority 序第一个可用号(惰性清冷却)│
 │    全池不可用 → 状态面板(每号+恢复时间) → 退出,不静默 │
 │ 3. 合并 env(settings.json.env ⊕ 账号.env ⊕ CCX_*)   │
 │    写 %TEMP%\ccx-settings-<pid>.json                │
 │ 4. & claude --settings <临时文件> <透传参数>          │
 │ 5. finally 删临时文件                                 │
 └─────────────────────────────────────────────────────┘
        │                                    ▲
        ▼                                    │ 报当前号/池况
 ┌─ Claude Code 会话 ────────────┐   ┌─ 插件 ccx ──────────────┐
 │ 请求 → 账号(启动时定格)        │   │ /modelx 命令(池面板)    │
 │ 会话内不热切(A期边界,→B期)     │◄──│ SessionStart hook       │
 └───────────────────────────────┘   │ statusline 片段(可选)   │
        │                            └─────────────────────────┘
        ▼ 裸 claude(不经 ccx)
 ┌─ ~/.claude/settings.json 默认号快照(行为=今天, 兜底) ─┐
 │ 唯一写入口 = ccx set-default(值来自 registry=事实源)  │
 └──────────────────────────────────────────────────────┘
```

**组件**：
| 组件 | 位置 | 职责 |
|---|---|---|
| registry.json | `~/.claude/model-accounts/` | 号池**事实源**（含 token，永不入仓） |
| state.json | 同上 | 运行态：受限标记 / 冷却 / 最后选用时间 |
| bin/ccx.ps1 | 仓内 `ccx/bin/` | 启动器（选号 → 临时 settings → 透传启动） |
| 插件 ccx | 仓内（marketplace 分发） | `/modelx` + SessionStart hook + statusline 片段 |
| settings.json | `~/.claude/` | 默认号**派生快照**（裸 claude 兜底） |

---

## 4. 数据模型

**registry.json**（schema 1）：
```json
{
  "schema": 1,
  "models": {
    "glm": { "vendor": "bigmodel", "label": "智谱 GLM", "versions": ["glm5.4[1M]", "glm-5.3[1M]"], "default_version": "glm5.4[1M]", "versions_include": "glm-5" }
  },
  "accounts": [
    {
      "id": "glm-1",
      "label": "智谱主力",
      "vendor": "bigmodel",
      "base_url": "https://open.bigmodel.cn/api/anthropic",
      "auth_token": "<真实token,只存在本文件>",
      "env": {
        "ANTHROPIC_MODEL": "glm-5.3[1M]",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL": "glm-5.3[1M]",
        "ANTHROPIC_DEFAULT_SONNET_MODEL": "glm-5.3[1M]",
        "ANTHROPIC_DEFAULT_OPUS_MODEL": "glm-5.3[1M]",
        "ANTHROPIC_DEFAULT_FABLE_MODEL": "glm-5.3[1M]",
        "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME": "glm-5.3",
        "ANTHROPIC_DEFAULT_OPUS_MODEL_NAME": "glm-5.3",
        "ANTHROPIC_DEFAULT_HAIKU_MODEL_NAME": "glm-5.3"
      },
      "priority": 1,
      "reset_time": "00:00",
      "enabled": true
    }
  ]
}
```
- `vendor` 相同 = 同厂商号池（自动切换只发生在池内）；`env` 块同厂商通常一致，仍**按号存**（为异构留口）
- `reset_time`：当日额度恢复点（本地时刻，默认 `00:00`=次日零点），按号可配
- `models`：模型别名 → 厂商组解析表（`ccx glm` / 交互选择器用；评审#3 裁定）；缺省时按 vendor 分组兜底。**首日实装与验证 = bigmodel 池**，schema 天然支持多厂商（后续 `ccx add` 即扩，零改码）
- `versions`/`default_version`/`versions_include`（均可选，详 §13）：C 真相源——在线列表**实测不含 `[1M]` 变体**，变体只能手配；`default_version` 须为 `versions` 之一；`versions_include` 正则过滤在线发现（缺省 `.*`）

**state.json**（schema 1）：
```json
{
  "schema": 1,
  "accounts": {
    "glm-1": { "status": "daily", "until": "2026-11-26T00:00:00+08:00", "updated_at": "2026-11-25T21:00:00+08:00", "note": "手动标记" },
    "glm-2": { "status": "ok", "last_used_at": "2026-11-25T21:05:00+08:00" }
  }
}
```

---

## 5. 受限分层与状态机

```
            mark r429              60s(可配)到期
   ┌──────┐ ────────► ┌──────┐ ─────────────► ┌──────┐
   │  ok  │           │ r429 │   (惰性判定:    │  ok  │
   │      │ ◄─────────┤      │    读取时清)    │      │
   └──────┘           └──────┘                └──────┘
     │  mark daily  ──► daily ──(reset_time 到)──► ok
     │  mark blocked ─► blocked ──(仅 ccx unlock)──► ok
```

| 状态 | 含义 | 进入 | 恢复 |
|---|---|---|---|
| `ok` | 可用 | 默认 / 解锁 / 冷却到期（读时惰性判定并回写） | — |
| `r429` | 限流 | `ccx mark <id> r429` | 60s 后自动（可配） |
| `daily` | 当日额度用尽 | `ccx mark <id> daily` | 该号 `reset_time`（默认次日 00:00 本地） |
| `blocked` | 欠费 / 封号 / key 失效 | `ccx mark <id> blocked` | **仅** `ccx unlock <id>`，永不自动 |

---

## 6. 选号算法（默认路径，即"自动切换"核心）

1. 取该模型组（= vendor）全部 `enabled` 号
2. **惰性清冷却**：`now ≥ until` → 视为 ok（并回写 state.json）
3. 依 `priority` 升序取第一个 ok 号 → 选中（priority 并列取 `last_used_at` 最旧，轻轮转）
4. **无 ok 号** → 全池面板（每号状态+恢复时间+「全池不可用，最早恢复 glm-1 明日00:00」），退出码非 0，绝不静默；可 `ccx <model>@<id>` 显式强指（选 non-ok 号给警示但尊重选择）

**数值代入预演**（判据已代入算过）：
- 池 `[glm-1 daily(until=明日00:00), glm-2 ok, glm-3 ok(priority=3)]` → `ccx` → **选中 glm-2** ✓
- 再 `mark glm-2 daily` → `ccx -c` → **选中 glm-3** ✓
- 全部 mark → `ccx` → **面板「3 号全部不可用，最早恢复 glm-1 明日 00:00」** ✓

**启动预检 preflight【已拍板：默认开，`--no-check` 可关】**（评审问题#1：号死了但用户忘 `mark` → `ccx -c` 会**原样选回刚死的号**，新窗口再死一遍，"自动切换"体感失灵）
- 机制：选号后、启动前，对该号发 1 次最小请求（max_tokens≈1，用该号 env 的模型名**剥去尾部 `[..]` 标签后的基名**——与 Claude Code 客户端同构：CC 发请求前剥 `[1M]` 类标签，裸发带 `[1M]` 串实测必 400 [1211]，探针不同构会把好号误报死）实测可用性
- 失败分类（**保守，不误杀**）：`401` → 自动 mark blocked；**报文含 余额/欠费/insufficient/额度/exhaust → 自动 mark daily（先于 429 判定**：GLM 欠费/额度尽的实测形态=429+欠费报文，若按状态码先判会把欠费号误标 r429、60s 后反复死探）；**报文含 模型不存在/model not found 类 → Fatal：明错终止、不标记不启动不接力（含强指路径）**——模型名配置错非号的状态，标记无意义，启动必死即吞业务失败；`ccx check` 面板渲染「模型不存在(配置错)」行不中断遍历；**`429` → 自动 mark r429；未知错误 → 不标记**，警告后照常用该号启动（可能是本机网络问题，不能把号全杀）
- 标记后自动取下一号继续预检（上限=池大小）；全池预检失败 → 全池面板
- 代价：每次开窗/续会话 **+0.5~2s**、1 次最小请求（token 成本≈0）；`--no-check` 可关
- 多窗口并发下预检可能吃 429（另一窗口打满并发）→ 轻轮转到下一号，60s 自愈，无害
- 拍板"开"已同步：§1 非目标第 4 条已修订；`ccx check` 可选任务并入本机制（= 对全池逐号预检的手动全量版）

---

## 7. 交互总表

| 命令 | 行为 |
|---|---|
| `ccx` | 交互选模型（多组时）→ **交互选版本**（§13：组配了 versions 或在线有发现；唯一选项静默直用；回车=默认版）→ **自动选号** → 启动 claude（参数全透传） |
| `ccx -c` / `ccx -r` | 续会话，重新走自动选号（多组时同样先选组；版本菜单同 §13，回车=默认） |
| `ccx <model>` | 按模型别名直启（如 `ccx glm` → bigmodel 组；版本=`default_version` 直用不问，组未配则账号 env 原样） |
| `ccx <model>@<id>` | 手动指定号（强指） |
| `ccx list` | 全终端池状态面板 + **快照漂移提示**（settings.json 快照 ≠ registry 默认号时显示一行，防 cc-switch 手改漂移；评审#4 裁定：cc-switch 按退役处理，共存无害——ccx 路径不依赖快照） |
| `ccx mark <id> <r429\|daily\|blocked>` | 标记受限（分层入 §5 状态机） |
| `ccx unlock <id>` | 解锁 blocked |
| `ccx add` / `ccx rm <id>` | 号池维护（向导式，token 只写 registry） |
| `ccx set-default <id>` | registry + settings.json 快照同步（**唯一**写 settings.json 的入口） |
| `ccx import-ccswitch`（可选任务） | 一次性从 `~/.cc-switch/cc-switch.db` 导入存量号 |
| `ccx check` | 全池逐号预检（= §6 preflight 的手动全量版），面板显示每号实测结果 |
| `/modelx`（会话内） | 池面板 + 当前窗口号 + **会话内一键标记**：直接执行插件目录 `ccx.ps1 mark <id> <type>`（评审#2 裁定——死窗口里没有 PowerShell，指引式两步太脆；CLI `ccx mark` 保留为兜底），标记完提示 `ccx -c` 续跑即自动换号 |

---

## 8. 启动器机制细节

- **临时 settings**：`%TEMP%\ccx-settings-<pid>.json`，内容 `{"env": <settings.json.env ⊕ 账号.env ⊕ CCX_ACCOUNT_ID/CCX_ACCOUNT_LABEL>}` → `claude --settings <文件路径> <透传参数>` → finally 删除；每次启动顺手清理 >1h 残留
- **写完整 env 块而非仅差异键**：合并语义已由 P5 定谳为**按键合并**，但维持写完整块——临时文件自洽、对未来语义变化免疫，`CLAUDE_CODE_EFFORT_LEVEL` / `ENABLE_TOOL_SEARCH` 等绝不丢（铁律：不破坏既有行为）；`--settings` 文件路径可用性已由 P4 实证
- **CCX_ACCOUNT_ID / CCX_ACCOUNT_LABEL 走进程 env**（settings.json 未定义这些键，P1 已证此路畅通）→ SessionStart hook 与 statusline 由此读当前号
- **PowerShell 5.1 兼容**：无 `&&`/三元；JSON 一律走临时文件，不做内联传参（引号地狱）

---

## 9. 插件结构

```
ccx/
  .claude-plugin/plugin.json
  bin/ccx.ps1              # 启动器本体
  commands/modelx.md       # /modelx
  hooks/hooks.json         # SessionStart → scripts/session-info.ps1
  scripts/session-info.ps1 # 读 CCX_* + state.json → additionalContext
  test/
  docs/features/ccx/specs/{ccx.md, archive/ccx-changelog.md}
```
- 插件本体走 claude-tools marketplace 安装；启动器另需一次性 `ccx install`（把 profile function 指向本仓 `bin/ccx.ps1`）——plan 细化
- statusline 集成为可选任务（显示当前号 label，多窗口一眼分辨）

---

## 10. 兜底链（不破坏承诺）

```
ccx 启动(--settings 层) > 裸 claude(settings.json 快照号, 行为=今天) 
ccx 崩 / registry 损坏 / 池空 → 显式报错 + 明示"裸 claude 仍可用"，不吞不装死
settings.json 仅 set-default 显式改；值永远来自 registry（单一事实源）
```

**回归义务**：每次改动后必须验证一次裸 `claude` 场景（判据 §12-1），证明兜底层活着。

---

## 11. A期已知限制（→ B期）

1. 会话中途号受限：当前窗口不能热切 → 标记 + `ccx -c`（B期：代理拦截 429/额度错误自动换 key 重试，无感续跑）
2. 多窗口可能同时选中同一号（无全局分配）→ B期代理统一出口后自然解决
3. 受限发现 = 启动时预检 + 会话内一键 mark；**会话运行中**的受限仍靠人发现（B期代理自动）
4. **B期预研任务**：① `apiKeyHelper` 是否在鉴权失败时被重新调用（若按请求/按失败调用 → 免代理换 key 路线）② 本地代理 + 心跳自愈 + 挂了必报警（反 cc-switch 静默死设计）
5. A期资产（registry/state/分层冷却/选号算法）全部被 B期复用，无推倒项

---

## 12. 验收判据（数值代入预演见 §6）

1. **回归**：裸 `claude`（不经 ccx）启动/对话/effort=max/tool search 与今天完全一致
2. §6 场景全过：自动跳过受限号 / 次号接力（mark 后 `ccx -c`）/ 全池面板 / **未 mark 但号死（registry 放一个假 token 号）→ `ccx` 预检自动标记 blocked 并落到下一号**
3. `ccx` 启动的窗口（**交互式**验证——P6/P7 已证 `-p` 模式测不了插件）：`/modelx` 显示正确当前号、插件/hooks/enabledPlugins 照常加载（若失载 → 启用"临时文件补 `enabledPlugins`"兜底并回归）；临时 settings 文件退出后无残留
4. `mark daily` 后 `ccx -c` 换号成功，且旧窗口不受影响
5. **卫生门**：仓内全量 grep 不到任何 token 片段；`~/.claude/model-accounts/` 不在仓内

---

## 13. 版本选择（组→版本二级菜单：C 真相源 ⊕ B 在线发现）

> 2026-11-26 增量。前半需求（多窗口各用不同大模型）A期已支持——每窗口独立临时 settings 互不干扰，不重做；本节 = 版本**可选不手输**。

```
裸 ccx（交互、无 -p）                      ccx glm / @id 强指 / -p 非交互
     │ 解析到组                                  │ 解析到组
     ▼                                          ▼
C versions 或 B 在线发现 非空？ ──否──► 无二级菜单（=A期行为，兜底）
     │是（唯一选项→静默直用）                    │ 用 default_version 直用不问；
     ▼                                          │ 组未配 default → 不覆盖（账号 env 原样）
版本菜单（回车=默认版）→ 选中 → Merge-CcxEnv -Version 覆盖模型键 → 选号预检 → 启动

C 手配：models.<key>.versions（配置序·默认版标注·含 [1M] 变体）
B 发现：GET 首号 base_url + /v1/models（Bearer·4s 超时·失败静默只显 C·✚ 标注·归一化去重·永不写回）
```

- **归一化去重**：小写 + 去尾 `[..]` 变体 + 去非字母数字 → `glm5.4[1M]` ≡ `glm-5.4`（基 `glm54`）；在线 id 与 C 任一条同基 → 不追加
- **env 覆盖规则**：仅动 `ANTHROPIC_*` 且含 `MODEL` 的键——`*_NAME` ← 基名（版本串去尾 `[..]`），其余 ← 版本串原样；并确保 `ANTHROPIC_MODEL` 至少写入（最小 env 号可用）；`BASE_URL`/`AUTH_TOKEN`/非模型键一律不动
- **实测依据**（2026-11-26 双 vendor 探针）：bigmodel `/v1/models` 200 返 13 id（glm-4.5~glm-5.4，**无 [1M] 变体**）；freemodel 200 返 claude 系 id（**无 "claude code"**）→ B 只能当发现器，C 必须为根

**验收（数值代入）**：
- 组 glm：versions=[glm5.4[1M](默认), glm-5.3[1M]]，在线拉到 [glm-5.4, glm-5.3, glm-5.2, glm-4.5] → 菜单 4 项 = glm5.4[1M]←默认 / glm-5.3[1M] / ✚glm-5.2 / ✚glm-4.5（glm-5.4、glm-5.3 同基去重不追加）✓
- 交互选 2 → 临时 settings `ANTHROPIC_MODEL=glm-5.3[1M]`、`*_MODEL_NAME=glm-5.3`，`ANTHROPIC_BASE_URL/AUTH_TOKEN` 原值 ✓
- `ccx glm` 不问 → `ANTHROPIC_MODEL=glm5.4[1M]` ✓；组无 versions 且在线失败 → 无二级菜单照旧启动 ✓；在线失败但 C 有配置 → 菜单只显 C 无报错 ✓
