import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/ui/widgets/pnl.dart';

void main() {
  group('pnlColor', () {
    test('positive is iOS green', () {
      expect(pnlColor(2.93), const Color(0xFF34C759));
    });
    test('negative is iOS red', () {
      expect(pnlColor(-1.02), const Color(0xFFFF3B30));
    });
    test('zero counts as a gain (green)', () {
      expect(pnlColor(0), const Color(0xFF34C759));
    });
  });

  group('pnlLabel', () {
    test('positive is signed with 2 decimals', () {
      expect(pnlLabel(2.934), '+2.93%');
    });
    test('negative keeps its own sign', () {
      expect(pnlLabel(-1.02), '-1.02%');
    });
    test('zero is shown as +0.00%', () {
      expect(pnlLabel(0), '+0.00%');
    });
  });

  group('PnlPill', () {
    testWidgets('renders the formatted label text', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: PnlPill(2.93))));
      expect(find.text('+2.93%'), findsOneWidget);
    });

    testWidgets('compact variant renders the formatted label text', (tester) async {
      await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: PnlPill(-4.2, compact: true))));
      expect(find.text('-4.20%'), findsOneWidget);
    });
  });

  group('MoneyText', () {
    testWidgets('renders value with 2 decimals', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Scaffold(body: MoneyText(200.7))));
      expect(find.text('200.70'), findsOneWidget);
    });
  });
}
