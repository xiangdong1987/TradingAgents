// app/lib/ui/analysis_detail_page.dart
/// 深度分析全文页：按固定顺序列出所有非空 section，可展开看 markdown。
/// zh 模式优先显示译文（sectionFor），缺译文的段落头部有「翻译此段」按钮。
library;

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../l10n.dart';
import '../models/models.dart';
import '../providers.dart';

List<({String key, String title})> _sectionTitles(L10n t) => [
      (key: 'market', title: t.secMarket),
      (key: 'sentiment', title: t.secSentiment),
      (key: 'news', title: t.secNews),
      (key: 'fundamentals', title: t.secFundamentals),
      (key: 'bull', title: t.secBull),
      (key: 'bear', title: t.secBear),
      (key: 'researchManager', title: t.secResearchManager),
      (key: 'traderPlan', title: t.secTraderPlan),
      (key: 'riskAggressive', title: t.secRiskAggressive),
      (key: 'riskConservative', title: t.secRiskConservative),
      (key: 'riskNeutral', title: t.secRiskNeutral),
      (key: 'portfolioDecision', title: t.secPortfolioDecision),
      (key: 'finalDecision', title: t.secFinalDecision),
    ];

/// 「翻译此段」按钮：仅当该段在当前语言下缺译文时显示；点击写一条
/// translate job，runner 写回 sectionsZh 后 Firestore 流自动刷新，按钮随
/// needsTranslation 变 false 消失。详情页与仪表盘共用。
class AnalysisTranslateButton extends ConsumerWidget {
  const AnalysisTranslateButton(
      {super.key, required this.analysis, required this.sectionKey, this.dense = false});
  final Analysis analysis;
  final String sectionKey;
  final bool dense;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final lang = ref.watch(langProvider);
    if (!analysis.needsTranslation(sectionKey, lang)) {
      return const SizedBox.shrink();
    }
    return TextButton(
      key: Key('translate-$sectionKey'),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 6),
        textStyle: TextStyle(fontSize: dense ? 11 : 12),
      ),
      onPressed: () async {
        await ref
            .read(repoProvider)
            .enqueueTranslate(analysis.id, [sectionKey]);
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(t.translationQueued)));
        }
      },
      child: Text(t.translateSection),
    );
  }
}

class AnalysisDetailPage extends ConsumerWidget {
  const AnalysisDetailPage({super.key, required this.analysis});
  final Analysis analysis;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final lang = ref.watch(langProvider);
    final a = analysis;
    return Scaffold(
      appBar: AppBar(title: Text('${a.ticker} ${a.tradeDate}')),
      body: ListView(
        children: [
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(t.decision(a.decision),
                  style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          for (final s in _sectionTitles(t))
            if (a.sectionFor(s.key, lang).isNotEmpty)
              ExpansionTile(
                title: Row(
                  children: [
                    Expanded(child: Text(s.title)),
                    AnalysisTranslateButton(analysis: a, sectionKey: s.key),
                  ],
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: MarkdownBody(data: a.sectionFor(s.key, lang)),
                  ),
                ],
              ),
        ],
      ),
    );
  }
}
