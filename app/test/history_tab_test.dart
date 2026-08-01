import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/history_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: HistoryTab())),
    );

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('analyses').add({
    'ticker': 'NVDA', 'tradeDate': '2026-08-01', 'decision': 'SELL',
    'sections': {'market': '# 技术面\n均线走弱', 'bull': '', 'finalDecision': '减仓'},
    'createdAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('suggestions').add({
    'ticker': 'NVDA', 'action': 'trim', 'rationale': 'r', 'analysisId': 'a',
    'status': 'accepted', 'createdAt': '2026-07-10T00:00:00+00:00',
    'outcomePct': -4.2,
  });
}

void main() {
  testWidgets('analyses segment lists analysis and opens detail', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('NVDA · SELL'), findsOneWidget);
    await tester.tap(find.text('NVDA · SELL'));
    await tester.pumpAndSettle();
    expect(find.text('NVDA 2026-08-01'), findsOneWidget);   // 详情页 AppBar
    expect(find.text('市场技术面'), findsOneWidget);          // 非空节
    expect(find.text('多方观点'), findsNothing);              // 空节隐藏
    await tester.tap(find.text('市场技术面'));
    await tester.pumpAndSettle();
    expect(find.textContaining('均线走弱'), findsOneWidget);  // markdown 展开
  });

  testWidgets('suggestions segment shows status and outcome', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('建议'));
    await tester.pumpAndSettle();
    expect(find.text('NVDA · TRIM'), findsOneWidget);
    expect(find.text('已采纳'), findsOneWidget);
    expect(find.textContaining('-4.2'), findsOneWidget);
  });
}
