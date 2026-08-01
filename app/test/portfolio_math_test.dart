import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/logic/portfolio_math.dart';
import 'package:wealth_assistant/models/models.dart';

Position _pos(String ticker, double shares, double avgCost) => Position(
      ticker: ticker,
      shares: shares,
      avgCost: avgCost,
      updatedAt: DateTime.utc(2026, 8, 1),
    );

void main() {
  test('mixed-quote two-position portfolio computes the 22.88% pnl case', () {
    final positions = [_pos('NVDA', 10, 150.0), _pos('AAPL', 5, 100.0)];
    const meta = PortfolioMeta(cash: 5000, currency: 'USD');
    final quotes = {
      'NVDA': const TickerQuote(close: 200.75, pctChange: 2.93),
      'AAPL': const TickerQuote(close: 90.0, pctChange: -10.0),
    };

    final summary = summarize(positions, meta, quotes);

    expect(summary.cash, 5000.0);
    expect(summary.stockValue, closeTo(2457.5, 1e-9)); // 10*200.75 + 5*90
    expect(summary.cost, 2000.0); // 10*150 + 5*100
    expect(summary.total, closeTo(7457.5, 1e-9));
    expect(summary.pnlPct, closeTo(22.875, 1e-9)); // (2457.5-2000)/2000*100
  });

  test('no quotes for any held ticker leaves pnlPct null (falls back to cost)', () {
    final positions = [_pos('NVDA', 10, 150.0)];
    const meta = PortfolioMeta(cash: 1000, currency: 'USD');

    final summary = summarize(positions, meta, const {});

    expect(summary.stockValue, 1500.0); // no quote -> priced at avgCost
    expect(summary.total, 2500.0);
    expect(summary.pnlPct, isNull);
  });

  test('empty portfolio has zero values and null pnlPct', () {
    const meta = PortfolioMeta(cash: 250, currency: 'USD');

    final summary = summarize(const [], meta, const {});

    expect(summary.stockValue, 0.0);
    expect(summary.cost, 0.0);
    expect(summary.total, 250.0);
    expect(summary.pnlPct, isNull);
  });
}
