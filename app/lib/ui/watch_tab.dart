import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import '../providers.dart';
import 'history_tab.dart';

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
                        title: Text(w.ticker),
                        subtitle: Text(_quoteLine(quotes[w.ticker])),
                        onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => TickerAnalysesPage(ticker: w.ticker))),
                        leading: ActionChip(
                          label: Text(w.deepFreq),
                          onPressed: () => ref.read(repoProvider).setDeepFreq(
                              w.ticker, w.deepFreq == 'weekly' ? 'manual' : 'weekly'),
                        ),
                        trailing: activeTickers.containsKey(w.ticker)
                            ? Chip(label: Text(
                                activeTickers[w.ticker] == 'queued' ? '排队中' : '分析中'))
                            : TextButton(
                                onPressed: () async {
                                  await ref.read(repoProvider).enqueueDeepAnalysis(w.ticker);
                                  if (context.mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                        SnackBar(content: Text('${w.ticker} 已排队')));
                                  }
                                },
                                child: const Text('分析')),
                      ),
                    ),
                ],
              ),
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('自选加载失败: $e')),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showDialog<void>(
            context: context, builder: (_) => _AddWatchDialog(ref: ref)),
        child: const Icon(Icons.add),
      ),
    );
  }

  String _quoteLine(TickerQuote? q) => q == null
      ? '—'
      : '\$${q.close.toStringAsFixed(2)}  ${q.pctChange >= 0 ? '+' : ''}${q.pctChange.toStringAsFixed(2)}%';
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
          TextField(key: const Key('watchTicker'), controller: _ticker,
              decoration: const InputDecoration(labelText: '代码（如 NVDA）'),
              textCapitalization: TextCapitalization.characters),
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
