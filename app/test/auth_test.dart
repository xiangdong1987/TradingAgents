import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mock_exceptions/mock_exceptions.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/auth_gate.dart';
import 'package:wealth_assistant/ui/login_page.dart';

Widget _app(MockFirebaseAuth auth, FakeFirebaseFirestore db) => ProviderScope(
      overrides: [
        firebaseAuthProvider.overrideWithValue(auth),
        firestoreProvider.overrideWithValue(db),
      ],
      child: const MaterialApp(home: AuthGate()),
    );

void main() {
  testWidgets('signed out shows LoginPage', (tester) async {
    final auth = MockFirebaseAuth(signedIn: false);
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('signed in shows home shell scaffold with 4 tabs', (tester) async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1', email: 'me@x.com'));
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsNothing);
    expect(find.text('今日'), findsOneWidget);
    expect(find.text('自选'), findsOneWidget);
    expect(find.text('持仓'), findsOneWidget);
    expect(find.text('历史'), findsOneWidget);
  });

  testWidgets('login form signs in via FirebaseAuth', (tester) async {
    final auth = MockFirebaseAuth(signedIn: false);
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'me@x.com');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.tap(find.byKey(const Key('signInButton')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsNothing);  // MockFirebaseAuth 登录成功切换到主壳
  });

  testWidgets('login shows FirebaseAuthException message and stays on LoginPage', (tester) async {
    final auth = MockFirebaseAuth(signedIn: false);
    // firebase_auth_mocks 0.15.2 removed the `authExceptions:` constructor param;
    // its documented replacement is whenCalling(...).on(...).thenThrow(...) from
    // the mock_exceptions package (see firebase_auth_mocks README "Throwing exceptions").
    whenCalling(Invocation.method(#signInWithEmailAndPassword, null))
        .on(auth)
        .thenThrow(FirebaseAuthException(code: 'user-not-found', message: '账号不存在'));
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'me@x.com');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.tap(find.byKey(const Key('signInButton')));
    await tester.pumpAndSettle();
    expect(find.text('账号不存在'), findsOneWidget);
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('logout button signs out back to LoginPage', (tester) async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1'));
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('logoutButton')));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('login shows generic error and stays on LoginPage for non-FirebaseAuthException',
      (tester) async {
    final auth = MockFirebaseAuth(signedIn: false);
    // Exercises the catch-all branch (anything other than FirebaseAuthException),
    // e.g. a PlatformException or network error from the plugin channel.
    whenCalling(Invocation.method(#signInWithEmailAndPassword, null))
        .on(auth)
        .thenThrow(Exception('网络错误'));
    await tester.pumpWidget(_app(auth, FakeFirebaseFirestore()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('email')), 'me@x.com');
    await tester.enterText(find.byKey(const Key('password')), 'secret123');
    await tester.tap(find.byKey(const Key('signInButton')));
    await tester.pumpAndSettle();
    expect(find.textContaining('登录失败'), findsOneWidget);
    expect(find.byType(LoginPage), findsOneWidget);
  });

  testWidgets('refresh button enqueues a refresh_quotes job', (tester) async {
    final auth = MockFirebaseAuth(signedIn: true, mockUser: MockUser(uid: 'u1'));
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(_app(auth, db));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('refreshQuotes')));
    await tester.pumpAndSettle();
    final jobs = await db.collection('jobs').get();
    expect(jobs.docs.single.data()['type'], 'refresh_quotes');
  });
}
