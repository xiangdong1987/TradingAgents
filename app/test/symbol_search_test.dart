import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/data/symbol_search.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/widgets/ticker_field.dart';

const _csv = '''
A,"Agilent Technologies, Inc."
AA,Alcoa Corporation
AAPL,Apple Inc.
AAP,Advance Auto Parts Inc.
MSFT,Microsoft Corporation
NVDA,NVIDIA Corporation
''';

void main() {
  final index = SymbolIndex.fromCsvString(_csv);

  test('exact symbol match ranks first', () {
    final hits = index.search('AAPL');
    expect(hits.first.symbol, 'AAPL');
  });

  test('symbol prefix matches sorted by length, case-insensitive', () {
    final hits = index.search('aa');
    expect(hits.map((e) => e.symbol).take(3), ['AA', 'AAP', 'AAPL']);
  });

  test('chinese alias finds ticker', () {
    final hits = index.search('苹果');
    expect(hits.single.symbol, 'AAPL');
  });

  test('english name substring finds ticker with quoted-name parsing', () {
    final hits = index.search('agilent');
    expect(hits.single.symbol, 'A');
    expect(hits.single.name, 'Agilent Technologies, Inc.');
  });

  test('empty and no-hit queries return empty', () {
    expect(index.search(''), isEmpty);
    expect(index.search('zzzz不存在'), isEmpty);
  });


  test('milan entries are searchable by symbol and chinese alias', () {
    final enel = index.search('enel');
    expect(enel.first.symbol, 'ENEL.MI');
    final ferrari = index.search('法拉利');
    expect(ferrari.single.symbol, 'RACE.MI');
  });

  testWidgets('TickerField shows suggestions and fills symbol on tap',
      (tester) async {
    SymbolIndex.instance = index; // 预置索引，避免测试读资产
    final controller = TextEditingController();
    // TickerField 缺省 label 走 l10nProvider，需要 ProviderScope + fake firestore。
    await tester.pumpWidget(ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(FakeFirebaseFirestore())],
      child: MaterialApp(
        home: Scaffold(
          body: TickerField(fieldKey: const Key('t'), controller: controller),
        ),
      ),
    ));
    await tester.enterText(find.byKey(const Key('t')), '苹果');
    await tester.pumpAndSettle();
    expect(find.text('AAPL'), findsWidgets); // 下拉里出现
    await tester.tap(find.text('AAPL').last);
    await tester.pumpAndSettle();
    expect(controller.text, 'AAPL');
    controller.dispose();
  });
}
