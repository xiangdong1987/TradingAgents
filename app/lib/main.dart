import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'firebase_options.dart';
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
  runApp(ProviderScope(
    child: MaterialApp(
      title: '理财助手',
      theme: _lightTheme,
      darkTheme: _darkTheme,
      themeMode: ThemeMode.dark,
      home: const AuthGate(),
    ),
  ));
}
