import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
}
