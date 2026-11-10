# claude-tools

Claude Code 插件集合（gitee marketplace 仓）。

## 安装

```bash
claude plugin marketplace add https://gitee.com/xjunsen/claude-tools.git
claude plugin install context-keeper@claude-tools
```

## 插件清单

| 插件 | 作用 | 前置 |
|---|---|---|
| [context-keeper](./context-keeper) | context 到 **200k** 自动压缩后**忠实回注近期原文**，落点稳定 ≈150k（原生落点不可配，实测 478k→19.6k） | `~/.claude/settings.json` 加 `"autoCompactEnabled": true, "autoCompactWindow": 200000`（发条：不配则 1M 模型 ~967k 才压缩，插件永不触发）；Node ≥18 |
| [llm-cost](./llm-cost) | **通用 LLM 使用成本计算**：单价注册表×token 分档（hit/miss/out），手报/文件/SQL/余额四源，`report` 默认视图=今日+近 N 天×来源+余额 | Python ≥3.9；SQL 源另需 `pip install pymysql` |

## 添加新插件

1. 建子目录 `<tool>/`，内含 `<tool>/.claude-plugin/plugin.json`
2. 在 `.claude-plugin/marketplace.json` 的 `plugins` 数组加 `{"name": "<tool>", "source": "./<tool>"}`
3. 更新本清单表
