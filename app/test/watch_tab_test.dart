import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/watch_tab.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: WatchTab())),
    );

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('watchlist').doc('NVDA').set({
    'ticker': 'NVDA', 'note': '', 'deepFreq': 'weekly',
    'addedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('briefs').doc('2026-08-01').set({
    'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['NVDA'],
    'createdAt': '2026-08-01T00:00:00+00:00',
    'quotes': {'NVDA': {'close': 200.75, 'pctChange': 2.93}},
  });
}

void main() {
  testWidgets('renders watch item with quote from latest brief', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('NVDA'), findsOneWidget);
    expect(find.textContaining('200.75'), findsOneWidget);
    expect(find.textContaining('2.93'), findsOneWidget);
    expect(find.text('每周自动分析'), findsOneWidget);
  });

  testWidgets('analyze button enqueues a user job', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('分析'));
    await tester.pumpAndSettle();
    final job = (await db.collection('jobs').get()).docs.single.data();
    expect(job['type'], 'deep_analysis');
    expect(job['ticker'], 'NVDA');
    expect(job['requestedBy'], 'user');
  });

  testWidgets('active job replaces analyze button with status chip', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await db.collection('jobs').add({
      'type': 'deep_analysis', 'ticker': 'NVDA', 'status': 'running',
      'requestedBy': 'user', 'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('分析'), findsNothing);
    expect(find.text('分析中'), findsOneWidget);
  });

  testWidgets('add dialog writes watch doc uppercased', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.textContaining('自选列表为空'), findsOneWidget);
    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('watchTicker')), 'aapl');
    await tester.tap(find.byKey(const Key('watchAdd')));
    await tester.pumpAndSettle();
    final doc = (await db.collection('watchlist').doc('AAPL').get()).data()!;
    expect(doc['ticker'], 'AAPL');
    expect(doc['deepFreq'], 'manual');
  });

  testWidgets('deepFreq label toggles on tap', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.tap(find.text('每周自动分析'));
    await tester.pumpAndSettle();
    expect((await db.collection('watchlist').doc('NVDA').get()).data()!['deepFreq'], 'manual');
  });
}
