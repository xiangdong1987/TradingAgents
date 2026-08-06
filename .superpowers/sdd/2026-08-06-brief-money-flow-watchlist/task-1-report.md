# Task 1 完成报告：`get_money_flow` 资金流指标

## 改动文件清单
- `assistant/quotes.py`
  - 添加 `_clean_volume(v) -> float` 辅助函数，处理 Volume 列的 NaN/缺列（均归 0）
  - 修改 `_yf_history_ohlc()` 返回字典添加 `"volume"` 字段
  - 文件末尾追加 `get_money_flow(ticker: str, end_date: str, *, _history=_yf_history_ohlc) -> dict | None`
- `tests/test_assistant_quotes.py`
  - 追加 6 个测试用例到文件末尾（顶层）

## 测试执行

### 新测试（money_flow 相关）
```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py -q -k money_flow; echo RC=$?
```
结果：6 passed, RC=0

### 全量回归测试（含既有海龟/回测）
```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py tests/test_assistant_turtle.py tests/test_assistant_backtest.py -q; echo RC=$?
```
结果：41 passed, RC=0

## 实现细节

### `get_money_flow` 函数签名
```python
def get_money_flow(ticker: str, end_date: str, *, _history=_yf_history_ohlc) -> dict | None
```

### 返回值结构
成功时返回包含以下字段的字典：
- `volumeRatio` (float): 最后一日成交量 / 前 20 日平均成交量
- `mfi14` (float): Money Flow Index 14 日指标（0-100）
- `obvTrend` (str): OBV 近 5 日趋势，值为 "up"、"down" 或 "flat"
- `chg5dPct` (float): 5 日涨跌幅百分比

失败情景返回 `None`（不抛异常）

### 覆盖的失败场景
1. ISIN 代码（Borsa 债券/基金）：直接返回 None
2. 数据不足（< 21 根日线）：返回 None
3. 成交量全零或平均成交量 ≤ 0：返回 None
4. 网络/数据获取异常：返回 None

## 自审检查清单

- ✓ `_yf_history_ohlc` 返回字典包含 volume 字段
- ✓ `_clean_volume` 正确处理 NaN（NaN != NaN）和缺列
- ✓ `get_money_flow` 接收 ISIN 时不发起网络请求
- ✓ MFI14 计算基于 typical price 的正/负资金流占比
- ✓ OBV 趋势判定：首尾差相对于 20% 摆动区间判断走平
- ✓ 5 日涨跌幅计算：(bars[-1] - bars[-6]) / bars[-6]
- ✓ 所有数值按 brief 要求的精度 round（volumeRatio、mfi14、chg5dPct 均已 round）
- ✓ 所有测试用例按 brief 手算值验证通过
- ✓ 既有测试（海龟、回测）无回归

## 疑虑

无。所有实现细节均严格对照 brief 代码片段，测试数据手算验证一致。

---

## 修复：异常保护完整覆盖计算阶段

### 问题
初始实现的 try/except 仅保护数据获取阶段，而计算段（特别是 return 语句中的 `bars[-6]["close"]` 作除数）暴露在异常处理外。若 OHLC 数据中出现 `close==0` 的脏数据，会抛 ZeroDivisionError，违反「任何失败都返回 None，绝不抛出」的契约。

### 修复方案
将整个计算逻辑（从数据获取开始）包进单一 try/except 块，保留 ISIN 检查在 try 外作为快速路径。

### 改动
- `assistant/quotes.py`：`get_money_flow` 函数体改为把所有取数、计算、return 都放在 try 块内，catch 所有异常返回 None

### 新增测试
- `tests/test_assistant_quotes.py`：`test_money_flow_none_on_dirty_zero_close`
  - 构造 21 根日线，index [15] (倒数第6个) 的 close 设为 0
  - 验证函数返回 None 而不是抛 ZeroDivisionError

### 测试命令与输出
```bash
source .venv/bin/activate && python -m pytest tests/test_assistant_quotes.py -q; echo RC=$?
```
结果：**42 passed, RC=0**（包括新增 1 个回归测试 + 6 个原始 money_flow 测试 + 35 个既有测试）

### 提交
- Hash: `0452332`
- Message: `fix(assistant): get_money_flow 异常保护完整覆盖计算阶段`
