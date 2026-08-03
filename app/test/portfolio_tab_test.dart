import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/portfolio_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: PortfolioTab())),
    );

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('positions').doc('NVDA').set({
    'ticker': 'NVDA', 'shares': 10, 'avgCost': 150.0,
    'updatedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('meta').doc('portfolio').set({'cash': 5000.0, 'currency': 'USD'});
  await db.collection('briefs').doc('2026-08-01').set({
    'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['NVDA'],
    'createdAt': '2026-08-01T00:00:00+00:00',
    'quotes': {'NVDA': {'close': 200.75, 'pctChange': 2.93}},
  });
}

// 两只持仓，且各自涨跌方向相反，令组合总浮动盈亏 % 必然不同于任意单一持仓的盈亏 %——
// 避免 `find.textContaining` 因数值巧合命中总览与持仓行两处而产生误判。
Future<void> _seedOverview(FakeFirebaseFirestore db) async {
  await db.collection('positions').doc('NVDA').set({
    'ticker': 'NVDA', 'shares': 10, 'avgCost': 150.0,
    'updatedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('positions').doc('AAPL').set({
    'ticker': 'AAPL', 'shares': 5, 'avgCost': 100.0,
    'updatedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('meta').doc('portfolio').set({'cash': 5000.0, 'currency': 'USD'});
  await db.collection('briefs').doc('2026-08-01').set({
    'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['NVDA', 'AAPL'],
    'createdAt': '2026-08-01T00:00:00+00:00',
    'quotes': {
      'EURUSD=X': {'close': 1.25, 'pctChange': 0.0},
      'NVDA': {'close': 200.75, 'pctChange': 2.93},
      'AAPL': {'close': 90.0, 'pctChange': -10.0},
    },
  });
}

void main() {
  testWidgets('overview shows cash, market value and pnl from quotes', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seedOverview(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    // 汇率 1.25：现金 5000USD→€4000；股票市值 2457.50USD→€1966；
    // 总市值 €5966.00；总浮动盈亏 = (2457.5-2000)/2000 = +22.88%（折算不变），
    // 与 NVDA 自身 +33.83% 、AAPL 自身 -10.00% 均不同，可唯一定位总览行文本。
    expect(find.textContaining('€4,000.00'), findsOneWidget);    // 现金（欧元）
    expect(find.textContaining('€5,966.00'), findsOneWidget);    // 总市值（欧元）
    expect(find.textContaining('22.88'), findsOneWidget);        // 总浮动盈亏
    expect(find.textContaining('NVDA'), findsWidgets);
    expect(find.textContaining('AAPL'), findsWidgets);
  });

  testWidgets('edit cash via dialog', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('cashCard')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cashField')), '8888');
    await tester.tap(find.byKey(const Key('cashSave')));
    await tester.pumpAndSettle();
    expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 8888.0);
  });

  testWidgets('add position via FAB dialog', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('暂无持仓'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('posTicker')), 'aapl');
    await tester.enterText(find.byKey(const Key('posShares')), '5');
    await tester.enterText(find.byKey(const Key('posAvgCost')), '180.5');
    await tester.tap(find.byKey(const Key('posSave')));
    await tester.pumpAndSettle();
    final doc = (await db.collection('positions').doc('AAPL').get()).data()!;
    expect(doc['shares'], 5.0);
    expect(doc['avgCost'], 180.5);
  });

  testWidgets('edit and delete existing position', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('NVDA').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('posShares')), '20');
    await tester.tap(find.byKey(const Key('posSave')));
    await tester.pumpAndSettle();
    expect((await db.collection('positions').doc('NVDA').get()).data()!['shares'], 20.0);
    await tester.tap(find.textContaining('NVDA').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('posDelete')));
    await tester.pumpAndSettle();
    // Delete now opens a confirmation dialog before doing anything destructive.
    expect(find.textContaining('删除 NVDA 持仓'), findsOneWidget);
    expect((await db.collection('positions').doc('NVDA').get()).exists, isTrue);
    await tester.tap(find.byKey(const Key('posDeleteConfirm')));
    await tester.pumpAndSettle();
    expect((await db.collection('positions').doc('NVDA').get()).exists, isFalse);
    expect(find.textContaining('已删除 NVDA'), findsOneWidget);
  });

  testWidgets('cancelling the delete confirmation keeps the position', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('NVDA').first);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('posDelete')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect((await db.collection('positions').doc('NVDA').get()).exists, isTrue);
    // The edit dialog itself should still be open (only the confirm closed).
    expect(find.byKey(const Key('posSave')), findsOneWidget);
  });

  testWidgets('edit dialog prefills fractional shares/avgCost losslessly', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('positions').doc('NVDA').set({
      'ticker': 'NVDA', 'shares': 10.5, 'avgCost': 150.25,
      'updatedAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('NVDA').first);
    await tester.pumpAndSettle();
    expect(find.text('10.5'), findsOneWidget);
    expect(find.text('150.25'), findsOneWidget);
    await tester.tap(find.byKey(const Key('posSave')));
    await tester.pumpAndSettle();
    final doc = (await db.collection('positions').doc('NVDA').get()).data()!;
    expect(doc['shares'], 10.5);
    expect(doc['avgCost'], 150.25);
  });

  group('卖出与统计', () {
    // NVDA 10 股 @成本 150，现价 200.75；现金 5000 USD（_seed 无汇率 → EUR 聚合为 null）
    Future<void> seedEur(FakeFirebaseFirestore db) async {
      await db.collection('positions').doc('ENEL.MI').set({
        'ticker': 'ENEL.MI', 'shares': 100, 'avgCost': 8.0,
        'updatedAt': '2026-08-01T00:00:00+00:00',
      });
      await db.collection('meta').doc('portfolio').set({'cash': 1000.0, 'currency': 'EUR'});
      await db.collection('briefs').doc('2026-08-01').set({
        'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['ENEL.MI'],
        'createdAt': '2026-08-01T00:00:00+00:00',
        'quotes': {
          'ENEL.MI': {'close': 10.0, 'pctChange': 1.0},
          'EURUSD=X': {'close': 1.1, 'pctChange': 0.0},
        },
      });
    }

    testWidgets('concentration card shows weights and the position row shows its %',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur(db);   // 持仓 €1000 / 现金 €1000 → 各 50%
      await tester.pumpWidget(_wrap(db));
      await tester.pumpAndSettle();
      expect(find.text('集中度'), findsOneWidget);
      expect(find.textContaining('最大 50.0%'), findsOneWidget);
      expect(find.textContaining('现金 50.0%'), findsOneWidget);
      expect(find.textContaining('50.0%'), findsWidgets);   // 持仓行的权重
    });

    testWidgets('concentration bar segments have real height (not collapsed)',
        (tester) async {
      // 回归：无子节点的 ColoredBox 在松高度约束下会算出 0 高，整条色带消失。
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await tester.pumpWidget(_wrap(db));
      await tester.pumpAndSettle();
      final segs = find.descendant(
          of: find.byType(ClipRRect), matching: find.byType(ColoredBox));
      expect(segs, findsNWidgets(2));   // 一段持仓 + 一段现金
      for (final e in segs.evaluate()) {
        final size = (e.renderObject as RenderBox).size;
        expect(size.height, 8);
        expect(size.width, greaterThan(0));
      }
    });

    testWidgets('selling from the position dialog updates position, cash and trades',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await tester.pumpWidget(_wrap(db));
      await tester.pumpAndSettle();

      await tester.tap(find.text('ENEL.MI'));                 // 打开编辑框
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('posSell')));     // 转到卖出框
      await tester.pumpAndSettle();

      // 股数缺省全部持仓、价格缺省当前行情
      expect(find.text('100'), findsWidgets);
      expect(find.text('10.00'), findsWidgets);

      await tester.enterText(find.byKey(const Key('sellShares')), '40');
      await tester.tap(find.byKey(const Key('sellConfirm')));
      await tester.pumpAndSettle();

      final pos = (await db.collection('positions').doc('ENEL.MI').get()).data()!;
      expect(pos['shares'], 60);
      expect(pos['avgCost'], 8.0);
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'],
          1000 + 400);
      final tr = (await db.collection('trades').get()).docs.single.data();
      expect(tr['side'], 'sell');
      expect(tr['realizedPnl'], 80.0);        // (10 - 8) * 40
    });

    testWidgets('realized pnl from past sells shows in the overview', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await db.collection('trades').add({
        'ticker': 'ENEL.MI', 'side': 'sell', 'shares': 10.0, 'price': 12.0,
        'date': '2026-07-20', 'realizedPnl': 40.0, 'avgCostAtTrade': 8.0,
      });
      await tester.pumpWidget(_wrap(db));
      await tester.pumpAndSettle();
      expect(find.text('已实现盈亏'), findsOneWidget);
      expect(find.text('€40.00'), findsOneWidget);
    });

    testWidgets('trade history entry is present and counts trades', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await db.collection('trades').add({
        'ticker': 'ENEL.MI', 'side': 'buy', 'shares': 10.0, 'price': 8.0,
        'date': '2026-07-01',
      });
      await tester.pumpWidget(_wrap(db));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('tradeHistoryEntry')), findsOneWidget);
      expect(find.text('交易记录'), findsOneWidget);
    });
  });
}
