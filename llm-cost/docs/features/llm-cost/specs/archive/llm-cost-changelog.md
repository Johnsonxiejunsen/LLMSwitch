# llm-cost changelog(演进日志, 每次改动追加一行)

| 日期 | 变更 | 为什么 |
|---|---|---|
| 2026-11-10 | 立项: spec v0.1 草案(通用 LLM 成本计算 skill, 四数据源 A/B/C/D + 默认视图), claude-tools 新插件 | 痛点"每次查成本都要现写脚本"; 用户拍板做通用工具发布公开仓 |
| 2026-11-10 | spec v0.1 → v1.0 定稿吸收 builder 评审 7 问: report 全源并列(用户拍板)/占位符 {start_date}/{end_date}/{days}/本地 prices.json 覆盖合并(本地赢)/balance 去 --name 单配置节/effective_from 仅元数据/判据④用 186 只读验证/推送=AI 执行+现场令牌 | 评审问题分"用户拍板×2 + 裁定×5"处置, 细见 spec 各"评审定稿"标注 |
| 2026-11-10 | spec v1.0 → v1.1: 对抗审查(3C+9I+10M)全处置——C1 token 口径定义+hit_included_in_input 开关 / C2 退出码三态(0/1/2) / C3 column_map 必填规则(model|cost 二选一) / I1 日期边界(start=今日−(days−1), end=今日+1, 含首不含尾) / I2 api_key_env / I3 跳过原因枚举 / I4 report 透传列旗标 / I5 --json 契约 / I6 days 优先级 / I7 占位符字面 replace / I8 超时三档 / I9 卫生门正则扩段+人工通读+文档内部痕迹泛称化 / M1-M10(format 嗅探/列旗标命名/混币种分组/stdlib 注/判据字面性/parse_float=Decimal/别名 note/余额字段/行键×模型/无源文案) | 口径与契约层缺陷不修会产出系统性低报(C1)+两种相反实现(C2/C3)+结构性假绿(I1); 全部为定义补齐, 不改方向 |
