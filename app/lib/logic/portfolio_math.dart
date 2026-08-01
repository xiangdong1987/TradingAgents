// app/lib/logic/portfolio_math.dart
/// Pure portfolio arithmetic shared by the today/portfolio tabs' overview
/// cards. No Firestore/Flutter dependency — just the same math both tabs
/// used to duplicate.
library;

import '../models/models.dart';

class PortfolioSummary {
  const PortfolioSummary({
    required this.cash,
    required this.stockValue,
    required this.cost,
    required this.pnlPct,
  });

  final double cash;
  final double stockValue;
  final double cost;
  final double? pnlPct;

  double get total => cash + stockValue;
}

/// Missing quotes fall back to cost basis for valuation; `pnlPct` is only
/// populated once at least one held ticker has a live quote (otherwise the
/// "gain" would just be measuring cost against itself).
PortfolioSummary summarize(
  List<Position> positions,
  PortfolioMeta meta,
  Map<String, TickerQuote> quotes,
) {
  double priceOf(Position p) => quotes[p.ticker]?.close ?? p.avgCost;
  final stockValue = positions.fold<double>(0, (sum, p) => sum + p.shares * priceOf(p));
  final cost = positions.fold<double>(0, (sum, p) => sum + p.shares * p.avgCost);
  final hasQuote = positions.any((p) => quotes.containsKey(p.ticker));
  final pnlPct = (cost > 0 && hasQuote) ? (stockValue - cost) / cost * 100 : null;
  return PortfolioSummary(cash: meta.cash, stockValue: stockValue, cost: cost, pnlPct: pnlPct);
}
