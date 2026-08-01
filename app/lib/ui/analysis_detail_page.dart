import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/models.dart';

const _sectionTitles = <String, String>{
  'market': '市场技术面', 'sentiment': '情绪', 'news': '新闻',
  'fundamentals': '基本面', 'bull': '多方观点', 'bear': '空方观点',
  'researchManager': '研究主管结论', 'traderPlan': '交易员计划',
  'riskAggressive': '激进风控', 'riskConservative': '保守风控',
  'riskNeutral': '中性风控', 'portfolioDecision': '组合经理决定',
  'finalDecision': '最终决策',
};

class AnalysisDetailPage extends StatelessWidget {
  const AnalysisDetailPage({super.key, required this.analysis});
  final Analysis analysis;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    return Scaffold(
      appBar: AppBar(title: Text('${a.ticker} ${a.tradeDate}')),
      body: ListView(
        children: [
          Card(
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text('决策：${a.decision}', style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          for (final entry in _sectionTitles.entries)
            if (a.section(entry.key).isNotEmpty)
              ExpansionTile(
                title: Text(entry.value),
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    child: MarkdownBody(data: a.section(entry.key)),
                  ),
                ],
              ),
        ],
      ),
    );
  }
}
