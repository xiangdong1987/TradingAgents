import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/logic/policy.dart';
import 'package:wealth_assistant/models/models.dart';

Position pos(String ticker, double shares, double cost,
        {String? layer, bool? htm}) =>
    Position(ticker: ticker, shares: shares, avgCost: cost,
        updatedAt: DateTime.utc(2026), layer: layer, holdToMaturity: htm);

const quotes = {
  'ENEL.MI': TickerQuote(close: 10, pctChange: 0),
  'VUAA.MI': TickerQuote(close: 100, pctChange: 0),
  'IT0005696320': TickerQuote(close: 100, pctChange: 0),
  'MSFT': TickerQuote(close: 250, pctChange: 0),
  'EURUSD=X': TickerQuote(close: 2.0, pctChange: 0),
};

void main() {
  group('PolicyConfig.fromMap', () {
    test('empty map keeps the code defaults', () {
      const def = PolicyConfig();
      final p = PolicyConfig.fromMap(null);
      expect(p.cashFloorPct, def.cashFloorPct);
      expect(p.maxSingleStockPct, 8);
      expect(p.bands[layerCore]!.lo, 10);
    });

    test('overrides are applied and nested bands merge', () {
      final p = PolicyConfig.fromMap({
        'cashFloorPct': 10,
        'maxSingleStockPct': 6,
        'layers': {'core': [20, 40]},
        'layerMap': {'VUAA.MI': 'core'},
        'holdToMaturity': ['IT0005696320'],
        'usdLookthrough': {'VUAA.MI': 100},
      });
      expect(p.cashFloorPct, 10);
      expect(p.maxSingleStockPct, 6);
      expect(p.bands[layerCore]!.hi, 40);
      expect(p.bands[layerSatellite]!.hi, 15);   // 未覆盖的保留缺省
      expect(p.layerMap['VUAA.MI'], 'core');
      expect(p.holdToMaturity.contains('IT0005696320'), isTrue);
      expect(p.usdPctOf('VUAA.MI'), 100);
    });

    test('int values from Firestore are coerced to double', () {
      final p = PolicyConfig.fromMap({'maxSatellitePct': 20});
      expect(p.maxSatellitePct, 20.0);
    });
  });

  group('layerOf', () {
    final p = PolicyConfig.fromMap({'layerMap': {'VUAA.MI': 'core'}});

    test('position field wins over the map and the fallback', () {
      expect(p.layerOf('VUAA.MI', pos('VUAA.MI', 1, 1, layer: 'satellite')),
          layerSatellite);
    });
    test('layerMap comes next', () {
      expect(p.layerOf('VUAA.MI'), layerCore);
    });
    test('ISIN falls back to defensive, others to satellite', () {
      expect(p.layerOf('IT0005696320'), layerDefensive);
      expect(p.layerOf('MSFT'), layerSatellite);
    });
    test('an unknown layer string is ignored', () {
      expect(p.layerOf('MSFT', pos('MSFT', 1, 1, layer: 'bogus')), layerSatellite);
    });
  });

  group('usdPctOf mirrors the economic look-through', () {
    final p = PolicyConfig.fromMap({'usdLookthrough': {'VUAA.MI': 100}});
    test('EUR-listed US index still counts as USD exposure', () {
      expect(p.usdPctOf('VUAA.MI'), 100);
    });
    test('plain EUR and USD listings', () {
      expect(p.usdPctOf('ENEL.MI'), 0);
      expect(p.usdPctOf('MSFT'), 100);
    });
  });

  group('layerBreakdown', () {
    // ENEL €4000(卫星) + VUAA €2000(核心) + BTP €1000(防守) + MSFT $2000→€1000(卫星)
    // + 现金 €2000 = 总 €10000
    final positions = [
      pos('ENEL.MI', 400, 9),
      pos('VUAA.MI', 20, 90),
      pos('IT0005696320', 10, 100),
      pos('MSFT', 8, 200),
    ];
    const meta = PortfolioMeta(cash: 2000, currency: 'EUR');
    final config = PolicyConfig.fromMap({
      'layerMap': {'VUAA.MI': 'core'},
      'usdLookthrough': {'VUAA.MI': 100},
    });

    test('groups by layer with cash in the denominator', () {
      final b = layerBreakdown(positions, meta, quotes, config)!;
      expect(b.statOf(layerSatellite)!.pct, closeTo(50, 0.01));   // 4000+1000
      expect(b.statOf(layerCore)!.pct, closeTo(20, 0.01));
      expect(b.statOf(layerDefensive)!.pct, closeTo(10, 0.01));
      expect(b.cashPct, closeTo(20, 0.01));
    });

    test('flags breaches against the target bands', () {
      final b = layerBreakdown(positions, meta, quotes, config)!;
      expect(b.statOf(layerSatellite)!.overCap, isTrue);     // 50% > 15%
      expect(b.statOf(layerCore)!.breached, isFalse);        // 20% 落在 10-25%
      expect(b.statOf(layerDefensive)!.underFloor, isTrue);  // 10% < 60%
    });

    test('usd exposure is economic, not currency-of-listing', () {
      final b = layerBreakdown(positions, meta, quotes, config)!;
      // VUAA €2000（欧元计价但底层美股）+ MSFT €1000 = €3000 → 30%
      expect(b.usdPct, closeTo(30, 0.01));
      expect(b.usdOverCap, isTrue);                          // 30% > 25%
    });

    test('cash floor breach is flagged', () {
      final b = layerBreakdown(positions,
          const PortfolioMeta(cash: 0, currency: 'EUR'), quotes, config)!;
      expect(b.cashBelowFloor, isTrue);
      final ok = layerBreakdown(positions, meta, quotes, config)!;
      expect(ok.cashBelowFloor, isFalse);                    // 20% ≥ 5%
    });

    test('null when fx is missing but a USD holding exists', () {
      const noFx = {'MSFT': TickerQuote(close: 250, pctChange: 0)};
      expect(layerBreakdown([pos('MSFT', 8, 200)], meta, noFx, config), isNull);
    });

    test('null on an empty portfolio', () {
      expect(layerBreakdown(const [],
          const PortfolioMeta(cash: 0, currency: 'EUR'), quotes, config), isNull);
    });
  });
}
