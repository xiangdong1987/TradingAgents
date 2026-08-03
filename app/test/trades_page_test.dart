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
}
