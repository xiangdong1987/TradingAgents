import 'dart:async';

import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/widgets/snapshot_list.dart';

// StreamError 现在从 l10nProvider 取文案，需要 ProviderScope + fake firestore。
Widget _wrap(Widget child) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(FakeFirebaseFirestore())],
      child: MaterialApp(home: Scaffold(body: child)),
    );

void main() {
  testWidgets('shows StreamError (not the empty state) on stream error', (tester) async {
    var retried = false;
    await tester.pumpWidget(_wrap(SnapshotList<String>(
      stream: Stream<List<String>>.error(Exception('boom')),
      itemBuilder: (_, items) => Text('items: ${items.length}'),
      emptyText: '空空如也',
      onRetry: () => retried = true,
    )));
    await tester.pump();
    expect(find.textContaining('boom'), findsOneWidget);
    expect(find.text('空空如也'), findsNothing);
    await tester.tap(find.text('重试'));
    await tester.pump();
    expect(retried, isTrue);
  });

  testWidgets('shows a spinner (not the empty state) while waiting with no data', (tester) async {
    final controller = StreamController<List<String>>();
    addTearDown(controller.close);
    await tester.pumpWidget(_wrap(SnapshotList<String>(
      stream: controller.stream,
      itemBuilder: (_, items) => Text('items: ${items.length}'),
      emptyText: '空空如也',
      onRetry: () {},
    )));
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('空空如也'), findsNothing);
  });

  testWidgets('shows emptyText once the stream completes with no items', (tester) async {
    await tester.pumpWidget(_wrap(SnapshotList<String>(
      stream: Stream<List<String>>.empty(),
      itemBuilder: (_, items) => Text('items: ${items.length}'),
      emptyText: '空空如也',
      onRetry: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('空空如也'), findsOneWidget);
  });

  testWidgets('shows itemBuilder output when data arrives', (tester) async {
    await tester.pumpWidget(_wrap(SnapshotList<String>(
      stream: Stream<List<String>>.value(const ['a', 'b']),
      itemBuilder: (_, items) => Text('items: ${items.length}'),
      emptyText: '空空如也',
      onRetry: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.text('items: 2'), findsOneWidget);
    expect(find.text('空空如也'), findsNothing);
  });
}
