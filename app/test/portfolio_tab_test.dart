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
}
