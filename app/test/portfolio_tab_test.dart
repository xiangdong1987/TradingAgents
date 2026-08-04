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

/// 持仓页在真机上是可滚动的一长条；默认 800x600 测试视口只会构建首屏，
/// 底部的持仓行 / 交易记录入口根本不进树，`find` 就会假阴性。
/// 这里把视口拉高（宽度保持 800，不影响换行与排版断言），让整页一次性建完。
Future<void> _pump(WidgetTester tester, FakeFirebaseFirestore db) async {
  tester.view.physicalSize = const Size(800, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_wrap(db));
  await tester.pumpAndSettle();
}

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
    await _pump(tester, db);
    // 汇率 1.25：现金 5000USD→€4000；股票市值 2457.50USD→€1966；
    // 总市值 €5966.00；总浮动盈亏 = (2457.5-2000)/2000 = +22.88%（折算不变），
    // 与 NVDA 自身 +33.83% 、AAPL 自身 -10.00% 均不同，可唯一定位总览行文本。
    expect(find.textContaining('€4,000.00'), findsOneWidget);    // 现金（欧元）
    expect(find.textContaining('€5,966.00'), findsOneWidget);    // 总市值（欧元）
    // 收益卡在「无卖出、无分红」时累计收益率与浮动盈亏 % 相同，会出现两处；
    // 这里收窄到概览卡子树内，断言仍然唯一。
    expect(
        find.descendant(
            of: find.byKey(const Key('cashCard')),
            matching: find.textContaining('22.88')),
        findsOneWidget);                                             // 总浮动盈亏
    expect(find.textContaining('NVDA'), findsWidgets);
    expect(find.textContaining('AAPL'), findsWidgets);
  });

  testWidgets('edit cash via dialog', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await _pump(tester, db);
    await tester.tap(find.byKey(const Key('cashCard')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('cashField')), '8888');
    await tester.tap(find.byKey(const Key('cashSave')));
    await tester.pumpAndSettle();
    expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 8888.0);
  });

  testWidgets('add position via FAB dialog', (tester) async {
    final db = FakeFirebaseFirestore();
    await _pump(tester, db);
    expect(find.text('暂无持仓'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    // FAB 现在先弹三选一（买入记成交 / 录入已有持仓 / 记分红），选录入
    await tester.tap(find.byKey(const Key('fabEnter')));
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
    await _pump(tester, db);
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
    await _pump(tester, db);
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
    await _pump(tester, db);
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
      await _pump(tester, db);
      expect(find.text('集中度'), findsOneWidget);
      expect(find.textContaining('最大 50.0%'), findsOneWidget);   // 汇总行
      // 图例：每段色带都能对上是哪只（持仓一项 + 现金一项）
      expect(find.text('ENEL.MI 50.0%'), findsOneWidget);
      expect(find.text('现金 50.0%'), findsOneWidget);
      expect(find.textContaining('50.0%'), findsWidgets);   // 持仓行的权重
    });

    testWidgets('concentration bar segments have real height (not collapsed)',
        (tester) async {
      // 回归：无子节点的 ColoredBox 在松高度约束下会算出 0 高，整条色带消失。
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await _pump(tester, db);
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
      await _pump(tester, db);

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
      // 到账 = 本金 320 + 税后盈利 80×0.74 = 379.2（不是全额 400）
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'],
          closeTo(1000 + 379.2, 0.001));
      final tr = (await db.collection('trades').get()).docs.single.data();
      expect(tr['side'], 'sell');
      expect(tr['realizedPnl'], 80.0);        // (10 - 8) * 40
      expect(tr['taxAmount'], closeTo(20.8, 0.001));   // 80 × 26%
    });

    testWidgets('realized pnl from past sells shows in the return card',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await db.collection('trades').add({
        'ticker': 'ENEL.MI', 'side': 'sell', 'shares': 10.0, 'price': 12.0,
        'date': '2026-07-20', 'realizedPnl': 40.0, 'avgCostAtTrade': 8.0,
      });
      await _pump(tester, db);
      expect(find.text('已实现'), findsOneWidget);      // 收益卡的拆解项
      expect(find.text('€40.00'), findsOneWidget);
    });

    testWidgets('trade history entry is present and counts trades', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur(db);
      await db.collection('trades').add({
        'ticker': 'ENEL.MI', 'side': 'buy', 'shares': 10.0, 'price': 8.0,
        'date': '2026-07-01',
      });
      await _pump(tester, db);
      expect(find.byKey(const Key('tradeHistoryEntry')), findsOneWidget);
      expect(find.text('交易记录'), findsOneWidget);
    });
  });

  group('买入与累计收益', () {
    Future<void> seedEur2(FakeFirebaseFirestore db) async {
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

    testWidgets('cumulative return card breaks out unrealized / realized / income',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur2(db);
      await db.collection('trades').add({
        'ticker': 'ENEL.MI', 'side': 'sell', 'shares': 10.0, 'price': 12.0,
        'date': '2026-07-20', 'realizedPnl': 40.0,
      });
      await db.collection('income').doc('ENEL.MI_2026-07-15').set({
        'ticker': 'ENEL.MI', 'date': '2026-07-15', 'amount': 30.0,
        'perShare': 0.3, 'shares': 100.0, 'source': 'auto',
      });
      await _pump(tester, db);
      expect(find.text('累计收益'), findsOneWidget);
      // 浮动 +€200（100×(10−8)）+ 已实现 €40 + 分红 €30 = €270，成本 €800 → +33.75%
      expect(find.text('€270.00'), findsOneWidget);
      expect(find.text('+33.75%'), findsOneWidget);
      expect(find.text('€200.00'), findsOneWidget);
      expect(find.text('€40.00'), findsOneWidget);
      expect(find.text('€30.00'), findsOneWidget);
    });

    testWidgets('buying from the position dialog re-weights cost and debits cash',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur2(db);
      await _pump(tester, db);
      await tester.tap(find.text('ENEL.MI'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('posBuy')));
      await tester.pumpAndSettle();
      expect(find.text('10.00'), findsWidgets);          // 价格缺省当前行情
      await tester.enterText(find.byKey(const Key('buyShares')), '100');
      await tester.tap(find.byKey(const Key('buyConfirm')));
      await tester.pumpAndSettle();
      final pos = (await db.collection('positions').doc('ENEL.MI').get()).data()!;
      expect(pos['shares'], 200);
      expect(pos['avgCost'], 9.0);                       // (100×8 + 100×10)/200
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'],
          1000 - 1000);
      expect((await db.collection('trades').get()).docs.single.data()['side'], 'buy');
    });

    testWidgets('FAB offers buy / enter-existing / record-income', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur2(db);
      await _pump(tester, db);
      await tester.tap(find.byKey(const Key('addFab')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('fabBuy')), findsOneWidget);
      expect(find.byKey(const Key('fabEnter')), findsOneWidget);
      expect(find.byKey(const Key('fabIncome')), findsOneWidget);
    });

    testWidgets('manual income entry records the row and credits cash',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedEur2(db);
      await _pump(tester, db);
      await tester.tap(find.byKey(const Key('addFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fabIncome')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('incomeTicker')), 'IT0005696320');
      await tester.enterText(find.byKey(const Key('incomeAmount')), '450');
      await tester.tap(find.byKey(const Key('incomeConfirm')));
      await tester.pumpAndSettle();
      final row = (await db.collection('income').get()).docs.single.data();
      expect(row['ticker'], 'IT0005696320');
      expect(row['amount'], 450.0);
      expect(row['source'], 'manual');
      expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'],
          1000 + 450);
    });
  });

  group('税前/税后与流水编辑', () {
    Future<void> seedTaxed(FakeFirebaseFirestore db) async {
      await db.collection('positions').doc('ENEL.MI').set({
        'ticker': 'ENEL.MI', 'shares': 100, 'avgCost': 8.0,
        'updatedAt': '2026-08-01T00:00:00+00:00',
      });
      await db.collection('meta').doc('portfolio').set({'cash': 0.0, 'currency': 'EUR'});
      await db.collection('briefs').doc('2026-08-01').set({
        'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['ENEL.MI'],
        'createdAt': '2026-08-01T00:00:00+00:00',
        'quotes': {
          'ENEL.MI': {'close': 10.0, 'pctChange': 1.0},
          'EURUSD=X': {'close': 1.1, 'pctChange': 0.0},
        },
      });
      await db.collection('income').doc('ENEL.MI_2026-07-15').set({
        'ticker': 'ENEL.MI', 'date': '2026-07-15', 'amount': 100.0,
        'taxAmount': 26.0, 'taxPct': 26.0, 'source': 'auto', 'creditedCash': false,
      });
    }

    testWidgets('return card shows the after-tax figure and the tax total',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedTaxed(db);
      await _pump(tester, db);
      // 浮动 200 + 分红 100 = 税前 300；税 26 → 税后 274
      expect(find.text('€300.00'), findsOneWidget);
      expect(find.textContaining('税后 €274.00'), findsOneWidget);
      expect(find.textContaining('税 €26.00'), findsOneWidget);
    });

    testWidgets('position dialog carries the opened-on date', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedTaxed(db);
      await _pump(tester, db);
      await tester.tap(find.text('ENEL.MI'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('posOpenedAt')), '2026-07-01');
      await tester.tap(find.byKey(const Key('posSave')));
      await tester.pumpAndSettle();
      expect((await db.collection('positions').doc('ENEL.MI').get()).data()!['openedAt'],
          '2026-07-01');
    });
  });

  group('分红自动算税', () {
    Future<void> seedMin(FakeFirebaseFirestore db) async {
      await db.collection('meta').doc('portfolio').set({'cash': 0.0, 'currency': 'EUR'});
    }

    Future<void> openIncome(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('addFab')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('fabIncome')));
      await tester.pumpAndSettle();
    }

    testWidgets('italian holding gets 26% prefilled after amount entry',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedMin(db);
      await _pump(tester, db);
      await openIncome(tester);
      await tester.enterText(find.byKey(const Key('incomeTicker')), 'ENEL.MI');
      await tester.enterText(find.byKey(const Key('incomeAmount')), '100');
      await tester.pumpAndSettle();
      expect(find.text('26.00'), findsOneWidget);
    });

    testWidgets('ticker typed after the amount still triggers the tax prefill',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedMin(db);
      await _pump(tester, db);
      await openIncome(tester);
      // 反序：先金额后标的——回归此前只在金额变化时才算的漏洞
      await tester.enterText(find.byKey(const Key('incomeAmount')), '100');
      await tester.enterText(find.byKey(const Key('incomeTicker')), 'MSFT');
      await tester.pumpAndSettle();
      expect(find.text('37.10'), findsOneWidget);   // 美股 15% + 意 26% 叠加
    });

    testWidgets('a hand-edited tax is never overwritten', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedMin(db);
      await _pump(tester, db);
      await openIncome(tester);
      await tester.enterText(find.byKey(const Key('incomeTicker')), 'ENEL.MI');
      await tester.enterText(find.byKey(const Key('incomeAmount')), '100');
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('incomeTax')), '13');  // 券商实际扣缴
      await tester.enterText(find.byKey(const Key('incomeAmount')), '200');
      await tester.pumpAndSettle();
      expect(find.text('13'), findsOneWidget);       // 没被 52.00 覆盖
      await tester.tap(find.byKey(const Key('incomeConfirm')));
      await tester.pumpAndSettle();
      final row = (await db.collection('income').get()).docs.single.data();
      expect(row['amount'], 200.0);
      expect(row['taxAmount'], 13.0);
    });
  });

  group('分层可视化与编辑', () {
    // ENEL €4000(卫星) + VUAA €2000(核心) + BTP €1000(防守) + 现金 €3000 = €10000
    Future<void> seedLayers(FakeFirebaseFirestore db) async {
      await db.collection('positions').doc('ENEL.MI').set({
        'ticker': 'ENEL.MI', 'shares': 400, 'avgCost': 9.0, 'updatedAt': '2026-08-01T00:00:00+00:00',
      });
      await db.collection('positions').doc('VUAA.MI').set({
        'ticker': 'VUAA.MI', 'shares': 20, 'avgCost': 90.0, 'updatedAt': '2026-08-01T00:00:00+00:00',
      });
      await db.collection('positions').doc('IT0005696320').set({
        'ticker': 'IT0005696320', 'shares': 10, 'avgCost': 100.0,
        'updatedAt': '2026-08-01T00:00:00+00:00', 'holdToMaturity': true,
      });
      await db.collection('meta').doc('portfolio').set({'cash': 3000.0, 'currency': 'EUR'});
      await db.collection('meta').doc('policy').set({
        'layerMap': {'VUAA.MI': 'core'},
        'usdLookthrough': {'VUAA.MI': 100},
      });
      await db.collection('briefs').doc('2026-08-01').set({
        'date': '2026-08-01', 'markdownZh': 'x', 'tickers': <String>[],
        'createdAt': '2026-08-01T00:00:00+00:00',
        'quotes': {
          'ENEL.MI': {'close': 10.0, 'pctChange': 0.0},
          'VUAA.MI': {'close': 100.0, 'pctChange': 0.0},
          'IT0005696320': {'close': 100.0, 'pctChange': 0.0},
          'EURUSD=X': {'close': 1.1, 'pctChange': 0.0},
        },
      });
    }

    testWidgets('layer card shows each layer with its target band', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedLayers(db);
      await _pump(tester, db);
      expect(find.text('仓位分层'), findsOneWidget);
      expect(find.text('防守'), findsWidgets);
      // 占比要收窄到分层卡内断言：持仓行的权重百分比可能与层占比数值相同
      Finder inCard(String s) => find.descendant(
          of: find.byKey(const Key('layerCard')), matching: find.text(s));
      expect(inCard('40.0%'), findsOneWidget);      // 卫星 4000/10000
      // 核心 2000/10000；美元敞口也恰好是 20%（VUAA 全额穿透），故卡内两处
      expect(inCard('20.0%'), findsNWidgets(2));
      expect(inCard('10.0%'), findsOneWidget);      // 防守 1000/10000
      expect(find.textContaining('目标 60–85%'), findsOneWidget);
    });

    testWidgets('breaches are tagged over-cap / below-floor', (tester) async {
      final db = FakeFirebaseFirestore();
      await seedLayers(db);
      await _pump(tester, db);
      expect(find.textContaining('超上限'), findsOneWidget);      // 卫星 40% > 15%
      expect(find.textContaining('低于下限'), findsOneWidget);    // 防守 10% < 60%
    });

    testWidgets('cash and USD exposure flags sit under the layers',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedLayers(db);
      await _pump(tester, db);
      expect(find.text('30.0%'), findsWidgets);        // 现金 3000/10000
      expect(find.textContaining('美元敞口'), findsOneWidget);
      expect(find.textContaining('上限 25%'), findsOneWidget);
      // VUAA 走 usdLookthrough 100% → €2000/€10000 = 20% 的底层美元敞口
      expect(
          find.descendant(
              of: find.byKey(const Key('layerCard')),
              matching: find.text('20.0%')),
          findsNWidgets(2));                           // 核心层 + 美元敞口
    });

    testWidgets('position row shows its layer and hold-to-maturity tag',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedLayers(db);
      await _pump(tester, db);
      expect(find.textContaining('卫星'), findsWidgets);          // ENEL 行
      expect(find.textContaining('持有到期'), findsWidgets);       // BTP 行
    });

    testWidgets('editing a position writes layer and hold-to-maturity',
        (tester) async {
      final db = FakeFirebaseFirestore();
      await seedLayers(db);
      await _pump(tester, db);
      await tester.tap(find.text('ENEL.MI'));
      await tester.pumpAndSettle();
      // 缺省推断为卫星，改成核心
      await tester.tap(find.descendant(
          of: find.byKey(const Key('posLayer')), matching: find.text('核心')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('posHoldToMaturity')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('posSave')));
      await tester.pumpAndSettle();
      final pos = (await db.collection('positions').doc('ENEL.MI').get()).data()!;
      expect(pos['layer'], 'core');
      expect(pos['holdToMaturity'], isTrue);
    });
  });
}
