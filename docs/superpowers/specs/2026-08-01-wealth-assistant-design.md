# 理财助手（Wealth Assistant）设计文档

日期：2026-08-01
状态：已与用户逐节确认

## 1. 目标与范围

在 TradingAgents 多 agent 分析引擎之上，构建一套**单用户**理财助手：

- 维护持仓与自选股（美股，App 手动录入）
- 每个交易日生成自选股**轻量日报**
- 定期（每周）或手动触发对个股做**完整多 agent 深度分析**，并结合当前持仓产出**操作建议**（含目标仓位）
- 建议支持**采纳/忽略跟踪**与**事后复盘**，复盘结果喂给引擎现有的 `reflect_and_remember` 记忆机制
- 客户端为 Flutter，**Android 优先验证 + macOS 桌面**，同一套代码

明确不做（YAGNI）：多用户/商业化、A 股/港股数据源、券商 API 对接、FCM/APNs 推送、实时行情、K 线图、模拟盘、iOS（以后加是配置活）。

所有建议仅为软件产出的分析展示，**下单永远由用户人工在券商完成**。

## 2. 总体架构（方案 A：Firestore 为中心，无自建服务）

```
┌─────────────┐     读写      ┌───────────┐     读写      ┌──────────────────┐
│   Flutter    │ ◄──────────► │ Firestore │ ◄──────────► │  Mac: assistant   │
│ Android/macOS│   实时监听    │  (数据中心) │   job 队列    │  runner (launchd) │
└─────────────┘              └───────────┘              └──────────────────┘
                                                                │ import
                                                         ┌──────▼──────┐
                                                         │tradingagents│ 现有引擎，不改核心
                                                         └─────────────┘
```

- Flutter 直连 Firestore：读日报/分析/建议，写持仓/自选/采纳标记/手动 job
- Mac 上的 Python runner 由 launchd 每 15 分钟拉起一次，跑完即退，无常驻进程
- **定时任务与手动触发共用一条 `jobs` 队列**：App 点"立即深度分析" = 写一条 job 文档；runner 醒来先领 job，再补定时任务。Mac 睡过头，下次醒来自动补跑
- 无 FCM 推送：客户端靠 Firestore snapshot 实时监听，打开 App 即最新数据

### 目录结构（本仓 monorepo，现有代码只加不改）

```
TradingAgents/
├── tradingagents/        # 现有引擎
├── assistant/            # 新增：Python runner
│   ├── runner.py         #   入口，launchd 每 15 分钟唤醒
│   ├── jobs.py           #   job 队列领取与执行
│   ├── daily_brief.py    #   轻量日报（单次 LLM 调用）
│   ├── deep_analysis.py  #   封装 propagate()，产出结构化报告
│   ├── advisor.py        #   结合持仓生成操作建议（目标仓位）
│   ├── review.py         #   建议复盘，接 reflect_and_remember
│   └── store.py          #   Firestore 读写层（可注入假实现供测试）
├── app/                  # 新增：Flutter（Android + macOS）
└── scripts/assistant.plist  # launchd 配置
```

## 3. Firestore 数据模型

单用户，顶层集合，安全规则锁定唯一 UID。

```
watchlist/{ticker}          自选股
  { ticker, note, addedAt, deepFreq: "weekly"|"manual" }

positions/{ticker}          持仓（App 手动录入维护）
  { ticker, shares, avgCost, updatedAt }
meta/portfolio              组合级信息
  { cash, currency: "USD" }

trades/{autoId}             交易流水（可选记录，用于复盘）
  { ticker, side: "buy"|"sell", shares, price, date, suggestionId? }

briefs/{YYYY-MM-DD}         每日轻量日报（文档 ID=日期，天然幂等）
  { date, markdownZh, tickers: [...], createdAt }

analyses/{autoId}           深度分析
  { ticker, tradeDate, decision, sections: {market, news, sentiment,
    fundamentals, debate, risk}, createdAt }

suggestions/{autoId}        操作建议
  { ticker, action: "buy"|"add"|"trim"|"sell"|"hold",
    targetWeightPct?, rationale, analysisId,
    status: "pending"|"accepted"|"dismissed",
    createdAt, resolvedAt?, reviewNote?, outcomePct? }

jobs/{autoId}               任务队列
  { type: "daily_brief"|"deep_analysis", ticker?,
    status: "queued"|"running"|"done"|"failed",
    requestedBy: "schedule"|"user", error?, createdAt, finishedAt? }
```

要点：

- **持仓 = positions 直接可编辑**；trades 流水为可选补充（记了才能精确复盘），不强制逐笔录入
- **建议闭环**：`suggestions.status` 由用户在 App 里置为 accepted/dismissed；采纳时可关联一笔 trade；`review.py` 在建议满 14 天后拉行情算 `outcomePct` 写回，并调 `reflect_and_remember`
- **日报文档 ID 用日期**：runner 判断"今天生成过没"查一个 doc 即可，重跑即覆盖
- 深度分析正文为引擎现有 Markdown 各节，直接存 Firestore（单文档 1MB 上限，报告通常几十 KB）

## 4. Runner 调度与分析流水线

每次唤醒按顺序执行：

```
1. 领 jobs        查 status=="queued"，标记 running 后逐个执行
                  （单机单进程无并发竞争；上次未跑完时 launchd 不重复拉起）

2. 补定时任务      交易日 且 美东16:30后 且 briefs/{今天} 不存在
                    → 自建 daily_brief job 并执行
                  周五收盘后 且 deepFreq=="weekly" 的自选股本周未分析
                    → 逐只自建 deep_analysis job

3. 复盘           已采纳/已忽略且满 14 天未复盘的 suggestion
                    → 拉行情算 outcomePct → 写回 → reflect_and_remember
```

交易日判断复用现有行情接口（拉不到当日 K 线即视为休市），不引入新依赖。

### daily_brief（轻量，每天 1 次 LLM 调用）

- 输入：watchlist ∪ positions 全部 ticker 的当日 OHLCV、涨跌幅、近 24h 头条新闻（复用现有 `dataflows`），加上持仓浮动盈亏
- 单次 `quick_think_llm` 调用，产出中文 Markdown：组合概览 → 逐股一句话点评 → 异动提示（可建议触发深度分析）
- 写入 `briefs/{date}`；成本每天几美分量级

### deep_analysis（重量，每周/手动）

- 调 `propagate(ticker, today)`，各节报告 + decision 写入 `analyses`
- **advisor.py** 追加一步：以 decision + 当前持仓/现金 + 现价为输入，再做一次 LLM 调用，把 BUY/SELL/HOLD 翻译成具体建议（action、targetWeightPct、rationale），写入 `suggestions`（status=pending）
- 引擎给 HOLD 且用户无持仓时不生成建议，避免噪音

### 错误处理

- job 失败：`status="failed"` + error 写回，App 可见；**不自动重试**（避免烧钱死循环），可在 App 手动重新排队
- runner 顶层 try/except，单只股失败不影响其余任务
- LLM 重试沿用现有 `llm_max_retries`
- 僵尸清理：发现 `running` 超 2 小时的 job 视为进程被杀，标记 failed

## 5. Flutter 客户端

技术栈：Flutter 3.x、`cloud_firestore`/`firebase_auth`/`firebase_core`、Riverpod、`flutter_markdown`。

页面（底部 4 tab）：

```
今日   最新日报 + pending 建议卡片；卡片上 [采纳][忽略]，采纳可顺手录成交
自选   watchlist 列表（现价/涨跌来自日报数据，非实时）；
       每只股 [立即深度分析] → 写 job；点进看历史 analyses
持仓   positions + 现金，浮动盈亏概览；增删改持仓；可选记录 trades
历史   analyses / suggestions 归档，复盘 outcomePct 一目了然
```

全部列表用 Firestore snapshot 监听——runner 写完，界面几秒内自动刷新；job 状态（排队/运行/失败）实时可见。

## 6. 安全

- 用户端：email/密码固定账号（Firebase 控制台手工创建，不开放注册），安全规则一条：`request.auth.uid == "<用户UID>"` 才可读写
- Runner 端：service account 密钥（`firebase-admin`），密钥文件放 `~/.tradingagents/`，不进仓库

## 7. 测试策略

- `assistant/`：pytest；`store.py` 定义接口并提供内存假实现注入，重点测调度判断（何时生成日报/周报、幂等、僵尸 job 清理）与 advisor 建议生成；LLM 全 mock
- Flutter：model 序列化测试 + 关键 widget 测试，不追求覆盖率
- 现有 `tests/` 全部保持通过

## 8. 分期交付

1. **一期（本设计范围）**：assistant runner + Firestore 数据层 + Flutter Android/macOS 四页面
2. 二期候选（不在本设计内）：A 股/港股数据源、券商 API 同步持仓、iOS、模拟盘对比、云端迁移（Cloud Run Jobs，Dockerfile 已具备）
