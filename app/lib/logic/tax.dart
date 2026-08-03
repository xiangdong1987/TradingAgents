// app/lib/logic/tax.dart
/// 税率缺省值。**每笔记录里存的是绝对税额，这里只提供新建时的预填**——
/// 券商实际扣缴多少，以流水里改过的数为准。
///
/// Python 侧 assistant/income.py 有一份同样的常量（runner 自动抓分红时用），
/// 改动要两边一起改。
library;

import 'portfolio_math.dart' show isEurListing;

/// 美国按协定对分红的预扣税率。
const taxPctUsWithholding = 15.0;

/// 意大利替代税（imposta sostitutiva）：本国分红/利息与资本利得同一税率。
const taxPctIt = 26.0;

/// 美股分红的综合税负：先被美国预扣 15%，剩下的再由意大利按 26% 征
/// → 1 − 0.85 × 0.74 = 37.1%（意大利法定口径，26% 征在扣净额上）。
/// 若券商单据是两道税直接相加（15 + 26 = 41），把这里改成 41.0。
const taxPctUsTotal = 37.1;

/// 卖出资本利得税率：意大利税务居民全球所得同一 26%。
const taxPctCapitalGains = taxPctIt;

/// 分红/利息的缺省税率：意大利标的 26%，其余（美股）37.1%。
double defaultIncomeTaxPct(String ticker) =>
    isEurListing(ticker) ? taxPctIt : taxPctUsTotal;

/// 卖出的缺省税额：只对**盈利**计税，亏损为 0（亏损用于抵扣是年度申报的事）。
double defaultSellTax(double realizedPnl) =>
    realizedPnl <= 0 ? 0 : realizedPnl * taxPctCapitalGains / 100;
