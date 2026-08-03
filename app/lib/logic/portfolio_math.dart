// app/lib/logic/portfolio_math.dart
/// Pure portfolio arithmetic shared by the today/portfolio tabs' overview
/// cards. No Firestore/Flutter dependency.
///
/// 计价规则：美股按 USD、米兰上市（.MI）按 EUR 报价；**组合总额一律折算成
/// EUR**。汇率取日报 quotes 里的 `EURUSD=X`（1 EUR 兑多少 USD）；汇率缺失时
/// 无法折算的聚合值为 null（UI 显示 —），单股原币种展示不受影响。
library;

import '../models/models.dart';

final _isinRe = RegExp(r'^[A-Z]{2}[A-Z0-9]{9}[0-9]$');

/// 12 位 ISIN（如 IT0001247391）——单只债券按 ISIN 跟踪，行情来自 Borsa Italiana。
bool isIsin(String ticker) => _isinRe.hasMatch(ticker);

/// Borsa Italiana listings (.MI) and Italian ISINs are EUR-quoted.
bool isEurListing(String ticker) =>
    ticker.endsWith('.MI') || (ticker.startsWith('IT') && isIsin(ticker));

class PortfolioSummary {
  const PortfolioSummary({
    required this.cashEur,
    required this.stockValueEur,
    required this.costEur,
    required this.pnlPct,
  });

  final double? cashEur;
  final double? stockValueEur;
  final double? costEur;
  final double? pnlPct;

  double? get totalEur => (cashEur == null || stockValueEur == null)
      ? null
      : cashEur! + stockValueEur!;
}

/// 单笔持仓的市值与占组合权重（权重分母含现金，与总市值口径一致）。
class PositionStat {
  const PositionStat({required this.ticker, required this.valueEur, required this.weightPct});
  final String ticker;
  final double valueEur;
  final double weightPct;
}

/// 集中度：各持仓权重（降序）+ 最大单一持仓 / 前三大合计 / 现金占比。
class Concentration {
  const Concentration({required this.stats, required this.cashPct});
  final List<PositionStat> stats; // 按权重降序
  final double cashPct;

  double get topPct => stats.isEmpty ? 0 : stats.first.weightPct;
  double get top3Pct =>
      stats.take(3).fold(0.0, (sum, s) => sum + s.weightPct);
}

/// 逐笔持仓的 EUR 市值与权重。汇率缺失导致某笔无法折算时整体返回 null
/// （与 [summarize] 同样的保守口径：宁可显示 — 也不给错数）。
Concentration? concentration(
  List<Position> positions,
  PortfolioMeta meta,
  Map<String, TickerQuote> quotes,
) {
  final s = summarize(positions, meta, quotes);
  final total = s.totalEur;
  if (total == null || total <= 0) return null;

  final rate = quotes['EURUSD=X']?.close;
  double? toEur(String ticker, double native) => isEurListing(ticker)
      ? native
      : ((rate == null || rate == 0) ? null : native / rate);

  final stats = <PositionStat>[];
  for (final p in positions) {
    final priceNative = quotes[p.ticker]?.close ?? p.avgCost;
    final v = toEur(p.ticker, p.shares * priceNative);
    if (v == null) return null;
    stats.add(PositionStat(
        ticker: p.ticker, valueEur: v, weightPct: v / total * 100));
  }
  stats.sort((a, b) => b.weightPct.compareTo(a.weightPct));
  return Concentration(
      stats: stats, cashPct: (s.cashEur ?? 0) / total * 100);
}

/// 已实现盈亏合计（EUR）。每笔卖出的 `realizedPnl` 是标的原币，这里按
/// **当前**汇率折算 USD 部分——历史汇率不追溯，和市值口径保持一致；
/// 汇率缺失且存在 USD 标的时返回 null。
double? realizedPnlEur(List<Trade> trades, Map<String, TickerQuote> quotes) =>
    _sumEur(trades.map((t) => (t.ticker, t.realizedPnl)), quotes);

/// 卖出记录里的资本利得税合计（EUR）。
double? realizedTaxEur(List<Trade> trades, Map<String, TickerQuote> quotes) =>
    _sumEur(trades.map((t) => (t.ticker, t.taxAmount)), quotes);

/// 把 (标的, 原币金额) 序列按当前汇率折成 EUR 求和；null 金额跳过，
/// 需要汇率却拿不到时整体返回 null。
double? _sumEur(Iterable<(String, double?)> items, Map<String, TickerQuote> quotes) {
  final rate = quotes['EURUSD=X']?.close;
  var sum = 0.0;
  for (final (ticker, value) in items) {
    if (value == null) continue;
    if (isEurListing(ticker)) {
      sum += value;
    } else {
      if (rate == null || rate == 0) return null;
      sum += value / rate;
    }
  }
  return sum;
}

/// 累计分红/利息合计（EUR）。口径与 [realizedPnlEur] 一致：原币金额按
/// **当前**汇率折算，不追溯历史汇率。
double? incomeEur(List<Income> incomes, Map<String, TickerQuote> quotes) =>
    _sumEur(incomes.map((i) => (i.ticker, i.amount)), quotes);

/// 分红/利息的预扣税合计（EUR）。
double? incomeTaxEur(List<Income> incomes, Map<String, TickerQuote> quotes) =>
    _sumEur(incomes.map((i) => (i.ticker, i.taxAmount)), quotes);

/// 累计收益（简单加总口径）：浮动盈亏 + 已实现盈亏 + 累计分红利息。
/// 收益率的分母是**当前持仓成本**——不是资金加权，也不年化，所以它回答的是
/// 「这些钱到今天为止一共赚了多少」，不是「年化几个点」。任一项无法折算
/// （缺汇率）时整体为 null。
class ReturnSummary {
  const ReturnSummary({required this.unrealizedEur, required this.realizedEur,
      required this.incomeEur, required this.taxEur, required this.costEur});
  final double unrealizedEur;
  final double realizedEur;
  final double incomeEur;
  /// 已发生的税合计：卖出的资本利得税 + 分红预扣税。浮动盈亏还没卖，不计税。
  final double taxEur;
  final double? costEur;

  /// 税前累计收益。
  double get totalEur => unrealizedEur + realizedEur + incomeEur;

  /// 税后累计收益（浮动部分按未来卖出前不计税处理，见 taxEur 注释）。
  double get netEur => totalEur - taxEur;

  double? get totalPct =>
      (costEur == null || costEur! <= 0) ? null : totalEur / costEur! * 100;
  double? get netPct =>
      (costEur == null || costEur! <= 0) ? null : netEur / costEur! * 100;
}

ReturnSummary? cumulativeReturn(
  PortfolioSummary summary,
  List<Trade> trades,
  List<Income> incomes,
  Map<String, TickerQuote> quotes,
) {
  final stock = summary.stockValueEur;
  final cost = summary.costEur;
  final realized = realizedPnlEur(trades, quotes);
  final income = incomeEur(incomes, quotes);
  final realizedTax = realizedTaxEur(trades, quotes);
  final incomeTax = incomeTaxEur(incomes, quotes);
  if (stock == null || cost == null || realized == null || income == null ||
      realizedTax == null || incomeTax == null) {
    return null;
  }
  return ReturnSummary(unrealizedEur: stock - cost, realizedEur: realized,
      incomeEur: income, taxEur: realizedTax + incomeTax, costEur: cost);
}

/// Missing per-ticker quotes fall back to cost basis for valuation; `pnlPct`
/// is only populated once at least one held ticker has a live quote.
PortfolioSummary summarize(
  List<Position> positions,
  PortfolioMeta meta,
  Map<String, TickerQuote> quotes,
) {
  final rate = quotes['EURUSD=X']?.close; // USD per 1 EUR

  double? usdToEur(double v) => (rate == null || rate == 0) ? null : v / rate;
  double? toEur(String ticker, double native) =>
      isEurListing(ticker) ? native : usdToEur(native);

  double? stockValue = 0.0;
  double? cost = 0.0;
  var hasQuote = false;
  for (final p in positions) {
    final priceNative = quotes[p.ticker]?.close ?? p.avgCost;
    if (quotes.containsKey(p.ticker)) hasQuote = true;
    final v = toEur(p.ticker, p.shares * priceNative);
    final c = toEur(p.ticker, p.shares * p.avgCost);
    if (v == null || c == null) {
      stockValue = null;
      cost = null;
      break;
    }
    stockValue = stockValue! + v;
    cost = cost! + c;
  }

  final cashEur = meta.currency == 'EUR' ? meta.cash : usdToEur(meta.cash);
  final pnlPct = (cost != null && cost > 0 && hasQuote && stockValue != null)
      ? (stockValue - cost) / cost * 100
      : null;
  return PortfolioSummary(
      cashEur: cashEur, stockValueEur: stockValue, costEur: cost, pnlPct: pnlPct);
}
