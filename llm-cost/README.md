# llm-cost — 通用 LLM 使用成本计算 skill

单价注册表 × token 分档(hit/miss/out 三档, 每百万 token), 四种数据源:

| 源 | 子命令 | 场景 |
|---|---|---|
| A 手报 token | `calc --model M --input N --output N [--cache-hit N]` | 算一笔 |
| B 用量文件 | `file <path> [--col-<标准列> <文件列名>]...` | JSONL/CSV 汇总 |
| C SQL 源 | `sql --name <源名>` / `report`(全源并列) | 自写 query 读任意库 |
| D 官方余额 | `balance` | DeepSeek 账户余额对账 |

`report` = 默认视图: 今日合计 + 近 N 天(天×来源×模型) + 各源小计 + 余额。

## 安装

```bash
claude plugin marketplace add https://gitee.com/xjunsen/claude-tools
claude plugin install llm-cost@claude-tools
```

前置: Python ≥ 3.9(脚本仅 stdlib); 用 SQL 源才需要 `pip install pymysql`。

## 配置三步

1. 复制模板: `skills/llm-cost/config.template.json` → `~/.claude/llm-cost/config.json`
2. 填 SQL 源(query 自写, 任意库任意表; `column_map` 二选一: `model+input_tokens+output_tokens` 走内核计价, 或 `cost` 直通库内已算金额)
3. (可选)填 `deepseek.api_key` 或 `api_key_env` 启用余额查询

密码/key 均支持 `*_env` 环境变量引用(优先于明文), 避免明文落盘。配置真值永不入仓。

### 通用示例 query(占位符由脚本按 `--days` 本地时区替换)

```sql
SELECT DATE(created_at) AS day, model_name AS model,
       SUM(input_tokens) AS input_tokens, SUM(output_tokens) AS output_tokens
FROM your_usage_table
WHERE created_at >= '{start_date}' AND created_at < '{end_date}'
GROUP BY day, model_name
```

`{start_date}`=今日−(days−1), `{end_date}`=今日+1(端点含首不含尾, 今日整段安全); `{days}` 也已可用。query 不含占位符=自包含。

## 加模型价格

本地 `~/.claude/llm-cost/prices.json`(勿改插件目录, 升级会覆盖), 与仓内注册表合并、同模型键本地赢:

```json
{ "models": { "your-model": { "hit": 1, "miss": 2, "out": 8, "currency": "CNY" } } }
```

未校准值请在条目里加 `"note"` 声明, 防占位数被当精确值。

## 已知限制

- **`effective_from` 不参与历史计价**: v1 单价不随日期生效, 历史行一律按现价计; 窗口内调过价则该段失真(日期感知计价为演进项)。
- **混币种不折算**: 按 `currency` 分组小计与合计, 各币种并列展示。
- DeepSeek 预置价来自按 key 用量×token 拟合校准(价格页读数虚高已弃用); `deepseek-v4-pro` 为占位未校准值。

## 开发

`test/test_llm_cost.py`(unittest, 零第三方依赖): `python -m unittest discover -s test`
