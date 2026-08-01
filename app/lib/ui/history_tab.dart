import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import 'analysis_detail_page.dart';

const _suggestionStatusLabels = <String, String>{
  'pending': '待处理', 'accepted': '已采纳', 'dismissed': '已忽略',
};

class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key});

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab> {
  String _segment = 'analyses';

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'analyses', label: Text('分析')),
              ButtonSegment(value: 'suggestions', label: Text('建议')),
            ],
            selected: {_segment},
            onSelectionChanged: (s) => setState(() => _segment = s.first),
          ),
        ),
        Expanded(
          child: _segment == 'analyses' ? const _AnalysesList() : const _SuggestionsList(),
        ),
      ],
    );
  }
}

class _AnalysesList extends ConsumerWidget {
  const _AnalysesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repoProvider);
    return StreamBuilder<List<Analysis>>(
      stream: repo.recentAnalyses(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <Analysis>[];
        if (items.isEmpty) return const Center(child: Text('还没有分析记录'));
        return ListView(
          children: [for (final a in items) AnalysisListTile(analysis: a)],
        );
      },
    );
  }
}

class _SuggestionsList extends ConsumerWidget {
  const _SuggestionsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repoProvider);
    return StreamBuilder<List<Suggestion>>(
      stream: repo.allSuggestions(),
      builder: (context, snapshot) {
        final items = snapshot.data ?? const <Suggestion>[];
        if (items.isEmpty) return const Center(child: Text('还没有建议记录'));
        return ListView(
          children: [
            for (final s in items)
              ListTile(
                title: Text('${s.ticker} · ${s.action.toUpperCase()}'),
                subtitle: s.outcomePct != null
                    ? Text('复盘 ${s.outcomePct! >= 0 ? '+' : ''}${s.outcomePct!.toStringAsFixed(1)}%')
                    : null,
                trailing: Chip(
                    label: Text(_suggestionStatusLabels[s.status] ?? s.status)),
              ),
          ],
        );
      },
    );
  }
}

/// Shared analysis row: `{ticker} · {decision}` + tradeDate, taps into detail page.
/// Reused by [HistoryTab]'s 分析 segment and [TickerAnalysesPage].
class AnalysisListTile extends StatelessWidget {
  const AnalysisListTile({super.key, required this.analysis});
  final Analysis analysis;

  @override
  Widget build(BuildContext context) {
    final a = analysis;
    return ListTile(
      title: Text('${a.ticker} · ${a.decision}'),
      subtitle: Text(a.tradeDate),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => AnalysisDetailPage(analysis: a)),
      ),
    );
  }
}

class TickerAnalysesPage extends ConsumerWidget {
  const TickerAnalysesPage({super.key, required this.ticker});
  final String ticker;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repoProvider);
    return Scaffold(
      appBar: AppBar(title: Text('$ticker 历史分析')),
      body: StreamBuilder<List<Analysis>>(
        stream: repo.analysesForTicker(ticker),
        builder: (context, snapshot) {
          final items = snapshot.data ?? const <Analysis>[];
          if (items.isEmpty) return const Center(child: Text('还没有分析记录'));
          return ListView(
            children: [for (final a in items) AnalysisListTile(analysis: a)],
          );
        },
      ),
    );
  }
}
