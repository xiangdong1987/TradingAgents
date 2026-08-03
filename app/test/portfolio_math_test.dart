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

  group('incomeEur / cumulativeReturn', () {
    const quotes = {
      'ENEL.MI': TickerQuote(close: 10, pctChange: 0),
      'MSFT': TickerQuote(close: 200, pctChange: 0),
      'EURUSD=X': TickerQuote(close: 2.0, pctChange: 0),
    };
    Income inc(String ticker, double amount) => Income(
        id: 'i', ticker: ticker, date: '2026-07-15', amount: amount);

    test('EUR income counts as-is, USD income converts', () {
      // €30 + $40/2 = €50
      expect(incomeEur([inc('ENEL.MI', 30), inc('MSFT', 40)], quotes),
          closeTo(50, 0.001));
    });

    test('missing fx with USD income yields null', () {
      expect(incomeEur([inc('MSFT', 40)], const {}), isNull);
    });

    test('cumulative return sums unrealized, realized and income', () {
      // 持仓 ENEL.MI 100 股 @成本 8 现价 10 → 浮动 +€200
      final positions = [
        Position(ticker: 'ENEL.MI', shares: 100, avgCost: 8, updatedAt: DateTime.utc(2026)),
      ];
      const meta = PortfolioMeta(cash: 0, currency: 'EUR');
      final summary = summarize(positions, meta, quotes);
      final trades = [
        Trade(id: 't', ticker: 'ENEL.MI', side: 'sell', shares: 1, price: 1,
            date: '2026-07-01', realizedPnl: 50),
      ];
      final r = cumulativeReturn(summary, trades, [inc('ENEL.MI', 30)], quotes)!;
      expect(r.unrealizedEur, closeTo(200, 0.001));
      expect(r.realizedEur, closeTo(50, 0.001));
      expect(r.incomeEur, closeTo(30, 0.001));
      expect(r.totalEur, closeTo(280, 0.001));
      expect(r.costEur, closeTo(800, 0.001));           // 100 × 8
      expect(r.totalPct, closeTo(35, 0.01));            // 280 / 800
    });

    test('no cost basis leaves the percentage null but keeps the amount', () {
      const empty = PortfolioSummary(
          cashEur: 0, stockValueEur: 0, costEur: 0, pnlPct: null);
      final r = cumulativeReturn(empty, const [], [inc('ENEL.MI', 30)], quotes)!;
      expect(r.totalEur, closeTo(30, 0.001));
      expect(r.totalPct, isNull);
    });

    test('unconvertible fx makes the whole summary null', () {
      final positions = [
        Position(ticker: 'MSFT', shares: 1, avgCost: 100, updatedAt: DateTime.utc(2026)),
      ];
      const meta = PortfolioMeta(cash: 0, currency: 'EUR');
      const noFx = {'MSFT': TickerQuote(close: 200, pctChange: 0)};
      final summary = summarize(positions, meta, noFx);
      expect(cumulativeReturn(summary, const [], const [], noFx), isNull);
    });
  });

  group('累计收益的税前/税后', () {
    const quotes = {
      'ENEL.MI': TickerQuote(close: 10, pctChange: 0),
      'MSFT': TickerQuote(close: 200, pctChange: 0),
      'EURUSD=X': TickerQuote(close: 2.0, pctChange: 0),
    };

    test('tax sums across sells and income, net subtracts it', () {
      final positions = [
        Position(ticker: 'ENEL.MI', shares: 100, avgCost: 8, updatedAt: DateTime.utc(2026)),
      ];
      const meta = PortfolioMeta(cash: 0, currency: 'EUR');
      final summary = summarize(positions, meta, quotes);
      final trades = [
        Trade(id: 't', ticker: 'ENEL.MI', side: 'sell', shares: 1, price: 1,
            date: '2026-07-01', realizedPnl: 100, taxAmount: 26),
      ];
      final incomes = [
        const Income(id: 'i', ticker: 'ENEL.MI', date: '2026-07-15',
            amount: 100, taxAmount: 26),
      ];
      final r = cumulativeReturn(summary, trades, incomes, quotes)!;
      expect(r.totalEur, closeTo(400, 0.001));     // 浮动 200 + 已实现 100 + 分红 100
      expect(r.taxEur, closeTo(52, 0.001));        // 26 + 26
      expect(r.netEur, closeTo(348, 0.001));
      expect(r.totalPct, closeTo(50, 0.01));       // 400 / 800
      expect(r.netPct, closeTo(43.5, 0.01));       // 348 / 800
    });

    test('USD taxes convert at the current rate', () {
      final incomes = [
        const Income(id: 'i', ticker: 'MSFT', date: '2026-07-15',
            amount: 100, taxAmount: 37.1),
      ];
      expect(incomeTaxEur(incomes, quotes), closeTo(18.55, 0.001));   // 37.1 / 2
      expect(realizedTaxEur([
        Trade(id: 't', ticker: 'MSFT', side: 'sell', shares: 1, price: 1,
            date: '2026-07-01', realizedPnl: 100, taxAmount: 26),
      ], quotes), closeTo(13, 0.001));
    });

    test('no tax recorded means net equals gross', () {
      const summary = PortfolioSummary(
          cashEur: 0, stockValueEur: 100, costEur: 100, pnlPct: 0);
      final r = cumulativeReturn(summary, const [], [
        const Income(id: 'i', ticker: 'ENEL.MI', date: 'd', amount: 50),
      ], quotes)!;
      expect(r.taxEur, 0);
      expect(r.netEur, r.totalEur);
    });
  });
}
