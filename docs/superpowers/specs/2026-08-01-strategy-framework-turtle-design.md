# 策略框架 + 海龟策略设计

日期：2026-08-01 ｜ 状态：已确认（用户拍板：配置型、可指定单策略、手动优先、即插即用）

## 目标

用户可配置的量化策略框架：对持仓 + 自选股跑确定性规则，产出走现有 suggestions
复盘闭环的建议。海龟（完整双系统）是第一个策略插件；新增策略 = 新增一个自注册模块文件。
**手动触发是一等公民**（定时是可选配置），单次扫描零 LLM 成本。

## 用户确认的取舍

- 覆盖：持仓（退出/止损/加仓）+ 自选股（入场信号）；ISIN 债券跳过
- 规则深度：完整双系统海龟（S1 20/10 带盈利过滤器 + S2 55/20 + ½N 金字塔 + 2N 止损 + 1% 风险单元）
- 输出：复用 suggestions 集合 + App 建议卡（加 source 来源标记）
- 理由文本：纯规则中文模板，不走 LLM

## 架构

```
meta/strategies 配置 ──┐
                      ▼
jobs: strategy_scan ──▶ assistant/strategies/engine.py（编排：取数、单元账本、去重、落建议）
  {strategy?, scope?}        │
  手动排队 / scheduler        ▼
  （schedule=daily 才自动）   REGISTRY（assistant/strategies/__init__.py，模块自注册）
                              └── turtle.py  scan(ctx) -> [Signal]（纯函数）
                      ▼
suggestions{source:"turtle", meta:{...}} ──▶ App 建议卡（🐢chip）──▶ 采纳记 trade ──▶ 14 天复盘
```

## 模块与接口

### 注册表（即插即用）

`assistant/strategies/__init__.py`：

```python
@dataclass(frozen=True)
class Strategy:
    name: str            # "turtle"
    label: str           # "海龟(双系统)"
    defaults: dict       # 缺省参数
    scan: Callable[[ScanContext], list[Signal]]

REGISTRY: dict[str, Strategy] = {}
def register(s: Strategy): ...
from assistant.strategies import turtle  # noqa: E402,F401 —— import 即注册
```

新增策略 = 写一个模块末尾调 `register(...)` 的文件 + 在 `__init__.py` 加一行 import。

### 纯函数接口

```python
ScanContext: ticker, bars(list[Bar(date,high,low,close)] 升序≥90根),
             position(dict|None), units(list[Unit(entry,shares,date)]),
             portfolio_value, cash, params(defaults ⊕ 配置覆盖)
Signal: action(buy|add|trim|sell), shares(float|None), price, stop(float|None),
        reason(中文模板), meta(dict: system/n/channel等)
```

engine 负责一切副作用（yfinance 取数、从 trades 重建单元、去重、写 suggestion、
组合总值计算）；策略模块只做 bars+状态 → 信号 的纯计算，保证可单测。

### 配置 `meta/strategies`

```json
{"turtle": {"enabled": true, "schedule": "manual",
            "scope": "positions+watchlist",
            "params": {"riskPct": 1.0, "maxUnits": 4,
                       "s1": {"entry": 20, "exit": 10, "filter": true},
                       "s2": {"entry": 55, "exit": 20}}}}
```

- 文档缺失/字段缺失 → 用代码内缺省（经典海龟参数）
- `enabled+schedule=daily` 只管**定时**；手动指定策略名的 job **无视 enabled**（用户点名就跑）
- `scope` 可被 job 覆盖（"指定某个策略给当前持仓" = `{strategy:"turtle", scope:"positions"}`）

### Job 与调度

- 新 job 类型：`{type:"strategy_scan", strategy:"turtle"|null(全部 enabled), scope:null(用配置), requestedBy:"user"|"schedule"}`
- `jobs.execute_job` 加分支 → `engine.run_scan(store, job, today)`
- `scheduler.plan_scheduled_jobs`：收盘后对 `schedule=="daily"` 的策略排一条（当日去重：查当日已有同类 job）
- **手动触发路径（MVP 主路径）**：
  1. `/strategy` 技能（`.claude/skills/strategy/SKILL.md`）：排 job → watch runner ≤120s 消费 → 技能轮询新建议并汇报
  2. CLI 直跑（runner 离线时兜底）：`python -m assistant.strategies turtle [positions]`——与 runner 调的是同一个 `run_scan`，注意别与排队中的 scan job 并发（去重兜底，后果最多重复一条建议）
  3. App 按钮：二期

### 海龟规则 → 手动持仓的映射

| 概念 | 实现 |
|---|---|
| N | 20 日 Wilder ATR（`quotes.get_ohlc_history` 新增，返回 H/L/C；取 ~120 根日线） |
| 入场 | 无单元时：收盘 > 20日高(S1，受过滤器) 或 > 55日高(S2) → buy |
| S1 盈利过滤器 | 纯历史推演上一次 S1 信号先触 2N 止损（亏，可入场）还是先到 10日低退出且盈利（跳过）——经典规则本就按"上一个信号"而非实际交易，无需状态存储 |
| 风险单元 | shares = 组合总值 × riskPct% ÷ (2N)，向下取整；组合总值 = cash + Σ持仓市值（沿用 advisor 的 EUR/USD 直加简化） |
| 单元账本 | source=turtle 的建议被采纳产生的 trades（有 suggestionId 关联）重建单元；**存量持仓无 trade 记录 → 1 个种子单元 entry=avgCost**；App 外的券商操作不可见（已知失真，种子兜底） |
| ½N 金字塔 | 收盘 ≥ 最新单元 entry + ½N 且单元数 < maxUnits → add 一单元 |
| 2N 止损 | 收盘 ≤ 最新单元 entry − 2N → sell（清仓建议；MVP 不做分单元 trim） |
| 退出 | 收盘 < 10日低(S1 仓)/20日低(S2 仓) → sell；单元归属系统：入场时记进 suggestion.meta，种子单元按 S1 处理 |

信号优先级（同一 ticker 单次扫描只出最高优先级一条）：止损 > 退出 > 加仓 > 入场。

### 去重

拉一次全部 pending suggestions（现有 status+createdAt 索引），内存过滤：
同 ticker+source+action 已有 pending → 跳过。不新增 Firestore 索引。

### 建议文档（新增 2 字段，向后兼容）

```json
{ticker, action, targetWeightPct: null,
 rationale: "S1：收盘 €9.98 突破 20 日高点 €9.95。N=0.17，按 1% 风险建议买入 58 股，止损 €9.64（entry−2N）。",
 analysisId: "", source: "turtle", meta: {"system":"s1","n":0.17,"stop":9.64,"shares":58},
 status: "pending", createdAt}
```

### App 最小改动

- `Suggestion` 模型加可选 `source`（缺省 ''，老数据兼容）
- 建议卡（今日 tab + 历史）来源 chip：source=='turtle' → 「🐢 海龟」；deep-analysis 建议不变
- 其余展示不动（模板 rationale 已含全部数字）

## 测试

- `tests/test_turtle.py`：ATR/Donchian、S1 过滤器（构造赢/亏两段行情）、入场股数、
  金字塔触发、止损/退出优先级、单元重建（trades+种子）、ISIN 跳过
- `tests/test_strategy_engine.py`：fake store——配置合并、scope 解析、去重、建议落库字段、
  手动点名无视 enabled
- `tests/test_scheduler.py` 扩展：schedule=daily 才排、当日去重
- App widget 测试：建议卡显示海龟 chip
- 实测：/strategy 技能对真实持仓跑一遍（写入前打印预览）

## 分期

- **P1（本次）**：quotes OHLC + 框架(registry/engine/CLI) + turtle 完整双系统 + jobs/scheduler 接入 + 去重 + /strategy 技能 + App source chip + 全部测试
- **P2**：App 设置页调参与手动触发按钮、仪表盘 Donchian 通道可视化、EUR/USD 真实汇率、LLM 型策略插件、分单元 trim
