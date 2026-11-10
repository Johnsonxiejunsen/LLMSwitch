# llm-cost — 通用 LLM 使用成本计算 skill

> 状态: **v1.1(对抗审查 3C+9I+10M 全处置; 用户已授权出 plan 并实施)** · 2026-11-10 · 域: llm-cost
> 变更历史: 见 `specs/archive/llm-cost-changelog.md`(立项起逐次追加)

---

## 0. 触发场景 / 背景(为什么做)

**用户原话痛点**: "每次都要让你现写脚本，很麻烦" —— 每次想知道"今天大模型花了多少钱",
都得让 AI 现写一个查数脚本, 用完即弃, 下次重来。

**现有资产(团队内部, 已在跑)**: 成本记账闭环(日账表+明细表)、单价引擎
(控制台按 key 用量×token 拟合校准, 价格页读数虚高≈3.3× 已证伪)、余额 API 封装。
但这些全部绑在内部业务仓里, 域外场景(其他项目/其他同事/公开安装)完全用不上。

**泛化拍板**: 用户明确 "我要的是一个**通用** skill, **通用的计算成本方式**" ——
做成公开仓 claude-tools 的通用插件, 仓内零内部信息, 任何人填自己的价格/接自己的数据源即可用。

---

## 1. 目标 / 非目标 / 反目标

**目标**
1. 一次安装, 任何会话里问"LLM 成本/花费/余额"即答, 不再现写脚本
2. 通用计算内核: token 分档(cache hit/miss + output) × 单价注册表 = 金额
3. 四数据源(**用户拍板 A/B/C/D**):
   - **A 手报**: 命令行直接给 token 数算一笔
   - **B 文件**: JSONL/CSV 用量文件逐行汇总
   - **C SQL**: 本地配置指向任意库表(用户自己写 query + 列映射), 可配多个命名源
   - **D 余额**: DeepSeek 官方 `GET /user/balance`(可选配 key)
4. 默认视图(**用户已确认**): 今日总额一句话 + 近 N 天(默认 7)"天×来源"拆分小表 + 余额(未配 key 跳过), N 可调
5. 公开仓卫生: 内部 IP / 密钥 / 表名零入仓, 环境细节全在本地配置文件

**非目标(v1 明确不做)**
- 不做记账/写库 —— 只读计算; 记账归各业务系统
- 不做价格自动抓取 —— 价格页已证虚高, 注册表手工维护 + `source` 字段留痕
- 不接 Langfuse / 代理网关用量 / DeepSeek 以外的余额 API
- 不做前端页面 / 不做跨币种汇率换算(各币种分别合计, 只标注不折算)

**反目标(做到=失败)**
- 任一数据源缺失/失败导致整体报错 → 必须**跳过该段并明示**, 其余照常输出
- 仓内出现任何 secret / 内网地址 / 内部表名

---

## 2. 全景图(数据流)

```
┌─ 单价注册表 data/prices.json(仓内, 手工维护) ─────────────────┐
│  model → {hit, miss, out, currency, source, effective_from}   │
│  aliases: 别名→正式名(deepseek-chat/reasoner → v4-flash)       │
└──────────────┬────────────────────────────────────────────┘
               ▼
        ╔═ 计算内核(纯函数, 零依赖) ═╗
        ║ ¥ = hit/1M×hit价           ║
        ║   + miss/1M×miss价         ║
        ║   + out/1M×out价           ║   reasoning 并入 out(思考 token 按输出价)
        ║ 无分档→全记 miss(不虚构命中) ║
        ╚═══════════╤═══════════════╝
                    ▲ 标准行: {day?, source?, model|cost 二选一,
          ┌─────────┴────────── input_tokens(默认含cache hit), output_tokens,
          │                     cache_hit_tokens?, currency?}
          │
┌─ 数据源适配器(按子命令选用, 缺哪个跳哪个) ────────────────────┐
│                                                              │
│  A calc      手报 token 数 ──────────── 直接算一笔            │
│  B file      JSONL/CSV 文件 ──列映射(默认+覆盖)── 逐行入核    │
│  C sql       ~/.claude/llm-cost/config.json 的 sql_sources   │
│              (用户自写 query, 可多命名源, 可 env 引密码)       │
│  D balance   DeepSeek /user/balance(配置缺 key → 跳过)        │
│                                                              │
│  report = 默认视图编排: 遍历全部已配置 SQL 源并列(行标"源名:")  │
│          + D 余额; --source sql:<名>/file:<路径> 收窄单源       │
│          A/B/C/D 亦可单独调用                                   │
└──────────────────────────────────────────────────────────────┘
```

**默认视图(report)形态示例**:

```
今日(2026-11-10) LLM 成本: ¥12.34   ← 一句话总额
近 7 天(天×来源):
  2026-11-10  quote_agent      ¥12.34   1.2M in / 0.4M out
  2026-11-09  quote_agent      ¥ 9.87   ...
  2026-11-09  evolution_analysis ¥ 1.02  ...
  ...合计: ¥88.21
余额: CNY 1234.56(账号级, 含其它服务消耗, 仅参考)   ← 未配 key 则此行不出现
[skipped] sql 源"prod" 连接超时 → 已跳过, 其余源照常   ← 跳过必须明示, 不许静默
```

---

## 3. 组件设计

### 3.1 仓内目录布局(claude-tools 新插件 `llm-cost/`)

```
llm-cost/
  .claude-plugin/plugin.json          # name/version/description
  README.md                           # 安装+配置说明+通用示例
  skills/llm-cost/
    SKILL.md                          # 触发词/决策流/输出格式约定
    scripts/llm_cost.py               # 唯一脚本: 内核+CLI(单文件, stdlib + 可选 pymysql)
    data/prices.json                  # 单价注册表(预置 DeepSeek 校准值)
    config.template.json              # 本地配置模板(占位符, 无真值)
  test/test_llm_cost.py               # unittest(零依赖, 随仓)
  docs/features/llm-cost/specs/...    # 本 spec + changelog
```

根 `.claude-plugin/marketplace.json` 的 `plugins[]` 加
`{"name": "llm-cost", "source": "./llm-cost", "description": "通用 LLM 使用成本计算: 单价注册表×token 分档, 手报/文件/SQL/余额四源"}`;
根 README 插件清单表同步加行。

### 3.2 单价注册表 `prices.json`(schema)

```json
{
  "version": 1,
  "models": {
    "deepseek-v4-flash": {
      "hit": 0.28, "miss": 0.28, "out": 2.84,
      "currency": "CNY", "unit": "per_M_tokens",
      "effective_from": "2026-09-10",
      "source": "控制台按key用量×token拟合(团队校准值, 价格页读数虚高已弃用)",
      "note": "hit 零观测按 miss 保守计"
    },
    "deepseek-v4-pro": {
      "hit": 0.84, "miss": 0.84, "out": 8.52,
      "currency": "CNY", "unit": "per_M_tokens",
      "effective_from": "2026-11-10",
      "source": "flash×3 占位, 未校准 —— 使用前请自行校准并更新本行"
    }
  },
  "aliases": {
    "deepseek-chat": "deepseek-v4-flash",
    "deepseek-reasoner": "deepseek-v4-flash"
  },
  "aliases_note": "chat/reasoner 为官方弃用别名, 均按 v4-flash 校准价计(不另设单价)"
}
```

- 价格单位统一 **每百万 token**; 三档(hit/miss/out)缺一不可(无分档供应者 hit=miss 同价)
- 加新模型 = 加一段 JSON, 改完即生效(脚本每次运行重读)
- **本地覆盖层**(评审定稿): `~/.claude/llm-cost/prices.json` 与仓内注册表合并,
  同模型键**本地赢**, `aliases` 同规则 —— 公开安装者加价格不改插件目录(插件升级会覆盖那里)
- **未校准值必须带 note 声明**, 防"占位数当精确值"流传
- 未识别模型: `calc` 直接报错并列出可用模型(计算器正确性优先, 不静默兜底);
  `file`/`sql` 聚合中跳过该行并计入 `skipped_unknown_models` 计数, 结尾明示

### 3.3 计算内核(纯函数)

```
cost(model, input_tokens, output_tokens, cache_hit_tokens=0) -> Decimal
  hit = min(cache_hit, input)          # 防御: 命中不可能超过输入(默认口径下)
  miss = input - hit
  ¥ = hit/1e6×P.hit + miss/1e6×P.miss + out/1e6×P.out
```

- **token 口径(对抗审查 C1 定稿)**: 默认口径 `input_tokens **已含** cache hit`(DeepSeek/OpenAI)。
  Anthropic 形态(input 不含 cache_read)由源级/文件级开关 `hit_included_in_input=false` 声明——
  此时计价 hit=cache_hit、miss=input_tokens, 展示总量=hit+miss。
  数据提供可选 `cache_miss_tokens` 列时以 `hit+miss==input` 自洽校验, 不自洽→全记 miss(不虚构命中)
- 单价 JSON 载入必须 `json.load(..., parse_float=Decimal)`(防 0.28 浮点污染, M6)
- 金额用 `Decimal` 计算(展示四舍五入), 展示精度: 单笔 4 位小数 / 汇总 2 位
- **v1 单价不随日期生效**(评审定稿): `effective_from` 仅为出处元数据, 历史行一律按现价计——
  窗口内调过价则该段失真, 此限制明写 README; 日期感知计价列演进项
- 未知模型 → `UnknownModelError`(见 3.2 处置)
- 内核零第三方依赖; SQL 源才 `import pymysql`(缺失时报"pip install pymysql"指引, 不炸其它子命令)

### 3.4 CLI 子命令(`python llm_cost.py <cmd>`)

| 子命令 | 参数 | 行为 |
|---|---|---|
| `calc` | `--model M --input N --output N [--cache-hit N]` | 单笔直算 |
| `file` | `<path> [--format jsonl\|csv] [--col-<标准列> <文件列名>]... [--hit-included-in-input false]` | 文件逐行汇总; format 缺省按扩展名嗅探(.csv→csv, 其余 jsonl); 列旗标用标准列名连字符形(如 `--col-input-tokens`) |
| `sql` | `--name <源名> [--days N]` | 按本地配置跑 query(占位符替换见 §3.5), 结果行列映射后入核 |
| `balance` | — | DeepSeek 余额(v1 单配置节): 展示 `is_available` + `balance_infos` 各币种 `total_balance`; 未配 key → 打印"未配置, 跳过" |
| `report` | `[--days N] [--source auto\|sql:<名>\|file:<路径>] [--format/--col-* 透传 file 源]` | 默认视图编排(见 §2 示例) |
| 通用 | `--json` | 机读输出, 骨架见下方 --json 契约 |

- `--source auto`(**评审定稿·用户拍板"全部并列"**): 遍历配置里**全部** SQL 源并列汇总,
  行标签 `源名:来源列`(如 `prod:quote_agent`), 各源独立小计;
  **跳过原因枚举**(I3): `not_configured`(显式 `sql:<名>` 不存在)/`unreachable`/`timeout`/`auth_failed`/`query_failed`/`no_sources`
- **report 表行键 = 天×来源×模型**(M9): model 列缺失的直通行标 `(未分模型)`
- **多币种**(M3): 按 `currency` 分组小计与合计, 不折算; `cost` 直通列缺币种信息时默认 CNY
- **"今日"口径**: 本地时区当日(`date.today()`); SQL 源若跨时区由用户 query 自行换算(配置注释说明)
- **`--days` 优先级**(I6): CLI 旗标 > 配置 `defaults.days` > 内置 7
- **占位符替换机制**(I7): 仅对 `{start_date}`/`{end_date}`/`{days}` 三个已知 token 做**字面 replace**,
  其余大括号内容原样保留(禁用 str.format, 防 query 内 JSON 字面量/未知 `{var}` 炸)
- **超时**(I8): SQL 连接 ≤5s / 读 ≤10s, balance HTTP ≤5s; 超时计入 `[skipped]`(reason=timeout), 不挂死 report
- **退出码**(C2 定稿): `0`=至少一源成功(或 calc 单笔成功);
  `1`=用法/业务错误(calc 未知模型 / 文件不存在 / 文件格式错 / 配置 schema 错);
  `2`=report 无任何成功源(全部 skipped/失败)——上游可与"没花钱"(0+空行)区分。
  数据源缺失/不可达/超时**不改变退出码**, 由 `[skipped]` 行与 `--json` 的 `skipped[]` 表达
- 无源且无文件时的提示(M10, 统一一条): "未发现可用数据源。首次使用: 复制 config.template.json
  到 ~/.claude/llm-cost/config.json 并填写(见 SKILL.md); 或直接 file/calc 算一笔"
- **`--json` 契约**(I5): `{"ok": <bool>, "today": {"date", "cost_by_currency"}, "rows":
  [{"day","source","model","cost","currency",...}], "totals": {"<币种>": <cost>},
  "balance": {...}|null, "skipped": [{"source","reason"}]}` —— 键名即公开契约, 改版须走 changelog

### 3.5 本地配置 `~/.claude/llm-cost/config.json`(模板入仓, 真值永不入仓)

```json
{
  "defaults": { "days": 7 },
  "sql_sources": {
    "<源名>": {
      "driver": "mysql",
      "host": "<HOST>", "port": 3306, "user": "<USER>",
      "password": "<明文或省略>", "password_env": "<环境变量名(优先于明文)>",
      "database": "<DB>",
      "query": "<你自己的聚合 SQL; 可用占位符 {start_date}/{end_date}/{days} 由脚本按 --days 本地时区替换, 不写=自包含>",
      "column_map": {
        "day": "day列名(可省=不按天分组)", "source": "source列名(可省)",
        "model": "model列名(与 cost 二选一)", "input_tokens": "...", "output_tokens": "...",
        "cache_hit_tokens": "(可省)", "cache_miss_tokens": "(可省, 供自洽校验)",
        "cost": "金额列名(与 model 二选一: 有=直通库内已算金额, 跳过计价)",
        "currency": "(可省, 直通行币种, 缺省 CNY)"
      },
      "hit_included_in_input": true
    }
  },
  "deepseek": { "base_url": "https://api.deepseek.com", "api_key": "<sk-...>", "api_key_env": "<环境变量名(优先于明文)>" }
}
```

- `query` 用户自写 → **通用性最大**(任意库任意表任意口径), 脚本不猜 schema;
  **占位符约定**(评审定稿): `{start_date}`/`{end_date}`/`{days}` 由脚本替换——
  **边界语义(I1 定稿)**: `{start_date}`=今日−(days−1)、`{end_date}`=**今日+1**(均 `YYYY-MM-DD` 本地时区),
  推荐 DATETIME 列写 `>= {start_date} AND < {end_date}`(端点含首不含尾, 今日整段安全);
  query 不含占位符=自包含, `--days` 仅影响展示窗口
- **column_map 必填规则(C3 定稿)**: 二选一——`(model + input_tokens + output_tokens)`(内核计价)
  或 `cost`(直通库内已算金额, 其余列皆可省); 两组都缺→该源配置错误:
  显式 `sql` 调用 exit 1, report 中该源 `[skipped]`(reason=not_configured)
- `hit_included_in_input`(C1): 源级布尔, 默认 true(input 已含 cache hit); false=Anthropic 形态
- 密码/key 支持 `*_env` 环境变量引用(`password_env`/`api_key_env`, 优先于明文), 避免明文落盘
- 模板 `config.template.json` 全占位符; SKILL.md 引导首次使用时复制到 `~/.claude/llm-cost/`

### 3.6 SKILL.md 行为约定

- **触发**: 用户问 LLM 成本/花费/多少钱/token 计价/余额等
- **决策流**: 问"今天花了多少"→ 配置存在则 `report`; 问"算一笔"→ `calc`;
  给了文件 → `file`; 首次使用(无配置)→ 引导复制模板并填源
- **输出**: 中文; 默认视图按 §2 示例; 金额单位 ¥(或注册表币种); 未知模型/跳过项必须显式列出
- **红线**: 永不把用户配置内容(含 query/IP/key)原样贴进对话以外的地方(如公开仓/issue)

---

## 4. 验收判据(实施后逐条过)

1. `calc --model deepseek-v4-flash --input 1000000 --output 500000` → **¥1.7000**(展示 4 位小数; 数值=0.28+1.42)
2. `calc` 带 `--cache-hit 400000` → 0.4M×0.28 + 0.6M×0.28 + 0.5M×2.84 = **¥1.70**(flash 预置 hit=miss 同价, 与判据①同值属正常); **分档拆分逻辑以单测注入 hit≠miss 的测试模型验证**(如 hit=0.1/miss=1.0: 1M in(400k hit)+0.5M out → 0.04+0.6+按 out 价, 手算对拍)
3. 造 3 行 JSONL(1 行带 cache_hit, 1 行未知模型, 1 行普通) → `file` 汇总=手算值, **退出码 0**, 未知行计入 skipped 计数并明示; 另造 Anthropic 口径行(input 不含 cache_read)配 `--hit-included-in-input false` → 与手算一致(防 C1 假绿)
4. `sql` 无配置 → `[skipped]` 明示 + 退出码 0; 配好测试源(**内部开发测试库只读**, 凭据只进本地配置, 评审定稿)后聚合值=同数据手算, 且 `{start_date}/{end_date}` 边界含今日全段(防 I1 假绿); 只返回 `day+cost` 两列的直通源同样出报表(数值=库内值); 配两个源时 `report` 行带 `源名:` 前缀且各源独立小计
5. `balance` 无 key → 跳过行; 有 key → 余额值(可人工核对 DeepSeek 控制台)
6. `report` 默认视图: 今日/近 N 天表/合计三段齐, 余额或跳过行**至少其一**出现(未配 key 且无跳过时余额段依设计缺席≠FAIL)
7. 公开卫生门(含 spec/README/changelog 全部随仓文件): 内网 IPv4 全段+回环+长密钥零命中——
   对**除本 spec 外**全部随仓文件跑(本节内嵌模式原文, 自指命中属噪声):
   `grep -rEn "192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}|127\.0\.0\.1|::1|sk-[A-Za-z0-9]{20,}"` 零命中;
   且**人工通读一遍** docs/ 与 README 无内部系统名/库号/主机名(I9: 正则拦不住内部简称)
8. `test_llm_cost.py` 全绿(内核分档/别名/未知模型/解析器/列映射/Decimal 精度/**口径开关 false 对拍**/**占位符边界与字面大括号保留**/**--json 骨架键**/**退出码三态**)
9. 安装冒烟: marketplace add + install 后新会话能触发 skill 出默认视图
10. **旧行为回归**: 无配置无文件时 `report` 不炸, 输出统一引导文案(见 §3.4 M10)

---

## 5. 备选方案(被否决记录)

| 方案 | 内容 | 否决理由 |
|---|---|---|
| B1 专用 skill | 直接查内部成本两张表 | 绑死内部系统, 公开仓装不了; 用户拍板要"通用" |
| B2 包装现有端点 | 调业务系统 /llm-cost/daily | 依赖服务可达性(生产端点部分网络不可达)且只覆盖单系统 |
| B3 价格自动抓取 | 爬官方价格页生成注册表 | 价格页实测虚高≈3.3×(垃圾进垃圾出); 手工维护+source 留痕更可信 |
| B4 多币种折算 | 汇率换算统一币种 | v1 复杂度不匹配收益, 各币种分别合计已够用 |

---

## 6. 中途发现 / 教训(沉淀)

- **价格页不可信**(内部实测教训): 单价必须留 `source` 校准出处字段, 未校准值必须带 note —— 本注册表 schema 直接继承该教训
- **差值法对账已废止**(内部仲裁): 余额是账号级多 key 共享, Δ余额≠单系统消耗 —— 所以余额只做"参考读数"展示并标注, 不参与任何对账逻辑
- **通用 vs 专用的分界**: 内部场景(团队业务系统的成本日账)不进本仓, 以"用户本地配置里的一条 SQL 源"形态接入 —— 仓是通用内核, 私有在配置; **spec/文档随仓发布, 内部系统名/库号一律用泛称**(对抗审查 I9: 正则门拦不住内部简称, 人工通读补位)

## 7. 实施 / 发布

- 发布流: claude-tools 仓直接开发 → 单测绿 → 公开卫生门(判据 7)过 → 用户确认 → commit + push(**用户拍板由 AI 推送**; 推送用私人令牌 URL 一次性嵌权, 令牌用户在推送时现场提供——不入仓、不入记忆; 推前把推送文件清单亮给用户过目)
- 后续演进(未排期): 更多模型预置价 / 多云余额 / 汇总图表 —— 一律走主 spec 改版 + changelog 追加
