# 买入区分资产类型：国债 + 票息自动入账

日期：2026-08-11 ｜ 状态：已确认，待实现

## 背景与目标

用户持有 BTP 国债，买入流程却只有股票一种形态（股数×价格）。国债的现实
形态：**只有投入金额，数量恒为 1，收益是按付息日历定期到账的票息**。

已探明的事实与已拍板的决策：

- Borsa Italiana 页面价格能抓但**票息元数据抓不稳**（实测两个 URL 都返回
  搜索表单页）；现有 BTP 的「行情价」45000 与成本完全相等，本身可疑。
  → **票息参数买入时填一次**（票面年利率%、付息频率、到期日——买国债时
  都知道），此后利息永久自动入账。
- **意大利国债利息税率 12.5%**（不是 26%）——新引擎直接用对税率。
- 国债估值 = 投入金额（复用刚落地的 `atCost` 全链路：按欧元成本计价、
  不拉行情、防守层、runner 全跳过）——顺带摆脱可疑的 Borsa 价格。

## 1. 数据模型

`positions/{ticker}` 债券持仓新增字段（股票持仓不写这些字段）：

```
assetType: 'bond'            // 缺省（无此字段）= 股票
couponPct: 4.0               // 票面年利率 %
payFreq: 'semiannual'        // 'annual' | 'semiannual'
maturity: '2030-03-15'       // 到期日 YYYY-MM-DD
```

债券恒有：`atCost: true`、`shares: 1`、`avgCost = 投入金额`、
层 `defensive`（atCost 推断已有）、`holdToMaturity: true`。

Dart `Position` 增加 `assetType/couponPct/payFreq/maturity`（全可空，
fromDoc 读取）；`repo` 提供把债券字段 merge 进 position 文档的写入路径
（不得覆盖 `applyTrade` 维护的 shares/avgCost）。

## 2. 买入 UI（`_BuyDialog`）

- 顶部 SegmentedButton **股票 / 国债**（key `buyAssetType`，缺省股票；
  股票模式与现状完全一致）。
- 国债模式表单：代码（ISIN 或自定义名）、**金额 €**（key `buyAmount`）、
  票面利率 %（`buyCouponPct`）、付息频率（`buyPayFreq`，年付/半年付）、
  到期日（`buyMaturity`，YYYY-MM-DD 文本框，校验格式）、买入日（沿用
  openedAt 语义，作为票息起算下限）。无价格、无股数字段。
- 保存 = `applyTrade`（buy，1 股 @ 金额 → 自动扣现金、记成交、加自选）
  + position 文档 merge 债券字段与 `atCost/holdToMaturity/layer`。
- 金额/利率/到期日缺一不可；频率缺省半年付（BTP 惯例）。

## 3. 票息引擎（Python `assistant/income.py`）

新增 `sync_bond_coupons(store, today) -> int`（返回新增行数），挂进
runner 现有的每日 income 同步档（与 `sync_dividends` 同一 marker）：

- 遍历 `assetType == 'bond'` 且三参数齐全的持仓。
- **付息日历从到期日倒推**：锚点 = maturity，按频率步进（半年付 −6 个月、
  年付 −12 个月）；日号保持与到期日一致，目标月无此日则取月末
  （如 31 → 2 月取 28/29）。
- 对每个付息日 `d`：`openedAt < d ≤ today` 且 `not has_income(f"{ticker}_{d}")`
  → 写 income：

  ```
  amount   = avgCost × couponPct/100 ÷ 次数/年
  taxPct   = 12.5（新常量 TAX_PCT_IT_GOV）
  taxAmount = amount × 12.5%
  source   = 'auto'，note = '国债票息'，creditedCash = false
  ```

- 幂等：income 文档 id `{ticker}_{d}`，与分红同一套路。历史漏付息日
  一次性补齐（openedAt 起算）。
- `openedAt` 缺失时以该券最早买入成交日兜底（复用 `opened_floor`）；
  两者都没有则跳过该券（不猜）。
- 任何单券异常只跳过该券，不影响其他券与分红同步。

**写死的简化**（spec 层面明确）：利息按投入金额近似面值计算（按面值
发行买入时零误差）；付息日严格晚于买入日才计（不做首期应计利息拆分）。

## 4. 税率常量

- Python `income.py`：`TAX_PCT_IT_GOV = 12.5`，仅票息引擎使用；
  `default_tax_pct`（分红用）不动。
- Dart `tax.dart`：加 `taxPctItGov = 12.5` 常量与注释（两端常量同步的
  既有惯例）；手工录入收入的缺省税率逻辑**不动**——国债票息的主路径是
  后端自动入账，已带对税率。

## 5. 日报与到期提醒（`daily_brief.py`）

- 债券持仓的数据块从「按成本计价资产（无行情）」升级为：

  ```
  ## {t}（持仓）
  国债 票面 4.00% 半年付 · 到期 2030-03-15 · 按成本计价
  ```

  持仓块行尾同样带 `票面 4.00%，按成本计`。非债券的 atCost 资产文案不变。
- `maturity ≤ today` 的债券：数据块追加 `【已到期，待处理本金回收】`，
  prompt 指示在「值得注意」里提醒用户把本金回收记成一笔卖出。
  系统**不自动动钱**。

## 6. 到期后的处理（人工，现有能力已覆盖）

到期兑付 = 用户在持仓里点该券 → 卖出 1 股 @ 金额（pnl=0 无税，现金
自动回账）。无需新代码，spec 记录操作路径即可。

## 7. 存量迁移

现有 BTP（IT0005696320，1 股 @ 45000）：实现完成后由控制器向用户索要
三个票息参数，直接写入 position 文档（补 `assetType/couponPct/payFreq/
maturity/atCost`），漏掉的历史票息由引擎自动补录。迁移后该券不再走
Borsa 行情。

## 不做

- 二级市场折溢价的面值/应计利息精确核算（可选「面值」字段留作扩展）
- 浮息债（CCT）、通胀挂钩债（BTP Italia 的指数化本金）——只支持固定票息
- 到期自动记卖出（违反「不自动动钱」原则）
- Dart 手工收入对话框按资产类型切默认税率（主路径是后端自动）

## 测试

- Python：付息日历倒推（半年/年付、月末夹紧 2/28、跨年）；只补
  `openedAt < d ≤ today` 区间；幂等不重复；12.5% 税额；三参数不齐/无
  openedAt 且无成交 → 跳过；单券异常隔离；runner 接线（与 sync_dividends
  同档）；日报债券行文案与到期提醒；非债券 atCost 文案不变
- Dart：模型字段 fromDoc；买入对话框切国债后字段集变化、校验、保存写入
  （trade 1 股 @ 金额 + position 债券字段 + atCost）；股票模式回归不变
- 两端全量回归全绿

## 交付

App 有改动：完成后 web 部署（单独征求同意）+ runner 重启 + 存量 BTP
迁移（问用户要参数）。
