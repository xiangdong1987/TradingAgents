import 'package:fake_cloud_firestore/fake_cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wealth_assistant/models/models.dart';
import 'package:wealth_assistant/providers.dart';
import 'package:wealth_assistant/ui/analysis_detail_page.dart';
import 'package:wealth_assistant/ui/ticker_dashboard_page.dart';
import 'package:wealth_assistant/ui/watch_tab.dart';

const _market = '''
## 关键指标汇总表

| 指标 | 当前值 | 信号 | 强度 |
|------|--------|------|------|
| 收盘价 | €9.84 | — | — |
| 50日SMA | €9.68 | 价格高于均线 | 偏多 ✅ |
| RSI | 50.68 | 中性区域 | 中性 ➡️ |
| MACD | 0.046 | 低于信号线 | 偏空 ⚠️ |
| 布林上轨 | €10.04 | 强阻力 | — |
''';

const _sections = {
  'market': _market,
  'sentiment': '**Overall Sentiment:** **Neutral** (Score: 5.0/10)\n**Confidence:** Low\n',
  'fundamentals': '''
| 指标 | 数值 | 分析评估 |
|------|------|----------|
| 股息收益率 | 5.31% | 极具吸引力 |
| PEG比率 | 0.9 | 低于1 |
''',
  'bull': '\nBull Analyst: 多方核心：能源转型受益者，长期趋势坚如磐石。',
  'bear': '\nBear Analyst: 空方核心：动能衰竭，财务脆弱性被低估。',
  'researchManager': '**Recommendation**: Underweight\n\n**Rationale**: 风险回报比不利于做多。',
  'traderPlan':
      '**Action**: Sell\n\n**Entry Price**: 10.02\n\n**Stop Loss**: 9.68\n\n**Position Sizing**: 降低30-50%',
  'riskAggressive': '\nAggressive Analyst: 顶背离已现，动能拐点确认。',
  'riskConservative': '\nConservative Analyst: 长期趋势未破，股息提供保护。',
  'riskNeutral': '\nNeutral Analyst: 分阶段管理风险最稳妥。',
  'portfolioDecision':
      '**Rating**: Underweight\n\n**Executive Summary**: 建议下调持仓权重至基准以下。\n\n**Time Horizon**: 1-3个月',
  'finalDecision': '**Rating**: Underweight',
};

Future<void> _seed(FakeFirebaseFirestore db) async {
  await db.collection('watchlist').doc('ENEL.MI').set({
    'ticker': 'ENEL.MI', 'note': '', 'deepFreq': 'manual',
    'addedAt': '2026-08-01T00:00:00+00:00',
  });
  await db.collection('briefs').doc('2026-08-01').set({
    'date': '2026-08-01', 'markdownZh': 'x', 'tickers': ['ENEL.MI'],
    'createdAt': '2026-08-01T00:00:00+00:00',
    'quotes': {'ENEL.MI': {'close': 9.84, 'pctChange': -0.61}},
  });
  await db.collection('analyses').add({
    'ticker': 'ENEL.MI', 'tradeDate': '2026-07-31', 'decision': 'Underweight',
    'sections': _sections, 'createdAt': '2026-07-31T20:00:00+00:00',
  });
  await db.collection('analyses').add({
    'ticker': 'ENEL.MI', 'tradeDate': '2026-07-20', 'decision': 'Hold',
    'sections': {'finalDecision': '**Rating**: Hold'},
    'createdAt': '2026-07-20T20:00:00+00:00',
  });
}

Widget _wrap(FakeFirebaseFirestore db, Widget home) => ProviderScope(
      overrides: [firestoreProvider.overrideWithValue(db)],
      child: MaterialApp(home: home),
    );

/// 仪表盘是懒构建的 ListView：默认 600px 测试视口下折叠线以下的区块
/// 根本不会 build。拉高视口让整页一次性构建，断言才可靠。
void _tallViewport(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 3600);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('dashboard renders rating, plan tiles, signals and history strip',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    _tallViewport(tester);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();

    // 评级横幅：中文档位 + 英文原文 + 现价
    expect(find.byKey(const Key('dashRating')), findsOneWidget);
    expect(find.text('减持', skipOffstage: false), findsWidgets);
    expect(find.textContaining('9.84'), findsWidgets);

    // 交易计划磁贴
    expect(find.text('10.02'), findsOneWidget);
    expect(find.text('9.68'), findsOneWidget);
    expect(find.text('卖出'), findsWidgets);
    expect(find.textContaining('仓位建议'), findsOneWidget);

    // 情绪条
    expect(find.text('5.0/10 · 置信度低'), findsOneWidget);

    // 技术信号：多空计数 + chips（收盘价/布林是价位行，不出 chips）
    expect(find.text('1 多 · 1 平 · 1 空'), findsOneWidget);
    expect(find.text('RSI 50.68'), findsOneWidget);
    expect(find.textContaining('收盘价'), findsNothing);

    // 基本面要点
    expect(find.text('股息收益率'), findsOneWidget);
    expect(find.text('5.31%'), findsOneWidget);

    // 多空对辩摘要
    expect(find.textContaining('多方核心'), findsOneWidget);
    expect(find.textContaining('空方核心'), findsOneWidget);

    // 历史评级时间线：两条记录
    expect(find.textContaining('历史评级'), findsOneWidget);
    expect(find.text('07-20'), findsOneWidget);
  });

  testWidgets('history strip opens the full report of that run', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    _tallViewport(tester);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('07-20'));
    await tester.tap(find.text('07-20'));
    await tester.pumpAndSettle();
    expect(find.byType(AnalysisDetailPage), findsOneWidget);
    expect(find.textContaining('决策：Hold'), findsOneWidget);
  });

  testWidgets('expandable card reveals full markdown inline', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    _tallViewport(tester);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Rationale'), findsNothing); // 摘要态只有纯文本
    await tester.ensureVisible(find.text('研究主管结论'));
    await tester.tap(find.text('研究主管结论'));
    await tester.pumpAndSettle();
    expect(find.textContaining('风险回报比不利于做多'), findsWidgets);
  });

  testWidgets('debate column opens bottom sheet with full text', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    _tallViewport(tester);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('多方观点'));
    await tester.tap(find.text('多方观点'));
    await tester.pumpAndSettle();
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.textContaining('能源转型受益者'), findsWidgets);
  });

  testWidgets('empty state offers analyze CTA and enqueues job', (tester) async {
    final db = FakeFirebaseFirestore();
    await db.collection('watchlist').doc('NVDA').set({
      'ticker': 'NVDA', 'note': '', 'deepFreq': 'manual',
      'addedAt': '2026-08-01T00:00:00+00:00',
    });
    await tester.pumpWidget(_wrap(db, const TickerDashboardPage(ticker: 'NVDA')));
    await tester.pumpAndSettle();

    expect(find.text('还没有分析记录'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reanalyze')));
    await tester.pumpAndSettle();
    final job = (await db.collection('jobs').get()).docs.single.data();
    expect(job['type'], 'deep_analysis');
    expect(job['ticker'], 'NVDA');
    // 入队后按钮变状态 chip
    expect(find.text('排队中'), findsOneWidget);
  });

  testWidgets('isin ticker shows unsupported note without CTA', (tester) async {
    final db = FakeFirebaseFirestore();
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'IT0005217390')));
    await tester.pumpAndSettle();
    expect(find.textContaining('暂不支持深度分析'), findsOneWidget);
    expect(find.byKey(const Key('reanalyze')), findsNothing);
  });

  testWidgets('no layout overflow at phone width', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    tester.view.physicalSize = const Size(1170, 2532); // 390x844 @3x
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();
    // 滚到页底，让每个区块都经历一次真实布局（溢出会直接抛错失败）。
    for (var i = 0; i < 8; i++) {
      await tester.drag(find.byType(ListView).first, const Offset(0, -500));
      await tester.pumpAndSettle();
    }
    expect(find.textContaining('历史评级'), findsOneWidget);
  });

  testWidgets('watch tab tile opens the dashboard', (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    await tester.pumpWidget(
        _wrap(db, const Scaffold(body: WatchTab())));
    await tester.pumpAndSettle();
    await tester.tap(find.text('ENEL.MI'));
    await tester.pumpAndSettle();
    expect(find.byType(TickerDashboardPage), findsOneWidget);
    expect(find.byKey(const Key('dashRating')), findsOneWidget);
  });

  // ---------------------------------------------------------------------------
  // 按需翻译按钮（zh 缺省语言，无 sectionsZh 译文）
  // ---------------------------------------------------------------------------

  testWidgets('dashboard translate button appears in zh and enqueues job',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    _tallViewport(tester);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();

    final btn = find.byKey(const Key('translate-bull'));
    expect(btn, findsOneWidget);
    await tester.ensureVisible(btn);
    await tester.tap(btn);
    await tester.pumpAndSettle();

    final analysisId = (await db
            .collection('analyses')
            .where('tradeDate', isEqualTo: '2026-07-31')
            .get())
        .docs
        .single
        .id;
    final job = (await db.collection('jobs').get())
        .docs
        .map((d) => d.data())
        .singleWhere((j) => j['type'] == 'translate');
    expect(job['analysisId'], analysisId);
    expect(job['sections'], ['bull']);
    expect(job['status'], 'queued');
    expect(find.text('翻译已排队，稍后自动显示'), findsOneWidget);
  });

  testWidgets('dashboard hides translate button and shows translation when present',
      (tester) async {
    final db = FakeFirebaseFirestore();
    await _seed(db);
    final doc = (await db
            .collection('analyses')
            .where('tradeDate', isEqualTo: '2026-07-31')
            .get())
        .docs
        .single;
    await doc.reference.update({
      'sectionsZh': {'bull': '译文：多方核心观点（中文）'},
    });
    _tallViewport(tester);
    await tester.pumpWidget(
        _wrap(db, const TickerDashboardPage(ticker: 'ENEL.MI')));
    await tester.pumpAndSettle();

    // bull 已有译文：按钮消失、正文显示译文；bear 仍缺译文，按钮还在。
    expect(find.byKey(const Key('translate-bull')), findsNothing);
    expect(find.textContaining('译文：多方核心观点'), findsOneWidget);
    expect(find.byKey(const Key('translate-bear')), findsOneWidget);
  });

  testWidgets('detail page translate button enqueues job for that section',
      (tester) async {
    final db = FakeFirebaseFirestore();
    final a = Analysis(
      id: 'a1',
      ticker: 'NVDA',
      tradeDate: '2026-08-01',
      decision: 'Buy',
      sections: const {'market': 'Moving averages trending up.'},
      createdAt: DateTime.utc(2026, 8, 1),
    );
    await tester.pumpWidget(_wrap(db, AnalysisDetailPage(analysis: a)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('translate-market')), findsOneWidget);
    await tester.tap(find.byKey(const Key('translate-market')));
    await tester.pumpAndSettle();

    final job = (await db.collection('jobs').get()).docs.single.data();
    expect(job['type'], 'translate');
    expect(job['analysisId'], 'a1');
    expect(job['sections'], ['market']);
    expect(find.text('翻译已排队，稍后自动显示'), findsOneWidget);
  });

  testWidgets('detail page shows translation and hides button when present',
      (tester) async {
    final db = FakeFirebaseFirestore();
    final a = Analysis(
      id: 'a2',
      ticker: 'NVDA',
      tradeDate: '2026-08-01',
      decision: 'Buy',
      sections: const {'market': 'Moving averages trending up.'},
      sectionsZh: const {'market': '均线趋势向上。'},
      createdAt: DateTime.utc(2026, 8, 1),
    );
    await tester.pumpWidget(_wrap(db, AnalysisDetailPage(analysis: a)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('translate-market')), findsNothing);
    await tester.tap(find.text('市场技术面'));
    await tester.pumpAndSettle();
    expect(find.textContaining('均线趋势向上'), findsOneWidget);
    expect(find.textContaining('Moving averages'), findsNothing);
  });
}
