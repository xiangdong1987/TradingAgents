import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import 'history_tab.dart';
import 'widgets/pnl.dart';
import 'widgets/stream_error.dart';
import 'widgets/ticker_field.dart';

class WatchTab extends ConsumerWidget {
  const WatchTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final watch = ref.watch(watchlistProvider);
    final quotes = ref.watch(latestBriefProvider).value?.quotes ?? const {};
    final jobs = ref.watch(activeJobsProvider).value ?? const <Job>[];
    final activeTickers = {for (final j in jobs) if (j.ticker != null) j.ticker!: j.status};

    return Scaffold(
      body: watch.when(
        data: (items) => items.isEmpty
            ? const Center(child: Text('自选列表为空，点右下角添加'))
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
                              SnackBar(content: Text('已删除 ${w.ticker}')));
                        }
                      },
                      child: ListTile(
                        title: Text(w.ticker,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800)),
                        subtitle: InkWell(
                          onTap: () => ref.read(repoProvider).setDeepFreq(
                              w.ticker, w.deepFreq == 'weekly' ? 'manual' : 'weekly'),
                          child: Text(
                            w.deepFreq == 'weekly' ? '每周自动分析' : '手动分析',
                            style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                          ),
                        ),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => TickerAnalysesPage(ticker: w.ticker))),
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _quoteColumn(quotes[w.ticker]),
                            const SizedBox(width: 8),
                            activeTickers.containsKey(w.ticker)
                                ? Chip(label: Text(
                                    activeTickers[w.ticker] == 'queued' ? '排队中' : '分析中'))
                                : FilledButton.tonal(
                                    style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact),
                                    onPressed: () async {
                                      await ref.read(repoProvider).enqueueDeepAnalysis(w.ticker);
                                      if (context.mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                            SnackBar(content: Text('${w.ticker} 已排队')));
                                      }
                                    },
                                    child: const Text('分析')),
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
            context: context, builder: (_) => _AddWatchDialog(ref: ref)),
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _quoteColumn(TickerQuote? q) {
    if (q == null) return const Text('—');
    return PriceWithPill(price: q.close, pct: q.pctChange);
  }
}

class _AddWatchDialog extends StatefulWidget {
  const _AddWatchDialog({required this.ref});
  final WidgetRef ref;

  @override
  State<_AddWatchDialog> createState() => _AddWatchDialogState();
}

class _AddWatchDialogState extends State<_AddWatchDialog> {
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
    await widget.ref.read(repoProvider).addWatch(t, deepFreq: _deepFreq);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加自选'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TickerField(fieldKey: const Key('watchTicker'), controller: _ticker,
              onSubmitted: _submit),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'manual', label: Text('手动分析')),
              ButtonSegment(value: 'weekly', label: Text('每周分析')),
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
          child: const Text('添加'),
        ),
      ],
    );
  }
}
