import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import 'analysis_detail_page.dart';
import 'widgets/pnl.dart';
import 'widgets/snapshot_list.dart';

class HistoryTab extends ConsumerStatefulWidget {
  const HistoryTab({super.key});

  @override
  ConsumerState<HistoryTab> createState() => _HistoryTabState();
}

class _HistoryTabState extends ConsumerState<HistoryTab> {
  String _segment = 'analyses';

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'analyses', label: Text(t.analysesSection)),
              ButtonSegment(value: 'suggestions', label: Text(t.suggestionsSection)),
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

/// Wraps a [SnapshotList] with a bump-the-key retry: re-invokes
/// [streamFactory] to get a fresh stream (a fresh `.snapshots()` subscription
/// for real Firestore) and forces [SnapshotList] to rebuild from scratch.
/// Kept as a tiny shared wrapper so the 3 call sites in this file behave
/// identically on retry.
class _RetryableStream<T> extends StatefulWidget {
  const _RetryableStream({
    super.key,
    required this.streamFactory,
    required this.itemBuilder,
    required this.emptyText,
  });

  final Stream<List<T>> Function() streamFactory;
  final Widget Function(BuildContext, List<T>) itemBuilder;
  final String emptyText;

  @override
  State<_RetryableStream<T>> createState() => _RetryableStreamState<T>();
}

class _RetryableStreamState<T> extends State<_RetryableStream<T>> {
  int _gen = 0;

  @override
  Widget build(BuildContext context) {
    return SnapshotList<T>(
      key: ValueKey(_gen),
      stream: widget.streamFactory(),
      itemBuilder: widget.itemBuilder,
      emptyText: widget.emptyText,
      onRetry: () => setState(() => _gen++),
    );
  }
}

class _AnalysesList extends ConsumerWidget {
  const _AnalysesList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final repo = ref.watch(repoProvider);
    return _RetryableStream<Analysis>(
      streamFactory: repo.recentAnalyses,
      emptyText: t.noAnalyses,
      itemBuilder: (context, items) => ListView(
        children: [for (final a in items) AnalysisListTile(analysis: a)],
      ),
    );
  }
}

class _SuggestionsList extends ConsumerWidget {
  const _SuggestionsList();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final repo = ref.watch(repoProvider);
    return _RetryableStream<Suggestion>(
      streamFactory: repo.allSuggestions,
      emptyText: t.noSuggestionHistory,
      itemBuilder: (context, items) => ListView(
        children: [
          for (final s in items)
            ListTile(
              title: Text('${s.ticker} · ${s.action.toUpperCase()}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (s.outcomePct != null) PnlPill(s.outcomePct!, compact: true),
                  const SizedBox(width: 6),
                  _StatusChip(status: s.status),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Outline-style status chip for a suggestion's lifecycle state:
/// accepted → green outline, dismissed → gray, pending → amber.
class _StatusChip extends ConsumerWidget {
  const _StatusChip({required this.status});
  final String status;

  Color get _color => switch (status) {
        'accepted' => const Color(0xFF34C759),
        'pending' => Colors.amber,
        _ => Colors.grey,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final label = switch (status) {
      'pending' => t.pendingStatus,
      'accepted' => t.accepted,
      'dismissed' => t.dismissed,
      _ => status,
    };
    final color = _color;
    return Chip(
      label: Text(label, style: TextStyle(color: color)),
      backgroundColor: Colors.transparent,
      side: BorderSide(color: color),
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
      title: Text('${a.ticker} · ${a.decision}', style: const TextStyle(fontWeight: FontWeight.w700)),
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
    final t = ref.watch(l10nProvider);
    final repo = ref.watch(repoProvider);
    return Scaffold(
      appBar: AppBar(title: Text(t.historyOf(ticker))),
      body: _RetryableStream<Analysis>(
        streamFactory: () => repo.analysesForTicker(ticker),
        emptyText: t.noAnalyses,
        itemBuilder: (context, items) => ListView(
          children: [for (final a in items) AnalysisListTile(analysis: a)],
        ),
      ),
    );
  }
}
