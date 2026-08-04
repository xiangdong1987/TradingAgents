import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/today_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: TodayTab())),
    );

Future<String> _seedPending(FakeFirebaseFirestore db) async {
  final ref = await db.collection('suggestions').add({
    'ticker': 'NVDA', 'action': 'trim', 'targetWeightPct': 15,
    'rationale': '估值过高', 'analysisId': 'a1',
    'status': 'pending', 'createdAt': '2026-08-01T00:00:00+00:00',
  });
  return ref.id;
}

void main() {
  testWidgets('dismiss updates status and card disappears', (tester) async {
    final db = FakeFirebaseFirestore();
    final id = await _seedPending(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('忽略'));
    await tester.pumpAndSettle();
    final doc = (await db.collection('suggestions').doc(id).get()).data()!;
    expect(doc['status'], 'dismissed');
    expect(doc['resolvedAt'], endsWith('+00:00'));
    expect(find.text('NVDA · TRIM'), findsNothing);   // pending 流里消失
  });

  testWidgets('accept-only marks accepted without trade', (tester) async {
    final db = FakeFirebaseFirestore();
    final id = await _seedPending(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采纳'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('acceptOnly')));
    await tester.pumpAndSettle();
    expect((await db.collection('suggestions').doc(id).get()).data()!['status'], 'accepted');
    expect((await db.collection('trades').get()).docs, isEmpty);
  });

  testWidgets('accept with trade records linked trade doc', (tester) async {
    final db = FakeFirebaseFirestore();
    final id = await _seedPending(db);
    // trim → sell：applyTrade 需要有持仓才卖得出去（否则不落库，见下一个用例）
    await db.collection('positions').doc('NVDA').set({
      'ticker': 'NVDA', 'shares': 10.0, 'avgCost': 150.0, 'updatedAt': 'x',
    });
    await db.collection('meta').doc('portfolio').set({'cash': 0.0, 'currency': 'USD'});
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采纳'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tradeShares')), '3');
    await tester.enterText(find.byKey(const Key('tradePrice')), '200.5');
    await tester.tap(find.byKey(const Key('acceptWithTrade')));
    await tester.pumpAndSettle();
    final trade = (await db.collection('trades').get()).docs.single.data();
    expect(trade['ticker'], 'NVDA');
    expect(trade['side'], 'sell');           // trim → sell
    expect(trade['shares'], 3.0);
    expect(trade['price'], 200.5);
    expect(trade['suggestionId'], id);
    expect((await db.collection('suggestions').doc(id).get()).data()!['status'], 'accepted');
  });

  testWidgets('turtle suggestion shows source chip, engine one does not',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _seedPending(db);
    await _seedTurtle(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('🐢 海龟'), findsOneWidget); // 引擎建议(NVDA)无 chip
    expect(find.textContaining('海龟入场'), findsOneWidget);
  });

  testWidgets('selling with no position tells you nothing was recorded',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _seedPending(db);        // trim NVDA，但库里没有 NVDA 持仓
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采纳'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('tradeShares')), '3');
    await tester.enterText(find.byKey(const Key('tradePrice')), '200.5');
    await tester.tap(find.byKey(const Key('acceptWithTrade')));
    await tester.pumpAndSettle();
    expect((await db.collection('trades').get()).docs, isEmpty);
    expect(find.text('没有可卖的持仓，这笔没有记录'), findsOneWidget);
  });
}

Future<void> _seedTurtle(FakeFirebaseFirestore db) async {
  await db.collection('suggestions').add({
    'ticker': 'ENEL.MI', 'action': 'buy', 'targetWeightPct': null,
    'rationale': '海龟入场（S1）：收盘 9.98 突破 20 日高点 9.95。',
    'analysisId': '', 'source': 'turtle', 'meta': {'system': 's1'},
    'status': 'pending', 'createdAt': '2026-08-01T01:00:00+00:00',
  });

}
