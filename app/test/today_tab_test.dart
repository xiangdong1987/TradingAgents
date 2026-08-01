import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:wealth_assistant/models/models.dart';
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
    // 日报默认收起：标题可见，点开后正文可见
    expect(find.textContaining('每日投资日报'), findsOneWidget);
    await tester.tap(find.byKey(const Key('briefTile')));
    await tester.pumpAndSettle();
    expect(find.textContaining('NVDA 上涨'), findsOneWidget);   // 展开后 markdown 正文可见
    expect(find.text('NVDA · TRIM'), findsOneWidget);          // 卡片标题
    expect(find.textContaining('估值过高'), findsOneWidget);
    expect(find.textContaining('15'), findsOneWidget);          // 目标仓位
  });

  testWidgets('active jobs card shows job, elapsed time and runner status',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('jobs').add({
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'running',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
      'startedAt': '2026-08-01T00:00:00+00:00',
    });
    await db.collection('jobs').add({
      'type': 'refresh_quotes', 'status': 'queued',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await db.collection('meta').doc('runner').set({
      'lastSeenAt': DateTime.now().toUtc().toIso8601String(),
      'mode': 'watch', 'intervalSeconds': 120,
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pump(const Duration(milliseconds: 400));  // 有动画，勿 pumpAndSettle
    expect(find.text('NVDA 深度分析'), findsOneWidget);
    expect(find.textContaining('已 '), findsOneWidget);      // 运行时长
    expect(find.text('行情刷新'), findsOneWidget);
    expect(find.text('排队中'), findsOneWidget);
    expect(find.text('Runner 在线'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
  });

  testWidgets('runner offline is called out', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('meta').doc('runner').set({
      'lastSeenAt': '2026-08-01T00:00:00+00:00',    // 很久以前
      'mode': 'watch', 'intervalSeconds': 120,
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('Runner 离线'), findsOneWidget);
  });

  testWidgets('calendar card marks event day and shows detail on select', (tester) async {
    final db = FakeFirebaseFirestore();
    final today = DateTime.now().toIso8601String().substring(0, 10);
    await db.collection('meta').doc('calendar').set({
      'updatedAt': '2026-08-01T00:00:00+00:00',
      'events': [
        {'ticker': 'NVDA', 'type': 'earnings', 'date': today},   // 今天有事件（默认选中）
      ],
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.byType(TableCalendar<CalendarEvent>), findsOneWidget);
    expect(find.text('NVDA'), findsOneWidget);   // 选中日明细
    expect(find.text('财报'), findsOneWidget);
  });
}
