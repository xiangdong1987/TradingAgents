import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
import 'l10n.dart';
import 'providers.dart';
import 'ui/auth_gate.dart';

const _brandGreen = Color(0xFF34C759);

final ThemeData _lightTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: _brandGreen),
);

/// Apple-Stocks-style dark theme: near-black surfaces, bold white type,
/// green/red pnl accents handled per-widget via `ui/widgets/pnl.dart`.
final ThemeData _darkTheme = ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: _brandGreen, brightness: Brightness.dark)
      .copyWith(surface: const Color(0xFF000000)),
  scaffoldBackgroundColor: Colors.black,
  appBarTheme: const AppBarThemeData(
    backgroundColor: Colors.black,
    elevation: 0,
    titleTextStyle: TextStyle(fontWeight: FontWeight.w800, fontSize: 28, color: Colors.white),
  ),
  cardTheme: const CardThemeData(
    color: Color(0xFF1C1C1E),
    elevation: 0,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(12))),
  ),
  navigationBarTheme: const NavigationBarThemeData(backgroundColor: Color(0xFF0D0D0F)),
  dialogTheme: const DialogThemeData(backgroundColor: Color(0xFF1C1C1E)),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  runApp(const ProviderScope(child: WealthApp()));
}

class WealthApp extends ConsumerWidget {
  const WealthApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 登录前 meta/settings 不可读（安全规则要求已认证），此时只用缺省中文标题，
    // 避免过早建立会被 permission-denied 杀死的 settings 监听。
    final signedIn = ref.watch(authStateProvider).value != null;
    return MaterialApp(
      title: signedIn ? ref.watch(l10nProvider).appTitle : l10nZh.appTitle,
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: ThemeMode.dark,
      home: const AuthGate(),
    );
  }
}
