import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// Markdown 渲染 import 按 Task 1 选定的包调整：
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import '../models/models.dart';
import '../providers.dart';
import 'widgets/stream_error.dart';
import 'widgets/suggestion_card.dart';

class TodayTab extends ConsumerWidget {
  const TodayTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final brief = ref.watch(latestBriefProvider);
    final suggestions = ref.watch(pendingSuggestionsProvider);
    final jobs = ref.watch(activeJobsProvider);

    return ListView(
      children: [
        for (final job in jobs.value ?? const <Job>[])
          MaterialBanner(
            content: Text(job.type == 'deep_analysis'
                ? '${job.ticker} 深度分析中（${job.status == "queued" ? "排队" : "分析中"}）'
                : '日报生成中'),
            // 用静态图标而非不确定态 CircularProgressIndicator：后者的 ticker 永不停止，
            // 会导致 job 处于 running 状态时 widget 测试里的 pumpAndSettle 永远等不到静止而超时。
            leading: const Icon(Icons.sync, size: 20),
            actions: const [SizedBox.shrink()],
          ),
        brief.when(
          data: (b) => b == null
              ? const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('还没有日报。runner 会在交易日收盘后生成第一份。',
                      textAlign: TextAlign.center),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(b.date, style: Theme.of(context).textTheme.labelLarge),
                      const SizedBox(height: 8),
                      MarkdownBody(data: b.markdownZh),
                    ],
                  ),
                ),
          loading: () => const Padding(
              padding: EdgeInsets.all(32), child: Center(child: CircularProgressIndicator())),
          error: (e, _) => StreamError(error: e, onRetry: () => ref.invalidate(latestBriefProvider)),
        ),
        ...switch (suggestions) {
          AsyncData(:final value) when value.isNotEmpty => [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                child: Text('待处理建议', style: Theme.of(context).textTheme.titleMedium),
              ),
              for (final s in value)
                SuggestionCard(
                  suggestion: s,
                  onDismiss: () async {
                    await ref.read(repoProvider).resolveSuggestion(s.id, accepted: false);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context)
                          .showSnackBar(const SnackBar(content: Text('已忽略')));
                    }
                  },
                  onAccept: () => showDialog<void>(
                    context: context,
                    builder: (_) => _AcceptDialog(suggestion: s, ref: ref),
                  ),
                ),
            ],
          _ => const <Widget>[],
        },
        const SizedBox(height: 24),
      ],
    );
  }
}

class _AcceptDialog extends StatefulWidget {
  const _AcceptDialog({required this.suggestion, required this.ref});
  final Suggestion suggestion;
  final WidgetRef ref;

  @override
  State<_AcceptDialog> createState() => _AcceptDialogState();
}

class _AcceptDialogState extends State<_AcceptDialog> {
  final _shares = TextEditingController();
  final _price = TextEditingController();

  @override
  void dispose() {
    _shares.dispose();
    _price.dispose();
    super.dispose();
  }

  String get _side => switch (widget.suggestion.action) {
        'sell' || 'trim' => 'sell',
        _ => 'buy',
      };

  Future<void> _accept({required bool withTrade}) async {
    final repo = widget.ref.read(repoProvider);
    if (withTrade) {
      final shares = double.tryParse(_shares.text);
      final price = double.tryParse(_price.text);
      if (shares == null || shares <= 0 || price == null || price <= 0) return;
      final today = DateTime.now().toUtc().toIso8601String().substring(0, 10);
      // Batched write: trade doc + suggestion status flip land atomically.
      await repo.acceptWithTrade(
          suggestionId: widget.suggestion.id, ticker: widget.suggestion.ticker,
          side: _side, shares: shares, price: price, date: today);
    } else {
      await repo.resolveSuggestion(widget.suggestion.id, accepted: true);
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.suggestion;
    return AlertDialog(
      title: Text('采纳建议：${s.ticker} ${s.action.toUpperCase()}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('可顺手记录实际成交（可选）：'),
          TextField(key: const Key('tradeShares'), controller: _shares,
              decoration: const InputDecoration(labelText: '股数'),
              keyboardType: TextInputType.number),
          TextField(key: const Key('tradePrice'), controller: _price,
              decoration: const InputDecoration(labelText: '成交价'),
              keyboardType: TextInputType.number),
        ],
      ),
      actions: [
        TextButton(key: const Key('acceptOnly'),
            onPressed: () => _accept(withTrade: false), child: const Text('仅标记采纳')),
        FilledButton(key: const Key('acceptWithTrade'),
            onPressed: () => _accept(withTrade: true), child: const Text('记录成交并采纳')),
      ],
    );
  }
}
