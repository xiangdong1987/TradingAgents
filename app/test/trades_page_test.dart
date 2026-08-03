import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/trades_page.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: TradesPage()),
    );

void main() {
  testWidgets('empty state', (tester) async {
    await tester.pumpWidget(_wrap(FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.text('还没有成交记录'), findsOneWidget);
  });

  testWidgets('sell row shows amount and realized pnl, buy row only amount',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('trades').add({
      'ticker': 'ENEL.MI', 'side': 'sell', 'shares': 40.0, 'price': 10.0,
      'date': '2026-08-03', 'realizedPnl': 80.0, 'avgCostAtTrade': 8.0,
    });
    await db.collection('trades').add({
      'ticker': 'MSFT', 'side': 'buy', 'shares': 5.0, 'price': 400.0,
      'date': '2026-08-01',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();

    expect(find.text('卖出'), findsOneWidget);
    expect(find.text('买入'), findsOneWidget);
    expect(find.text('€400.00'), findsOneWidget);    // 卖出成交额 40×10
    expect(find.text('+€80.00'), findsOneWidget);    // 已实现盈亏（欧元标的）
    expect(find.text('\$2,000.00'), findsOneWidget); // 买入成交额 5×400，美元标的
  });

  testWidgets('newest trade is listed first', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('trades').add({
      'ticker': 'OLD', 'side': 'buy', 'shares': 1.0, 'price': 1.0, 'date': '2026-07-01',
    });
    await db.collection('trades').add({
      'ticker': 'NEW', 'side': 'buy', 'shares': 1.0, 'price': 1.0, 'date': '2026-08-03',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    final newY = tester.getTopLeft(find.text('NEW')).dy;
    final oldY = tester.getTopLeft(find.text('OLD')).dy;
    expect(newY, lessThan(oldY));
  });

  testWidgets('income rows appear in the timeline with source and per-share',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('trades').add({
      'ticker': 'MSFT', 'side': 'buy', 'shares': 5.0, 'price': 400.0,
      'date': '2026-07-01',
    });
    await db.collection('income').doc('MSFT_2026-08-02').set({
      'ticker': 'MSFT', 'date': '2026-08-02', 'amount': 12.45,
      'perShare': 0.83, 'shares': 15.0, 'source': 'auto',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('分红利息'), findsOneWidget);
    expect(find.text('+\$12.45'), findsOneWidget);
    expect(find.textContaining('自动估算'), findsOneWidget);
    expect(find.textContaining('0.8300/股'), findsOneWidget);
    // 分红日期更新 → 排在买入之前
    expect(tester.getTopLeft(find.text('分红利息')).dy,
        lessThan(tester.getTopLeft(find.text('买入')).dy));
  });

  testWidgets('tapping a trade opens the editor and saving updates it',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('positions').doc('ENEL.MI').set({
      'ticker': 'ENEL.MI', 'shares': 90.0, 'avgCost': 8.0, 'updatedAt': 'x',
    });
    await db.collection('meta').doc('portfolio').set({'cash': 100.0, 'currency': 'EUR'});
    await db.collection('trades').add({
      'ticker': 'ENEL.MI', 'side': 'sell', 'shares': 10.0, 'price': 10.0,
      'date': '2026-08-03', 'realizedPnl': 20.0, 'taxAmount': 5.2,
      'avgCostAtTrade': 8.0,
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('税后'), findsOneWidget);   // 卖出行带税后一行

    await tester.tap(find.text('ENEL.MI'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editShares')), '20');
    await tester.tap(find.byKey(const Key('editSave')));
    await tester.pumpAndSettle();
    final tr = (await db.collection('trades').get()).docs.single.data();
    expect(tr['shares'], 20);
  });

  testWidgets('deleting a trade asks for confirmation first', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('positions').doc('KO').set({
      'ticker': 'KO', 'shares': 10.0, 'avgCost': 80.0, 'updatedAt': 'x',
    });
    await db.collection('meta').doc('portfolio').set({'cash': 0.0, 'currency': 'EUR'});
    await db.collection('trades').add({
      'ticker': 'KO', 'side': 'buy', 'shares': 5.0, 'price': 80.0, 'date': '2026-08-01',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KO'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('editDelete')));
    await tester.pumpAndSettle();
    expect(find.text('删除这笔记录？'), findsOneWidget);
    expect((await db.collection('trades').get()).docs, hasLength(1));  // 还没删
    await tester.tap(find.byKey(const Key('confirmDelete')));
    await tester.pumpAndSettle();
    expect((await db.collection('trades').get()).docs, isEmpty);
    // 撤回买入：股数减回、现金加回
    expect((await db.collection('positions').doc('KO').get()).data()!['shares'], 5);
    expect((await db.collection('meta').doc('portfolio').get()).data()!['cash'], 400);
  });

  testWidgets('income row opens its editor', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('meta').doc('portfolio').set({'cash': 0.0, 'currency': 'EUR'});
    await db.collection('income').doc('ENEL.MI_2026-07-15').set({
      'ticker': 'ENEL.MI', 'date': '2026-07-15', 'amount': 65.0,
      'taxAmount': 16.9, 'source': 'auto', 'creditedCash': false,
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('税后 €48.10'), findsOneWidget);   // 65 − 16.9
    await tester.tap(find.text('ENEL.MI'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('editIncomeTax')), '20');
    await tester.tap(find.byKey(const Key('editIncomeSave')));
    await tester.pumpAndSettle();
    final row = (await db.collection('income').doc('ENEL.MI_2026-07-15').get()).data()!;
    expect(row['taxAmount'], 20);
  });
}
