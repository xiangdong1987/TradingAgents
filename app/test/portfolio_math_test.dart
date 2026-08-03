import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/logic/portfolio_math.dart';
import 'package:wealth_assistant/models/models.dart';

Position _pos(String ticker, double shares, double avgCost) => Position(
      ticker: ticker,
      shares: shares,
      avgCost: avgCost,
      updatedAt: DateTime.utc(2026, 8, 1),
    );

const _fx = TickerQuote(close: 1.25, pctChange: 0.0); // 1 EUR = 1.25 USD

void main() {
  test('USD portfolio converts totals to EUR via EURUSD rate', () {
    final positions = [_pos('NVDA', 10, 150.0), _pos('AAPL', 5, 100.0)];
    const meta = PortfolioMeta(cash: 5000, currency: 'USD');
    final quotes = {
      'EURUSD=X': _fx,
      'NVDA': const TickerQuote(close: 200.75, pctChange: 2.93),
      'AAPL': const TickerQuote(close: 90.0, pctChange: -10.0),
    };

    final summary = summarize(positions, meta, quotes);

    expect(summary.cashEur, closeTo(4000.0, 1e-9)); // 5000/1.25
    expect(summary.stockValueEur, closeTo(1966.0, 1e-9)); // 2457.5/1.25
    expect(summary.costEur, closeTo(1600.0, 1e-9)); // 2000/1.25
    expect(summary.totalEur, closeTo(5966.0, 1e-9));
    expect(summary.pnlPct, closeTo(22.875, 1e-9)); // 汇率折算不改变盈亏比
  });

  test('mixed USD + Milan(EUR) portfolio sums in EUR', () {
    final positions = [_pos('NVDA', 10, 150.0), _pos('ENEL.MI', 100, 9.0)];
    const meta = PortfolioMeta(cash: 1000, currency: 'EUR'); // 现金本身是欧元
    final quotes = {
      'EURUSD=X': _fx,
      'NVDA': const TickerQuote(close: 200.75, pctChange: 2.93),
      'ENEL.MI': const TickerQuote(close: 9.84, pctChange: 0.13),
    };

    final summary = summarize(positions, meta, quotes);

    expect(summary.cashEur, 1000.0); // EUR 现金不折算
    // NVDA 2007.5 USD/1.25=1606 EUR；ENEL 100*9.84=984 EUR
    expect(summary.stockValueEur, closeTo(2590.0, 1e-9));
    expect(summary.costEur, closeTo(1200.0 + 900.0, 1e-9));
    expect(summary.pnlPct, closeTo((2590.0 - 2100.0) / 2100.0 * 100, 1e-9));
  });

  test('missing EURUSD rate nulls USD-dependent aggregates', () {
    final positions = [_pos('NVDA', 10, 150.0)];
    const meta = PortfolioMeta(cash: 1000, currency: 'USD');

    final summary = summarize(positions, meta,
        {'NVDA': const TickerQuote(close: 200.75, pctChange: 2.93)});

    expect(summary.cashEur, isNull);
    expect(summary.stockValueEur, isNull);
    expect(summary.totalEur, isNull);
    expect(summary.pnlPct, isNull);
  });

  test('pure Milan portfolio needs no rate; missing quote falls back to cost', () {
    final positions = [_pos('ENEL.MI', 100, 9.0), _pos('ISP.MI', 50, 6.0)];
    const meta = PortfolioMeta(cash: 500, currency: 'EUR');

    final summary = summarize(positions, meta,
        {'ENEL.MI': const TickerQuote(close: 9.84, pctChange: 0.13)});

    // ISP.MI 无行情按成本计：100*9.84 + 50*6 = 1284
    expect(summary.stockValueEur, closeTo(1284.0, 1e-9));
    expect(summary.costEur, closeTo(1200.0, 1e-9));
    expect(summary.totalEur, closeTo(1784.0, 1e-9));
    expect(summary.pnlPct, closeTo((1284.0 - 1200.0) / 1200.0 * 100, 1e-9));
  });

  test('empty portfolio: EUR cash passes through, zero stock value', () {
    const meta = PortfolioMeta(cash: 250, currency: 'EUR');

    final summary = summarize(const [], meta, const {});

    expect(summary.stockValueEur, 0.0);
    expect(summary.costEur, 0.0);
    expect(summary.totalEur, 250.0);
    expect(summary.pnlPct, isNull);
  });

  test('isin detection and eur classification', () {
    expect(isIsin('IT0001247391'), isTrue);
    expect(isIsin('ENEL.MI'), isFalse);
    expect(isIsin('NVDA'), isFalse);
    expect(isEurListing('IT0001247391'), isTrue);   // 意大利债券按欧元
    expect(isEurListing('US0378331005'), isFalse);  // 非 IT 前缀 ISIN 不按欧元
  });

  group('concentration', () {
    // 现金 €1000；ENEL.MI 100 股 @ €10 = €1000；MSFT 10 股 @ $200 = €1000（汇率 2.0）
    // 总值 €3000 → 每项各占 1/3
    final positions = [
      Position(ticker: 'ENEL.MI', shares: 100, avgCost: 8, updatedAt: DateTime.utc(2026)),
      Position(ticker: 'MSFT', shares: 10, avgCost: 150, updatedAt: DateTime.utc(2026)),
    ];
    const meta = PortfolioMeta(cash: 1000, currency: 'EUR');
    const quotes = {
      'ENEL.MI': TickerQuote(close: 10, pctChange: 0),
      'MSFT': TickerQuote(close: 200, pctChange: 0),
      'EURUSD=X': TickerQuote(close: 2.0, pctChange: 0),
    };

    test('weights use the EUR total including cash', () {
      final c = concentration(positions, meta, quotes)!;
      expect(c.stats, hasLength(2));
      expect(c.stats[0].weightPct, closeTo(33.33, 0.01));
      expect(c.stats[1].weightPct, closeTo(33.33, 0.01));
      expect(c.cashPct, closeTo(33.33, 0.01));
      expect(c.topPct, closeTo(33.33, 0.01));
      expect(c.top3Pct, closeTo(66.67, 0.01));
    });

    test('stats are sorted by weight descending', () {
      final big = [
        Position(ticker: 'ENEL.MI', shares: 500, avgCost: 8, updatedAt: DateTime.utc(2026)),
        Position(ticker: 'MSFT', shares: 1, avgCost: 150, updatedAt: DateTime.utc(2026)),
      ];
      final c = concentration(big, meta, quotes)!;
      expect(c.stats.first.ticker, 'ENEL.MI');
      expect(c.stats.first.weightPct, greaterThan(c.stats.last.weightPct));
    });

    test('missing fx with a USD holding yields null', () {
      const noFx = {'ENEL.MI': TickerQuote(close: 10, pctChange: 0)};
      expect(concentration(positions, meta, noFx), isNull);
    });

    test('empty portfolio yields null', () {
      expect(concentration(const [], const PortfolioMeta(cash: 0, currency: 'EUR'), quotes),
          isNull);
    });
  });

  group('realizedPnlEur', () {
    const quotes = {'EURUSD=X': TickerQuote(close: 2.0, pctChange: 0)};
    Trade sell(String ticker, double pnl) => Trade(
        id: 't', ticker: ticker, side: 'sell', shares: 1, price: 1,
        date: '2026-08-01', realizedPnl: pnl);

    test('sums EUR listings as-is and converts USD ones', () {
      // €100 + $200/2 = €200
      expect(realizedPnlEur([sell('ENEL.MI', 100), sell('MSFT', 200)], quotes),
          closeTo(200, 0.001));
    });

    test('buys contribute nothing', () {
      final buy = Trade(id: 'b', ticker: 'MSFT', side: 'buy', shares: 1,
          price: 100, date: '2026-08-01');
      expect(realizedPnlEur([buy], quotes), 0);
    });

    test('losses are negative', () {
      expect(realizedPnlEur([sell('ENEL.MI', -50)], quotes), closeTo(-50, 0.001));
    });

    test('missing fx with a USD trade yields null', () {
      expect(realizedPnlEur([sell('MSFT', 200)], const {}), isNull);
    });

    test('no trades is zero', () {
      expect(realizedPnlEur(const [], quotes), 0);
    });
  });
}
