import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/chat_page.dart';
import 'package:wealth_assistant/ui/history_tab.dart';
import 'package:wealth_assistant/ui/portfolio_tab.dart';
import 'package:wealth_assistant/ui/today_tab.dart';
import 'package:wealth_assistant/ui/trades_page.dart';
import 'package:wealth_assistant/ui/watch_tab.dart';

/// 手机排版回归：每个主页面在 320（iPhone SE）与 375（13 mini）两个宽度、
/// 中英两种语言下都不能有 RenderFlex 溢出。英文文案普遍比中文长一倍，
/// 只测中文会漏掉一大半问题——这个文件就是为了钉住这一点。
Future<FakeFirebaseFirestore> seed(String lang) async {
  final db = FakeFirebaseFirestore();
  await db.collection('meta').doc('settings').set({'lang': lang});
  const pos = [
    ['ENEL.MI', 250.0, 9.77], ['IT0005696320', 1.0, 45000.0],
    ['MSFT', 15.0, 385.0], ['PST.MI', 100.0, 6.2],
    ['SPM.MI', 320.0, 4.55], ['VST', 18.0, 148.3], ['VUAA.MI', 25.0, 127.1],
  ];
  for (final p in pos) {
    await db.collection('positions').doc(p[0] as String).set({
      'ticker': p[0], 'shares': p[1], 'avgCost': p[2],
      'updatedAt': '2026-08-01T19:11:11.653+00:00',
      if (p[0] == 'IT0005696320') 'holdToMaturity': true,
    });
  }
  await db.collection('meta').doc('portfolio').set({'cash': 10616.06, 'currency': 'EUR'});
  await db.collection('meta').doc('policy').set({
    'usdLookthrough': {'VUAA.MI': 100.0},
    'layerMap': {'SPM.MI': 'satellite', 'ENEL.MI': 'satellite', 'VST': 'satellite',
      'PST.MI': 'defensive', 'IT0005696320': 'defensive', 'MSFT': 'satellite',
      'VUAA.MI': 'core'},
  });
  await db.collection('briefs').doc('2026-08-03').set({
    'date': '2026-08-03', 'markdownZh': 'x', 'tickers': <String>[],
    'createdAt': '2026-08-03T00:00:00+00:00',
    'quotes': {
      'VST': {'close': 155.94, 'pctChange': 5.23},
      'EURUSD=X': {'close': 1.151145, 'pctChange': -0.1},
      'MSFT': {'close': 487.65, 'pctChange': 4.93},
      'VUAA.MI': {'close': 127.2, 'pctChange': 1.89},
      'SPM.MI': {'close': 4.282, 'pctChange': 5.0},
      'ENEL.MI': {'close': 9.912, 'pctChange': 0.71},
      'PST.MI': {'close': 26.71, 'pctChange': 1.56},
    },
  });
  return db;
}


/// 给其余页面补上够长的内容：英文文案 + 大数额是最容易顶爆的组合。
Future<void> seedOtherPages(FakeFirebaseFirestore db) async {
  await db.collection('briefs').doc('2026-08-04').set({
    'date': '2026-08-04',
    'markdownZh': '## 市场概览\n\n意大利股市今日走强，银行板块领涨。',
    'markdownEn': '## Market overview\n\nItalian equities rallied, led by banks.',
    'tickers': ['ENEL.MI', 'MSFT', 'IT0005696320'],
    'createdAt': '2026-08-04T00:00:00+00:00',
    'quotes': {
      'ENEL.MI': {'close': 9.912, 'pctChange': 0.71},
      'MSFT': {'close': 487.65, 'pctChange': 4.93},
      'IT0005696320': {'close': 45000.0, 'pctChange': -0.02},
      'EURUSD=X': {'close': 1.151145, 'pctChange': -0.1},
    },
  });
  await db.collection('suggestions').add({
    'ticker': 'IT0005696320', 'action': 'add', 'confidence': 'medium',
    'rationale': '海龟加仓触发：突破 20 日高点，且距上一单元已涨过 0.5N。',
    'rationaleEn': 'Turtle pyramid trigger: broke the 20-day high and has run '
        'more than 0.5N past the prior unit.',
    'createdAt': '2026-08-04T07:00:00+00:00', 'status': 'open',
    'source': 'turtle',
    'meta': {'shares': 120, 'stop': 41.4, 'blocked': true,
      'blockedBy': 'satellite', 'fundingCandidates': ['MSFT', 'VST']},
  });
  await db.collection('trades').add({
    'ticker': 'IT0003110886', 'side': 'sell', 'shares': 1300.0, 'price': 8.33,
    'date': '2026-08-03', 'realizedPnl': 819.0, 'taxAmount': 212.94,
    'avgCostAtTrade': 7.7,
  });
  await db.collection('income').doc('ENEL.MI_2026-07-20').set({
    'ticker': 'ENEL.MI', 'date': '2026-07-20', 'amount': 65.0, 'perShare': 0.26,
    'shares': 250.0, 'taxPct': 26.0, 'taxAmount': 16.9, 'source': 'auto',
  });
  await db.collection('watchlist').doc('IT0005696320').set({
    'ticker': 'IT0005696320', 'deepFreq': 'weekly',
    'addedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('analyses').add({
    'ticker': 'IT0005696320', 'date': '2026-08-03', 'rating': 'hold',
    'summary': 'Hold to maturity; carry beats the reinvestment alternative.',
    'createdAt': '2026-08-03T00:00:00+00:00',
  });
  await db.collection('chats').add({
    'question': 'Should I trim the satellite sleeve to get back under the cap?',
    'answer': 'The satellite sleeve is 17.1% against a 15% cap, so a trim of '
        'roughly EUR 1,550 would bring it back inside the band.',
    'createdAt': '2026-08-04T08:00:00+00:00',
  });
}

const pages = <String, Widget>{
  'today': TodayTab(),
  'watch': WatchTab(),
  'history': HistoryTab(),
  'chat': ChatPage(),
  'trades': TradesPage(),
};

void probeOtherPages() {
  for (final lang in ['zh', 'en']) {
    for (final w in [320.0, 375.0]) {
      for (final entry in pages.entries) {
        testWidgets('${entry.key} @ ${w.toInt()}px ($lang): no overflow',
            (tester) async {
          tester.view.physicalSize = Size(w, 2400);
          tester.view.devicePixelRatio = 1.0;
          addTearDown(tester.view.reset);
          final db = await seed(lang);
          await seedOtherPages(db);
          await tester.pumpWidget(ProviderScope(
            overrides: [firestoreProvider.overrideWithValue(db)],
            child: MaterialApp(home: Scaffold(body: entry.value)),
          ));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}

void main() {
  probeOtherPages();

  for (final lang in ['zh', 'en']) {
    for (final w in [320.0, 375.0]) {
      testWidgets('$lang @ ${w.toInt()}px: page renders without overflow',
          (tester) async {
        tester.view.physicalSize = Size(w, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          overrides: [firestoreProvider.overrideWithValue(await seed(lang))],
          child: const MaterialApp(home: Scaffold(body: PortfolioTab())),
        ));
        await tester.pumpAndSettle();
        final e = tester.takeException();
        if (e != null) debugDumpRenderTree();
        expect(e, isNull);
      });

      testWidgets('$lang @ ${w.toInt()}px: position dialog renders without overflow',
          (tester) async {
        tester.view.physicalSize = Size(w, 2400);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(ProviderScope(
          overrides: [firestoreProvider.overrideWithValue(await seed(lang))],
          child: const MaterialApp(home: Scaffold(body: PortfolioTab())),
        ));
        await tester.pumpAndSettle();
        await tester.tap(find.text('ENEL.MI'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
