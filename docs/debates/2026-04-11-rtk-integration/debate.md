# RTK x ModelSelector 深度集成方案辩论

**日期**: 2026-04-11
**参与者**: Gemini 2.5 Pro, Codex gpt-5.4 (Opus代写), Sonnet 4.6, Opus 4.6 (仲裁)
**议题**: 如何深度集成 RTK (Rust Token Killer) 与 ModelSelector 以最大化 token 节省

---

## 方案 A: 松耦合 - 共享数据契约 (Gemini 2.5 Pro)

架构核心是**单向、只读的数据流**。MS 和 RTK 保持为完全独立的二进制程序和脚本。集成点不是代码，而是 RTK 生成的 `tracking.db` SQLite 数据库。

### 1. 集成架构
RTK 继续作为纯粹的 Rust 应用，其 PreToolUse 钩子拦截命令、压缩输出，并将压缩比、命令模式等统计数据写入 tracking.db。RTK 对 MS 的存在一无所知。ModelSelector 的 model-selector.sh 脚本在评分逻辑中增加一个步骤：执行 sqlite3 查询，从 tracking.db 中读取特定命令模式的历史压缩率。install.sh 探测 RTK 是否安装，若存在则在 MS 配置中记录 tracking.db 路径。

### 2. 数据反馈回路
当 hook-model-selector.sh 触发评分时，MS 构造 SQL 查询：
```sql
sqlite3 /path/to/tracking.db "SELECT avg(compression_ratio) FROM commands WHERE command_pattern LIKE '%grep -r%' ORDER BY timestamp DESC LIMIT 10;"
```
返回的压缩率(如 0.85)作为成本缩减因子，应用到正则评分模型中。高压缩率的命令发往 T4 时预估成本显著降低，让 MS 更"勇敢"地选择高质量模型。

### 3. Hook 管道协调
两个钩子在各自生命周期独立运作：
1. UserPromptSubmit 首先触发，运行 hook-model-selector.sh 完成模型选择
2. Claude 准备执行 shell 命令时，PreToolUse 触发，RTK 介入重写命令并压缩输出

串行但解耦，无复杂握手或依赖。

### 4. T0 特殊优化
MS 在决策时结合 RTK 压缩率做前瞻性计算。低压缩率的大上下文(>6K tokens)被识别为"预估压缩后>8K"，主动跳过 T0 直接路由到 T1/T2，避免本地模型上下文超限的重试循环。

### 5. 经济统一
创建独立的仪表盘脚本，从两个数据源拉取：RTK tracking.db 提供 token 节省量，MS 日志记录模型选择。关联时间戳计算有效成本。

### 6. 质量保证
依赖 RTK 内建的 TOML 过滤器(精细正则配置防止压缩结构化输出)和 Tee 恢复机制(原始输出保存供随时读取)。集成 MS 不给 RTK 增加新的质量风险。

---

## 方案 B: 深度合并 - 统一系统 (Codex gpt-5.4 立场, Opus 代写)

松耦合是妥协，不是工程。两个系统解决同一个问题的两个面--token 经济学--就该是一个系统。

### 1. 集成架构
创建 `token-os` 统一二进制(Rust)。RTK 的过滤引擎提取为 `rtk-core` library crate，ModelSelector 的 bash 评分逻辑用 Rust regex 重写为 `ms-scorer` crate。主 crate `token-os` 组合两者：
```
token-os/
  Cargo.toml (workspace)
  crates/
    rtk-core/     (从 RTK 提取的过滤+追踪引擎)
    ms-scorer/    (从 MS bash 移植的评分引擎)
    token-os/     (统一入口: CLI + hook handler)
```
单 binary，单 install，单 config (`~/.config/token-os/config.toml`)，单 SQLite。

### 2. 数据反馈回路
这是深度合并的杀手级优势：**实时闭环**。评分引擎在同一进程内直接调用 rtk-core 的压缩预估函数，而非事后读取 SQLite 统计。流程：
1. prompt 进来 -> ms-scorer 评分
2. ms-scorer 调用 rtk-core::estimate_compression(command_pattern) 获取该命令类型的历史压缩率
3. 压缩率直接参与 capability scoring 的 D4 modifier
4. 路由决策 + 压缩策略一次性确定

没有 sqlite3 进程启动开销，没有 JSON 中间文件，没有刷新延迟。

### 3. Hook 管线协调
一个 binary 注册两个 hook event：
- UserPromptSubmit -> token-os score (路由决策)
- PreToolUse -> token-os filter (命令重写+输出压缩)

共享进程上下文，评分结果直接传递给过滤阶段。例如：T0 路由决策时同时设置 `aggressive_filter=true`，因为本地模型需要最大压缩。

### 4. T0 特殊优化
统一系统的独特优势：**自适应压缩等级**。
- T0 (8K): rtk-core 使用 aggressive 过滤(code_filter=aggressive, tree_compression=max)
- T3 (200K): rtk-core 使用 minimal 过滤(只去 ANSI 和进度条)
- T4 (1M): rtk-core 几乎 passthrough

这不是"读统计然后猜"，是路由决策直接控制压缩策略。

### 5. 经济统一
单 SQLite，单表设计：
```sql
CREATE TABLE operations (
  id INTEGER PRIMARY KEY,
  timestamp INTEGER,
  prompt_hash TEXT,
  tier TEXT,            -- T0/T1/T2/T3/T4
  input_tokens INTEGER,
  output_tokens INTEGER,
  compressed_tokens INTEGER,
  compression_ratio REAL,
  model_cost_usd REAL,
  savings_usd REAL
);
```
`token-os --stats` 一个命令展示完整 ROI。

### 6. 质量保证
统一系统可以做**tier-aware quality gate**：T0 压缩后如果 tee 恢复率 >5%，自动升级到 T2 并降低压缩。这在松耦合架构中不可能实现，因为路由和压缩是分离的。

### 代价
重写 MS 的 450 行 bash 为 Rust。但 bash regex 到 Rust regex 是 1:1 映射，实际工作量约 2-3 天。换来的是：编译时类型安全、单 binary 分发、实时闭环。

---

## 方案 C: 适配器桥接模式 (Sonnet 4.6)

MS 和 RTK 解决正交问题：路由决策 vs 令牌压缩。强行合并产生耦合税。桥接层(`ms-rtk-bridge`，约 200 行 Rust)精确切断依赖链。

### 1. 集成架构
两个项目保持独立可测试、独立发布、独立使用。桥接器是唯一新增代码，职责明确：数据转换 + hook 协调。

### 2. 数据反馈回路
bash 访问 SQLite 需依赖 sqlite3 二进制，进程启动开销大，输出格式不稳定。桥接器以 Rust 原生读取 SQLite(rusqlite)，预计算统计到 `~/.config/model-selector/rtk-stats.json`：
```json
{
  "avg_compression_ratio": 0.72,
  "p95_output_tokens": 1840,
  "tee_recovery_rate": 0.03,
  "last_updated": 1744329600
}
```
MS 在 P5 后处理阶段读取 JSON，成本是一次文件读取，零 Rust 依赖侵入。

### 3. Hook 协调
Claude Code 不保证多 hook 执行顺序。若 MS hook 和 RTK hook 独立注册，存在竞态：MS 在 RTK 压缩前评分(看到原始令牌量)，或 RTK 在 MS 路由后压缩(无法影响路由)。桥接器作为唯一注册 hook，强制执行顺序：先 RTK 压缩，再将压缩后 context 尺寸传给 MS 评分。

### 4. T0 优化
桥接器计算 `effective_context = model_window - avg_rtk_output`，注入 MS capability scoring。这是**路由降级**--原本因 context 溢出被迫升 T3 的任务可安全留在 T0。

### 5. 经济统一
桥接器 merge 两个数据源输出：
```
Session: T0x12 (T3 downgraded via RTK), T3x4, T4x1
RTK savings: 18,400 tokens ~ $0.55
Effective cost: $1.20 (without RTK: $1.75)
```

### 6. 质量保证
桥接器监控 tee recovery rate。当 `tee_recovery_rate > 0.05` 时，向 MS 的 D4 修饰符注入降级信号，同时触发日志告警。两个系统的质量反馈闭合成可观测回路。

---

## 仲裁: Opus 4.6 综合裁决

### 评分矩阵

| 维度 | 方案A 松耦合 | 方案B 深度合并 | 方案C 桥接器 |
|------|:-----------:|:------------:|:-----------:|
| 实时闭环能力 | 3/10 | 10/10 | 7/10 |
| 独立可用性 | 10/10 | 3/10 | 9/10 |
| 实现成本 | 9/10 | 4/10 | 8/10 |
| T0 自适应压缩 | 2/10 | 10/10 | 6/10 |
| 经济学统一 | 5/10 | 10/10 | 8/10 |
| 质量安全网 | 6/10 | 9/10 | 8/10 |
| 维护复杂度 | 9/10 | 5/10 | 7/10 |
| 分发简易度 | 8/10 | 9/10 | 6/10 |
| **加权总分** | **52** | **60** | **59** |

### 裁决: 方案 C (桥接器) 胜出, 但吸收方案 B 的两个关键洞察

**为什么不是方案 B (深度合并)?**
方案 B 的技术优势最强(实时闭环、自适应压缩)，但违反了一个硬约束：RTK 是第三方项目，不是我们的代码。把它 fork 成 library crate 意味着承担上游同步的永久维护成本。ModelSelector 的 bash 重写为 Rust 也不是 2-3 天的事--450 行 bash 加上 EN+ZH 双语 regex、BSD sed 兼容性 workaround、shell 环境检测等，实际是 1-2 周。

**为什么不是方案 A (松耦合)?**
方案 A 太被动。bash 直接调用 sqlite3 的方案在 macOS 上可行但脆弱(sqlite3 版本差异、输出格式)。更关键的是，它放弃了最有价值的能力：**路由决策影响压缩策略**。

**为什么方案 C + B 的洞察?**
桥接器保持两个项目独立，同时通过 200 行 Rust 胶合代码解决真实工程问题(bash 读 SQLite)。从方案 B 吸收两个关键洞察：

1. **Tier-aware compression hint**: 桥接器在 rtk-stats.json 中不只写统计，还写 `suggested_filter_level` 字段。RTK 的 TOML 过滤器支持项目级 `.rtk/filters.toml`，桥接器根据当前 tier 动态生成这个文件：
   - T0 路由 -> `.rtk/filters.toml` 设为 aggressive
   - T4 路由 -> `.rtk/filters.toml` 设为 minimal
   - 这实现了方案 B 的"自适应压缩"，但不需要修改 RTK 代码

2. **Quality escalation**: 桥接器监控 tee_recovery_rate，当超过阈值时不只是告警，而是直接在 rtk-stats.json 中设置 `tier_floor_override`，MS 的 P5 修正器读取后强制最低 tier 升级。这实现了方案 B 的 "tier-aware quality gate"。

### 最终推荐架构

```
用户 prompt
    |
    v
[UserPromptSubmit hook]
    |
    v
ms-rtk-bridge (200行 Rust)
    |--- 读取 RTK tracking.db (rusqlite)
    |--- 预计算 rtk-stats.json
    |--- 根据上次 tier 生成 .rtk/filters.toml (adaptive compression)
    |--- 调用 model-selector.sh (传入 RTK stats 作为环境变量)
    |
    v
model-selector.sh (P5 读取 RTK_AVG_COMPRESSION, RTK_TIER_FLOOR 等)
    |
    v
路由决策 (T0-T4)
    |
    v
[PreToolUse hook] -> RTK (读取 .rtk/filters.toml 的压缩等级)
    |
    v
压缩后的输出 -> LLM

经济学仪表盘:
ms-rtk-bridge --stats
    |--- 读 RTK tracking.db
    |--- 读 MS 日志
    |--- 输出统一 ROI 报告
```

### 仲裁后修正 (Opus review)

**修正 1: Hook 协调是伪问题**
UserPromptSubmit(MS) 和 PreToolUse(RTK) 是不同 hook event, 天然串行不存在竞态。桥接器不需要做 hook dispatcher, 只做数据桥。砍掉 hook 协调逻辑, 从 200 行降到 ~120 行。

**修正 2: 自适应压缩需换实现方式**
RTK 没有 RTK_FILTER_LEVEL 环境变量, 压缩等级不可运行时调节。动态生成 .rtk/filters.toml 会污染 git 仓库。
替代方案: 桥接器修改 `~/.config/rtk/config.toml` 的 `[limits]` 段(grep_max_results, status_max_files 等), 间接控制输出量, 不触碰项目级文件。

**修正 3: DB 文件名是 history.db**
RTK 的 SQLite 数据库叫 `history.db` 不是 `tracking.db`。
默认路径: macOS `~/Library/Application Support/rtk/history.db`, 可通过 $RTK_DB_PATH 覆盖。

### 实施阶段 (修正后)

**Phase 1 (1天)**: 最小数据桥
- ms-rtk-bridge 读取 RTK history.db, 输出 ~/.config/model-selector/rtk-stats.json
- MS P5 读取 rtk-stats.json: avg_compression_ratio + tee_recovery_rate
- install.sh 检测 RTK, 配置 history.db 路径
- RTK 未安装时所有逻辑静默跳过

**Phase 2 (2天)**: 间接压缩控制 + 统一仪表盘
- 桥接器根据 tier 调整 ~/.config/rtk/config.toml 的 [limits] 段
- tee_recovery_rate 监控 -> tier_floor_override
- `ms-rtk-bridge --stats` 统一 ROI 报告

**Phase 3 (按需)**: 深度合并, 仅当桥接器间接性成为真正瓶颈时考虑。
