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

void main() {
  testWidgets('empty state renders hint when no brief exists', (tester) async {
    await tester.pumpWidget(_wrap(FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.textContaining('还没有日报'), findsOneWidget);
  });

  testWidgets('renders latest brief markdown and pending suggestion cards', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('briefs').doc('2026-08-01').set({
      'date': '2026-08-01', 'markdownZh': '# 投资日报\nNVDA 上涨', 'tickers': ['NVDA'],
      'createdAt': '2026-08-01T21:00:00+00:00',
    });
    await db.collection('suggestions').add({
      'ticker': 'NVDA', 'action': 'trim', 'targetWeightPct': 15,
      'rationale': '估值过高，建议减仓', 'analysisId': 'a1',
      'status': 'pending', 'createdAt': '2026-08-01T22:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('投资日报'), findsOneWidget);   // markdown 渲染
    expect(find.text('NVDA · TRIM'), findsOneWidget);          // 卡片标题
    expect(find.textContaining('估值过高'), findsOneWidget);
    expect(find.textContaining('15'), findsOneWidget);          // 目标仓位
  });

  testWidgets('running job shows status banner', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('jobs').add({
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'running',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('NVDA'), findsWidgets);
    expect(find.textContaining('分析中'), findsOneWidget);
  });
}
