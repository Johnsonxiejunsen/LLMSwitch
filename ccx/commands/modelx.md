---
description: 号池面板与标记（当前窗口账号 / 全池状态 / 一键标记受限号）
---

按步骤操作（不要跳步、不要伪造任何面板数据）：

1. **查看号池面板**：运行 PowerShell 命令
   ```
   & "$env:CLAUDE_PLUGIN_ROOT\bin\ccx.ps1" list
   ```
   若 `$env:CLAUDE_PLUGIN_ROOT` 为空（本窗口非插件环境），改用 `ccx list`。
   若两者都失败：明确告诉用户 ccx 启动器未安装/未 `ccx install`，给出 claude-tools 仓库地址，**不要编造面板**。

2. **把面板原样展示**给用户（代码块），并说明：
   - 本窗口当前账号见会话开头的 `[ccx]` 提示行（无则是 settings.json 快照号，非 ccx 启动）
   - `r429` / `daily` 状态的号到点自动冷却恢复（面板有恢复时间）
   - `blocked`（欠费/封号/401）不会自动恢复，处理后再 `ccx unlock <id>`

3. 用户要求**标记/切换**时（例："glm-1 没额度了"、"标记 daily"、"切号"）：运行
   ```
   & "$env:CLAUDE_PLUGIN_ROOT\bin\ccx.ps1" mark <id> <r429|daily|blocked>
   ```
   （`$env:CLAUDE_PLUGIN_ROOT` 为空时用 `ccx mark <id> <type>`）
   标记成功后提示用户：**本窗口是旧号无法热切换，新开窗口用 `ccx` 或续会话 `ccx -c`，ccx 会自动换到有额度的号**。

4. 用户要求**解锁**时：`ccx unlock <id>`；要求**全池体检**时：`ccx check`。
