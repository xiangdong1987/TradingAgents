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
