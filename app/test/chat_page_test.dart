import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/chat_page.dart';

Widget _wrap(FakeFirebaseFirestore db) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: const MaterialApp(home: Scaffold(body: ChatPage())),
    );

void main() {
  testWidgets('sending a question writes chat doc + chat job and echoes bubble',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('askField')), 'KO 和 ISP.MI 买哪个？');
    await tester.tap(find.byKey(const Key('askSend')));
    await tester.pumpAndSettle();
    final chat = (await db.collection('chats').get()).docs.single;
    expect(chat.data()['question'], 'KO 和 ISP.MI 买哪个？');
    final job = (await db.collection('jobs').get()).docs.single.data();
    expect(job['type'], 'chat');
    expect(job['chatId'], chat.id);
    expect(find.text('KO 和 ISP.MI 买哪个？'), findsOneWidget);
    expect(find.text('分析中…'), findsOneWidget);
  });

  testWidgets('answered chat renders markdown bubble', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('chats').add({
      'question': '现金太多吗', 'answer': '**结论**：可以加仓', 'status': 'answered',
      'createdAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    expect(find.text('现金太多吗'), findsOneWidget);
    expect(find.textContaining('可以加仓'), findsOneWidget);
  });

  testWidgets('long-press on a bubble copies its text to clipboard',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('chats').add({
      'question': '复制我', 'answer': '答案内容', 'status': 'answered',
      'createdAt': '2026-08-01T00:00:00+00:00',
    });
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      calls.add(call);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(_wrap(db));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('复制我'));
    await tester.pumpAndSettle();
    final copies =
        calls.where((c) => c.method == 'Clipboard.setData').toList();
    expect(copies, hasLength(1));
    expect((copies.single.arguments as Map)['text'], '复制我');
    expect(find.text('已复制'), findsOneWidget); // SnackBar 提示
  });
}
