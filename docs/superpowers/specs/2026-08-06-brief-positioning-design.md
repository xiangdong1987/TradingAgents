# 每日简报：个股多空 + 股指期货情绪

日期：2026-08-06 ｜ 状态：已落地（2026-08-07）

## 目标

在日报（`daily_brief.py`）里补上「多空盘」维度，延续资金流的原则：Python 算好
可验证的数字，LLM 只解读。三块数据（口径已与用户对齐，均经真实探测验证）：

1. **个股做空数据**（美股，FINRA 双周更新）：空头占流通盘 %、环比趋势、回补天数
2. **个股期权多空比**（美股）：最近到期链 put/call 持仓比与成交比
3. **股指期货情绪**（指数层面）：ES=F / NQ=F 最新价与涨跌 %

明确不做：意大利个股多空（Yahoo 无数据，ENEL.MI 实测全空）、意大利股指期货
（Yahoo 无 FTSE MIB 期货源）、CFTC COT 持仓报告（周更且只有指数/商品，价值低）。
日报解读按数据真实粒度来（做空双周、P/C 为快照），不假装实时。

## 1. 数据层 — `assistant/quotes.py`

```python
def get_positioning(ticker: str, *, _ticker_factory=None) -> dict | None:
    # {"shortPctFloat": 1.39, "shortChangePct": 8.1, "shortRatioDays": 2.24,
    #  "pcOi": 0.49, "pcVol": 0.50}   —— 键都可选，至少一键才返回 dict
```

- 做空三键来自 `yf.Ticker(t).info`：
  - `shortPctFloat` = `shortPercentOfFloat` × 100（Yahoo 给小数）
  - `shortChangePct` = (`sharesShort` − `sharesShortPriorMonth`) / `sharesShortPriorMonth` × 100
  - `shortRatioDays` = `shortRatio` 原值
  - 对应源字段缺失/为 0 分母 → 对应键不写
- 期权两键来自最近到期 `option_chain`：`pcOi` = puts OI 合计 ÷ calls OI 合计、
  `pcVol` 同理用 volume；calls 合计为 0 → 该键不写；无期权链 → 两键不写
- 五键数值一律 round(2)；展示层（多空行）对百分比用 `.1f` 格式化
- **返回 None**：ISIN、`.MI` 后缀（无数据，省两次白调用）、五键全无、任何异常。
  绝不抛出。`_ticker_factory` 供测试注入假 `yf.Ticker`。

```python
def get_futures_snapshot(*, _fetch_quote=get_quote) -> list[dict]:
    # [{"name": "标普500期指", "close": 7779.75, "pctChange": 0.31}, ...]
```

- 固定两条：`ES=F` → 标普500期指、`NQ=F` → 纳指100期指
- 复用 `get_quote` 的收盘/涨跌口径；单条异常跳过；全失败返回 `[]`。绝不抛出。

## 2. 日报 — `assistant/daily_brief.py`

- 签名加 `fetch_positioning=get_positioning, fetch_futures=get_futures_snapshot`
- 数据区在「# 组合」前新增块（`fetch_futures()` 结果为空则整块写「（期指数据缺失）」）：

  ```
  # 股指期货
  标普500期指: 7779.75，+0.31%
  纳指100期指: 29834.75，+0.55%
  ```

- 每票数据块在资金流行之后加一行（键缺省就跳过对应片段，全 None 显示
  `多空: 无数据`；单票 `fetch_positioning` 抛出同样降级该票）：

  ```
  多空: 空头占流通 1.4%（环比 +8.1%），回补 2.2 天，期权P/C 持仓 0.49 / 成交 0.50
  ```

- prompt 指示更新：
  - 组合概览要求点一句隔夜期指情绪（数据缺失就不提）
  - 口径说明追加：`空头占流通盘越高、环比上升 = 看空压力增；回补天数为空头
    全部回补所需交易日；期权 P/C>1 偏空、<1 偏多；做空数据为 FINRA 双周频，
    非实时`
- 双语机制、brief 文档 schema、资金流行为全部不变。

## 3. runner 透传 — `assistant/runner.py`

`run_once` 加 `fetch_positioning=None, fetch_futures=None`，`brief_fn` 内非 None
才透传——与 `fetch_quote`/`fetch_money_flow` 完全同模式。生产 `main()` 不传参，
走真实现。

## 4. 错误处理

- `get_positioning` / `get_futures_snapshot` 内部吞掉一切异常（None / `[]`）
- 日报层面：期指块整体缺失不影响生成；单票多空失败只降级该票

## 5. 测试

- quotes：假 `_ticker_factory`（假 info + 假 option_chain）验五键数值与部分可用
  语义；.MI/ISIN 不发请求直接 None；异常 → None；期指快照单条失败跳过、全失败 `[]`
- daily_brief：prompt 含期指块与多空行；部分键渲染（只有做空没有期权）；
  降级文案；既有测试全部注入 `fetch_positioning` / `fetch_futures` 假实现隔离网络
- runner：透传链路（既有 run_once 测试补注入）

## 6. 成本

每只美股 +2 次 yfinance 调用（当前 10 只美股 ≈ 20 次）+ 期指 2 次；
`.MI`/ISIN 零额外调用。全部跑在既有日报 job 里，无新依赖。
