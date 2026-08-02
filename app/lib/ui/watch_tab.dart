import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../logic/portfolio_math.dart' show isIsin;
import '../models/models.dart';
import '../providers.dart';
import 'ticker_dashboard_page.dart';
import 'widgets/pnl.dart';
import 'widgets/stream_error.dart';
import 'widgets/ticker_field.dart';

class WatchTab extends ConsumerWidget {
  const WatchTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final t = ref.watch(l10nProvider);
    final watch = ref.watch(watchlistProvider);
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final jobs = ref.watch(activeJobsProvider).value ?? const <Job>[];
    final activeTickers = {for (final j in jobs) if (j.ticker != null) j.ticker!: j.status};

    return Scaffold(
      body: watch.when(
        data: (items) => items.isEmpty
            ? Center(child: Text(t.watchEmpty))
            : ListView(
                children: [
                  for (final w in items)
                    Dismissible(
                      key: ValueKey(w.ticker),
                      direction: DismissDirection.endToStart,
                      background: Container(
                          color: Colors.red,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 16),
                          child: const Icon(Icons.delete, color: Colors.white)),
                      onDismissed: (_) async {
                        await ref.read(repoProvider).removeWatch(w.ticker);
                        if (context.mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text(t.deleted(w.ticker))));
                        }
                      },
                      child: ListTile(
                        title: Text(w.ticker,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        subtitle: InkWell(
                          onTap: () => ref.read(repoProvider).setDeepFreq(
                              w.ticker, w.deepFreq == 'weekly' ? 'manual' : 'weekly'),
                          child: Text(
                            w.deepFreq == 'weekly' ? t.weeklyAuto : t.manualAnalysis,
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => TickerDashboardPage(ticker: w.ticker))),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _quoteColumn(w.ticker, quotes[w.ticker]),
                            const SizedBox(width: 8),
                            isIsin(w.ticker)
                                // 单只债券没有可分析的资料面，隐藏分析入口
                                ? const SizedBox.shrink()
                                : activeTickers.containsKey(w.ticker)
                                ? Chip(label: Text(
                                    activeTickers[w.ticker] == 'queued'
                                        ? t.jobQueued : t.analyzing))
                                : FilledButton.tonal(
                                    style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact),
                                    onPressed: () async {
                                      await ref.read(repoProvider).enqueueDeepAnalysis(w.ticker);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text(t.queued(w.ticker))));
                                      }
                                    },
                                    child: Text(t.analyze)),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => StreamError(error: e, onRetry: () => ref.invalidate(watchlistProvider)),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => const _AddWatchDialog()),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _quoteColumn(String ticker, TickerQuote? q) {
    if (q == null) return const Text('—');
    return PriceWithPill(
        price: q.close, pct: q.pctChange, prefix: currencyPrefix(ticker));
  }
}

class _AddWatchDialog extends ConsumerStatefulWidget {
  const _AddWatchDialog();

  @override
  ConsumerState<_AddWatchDialog> createState() => _AddWatchDialogState();
}

class _AddWatchDialogState extends ConsumerState<_AddWatchDialog> {
  final _ticker = TextEditingController();
  String _deepFreq = 'manual';

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final t = _ticker.text.trim().toUpperCase();
    if (t.isEmpty) return;
    await ref.read(repoProvider).addWatch(t, deepFreq: _deepFreq);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final t = ref.watch(l10nProvider);
    return AlertDialog(
      title: Text(t.addWatch),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TickerField(fieldKey: const Key('watchTicker'), controller: _ticker,
              onSubmitted: _submit),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: [
              ButtonSegment(value: 'manual', label: Text(t.manualAnalysis)),
              ButtonSegment(value: 'weekly', label: Text(t.weeklyLabel)),
            ],
            selected: {_deepFreq},
            onSelectionChanged: (s) => setState(() => _deepFreq = s.first),
          ),
        ],
      ),
      actions: [
        FilledButton(
          key: const Key('watchAdd'),
          onPressed: _submit,
          child: Text(t.add),
        ),
      ],
    );
  }
}
