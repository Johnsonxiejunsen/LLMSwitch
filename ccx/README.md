# ccx — Claude Code 号池启动器（A期）

同一模型厂商（如智谱 GLM）多个账号组成号池：当前号受限时自动切到有额度的号，全部受限则给出全池面板与最早恢复时间。**宁可不切也不换模型**；裸 `claude` 完全不受影响。

## 安装（三步）

1. **装插件**（本仓为 claude-tools marketplace）：

   ```
   /plugin marketplace add https://gitee.com/xjunsen/claude-tools
   /plugin install ccx@claude-tools
   ```
   装上的是 `/modelx` 会话内面板与 SessionStart 提示；启动器本体在仓库 `ccx/bin/`。

2. **装启动器命令**（把 `ccx` 命令写进 PowerShell profile，幂等可重复执行）：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File <仓库路径>\ccx\bin\ccx.ps1 install
   ```

3. **添加账号**（token 只写本机 `~\.claude\model-accounts\registry.json`，永不入仓）：

   ```powershell
   ccx add        # 向导：label / vendor / base_url / token / 模型名
   ccx set-default <id>   # 可选：设默认号并同步 settings.json（自动备份）
   ```

## 日常使用

| 命令 | 行为 |
|---|---|
| `ccx` | 交互选模型组 → 自动选号（预检默认开）→ 启动 claude |
| `ccx -c` / `ccx -r` | 续会话，重新自动选号（死号标记后这样接力） |
| `ccx <model>` / `ccx <model>@<id>` | 直启模型 / 强指某个号 |
| `ccx ... --no-check` | 跳过启动预检 |
| `ccx list` | 全池状态面板 + settings.json 快照漂移提示 |
| `ccx mark <id> <r429\|daily\|blocked>` | 手动标记受限 |
| `ccx unlock <id>` | 解锁 blocked |
| `ccx rm <id>` / `ccx check` | 删号 / 全池逐号预检 |
| `/modelx`（会话内） | 池面板 + 一键标记 + `ccx -c` 续跑指引 |

## 机制与边界

- **自动切换**只发生在同 vendor 池内：priority 升序 + 最久未用轻轮转；`r429` 60s 自愈、`daily` 到 reset_time 自愈、`blocked` 只能手动解锁。
- **启动预检**（默认开）：选号后发一次 max_tokens=1 最小请求；401→标 blocked、报文含 余额/欠费/额度→标 daily、429→标 r429、未知/网络错→不标记照常启动（不误杀）。标记后自动换下一号接力。
- **切换发生窗口边界**（A期）：开新窗/续会话时生效；已开窗口内不热切（B期做 proxy/apiKeyHelper）。
- **兜底链**：`ccx --settings 层 > 裸 claude(settings.json)`；registry 损坏/池空 → 显式报错并明示"裸 claude 仍可用"，绝不静默。settings.json 仅 `ccx set-default` 一个入口写（先备份）。
- 数据目录 `~\.claude\model-accounts\`（registry.json / state.json）；测试 `ccx/test/run-tests.ps1`。

## 已知限制（A期 → B期路线）

- 会话中不可热切换；预检吃 0.5~2s/次；多窗口并发预检可能互吃 429（60s 自愈，无害）。
- B期：会话内无缝切换（代理 / apiKeyHelper）、statusline 集成、cc-switch 存量导入。
