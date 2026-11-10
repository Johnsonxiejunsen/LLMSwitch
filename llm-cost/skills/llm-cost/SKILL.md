---
name: llm-cost
description: 通用 LLM 使用成本计算。用户问大模型成本/花费/多少钱/token 计价/余额/今日消耗/近几天成本时使用。四数据源: 手报 token 直算(calc)、用量文件(file)、本地配置的 SQL 源(sql/report)、DeepSeek 官方余额(balance)。单价注册表×token 分档, 支持本地覆盖与多币种分组。
---

# llm-cost — 通用 LLM 使用成本计算

单一脚本: `scripts/llm_cost.py`(Python≥3.9, stdlib; SQL 源需 `pip install pymysql`)。
单价注册表: `data/prices.json`(每百万 token 三档: hit/miss/out), 本地覆盖 `~/.claude/llm-cost/prices.json`(同模型键本地赢)。

## 决策流(按用户意图选子命令)

```
用户问成本/花费/余额
├─ 问"今天/近几天花了多少" ──→ 配置存在(~/.claude/llm-cost/config.json)?
│                                ├─ 是 → python scripts/llm_cost.py report [--days N]
│                                │       (默认全 SQL 源并列 + 今日合计 + 余额)
│                                └─ 否 → 引导: 复制 config.template.json 到
│                                        ~/.claude/llm-cost/config.json 并填写
│                                        (本 skill 目录下有模板), 填好后再跑 report
├─ "算一笔/这单要多少钱"(报 token 数) ──→ calc --model M --input N --output N [--cache-hit N]
├─ 给了用量文件(JSONL/CSV) ──→ file <path> [--col-<标准列> <文件列名>]...
├─ 只要 DeepSeek 账户余额 ──→ balance
└─ 指定某 SQL 源单跑 ──→ sql --name <源名> [--days N]
```

- 机读需求(脚本/管道)加 `--json`(骨架: ok/today/rows/totals/subtotals_by_source/balance/skipped)。
- report 收窄: `--source sql:<名>` 或 `--source file:<路径>`; 缺省 auto=全部 SQL 源并列。

## 输出约定

- 中文; 金额单位 ¥(或注册表币种), 单笔 4 位小数 / 汇总 2 位; 多币种分组小计, **不折算**。
- 未知模型行、跳过源(`[skipped] 源名: 原因 → 已跳过, 其余照常`)必须**显式**转述给用户, 不得吞掉。
- 退出码: `0`=至少一源成功; `1`=用法/业务错误; `2`=report 全源失败。转述时区分"没花钱"(0+空行)与"取数失败"(2)。

## 配置(首次使用)

模板在本 skill 目录 `config.template.json`。复制到 `~/.claude/llm-cost/config.json` 后填:

1. `sql_sources.<源名>`: 自写聚合 SQL(query 任意, 占位符 `{start_date}`/`{end_date}`/`{days}` 由脚本按 `--days` 本地时区替换, 推荐写 `>= {start_date} AND < {end_date}`); `column_map` 二选一: `model+input_tokens+output_tokens`(内核计价)或 `cost`(直通库内已算金额)。
2. `deepseek`: 填 `api_key` 或 `api_key_env`(环境变量名, 优先于明文)。
3. 密码同理: `password_env` 优先于 `password` 明文。

## 红线

- **永不**把用户配置内容(含 query、IP、host、key、密码)贴进对话以外的任何地方(公开仓、issue、文档)。
- 配置真值只存在于用户本地 `~/.claude/llm-cost/`; 仓内只允许占位符模板。
- 加新模型价格: 改本地 `~/.claude/llm-cost/prices.json`(勿改插件目录, 升级会覆盖); 未校准值必须带 note 声明。
